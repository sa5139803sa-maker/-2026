-- Permit multiple collectors per pump and add a tenant-isolated operations log.
DROP INDEX IF EXISTS public.pump_assignments_one_collector_per_pump_idx;
CREATE INDEX IF NOT EXISTS pump_assignments_collectors_by_pump_idx
  ON public.pump_assignments (organization_id, pump_id, user_id)
  WHERE assignment_role = 'collector'::public.app_role;

CREATE UNIQUE INDEX IF NOT EXISTS subscribers_id_tenant_pump_key
  ON public.subscribers (id, organization_id, pump_id);

CREATE TABLE public.pump_operations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  subscriber_id uuid,
  subscriber_name text NOT NULL CHECK (char_length(trim(subscriber_name)) BETWEEN 2 AND 120),
  operator_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  operation_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Hebron')::date),
  planned_minutes integer NOT NULL CHECK (planned_minutes BETWEEN 1 AND 1440),
  status text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'paused', 'completed')),
  started_at timestamptz NOT NULL DEFAULT now(),
  paused_at timestamptz,
  paused_seconds integer NOT NULL DEFAULT 0 CHECK (paused_seconds >= 0),
  ended_at timestamptz,
  actual_seconds integer CHECK (actual_seconds IS NULL OR actual_seconds >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pump_operations_pump_tenant_fkey FOREIGN KEY (pump_id, organization_id)
    REFERENCES public.pumps (id, organization_id) ON DELETE RESTRICT,
  CONSTRAINT pump_operations_subscriber_scope_fkey FOREIGN KEY (subscriber_id, organization_id, pump_id)
    REFERENCES public.subscribers (id, organization_id, pump_id) ON DELETE RESTRICT,
  CONSTRAINT pump_operations_state_check CHECK (
    (status = 'running' AND paused_at IS NULL AND ended_at IS NULL AND actual_seconds IS NULL)
    OR (status = 'paused' AND paused_at IS NOT NULL AND ended_at IS NULL AND actual_seconds IS NULL)
    OR (status = 'completed' AND paused_at IS NULL AND ended_at IS NOT NULL AND actual_seconds IS NOT NULL)
  )
);

CREATE UNIQUE INDEX pump_operations_one_active_per_pump_idx
  ON public.pump_operations (pump_id) WHERE status IN ('running', 'paused');
CREATE INDEX pump_operations_org_date_pump_idx
  ON public.pump_operations (organization_id, operation_date, pump_id, started_at DESC);
CREATE INDEX pump_operations_subscriber_idx
  ON public.pump_operations (subscriber_id, operation_date) WHERE subscriber_id IS NOT NULL;

ALTER TABLE public.pump_operations ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.pump_operations TO authenticated;
GRANT INSERT (organization_id, pump_id, subscriber_id, subscriber_name, operator_id, planned_minutes)
  ON public.pump_operations TO authenticated;
GRANT UPDATE (status, paused_at, paused_seconds, ended_at, actual_seconds)
  ON public.pump_operations TO authenticated;
REVOKE ALL ON public.pump_operations FROM anon;

CREATE POLICY pump_operations_select_scoped ON public.pump_operations
  FOR SELECT TO authenticated USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = pump_operations.organization_id
          AND pa.pump_id = pump_operations.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = 'operator'::public.app_role)
    )
  );

CREATE POLICY pump_operations_insert_scoped ON public.pump_operations
  FOR INSERT TO authenticated WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND operator_id = (SELECT auth.uid())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = pump_operations.organization_id
          AND pa.pump_id = pump_operations.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = 'operator'::public.app_role)
    )
  );

CREATE POLICY pump_operations_update_scoped ON public.pump_operations
  FOR UPDATE TO authenticated USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR (operator_id = (SELECT auth.uid()) AND EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = pump_operations.organization_id
          AND pa.pump_id = pump_operations.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = 'operator'::public.app_role))
    )
  ) WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR (operator_id = (SELECT auth.uid()) AND EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = pump_operations.organization_id
          AND pa.pump_id = pump_operations.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = 'operator'::public.app_role))
    )
  );

CREATE OR REPLACE FUNCTION public.start_pump_operation(
  p_pump_id uuid, p_subscriber_id uuid, p_subscriber_name text, p_planned_minutes integer
) RETURNS public.pump_operations
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_name text;
  v_operation public.pump_operations%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR v_org_id IS NULL OR v_role NOT IN ('manager', 'operator') THEN
    RAISE EXCEPTION 'Not authorized to start pump operations' USING ERRCODE = '42501';
  END IF;
  IF p_planned_minutes IS NULL OR p_planned_minutes NOT BETWEEN 1 AND 1440 THEN
    RAISE EXCEPTION 'Planned minutes must be between 1 and 1440' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pumps p WHERE p.id = p_pump_id
    AND p.organization_id = v_org_id AND p.status = 'active') THEN
    RAISE EXCEPTION 'Pump is not active or not accessible' USING ERRCODE = '42501';
  END IF;
  IF v_role = 'operator' AND NOT EXISTS (SELECT 1 FROM public.pump_assignments pa
    WHERE pa.pump_id = p_pump_id AND pa.organization_id = v_org_id
      AND pa.user_id = auth.uid() AND pa.assignment_role = 'operator') THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump' USING ERRCODE = '42501';
  END IF;
  IF p_subscriber_id IS NOT NULL THEN
    SELECT s.full_name INTO v_name FROM public.subscribers s
    WHERE s.id = p_subscriber_id AND s.organization_id = v_org_id
      AND s.pump_id = p_pump_id AND s.is_active = true;
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
    organization_id, pump_id, subscriber_id, subscriber_name, operator_id, planned_minutes
  ) VALUES (v_org_id, p_pump_id, p_subscriber_id, v_name, auth.uid(), p_planned_minutes)
  RETURNING * INTO v_operation;
  RETURN v_operation;
END;
$$;

CREATE OR REPLACE FUNCTION public.pause_pump_operation(p_operation_id uuid)
RETURNS public.pump_operations LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE v_operation public.pump_operations%ROWTYPE;
BEGIN
  UPDATE public.pump_operations SET status = 'paused', paused_at = now()
  WHERE id = p_operation_id AND status = 'running' RETURNING * INTO v_operation;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Operation is not running or is not accessible' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_operation;
END;
$$;

CREATE OR REPLACE FUNCTION public.resume_pump_operation(p_operation_id uuid)
RETURNS public.pump_operations LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE v_operation public.pump_operations%ROWTYPE;
BEGIN
  UPDATE public.pump_operations
  SET status = 'running',
      paused_seconds = paused_seconds + GREATEST(0, floor(extract(epoch FROM (now() - paused_at)))::integer),
      paused_at = NULL
  WHERE id = p_operation_id AND status = 'paused' RETURNING * INTO v_operation;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Operation is not paused or is not accessible' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_operation;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_pump_operation(p_operation_id uuid)
RETURNS public.pump_operations LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $$
DECLARE v_operation public.pump_operations%ROWTYPE;
BEGIN
  UPDATE public.pump_operations
  SET status = 'completed',
      ended_at = now(),
      actual_seconds = GREATEST(0,
        floor(extract(epoch FROM (now() - started_at)))::integer
        - paused_seconds
        - CASE WHEN paused_at IS NULL THEN 0
          ELSE GREATEST(0, floor(extract(epoch FROM (now() - paused_at)))::integer) END),
      paused_at = NULL,
      paused_seconds = paused_seconds + CASE WHEN paused_at IS NULL THEN 0
        ELSE GREATEST(0, floor(extract(epoch FROM (now() - paused_at)))::integer) END
  WHERE id = p_operation_id AND status IN ('running', 'paused')
  RETURNING * INTO v_operation;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Operation is already completed or is not accessible' USING ERRCODE = 'P0002';
  END IF;
  RETURN v_operation;
END;
$$;

REVOKE ALL ON FUNCTION public.start_pump_operation(uuid, uuid, text, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.pause_pump_operation(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resume_pump_operation(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_pump_operation(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_pump_operation(uuid, uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.pause_pump_operation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resume_pump_operation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_pump_operation(uuid) TO authenticated;
