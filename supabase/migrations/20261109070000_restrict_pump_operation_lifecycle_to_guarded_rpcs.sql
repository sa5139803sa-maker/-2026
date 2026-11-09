-- Lifecycle transitions must only be executed through the guarded RPCs.
-- Remove direct UPDATE privileges; SECURITY DEFINER RPCs validate caller scope
-- explicitly before changing a session row.
REVOKE UPDATE ON TABLE public.pump_operations FROM authenticated;

CREATE OR REPLACE FUNCTION public.pause_pump_operation(p_operation_id uuid)
RETURNS public.pump_operations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
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
  SET status = 'paused', paused_at = now()
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

CREATE OR REPLACE FUNCTION public.resume_pump_operation(p_operation_id uuid)
RETURNS public.pump_operations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
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
      paused_at = NULL
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

CREATE OR REPLACE FUNCTION public.complete_pump_operation(p_operation_id uuid)
RETURNS public.pump_operations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
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

REVOKE ALL ON FUNCTION public.pause_pump_operation(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resume_pump_operation(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_pump_operation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pause_pump_operation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resume_pump_operation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_pump_operation(uuid) TO authenticated;
