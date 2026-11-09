
-- The mobile client must not create pump_operations rows directly.
-- All creation goes through the authenticated, tenant-scoped start RPC.
REVOKE INSERT ON TABLE public.pump_operations FROM PUBLIC, anon, authenticated;
REVOKE INSERT (
  organization_id,
  pump_id,
  subscriber_id,
  subscriber_name,
  operator_id,
  planned_minutes
) ON TABLE public.pump_operations FROM authenticated;

CREATE OR REPLACE FUNCTION water_management_private.start_pump_operation_internal(
  p_pump_id uuid,
  p_subscriber_id uuid,
  p_subscriber_name text,
  p_planned_minutes integer
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
  v_name text;
  v_operation public.pump_operations%ROWTYPE;
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to start pump operations' USING ERRCODE = '42501';
  END IF;

  IF p_planned_minutes IS NULL OR p_planned_minutes NOT BETWEEN 1 AND 1440 THEN
    RAISE EXCEPTION 'Planned minutes must be between 1 and 1440' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pumps p
    WHERE p.id = p_pump_id
      AND p.organization_id = v_org_id
      AND p.status = 'active'
  ) THEN
    RAISE EXCEPTION 'Pump is not active or not accessible' USING ERRCODE = '42501';
  END IF;

  IF v_role = 'operator'::public.app_role
     AND NOT EXISTS (
       SELECT 1 FROM public.pump_assignments pa
       WHERE pa.pump_id = p_pump_id
         AND pa.organization_id = v_org_id
         AND pa.user_id = v_user_id
         AND pa.assignment_role = 'operator'::public.app_role
     ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump' USING ERRCODE = '42501';
  END IF;

  IF p_subscriber_id IS NOT NULL THEN
    SELECT s.full_name INTO v_name
    FROM public.subscribers s
    WHERE s.id = p_subscriber_id
      AND s.organization_id = v_org_id
      AND s.pump_id = p_pump_id
      AND s.is_active = true;

    IF v_name IS NULL THEN
      RAISE EXCEPTION 'Subscriber is not active on this pump' USING ERRCODE = '22023';
    END IF;
  ELSE
    v_name := trim(COALESCE(p_subscriber_name, ''));
    IF char_length(v_name) NOT BETWEEN 2 AND 120 THEN
      RAISE EXCEPTION 'Emergency subscriber name is required' USING ERRCODE = '22023';
    END IF;
  END IF;

  INSERT INTO public.pump_operations (
    organization_id,
    pump_id,
    subscriber_id,
    subscriber_name,
    operator_id,
    planned_minutes
  ) VALUES (
    v_org_id,
    p_pump_id,
    p_subscriber_id,
    v_name,
    v_user_id,
    p_planned_minutes
  )
  RETURNING * INTO v_operation;

  RETURN v_operation;
END;
$$;

REVOKE ALL ON FUNCTION water_management_private.start_pump_operation_internal(uuid, uuid, text, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.start_pump_operation_internal(uuid, uuid, text, integer)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.start_pump_operation(
  p_pump_id uuid,
  p_subscriber_id uuid,
  p_subscriber_name text,
  p_planned_minutes integer
)
RETURNS public.pump_operations
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT water_management_private.start_pump_operation_internal(
    p_pump_id,
    p_subscriber_id,
    p_subscriber_name,
    p_planned_minutes
  )
$$;

REVOKE ALL ON FUNCTION public.start_pump_operation(uuid, uuid, text, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_pump_operation(uuid, uuid, text, integer)
  TO authenticated;
