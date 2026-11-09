-- Track electricity source usage as immutable time segments per pump operation.
-- All durations are computed from server timestamps; pause intervals are excluded.

CREATE TABLE public.pump_power_sources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 2 AND 100),
  source_type text NOT NULL CHECK (source_type IN ('solar', 'generator', 'grid', 'other')),
  is_active boolean NOT NULL DEFAULT true,
  archived_at timestamptz,
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pump_power_sources_id_tenant_pump_key UNIQUE (id, organization_id, pump_id),
  CONSTRAINT pump_power_sources_pump_scope_fkey
    FOREIGN KEY (pump_id, organization_id)
    REFERENCES public.pumps (id, organization_id) ON DELETE CASCADE,
  CONSTRAINT pump_power_sources_archive_state_check
    CHECK ((is_active AND archived_at IS NULL) OR (NOT is_active AND archived_at IS NOT NULL))
);

CREATE UNIQUE INDEX pump_power_sources_name_uidx
  ON public.pump_power_sources (organization_id, pump_id, lower(btrim(name)));
CREATE INDEX pump_power_sources_pump_active_idx
  ON public.pump_power_sources (organization_id, pump_id, is_active, lower(name));

-- Preserve historical names on segments/reports; never hard-delete a used source.
ALTER TABLE public.pump_power_sources ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pump_power_sources FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.pump_power_sources TO authenticated;
GRANT INSERT (pump_id, name, source_type)
  ON public.pump_power_sources TO authenticated;
GRANT UPDATE (name, source_type, is_active)
  ON public.pump_power_sources TO authenticated;

CREATE POLICY pump_power_sources_select_assigned
  ON public.pump_power_sources
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = pump_power_sources.organization_id
          AND pa.pump_id = pump_power_sources.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role::text = (SELECT water_management_private.current_user_role())::text
      )
    )
  );

CREATE POLICY pump_power_sources_manager_insert
  ON public.pump_power_sources
  FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    AND is_active
    AND archived_at IS NULL
    AND created_by = (SELECT auth.uid())
  );

CREATE POLICY pump_power_sources_manager_update
  ON public.pump_power_sources
  FOR UPDATE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  )
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

CREATE OR REPLACE FUNCTION water_management_private.set_pump_power_source_archive_time()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF OLD.is_active AND NOT NEW.is_active THEN
    NEW.archived_at := clock_timestamp();
  ELSIF NOT OLD.is_active AND NEW.is_active THEN
    NEW.archived_at := NULL;
  ELSE
    NEW.archived_at := OLD.archived_at;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION water_management_private.set_pump_power_source_archive_time()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER set_pump_power_source_archive_time
  BEFORE UPDATE OF is_active ON public.pump_power_sources
  FOR EACH ROW EXECUTE FUNCTION water_management_private.set_pump_power_source_archive_time();

-- Seed the three requested defaults for existing and future pumps.
INSERT INTO public.pump_power_sources (
  organization_id, pump_id, name, source_type
)
SELECT p.organization_id, p.id, seed.name, seed.source_type
FROM public.pumps p
CROSS JOIN (VALUES
  ('طاقة شمسية – مزود 1', 'solar'),
  ('مولد – مزود 3', 'generator'),
  ('طاقة شمسية – مزود 2', 'solar')
) AS seed(name, source_type)
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION water_management_private.seed_default_pump_power_sources()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.pump_power_sources (
    organization_id, pump_id, name, source_type, created_by
  ) VALUES
    (NEW.organization_id, NEW.id, 'طاقة شمسية – مزود 1', 'solar', auth.uid()),
    (NEW.organization_id, NEW.id, 'مولد – مزود 3', 'generator', auth.uid()),
    (NEW.organization_id, NEW.id, 'طاقة شمسية – مزود 2', 'solar', auth.uid())
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION water_management_private.seed_default_pump_power_sources()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER seed_default_pump_power_sources
  AFTER INSERT ON public.pumps
  FOR EACH ROW EXECUTE FUNCTION water_management_private.seed_default_pump_power_sources();

CREATE TABLE public.pump_operation_power_segments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  power_source_id uuid NOT NULL,
  source_name_snapshot text NOT NULL
    CHECK (char_length(btrim(source_name_snapshot)) BETWEEN 2 AND 100),
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  started_at timestamptz NOT NULL,
  ended_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pump_operation_power_segments_operation_scope_fkey
    FOREIGN KEY (operation_id, organization_id, pump_id)
    REFERENCES public.pump_operations (id, organization_id, pump_id) ON DELETE RESTRICT,
  CONSTRAINT pump_operation_power_segments_source_scope_fkey
    FOREIGN KEY (power_source_id, organization_id, pump_id)
    REFERENCES public.pump_power_sources (id, organization_id, pump_id) ON DELETE RESTRICT,
  CONSTRAINT pump_operation_power_segments_time_check
    CHECK (ended_at IS NULL OR ended_at > started_at)
);

CREATE UNIQUE INDEX pump_operation_power_segments_one_open_per_operation_uidx
  ON public.pump_operation_power_segments (operation_id)
  WHERE ended_at IS NULL;
CREATE INDEX pump_operation_power_segments_pump_time_idx
  ON public.pump_operation_power_segments (organization_id, pump_id, started_at, ended_at);
CREATE INDEX pump_operation_power_segments_source_time_idx
  ON public.pump_operation_power_segments (power_source_id, started_at, ended_at);

ALTER TABLE public.pump_operations
  ADD COLUMN current_power_source_id uuid,
  ADD COLUMN last_power_source_id uuid;

ALTER TABLE public.pump_operations
  ADD CONSTRAINT pump_operations_current_power_source_scope_fkey
  FOREIGN KEY (current_power_source_id, organization_id, pump_id)
  REFERENCES public.pump_power_sources (id, organization_id, pump_id) ON DELETE RESTRICT;

ALTER TABLE public.pump_operations
  ADD CONSTRAINT pump_operations_last_power_source_scope_fkey
  FOREIGN KEY (last_power_source_id, organization_id, pump_id)
  REFERENCES public.pump_power_sources (id, organization_id, pump_id) ON DELETE RESTRICT;

COMMENT ON COLUMN public.pump_operations.current_power_source_id IS
  'Power source currently active for the operation; NULL while paused or completed.';
COMMENT ON COLUMN public.pump_operations.last_power_source_id IS
  'Most recently selected source, retained while paused so the operator can confirm or change it on resume.';

ALTER TABLE public.pump_operation_power_segments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pump_operation_power_segments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.pump_operation_power_segments TO authenticated;

CREATE POLICY pump_operation_power_segments_select_scoped
  ON public.pump_operation_power_segments
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = pump_operation_power_segments.organization_id
          AND pa.pump_id = pump_operation_power_segments.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role::text IN ('operator', 'supervisor')
      )
    )
  );

-- Retire the old start/resume signatures so callers cannot bypass source selection.
DROP FUNCTION public.start_pump_operation(uuid, uuid, text, integer);
DROP FUNCTION water_management_private.start_pump_operation_internal(uuid, uuid, text, integer);
DROP FUNCTION public.resume_pump_operation(uuid);
DROP FUNCTION water_management_private.resume_pump_operation_internal(uuid);

CREATE OR REPLACE FUNCTION water_management_private.start_pump_operation_internal(
  p_pump_id uuid,
  p_subscriber_id uuid,
  p_subscriber_name text,
  p_planned_minutes integer,
  p_power_source_id uuid
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
  v_source_name text;
  v_now timestamptz := clock_timestamp();
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
    WHERE p.id = p_pump_id AND p.organization_id = v_org_id AND p.status = 'active'
  ) THEN
    RAISE EXCEPTION 'Pump is not active or not accessible' USING ERRCODE = '42501';
  END IF;
  IF v_role = 'operator'::public.app_role AND NOT EXISTS (
    SELECT 1 FROM public.pump_assignments pa
    WHERE pa.pump_id = p_pump_id AND pa.organization_id = v_org_id
      AND pa.user_id = v_user_id AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump' USING ERRCODE = '42501';
  END IF;
  SELECT s.name INTO v_source_name
  FROM public.pump_power_sources s
  WHERE s.id = p_power_source_id
    AND s.organization_id = v_org_id
    AND s.pump_id = p_pump_id
    AND s.is_active;
  IF v_source_name IS NULL THEN
    RAISE EXCEPTION 'Select an active power source for this pump' USING ERRCODE = '22023';
  END IF;

  IF p_subscriber_id IS NOT NULL THEN
    SELECT s.full_name INTO v_name
    FROM public.subscribers s
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
    organization_id, pump_id, subscriber_id, subscriber_name, operator_id,
    operation_date, planned_minutes, started_at, current_power_source_id, last_power_source_id
  ) VALUES (
    v_org_id, p_pump_id, p_subscriber_id, v_name, v_user_id,
    (v_now AT TIME ZONE 'Asia/Hebron')::date, p_planned_minutes, v_now,
    p_power_source_id, p_power_source_id
  )
  RETURNING * INTO v_operation;

  INSERT INTO public.pump_operation_power_segments (
    organization_id, pump_id, operation_id, power_source_id,
    source_name_snapshot, actor_id, started_at
  ) VALUES (
    v_org_id, p_pump_id, v_operation.id, p_power_source_id,
    v_source_name, v_user_id, v_now
  );
  RETURN v_operation;
END;
$$;

REVOKE ALL ON FUNCTION water_management_private.start_pump_operation_internal(uuid, uuid, text, integer, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.start_pump_operation_internal(uuid, uuid, text, integer, uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.start_pump_operation(
  p_pump_id uuid,
  p_subscriber_id uuid,
  p_subscriber_name text,
  p_planned_minutes integer,
  p_power_source_id uuid
)
RETURNS public.pump_operations
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT water_management_private.start_pump_operation_internal(
    p_pump_id, p_subscriber_id, p_subscriber_name, p_planned_minutes, p_power_source_id
  )
$$;
REVOKE ALL ON FUNCTION public.start_pump_operation(uuid, uuid, text, integer, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_pump_operation(uuid, uuid, text, integer, uuid)
  TO authenticated;

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
  v_now timestamptz := clock_timestamp();
  v_operation public.pump_operations%ROWTYPE;
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL OR v_role NOT IN ('manager', 'operator') THEN
    RAISE EXCEPTION 'Not authorized to control pump operations' USING ERRCODE = '42501';
  END IF;
  IF char_length(v_reason) NOT BETWEEN 2 AND 240 THEN
    RAISE EXCEPTION 'Pause reason must contain between 2 and 240 characters' USING ERRCODE = '22023';
  END IF;

  UPDATE public.pump_operations op
  SET status = 'paused', paused_at = v_now, pause_reason = v_reason,
      current_power_source_id = NULL
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

  UPDATE public.pump_operation_power_segments
  SET ended_at = v_now
  WHERE operation_id = v_operation.id AND ended_at IS NULL;
  RETURN v_operation;
END;
$$;

CREATE OR REPLACE FUNCTION water_management_private.resume_pump_operation_internal(
  p_operation_id uuid,
  p_power_source_id uuid
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
  v_source_name text;
  v_now timestamptz := clock_timestamp();
  v_operation public.pump_operations%ROWTYPE;
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL OR v_role NOT IN ('manager', 'operator') THEN
    RAISE EXCEPTION 'Not authorized to control pump operations' USING ERRCODE = '42501';
  END IF;

  UPDATE public.pump_operations op
  SET status = 'running',
      paused_seconds = op.paused_seconds
        + GREATEST(0, floor(extract(epoch FROM (v_now - op.paused_at)))::integer),
      paused_at = NULL,
      pause_reason = NULL,
      current_power_source_id = p_power_source_id,
      last_power_source_id = p_power_source_id
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

  SELECT s.name INTO v_source_name
  FROM public.pump_power_sources s
  WHERE s.id = p_power_source_id
    AND s.organization_id = v_operation.organization_id
    AND s.pump_id = v_operation.pump_id
    AND s.is_active;
  IF v_source_name IS NULL THEN
    RAISE EXCEPTION 'Select an active power source for this pump' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.pump_operation_power_segments (
    organization_id, pump_id, operation_id, power_source_id,
    source_name_snapshot, actor_id, started_at
  ) VALUES (
    v_operation.organization_id, v_operation.pump_id, v_operation.id, p_power_source_id,
    v_source_name, v_user_id, v_now
  );
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
  v_now timestamptz := clock_timestamp();
  v_operation public.pump_operations%ROWTYPE;
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL OR v_role NOT IN ('manager', 'operator') THEN
    RAISE EXCEPTION 'Not authorized to control pump operations' USING ERRCODE = '42501';
  END IF;

  UPDATE public.pump_operations op
  SET status = 'completed',
      ended_at = v_now,
      actual_seconds = GREATEST(
        0,
        floor(extract(epoch FROM (v_now - op.started_at))::integer)
        - op.paused_seconds
        - CASE WHEN op.paused_at IS NULL THEN 0
               ELSE GREATEST(0, floor(extract(epoch FROM (v_now - op.paused_at)))::integer)
          END
      ),
      paused_at = NULL,
      pause_reason = NULL,
      current_power_source_id = NULL,
      paused_seconds = op.paused_seconds
        + CASE WHEN op.paused_at IS NULL THEN 0
               ELSE GREATEST(0, floor(extract(epoch FROM (v_now - op.paused_at)))::integer)
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

  UPDATE public.pump_operation_power_segments
  SET ended_at = v_now
  WHERE operation_id = v_operation.id AND ended_at IS NULL;
  RETURN v_operation;
END;
$$;

REVOKE ALL ON FUNCTION water_management_private.pause_pump_operation_internal(uuid, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION water_management_private.resume_pump_operation_internal(uuid, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION water_management_private.complete_pump_operation_internal(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.pause_pump_operation_internal(uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION water_management_private.resume_pump_operation_internal(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION water_management_private.complete_pump_operation_internal(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.resume_pump_operation(
  p_operation_id uuid,
  p_power_source_id uuid
)
RETURNS public.pump_operations
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT water_management_private.resume_pump_operation_internal(p_operation_id, p_power_source_id)
$$;
REVOKE ALL ON FUNCTION public.resume_pump_operation(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resume_pump_operation(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_pump_power_usage(
  p_from date,
  p_to date,
  p_period text DEFAULT 'day',
  p_pump_id uuid DEFAULT NULL
)
RETURNS TABLE (
  pump_id uuid,
  period_start date,
  power_source_id uuid,
  power_source_name text,
  total_seconds bigint,
  total_minutes numeric,
  data_source text
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT * FROM water_management_private.get_pump_power_usage_internal(p_from, p_to, p_period, p_pump_id)
$$;

CREATE OR REPLACE FUNCTION water_management_private.get_pump_power_usage_internal(
  p_from date,
  p_to date,
  p_period text,
  p_pump_id uuid
)
RETURNS TABLE (
  pump_id uuid,
  period_start date,
  power_source_id uuid,
  power_source_name text,
  total_seconds bigint,
  total_minutes numeric,
  data_source text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role, 'supervisor'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to view power usage' USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to OR p_to - p_from > 366 THEN
    RAISE EXCEPTION 'Invalid power usage date range' USING ERRCODE = '22023';
  END IF;
  IF p_period NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'Power usage period must be day, week, or month' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH raw_days AS (
    SELECT seg.pump_id,
           seg.power_source_id,
           seg.source_name_snapshot,
           local_day::date AS work_day,
           GREATEST(
             0,
             floor(extract(epoch FROM (
               LEAST(COALESCE(seg.ended_at, clock_timestamp()), ((local_day::date + 1)::timestamp AT TIME ZONE 'Asia/Hebron'))
               - GREATEST(seg.started_at, (local_day::date::timestamp AT TIME ZONE 'Asia/Hebron'))
             )))::bigint
           ) AS seconds
    FROM public.pump_operation_power_segments seg
    CROSS JOIN LATERAL generate_series(
      (seg.started_at AT TIME ZONE 'Asia/Hebron')::date::timestamp,
      (COALESCE(seg.ended_at, clock_timestamp()) AT TIME ZONE 'Asia/Hebron')::date::timestamp,
      interval '1 day'
    ) AS local_day
    WHERE seg.organization_id = v_org_id
      AND (p_pump_id IS NULL OR seg.pump_id = p_pump_id)
  ),
  automatic_days AS (
    SELECT r.pump_id, r.power_source_id, r.source_name_snapshot AS source_name,
           r.work_day, sum(r.seconds)::bigint AS seconds, 'automatic'::text AS data_source
    FROM raw_days r
    WHERE r.work_day BETWEEN p_from AND p_to
      AND r.seconds > 0
      AND (
        v_role = 'manager'
        OR EXISTS (
          SELECT 1 FROM public.pump_assignments pa
          WHERE pa.organization_id = v_org_id AND pa.pump_id = r.pump_id
            AND pa.user_id = v_user_id
            AND pa.assignment_role::text = v_role::text
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.daily_work_reports report
        WHERE report.organization_id = v_org_id
          AND report.pump_id = r.pump_id
          AND report.work_date = r.work_day
          AND report.status = 'submitted'
      )
    GROUP BY r.pump_id, r.power_source_id, r.source_name_snapshot, r.work_day
  ),
  submitted_days AS (
    SELECT report.pump_id, totals.power_source_id, totals.source_name_snapshot AS source_name,
           report.work_date, (totals.minutes::bigint * 60) AS seconds,
           'daily_survey'::text AS data_source
    FROM public.daily_work_reports report
    JOIN public.daily_work_source_totals totals
      ON totals.daily_work_report_id = report.id
     AND totals.organization_id = report.organization_id
     AND totals.pump_id = report.pump_id
    WHERE report.organization_id = v_org_id
      AND report.status = 'submitted'
      AND report.work_date BETWEEN p_from AND p_to
      AND (p_pump_id IS NULL OR report.pump_id = p_pump_id)
      AND (
        v_role = 'manager'
        OR EXISTS (
          SELECT 1 FROM public.pump_assignments pa
          WHERE pa.organization_id = v_org_id AND pa.pump_id = report.pump_id
            AND pa.user_id = v_user_id
            AND pa.assignment_role::text = v_role::text
        )
      )
  ),
  all_days AS (
    SELECT * FROM automatic_days
    UNION ALL
    SELECT * FROM submitted_days
  ),
  buckets AS (
    SELECT d.*,
           CASE
             WHEN p_period = 'day' THEN d.work_day
             WHEN p_period = 'month' THEN date_trunc('month', d.work_day::timestamp)::date
             ELSE d.work_day - (
               (extract(isodow FROM d.work_day)::integer
                 - COALESCE(schedule_week.week_starts_on, 1) + 7) % 7
             )
           END AS bucket_start
    FROM all_days d
    LEFT JOIN LATERAL (
      SELECT ws.week_starts_on
      FROM public.weekly_schedules ws
      WHERE ws.organization_id = v_org_id
        AND ws.pump_id = d.pump_id
        AND ws.status = 'active'
        AND d.work_day >= ws.effective_from
        AND (ws.effective_to IS NULL OR d.work_day <= ws.effective_to)
      ORDER BY ws.effective_from DESC
      LIMIT 1
    ) schedule_week ON true
  )
  SELECT b.pump_id, b.bucket_start, b.power_source_id, b.source_name,
         sum(b.seconds)::bigint,
         round(sum(b.seconds)::numeric / 60, 2),
         b.data_source
  FROM buckets b
  GROUP BY b.pump_id, b.bucket_start, b.power_source_id, b.source_name, b.data_source
  ORDER BY b.pump_id, b.bucket_start, b.source_name;
END;
$$;

REVOKE ALL ON FUNCTION water_management_private.get_pump_power_usage_internal(date, date, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.get_pump_power_usage_internal(date, date, text, uuid)
  TO authenticated;
REVOKE ALL ON FUNCTION public.get_pump_power_usage(date, date, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pump_power_usage(date, date, text, uuid)
  TO authenticated;

COMMENT ON TABLE public.pump_power_sources IS
  'Per-pump electricity source catalog. Default sources are seeded for each pump; used sources are archived rather than deleted.';
COMMENT ON TABLE public.pump_operation_power_segments IS
  'Server-timestamped power source intervals for a pump operation. Paused periods are excluded by closing each segment.';
