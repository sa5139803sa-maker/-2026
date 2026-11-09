
-- Preserve the operational timeline as append-only events. pump_operations is
-- the current materialized session state; this ledger is the audit timeline.
ALTER TABLE public.pump_operations
  ADD COLUMN IF NOT EXISTS pause_reason text;

ALTER TABLE public.pump_operations
  DROP CONSTRAINT IF EXISTS pump_operations_pause_reason_state_check;

ALTER TABLE public.pump_operations
  ADD CONSTRAINT pump_operations_pause_reason_state_check CHECK (
    (status = 'paused' AND pause_reason IS NOT NULL
      AND char_length(trim(pause_reason)) BETWEEN 2 AND 240)
    OR (status IN ('running', 'completed') AND pause_reason IS NULL)
  );

CREATE UNIQUE INDEX IF NOT EXISTS pump_operations_id_tenant_pump_key
  ON public.pump_operations (id, organization_id, pump_id);

CREATE TABLE public.pump_operation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('started', 'paused', 'resumed', 'completed')),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  reason text,
  device_id uuid,
  client_event_id uuid,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT pump_operation_events_operation_scope_fkey
    FOREIGN KEY (operation_id, organization_id, pump_id)
    REFERENCES public.pump_operations (id, organization_id, pump_id)
    ON DELETE RESTRICT,
  CONSTRAINT pump_operation_events_reason_check
    CHECK (reason IS NULL OR char_length(trim(reason)) BETWEEN 2 AND 240)
);

CREATE INDEX pump_operation_events_operation_time_idx
  ON public.pump_operation_events (operation_id, occurred_at, id);
CREATE INDEX pump_operation_events_org_time_idx
  ON public.pump_operation_events (organization_id, occurred_at DESC);
CREATE INDEX pump_operation_events_pump_time_idx
  ON public.pump_operation_events (pump_id, occurred_at DESC);
CREATE UNIQUE INDEX pump_operation_events_client_event_uidx
  ON public.pump_operation_events (organization_id, client_event_id)
  WHERE client_event_id IS NOT NULL;

ALTER TABLE public.pump_operation_events ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.pump_operation_events TO authenticated;
REVOKE ALL ON public.pump_operation_events FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE ON public.pump_operation_events FROM authenticated;

CREATE POLICY pump_operation_events_select_scoped
  ON public.pump_operation_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = pump_operation_events.organization_id
          AND pa.pump_id = pump_operation_events.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = 'operator'::public.app_role
      )
    )
  );

CREATE OR REPLACE FUNCTION water_management_private.capture_pump_operation_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_event_type text;
  v_reason text;
  v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Operation events require an authenticated actor' USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_event_type := 'started';
    v_reason := NULL;
  ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
    v_event_type := CASE
      WHEN OLD.status = 'running' AND NEW.status = 'paused' THEN 'paused'
      WHEN OLD.status = 'paused' AND NEW.status = 'running' THEN 'resumed'
      WHEN OLD.status IN ('running', 'paused') AND NEW.status = 'completed' THEN 'completed'
      ELSE NULL
    END;
    v_reason := CASE
      WHEN v_event_type = 'paused' THEN NEW.pause_reason
      WHEN v_event_type IN ('resumed', 'completed') THEN OLD.pause_reason
      ELSE NULL
    END;
  ELSE
    RETURN NEW;
  END IF;

  IF v_event_type IS NULL THEN
    RAISE EXCEPTION 'Unsupported pump operation state transition' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.pump_operation_events (
    organization_id, pump_id, operation_id, actor_id,
    event_type, occurred_at, reason, metadata
  ) VALUES (
    NEW.organization_id, NEW.pump_id, NEW.id, v_actor_id,
    v_event_type, now(), v_reason,
    jsonb_build_object(
      'from_status', CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END,
      'to_status', NEW.status
    )
  );

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION water_management_private.capture_pump_operation_event() FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS pump_operations_capture_insert_event ON public.pump_operations;
CREATE TRIGGER pump_operations_capture_insert_event
AFTER INSERT ON public.pump_operations
FOR EACH ROW
EXECUTE FUNCTION water_management_private.capture_pump_operation_event();

DROP TRIGGER IF EXISTS pump_operations_capture_state_event ON public.pump_operations;
CREATE TRIGGER pump_operations_capture_state_event
AFTER UPDATE OF status ON public.pump_operations
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION water_management_private.capture_pump_operation_event();

-- Replace pause RPC with a reason-required lifecycle call.
DROP FUNCTION IF EXISTS public.pause_pump_operation(uuid);
DROP FUNCTION IF EXISTS water_management_private.pause_pump_operation_internal(uuid);

CREATE OR REPLACE FUNCTION water_management_private.pause_pump_operation_internal(
  p_operation_id uuid,
  p_reason text
)
RETURNS public.pump_operations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_reason text := trim(COALESCE(p_reason, ''));
  v_operation public.pump_operations%ROWTYPE;
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL OR v_role NOT IN ('manager', 'operator') THEN
    RAISE EXCEPTION 'Not authorized to control pump operations' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_reason) NOT BETWEEN 2 AND 240 THEN
    RAISE EXCEPTION 'Pause reason must contain between 2 and 240 characters' USING ERRCODE = '22023';
  END IF;

  UPDATE public.pump_operations op
  SET status = 'paused', paused_at = now(), pause_reason = v_reason
  WHERE op.id = p_operation_id AND op.organization_id = v_org_id
    AND op.status = 'running'
    AND (v_role = 'manager' OR (
      op.operator_id = v_user_id AND EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = v_org_id AND pa.pump_id = op.pump_id
          AND pa.user_id = v_user_id AND pa.assignment_role = 'operator'::public.app_role
      )
    ))
  RETURNING op.* INTO v_operation;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Operation is not running or is not accessible' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_operation;
END;
$$;

REVOKE ALL ON FUNCTION water_management_private.pause_pump_operation_internal(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.pause_pump_operation_internal(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.pause_pump_operation(
  p_operation_id uuid,
  p_reason text
)
RETURNS public.pump_operations
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT water_management_private.pause_pump_operation_internal(p_operation_id, p_reason)
$$;

REVOKE ALL ON FUNCTION public.pause_pump_operation(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pause_pump_operation(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION water_management_private.resume_pump_operation_internal(p_operation_id uuid)
RETURNS public.pump_operations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_operation public.pump_operations%ROWTYPE;
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL OR v_role NOT IN ('manager', 'operator') THEN
    RAISE EXCEPTION 'Not authorized to control pump operations' USING ERRCODE = '42501';
  END IF;

  UPDATE public.pump_operations op
  SET status = 'running',
      paused_seconds = op.paused_seconds
        + GREATEST(0, floor(extract(epoch FROM (now() - op.paused_at)))::integer),
      paused_at = NULL,
      pause_reason = NULL
  WHERE op.id = p_operation_id AND op.organization_id = v_org_id
    AND op.status = 'paused'
    AND (v_role = 'manager' OR (
      op.operator_id = v_user_id AND EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = v_org_id AND pa.pump_id = op.pump_id
          AND pa.user_id = v_user_id AND pa.assignment_role = 'operator'::public.app_role
      )
    ))
  RETURNING op.* INTO v_operation;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Operation is not paused or is not accessible' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_operation;
END;
$$;

CREATE OR REPLACE FUNCTION water_management_private.complete_pump_operation_internal(p_operation_id uuid)
RETURNS public.pump_operations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_operation public.pump_operations%ROWTYPE;
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL OR v_role NOT IN ('manager', 'operator') THEN
    RAISE EXCEPTION 'Not authorized to control pump operations' USING ERRCODE = '42501';
  END IF;

  UPDATE public.pump_operations op
  SET status = 'completed',
      ended_at = now(),
      actual_seconds = GREATEST(
        0,
        floor(extract(epoch FROM (now() - op.started_at)))::integer
        - op.paused_seconds
        - CASE WHEN op.paused_at IS NULL THEN 0
               ELSE GREATEST(0, floor(extract(epoch FROM (now() - op.paused_at)))::integer)
          END
      ),
      paused_at = NULL,
      pause_reason = NULL,
      paused_seconds = op.paused_seconds
        + CASE WHEN op.paused_at IS NULL THEN 0
               ELSE GREATEST(0, floor(extract(epoch FROM (now() - op.paused_at)))::integer)
          END
  WHERE op.id = p_operation_id AND op.organization_id = v_org_id
    AND op.status IN ('running', 'paused')
    AND (v_role = 'manager' OR (
      op.operator_id = v_user_id AND EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = v_org_id AND pa.pump_id = op.pump_id
          AND pa.user_id = v_user_id AND pa.assignment_role = 'operator'::public.app_role
      )
    ))
  RETURNING op.* INTO v_operation;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Operation is already completed or is not accessible' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_operation;
END;
$$;

REVOKE ALL ON FUNCTION water_management_private.resume_pump_operation_internal(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION water_management_private.complete_pump_operation_internal(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.resume_pump_operation_internal(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION water_management_private.complete_pump_operation_internal(uuid) TO authenticated;
