-- Extend an active filling session without creating a second queue item.
-- Every extension changes the current target and appends an immutable audit event.
ALTER TABLE public.pump_operation_events
  ADD CONSTRAINT pump_operation_events_event_type_check
  CHECK (event_type IN ('started', 'paused', 'resumed', 'completed', 'time_extended'));

CREATE OR REPLACE FUNCTION water_management_private.extend_pump_operation_time_internal(
  p_operation_id uuid,
  p_added_minutes integer
)
RETURNS public.pump_operations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $extend_pump_operation_time_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_operation public.pump_operations%ROWTYPE;
  v_before_minutes integer;
  v_after_minutes integer;
  v_event_sequence bigint;
  v_now timestamptz;
BEGIN
  IF v_user_id IS NULL
     OR v_organization_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to extend pump operations'
      USING ERRCODE = '42501';
  END IF;

  IF p_added_minutes IS NULL OR p_added_minutes NOT BETWEEN 1 AND 1440 THEN
    RAISE EXCEPTION 'Added minutes must be a positive whole number no greater than 1440'
      USING ERRCODE = '22023';
  END IF;

  -- Serialize concurrent extensions and lifecycle transitions on this session.
  SELECT op.* INTO v_operation
  FROM public.pump_operations op
  WHERE op.id = p_operation_id
    AND op.organization_id = v_organization_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Operation is not active or is not accessible'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_operation.status NOT IN ('running', 'paused') THEN
    RAISE EXCEPTION 'Only a running or paused operation can be extended'
      USING ERRCODE = 'P0002';
  END IF;

  -- Stamp the event after acquiring the row lock so event time follows its sequence.
  v_now := clock_timestamp();

  IF v_role = 'operator'::public.app_role
     AND (
       v_operation.operator_id IS DISTINCT FROM v_user_id
       OR NOT EXISTS (
         SELECT 1
         FROM public.pump_assignments pa
         WHERE pa.organization_id = v_organization_id
           AND pa.pump_id = v_operation.pump_id
           AND pa.user_id = v_user_id
           AND pa.assignment_role = 'operator'::public.app_role
       )
     ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this active operation'
      USING ERRCODE = '42501';
  END IF;

  v_before_minutes := v_operation.planned_minutes;
  v_after_minutes := v_before_minutes + p_added_minutes;

  IF v_after_minutes > 1440 THEN
    RAISE EXCEPTION 'The total planned duration cannot exceed 1440 minutes'
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.pump_operations
  SET planned_minutes = v_after_minutes
  WHERE id = v_operation.id
  RETURNING * INTO v_operation;

  -- The operation row lock also serializes this event sequence against the
  -- lifecycle trigger, which appends events while the same row is locked.
  SELECT COALESCE(max(e.event_sequence), 0) + 1
  INTO v_event_sequence
  FROM public.pump_operation_events e
  WHERE e.operation_id = v_operation.id;

  INSERT INTO public.pump_operation_events (
    organization_id,
    pump_id,
    operation_id,
    actor_id,
    event_type,
    occurred_at,
    event_sequence,
    metadata
  ) VALUES (
    v_operation.organization_id,
    v_operation.pump_id,
    v_operation.id,
    v_user_id,
    'time_extended',
    v_now,
    v_event_sequence,
    jsonb_build_object(
      'added_minutes', p_added_minutes,
      'planned_minutes_before', v_before_minutes,
      'planned_minutes_after', v_after_minutes,
      'operation_status', v_operation.status
    )
  );

  RETURN v_operation;
END;
$extend_pump_operation_time_internal$;

REVOKE ALL ON FUNCTION water_management_private.extend_pump_operation_time_internal(uuid, integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.extend_pump_operation_time_internal(uuid, integer)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.extend_pump_operation_time(
  p_operation_id uuid,
  p_added_minutes integer
)
RETURNS public.pump_operations
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $extend_pump_operation_time_rpc$
  SELECT water_management_private.extend_pump_operation_time_internal(
    p_operation_id, p_added_minutes
  )
$extend_pump_operation_time_rpc$;

REVOKE ALL ON FUNCTION public.extend_pump_operation_time(uuid, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.extend_pump_operation_time(uuid, integer)
  TO authenticated;

COMMENT ON FUNCTION public.extend_pump_operation_time(uuid, integer) IS
  'Adds whole minutes to a running or paused operation, subject to a 24-hour total cap; each extension is appended to the immutable operation event ledger.';
