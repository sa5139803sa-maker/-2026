-- End-of-day survey records work that happened outside the app without
-- manufacturing pump_operations rows. Submitted source totals supersede
-- automatic segments for the same pump/date in aggregate reports.

CREATE TABLE public.daily_work_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  work_date date NOT NULL,
  operator_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  work_started_at timestamptz NOT NULL,
  work_ended_at timestamptz NOT NULL,
  stoppage_minutes integer NOT NULL DEFAULT 0 CHECK (stoppage_minutes >= 0),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'submitted')),
  submitted_at timestamptz,
  submitted_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  revision integer NOT NULL DEFAULT 1 CHECK (revision > 0),
  CONSTRAINT daily_work_reports_id_tenant_pump_key UNIQUE (id, organization_id, pump_id),
  CONSTRAINT daily_work_reports_pump_scope_fkey
    FOREIGN KEY (pump_id, organization_id)
    REFERENCES public.pumps (id, organization_id) ON DELETE CASCADE,
  CONSTRAINT daily_work_reports_date_scope_check CHECK (
    work_date = (work_started_at AT TIME ZONE 'Asia/Hebron')::date
    AND work_date = (work_ended_at AT TIME ZONE 'Asia/Hebron')::date
    AND work_ended_at > work_started_at
    AND stoppage_minutes <= floor(extract(epoch FROM (work_ended_at - work_started_at)) / 60)::integer
  ),
  CONSTRAINT daily_work_reports_submit_state_check CHECK (
    (status = 'draft' AND submitted_at IS NULL AND submitted_by IS NULL)
    OR (status = 'submitted' AND submitted_at IS NOT NULL AND submitted_by IS NOT NULL)
  ),
  CONSTRAINT daily_work_reports_pump_date_uidx UNIQUE (organization_id, pump_id, work_date)
);

CREATE INDEX daily_work_reports_org_date_idx
  ON public.daily_work_reports (organization_id, work_date DESC, pump_id);
CREATE INDEX daily_work_reports_operator_date_idx
  ON public.daily_work_reports (operator_id, work_date DESC);

CREATE TABLE public.daily_work_source_totals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  daily_work_report_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  power_source_id uuid NOT NULL,
  source_name_snapshot text NOT NULL
    CHECK (char_length(btrim(source_name_snapshot)) BETWEEN 2 AND 100),
  minutes integer NOT NULL CHECK (minutes > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT daily_work_source_totals_report_source_uidx UNIQUE (daily_work_report_id, power_source_id),
  CONSTRAINT daily_work_source_totals_report_scope_fkey
    FOREIGN KEY (daily_work_report_id, organization_id, pump_id)
    REFERENCES public.daily_work_reports (id, organization_id, pump_id) ON DELETE CASCADE,
  CONSTRAINT daily_work_source_totals_source_scope_fkey
    FOREIGN KEY (power_source_id, organization_id, pump_id)
    REFERENCES public.pump_power_sources (id, organization_id, pump_id) ON DELETE RESTRICT
);

CREATE INDEX daily_work_source_totals_source_idx
  ON public.daily_work_source_totals (power_source_id, daily_work_report_id);

CREATE TABLE public.daily_work_report_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  daily_work_report_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  schedule_entry_id uuid REFERENCES public.schedule_entries(id) ON DELETE RESTRICT,
  subscriber_id uuid REFERENCES public.subscribers(id) ON DELETE RESTRICT,
  subscriber_name_snapshot text,
  external_beneficiary_name text,
  entry_type text NOT NULL CHECK (entry_type IN ('weekly', 'additional_registered', 'additional_guest')),
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  scheduled_minutes integer NOT NULL DEFAULT 0 CHECK (scheduled_minutes >= 0),
  app_recorded_minutes integer NOT NULL DEFAULT 0 CHECK (app_recorded_minutes >= 0),
  manual_minutes integer NOT NULL DEFAULT 0 CHECK (manual_minutes >= 0),
  extra_minutes integer NOT NULL DEFAULT 0 CHECK (extra_minutes >= 0),
  weekly_minutes_consumed integer GENERATED ALWAYS AS (
    LEAST(scheduled_minutes, app_recorded_minutes + manual_minutes)
  ) STORED,
  app_over_quota_minutes integer GENERATED ALWAYS AS (
    GREATEST(0, app_recorded_minutes + manual_minutes - scheduled_minutes)
  ) STORED,
  fulfillment_status text GENERATED ALWAYS AS (
    CASE
      WHEN entry_type <> 'weekly' THEN 'additional'
      WHEN app_recorded_minutes + manual_minutes = 0 THEN 'not_done'
      WHEN app_recorded_minutes + manual_minutes >= scheduled_minutes THEN 'complete'
      ELSE 'partial'
    END
  ) STORED,
  note text CHECK (note IS NULL OR char_length(note) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT daily_work_report_items_report_scope_fkey
    FOREIGN KEY (daily_work_report_id, organization_id, pump_id)
    REFERENCES public.daily_work_reports (id, organization_id, pump_id) ON DELETE CASCADE,
  CONSTRAINT daily_work_report_items_schedule_uidx UNIQUE (daily_work_report_id, schedule_entry_id),
  CONSTRAINT daily_work_report_items_order_uidx UNIQUE (daily_work_report_id, sort_order),
  CONSTRAINT daily_work_report_items_type_check CHECK (
    (
      entry_type = 'weekly'
      AND schedule_entry_id IS NOT NULL
      AND subscriber_id IS NOT NULL
      AND external_beneficiary_name IS NULL
      AND scheduled_minutes > 0
    )
    OR (
      entry_type = 'additional_registered'
      AND schedule_entry_id IS NULL
      AND subscriber_id IS NOT NULL
      AND external_beneficiary_name IS NULL
      AND scheduled_minutes = 0
    )
    OR (
      entry_type = 'additional_guest'
      AND schedule_entry_id IS NULL
      AND subscriber_id IS NULL
      AND char_length(btrim(COALESCE(external_beneficiary_name, ''))) BETWEEN 2 AND 120
      AND scheduled_minutes = 0
      AND app_recorded_minutes = 0
      AND manual_minutes = 0
    )
  )
);

CREATE INDEX daily_work_report_items_subscriber_idx
  ON public.daily_work_report_items (subscriber_id, daily_work_report_id)
  WHERE subscriber_id IS NOT NULL;

CREATE TABLE public.daily_work_report_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  daily_work_report_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('draft_created', 'draft_updated', 'submitted')),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT daily_work_report_events_report_scope_fkey
    FOREIGN KEY (daily_work_report_id, organization_id, pump_id)
    REFERENCES public.daily_work_reports (id, organization_id, pump_id) ON DELETE CASCADE
);

CREATE INDEX daily_work_report_events_report_time_idx
  ON public.daily_work_report_events (daily_work_report_id, occurred_at, id);
CREATE INDEX daily_work_report_events_pump_time_idx
  ON public.daily_work_report_events (organization_id, pump_id, occurred_at DESC);

-- A pump deletion cascades to its sources and reports. Remove report children
-- before the source cascade so the RESTRICT source FK preserves normal history
-- but does not block an authorized pump teardown.
CREATE OR REPLACE FUNCTION water_management_private.delete_pump_daily_work_reports()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $delete_pump_daily_work_reports$
BEGIN
  DELETE FROM public.daily_work_reports
  WHERE organization_id = OLD.organization_id
    AND pump_id = OLD.id;
  RETURN OLD;
END;
$delete_pump_daily_work_reports$;
ALTER FUNCTION water_management_private.delete_pump_daily_work_reports() OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.delete_pump_daily_work_reports()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER delete_pump_daily_work_reports
  BEFORE DELETE ON public.pumps
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.delete_pump_daily_work_reports();

ALTER TABLE public.daily_work_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_work_source_totals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_work_report_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_work_report_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.daily_work_reports FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.daily_work_source_totals FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.daily_work_report_items FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.daily_work_report_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.daily_work_reports TO authenticated;
GRANT SELECT ON public.daily_work_source_totals TO authenticated;
GRANT SELECT ON public.daily_work_report_items TO authenticated;
GRANT SELECT ON public.daily_work_report_events TO authenticated;

CREATE POLICY daily_work_reports_select_scoped
  ON public.daily_work_reports
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = daily_work_reports.organization_id
          AND pa.pump_id = daily_work_reports.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role::text IN ('operator', 'supervisor')
      )
    )
  );

CREATE POLICY daily_work_source_totals_select_scoped
  ON public.daily_work_source_totals
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1 FROM public.daily_work_reports r
      WHERE r.id = daily_work_source_totals.daily_work_report_id
        AND r.organization_id = daily_work_source_totals.organization_id
        AND r.pump_id = daily_work_source_totals.pump_id
    )
  );

CREATE POLICY daily_work_report_items_select_scoped
  ON public.daily_work_report_items
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1 FROM public.daily_work_reports r
      WHERE r.id = daily_work_report_items.daily_work_report_id
        AND r.organization_id = daily_work_report_items.organization_id
        AND r.pump_id = daily_work_report_items.pump_id
    )
  );

CREATE POLICY daily_work_report_events_select_scoped
  ON public.daily_work_report_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = daily_work_report_events.organization_id
          AND pa.pump_id = daily_work_report_events.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role::text IN ('operator', 'supervisor')
      )
    )
  );

CREATE OR REPLACE FUNCTION water_management_private.save_daily_work_report_internal(
  p_pump_id uuid,
  p_work_started_at timestamptz,
  p_work_ended_at timestamptz,
  p_stoppage_minutes integer,
  p_source_totals jsonb,
  p_items jsonb,
  p_submit boolean,
  p_report_id uuid
)
RETURNS public.daily_work_reports
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_work_date date;
  v_report public.daily_work_reports%ROWTYPE;
  v_existing boolean := false;
  v_expected_source_minutes integer;
  v_source_minutes integer := 0;
  v_source_count integer := 0;
  v_item_count integer := 0;
  v_sort_order integer;
  v_entry_type text;
  v_schedule_entry_id uuid;
  v_subscriber_id uuid;
  v_external_name text;
  v_manual_minutes integer;
  v_extra_minutes integer;
  v_note text;
  v_scheduled_minutes integer;
  v_app_minutes integer;
  v_subscriber_name text;
  v_source_id uuid;
  v_minutes integer;
  v_source_name text;
  v_event_type text;
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to save daily work reports' USING ERRCODE = '42501';
  END IF;
  IF v_role = 'operator'::public.app_role AND NOT EXISTS (
    SELECT 1 FROM public.pump_assignments pa
    WHERE pa.organization_id = v_org_id
      AND pa.pump_id = p_pump_id
      AND pa.user_id = v_user_id
      AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.pumps p
    WHERE p.id = p_pump_id AND p.organization_id = v_org_id
  ) THEN
    RAISE EXCEPTION 'Pump is not accessible' USING ERRCODE = '42501';
  END IF;
  IF p_work_started_at IS NULL OR p_work_ended_at IS NULL
     OR p_work_ended_at <= p_work_started_at
     OR p_stoppage_minutes IS NULL OR p_stoppage_minutes < 0
     OR COALESCE(jsonb_typeof(p_source_totals), '') <> 'array'
     OR COALESCE(jsonb_typeof(p_items), '') <> 'array'
     OR jsonb_array_length(p_source_totals) > 30
     OR jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Invalid daily work report payload' USING ERRCODE = '22023';
  END IF;

  v_work_date := (p_work_started_at AT TIME ZONE 'Asia/Hebron')::date;
  IF v_work_date <> (p_work_ended_at AT TIME ZONE 'Asia/Hebron')::date THEN
    RAISE EXCEPTION 'A daily work report must begin and end on the same local date' USING ERRCODE = '22023';
  END IF;
  v_expected_source_minutes :=
    floor(extract(epoch FROM (p_work_ended_at - p_work_started_at)) / 60)::integer
    - p_stoppage_minutes;
  IF v_expected_source_minutes < 0 THEN
    RAISE EXCEPTION 'Stoppage minutes exceed the total work duration' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_report
  FROM public.daily_work_reports r
  WHERE r.organization_id = v_org_id
    AND r.pump_id = p_pump_id
    AND r.work_date = v_work_date
    AND (v_role = 'manager'::public.app_role OR r.operator_id = v_user_id)
  FOR UPDATE;
  v_existing := FOUND;

  IF v_existing THEN
    IF p_report_id IS NOT NULL AND p_report_id <> v_report.id THEN
      RAISE EXCEPTION 'Daily report identifier does not match pump and work date' USING ERRCODE = '22023';
    END IF;
    IF v_report.status <> 'draft' THEN
      RAISE EXCEPTION 'Submitted daily reports are immutable; use a reviewed correction workflow' USING ERRCODE = '55000';
    END IF;
    UPDATE public.daily_work_reports
    SET work_started_at = p_work_started_at,
        work_ended_at = p_work_ended_at,
        stoppage_minutes = p_stoppage_minutes,
        updated_at = clock_timestamp(),
        revision = revision + 1
    WHERE id = v_report.id
    RETURNING * INTO v_report;
    DELETE FROM public.daily_work_source_totals WHERE daily_work_report_id = v_report.id;
    DELETE FROM public.daily_work_report_items WHERE daily_work_report_id = v_report.id;
    v_event_type := 'draft_updated';
  ELSE
    IF p_report_id IS NOT NULL THEN
      RAISE EXCEPTION 'Daily report was not found' USING ERRCODE = 'P0002';
    END IF;
    INSERT INTO public.daily_work_reports (
      organization_id, pump_id, work_date, operator_id,
      work_started_at, work_ended_at, stoppage_minutes
    ) VALUES (
      v_org_id, p_pump_id, v_work_date, v_user_id,
      p_work_started_at, p_work_ended_at, p_stoppage_minutes
    )
    RETURNING * INTO v_report;
    v_event_type := 'draft_created';
  END IF;

  FOR v_source_id, v_minutes IN
    SELECT (item->>'power_source_id')::uuid, (item->>'minutes')::integer
    FROM jsonb_array_elements(p_source_totals) AS item
  LOOP
    IF v_source_id IS NULL OR v_minutes IS NULL OR v_minutes <= 0 THEN
      RAISE EXCEPTION 'Each power source must have a positive whole-minute total' USING ERRCODE = '22023';
    END IF;
    SELECT s.name INTO v_source_name
    FROM public.pump_power_sources s
    WHERE s.id = v_source_id
      AND s.organization_id = v_org_id
      AND s.pump_id = p_pump_id;
    IF v_source_name IS NULL THEN
      RAISE EXCEPTION 'A selected power source does not belong to this pump' USING ERRCODE = '23503';
    END IF;
    INSERT INTO public.daily_work_source_totals (
      daily_work_report_id, organization_id, pump_id, power_source_id,
      source_name_snapshot, minutes
    ) VALUES (
      v_report.id, v_org_id, p_pump_id, v_source_id, v_source_name, v_minutes
    );
    v_source_minutes := v_source_minutes + v_minutes;
    v_source_count := v_source_count + 1;
  END LOOP;

  FOR v_entry_type, v_schedule_entry_id, v_subscriber_id, v_external_name,
      v_sort_order, v_manual_minutes, v_extra_minutes, v_note
  IN
    SELECT entry_type, schedule_entry_id, subscriber_id, external_beneficiary_name,
           sort_order, manual_minutes, extra_minutes, note
    FROM jsonb_to_recordset(p_items) AS item(
      entry_type text,
      schedule_entry_id uuid,
      subscriber_id uuid,
      external_beneficiary_name text,
      sort_order integer,
      manual_minutes integer,
      extra_minutes integer,
      note text
    )
  LOOP
    IF v_sort_order IS NULL OR v_sort_order < 0
       OR COALESCE(v_manual_minutes, 0) < 0
       OR COALESCE(v_extra_minutes, 0) < 0 THEN
      RAISE EXCEPTION 'Invalid daily work item values' USING ERRCODE = '22023';
    END IF;
    v_manual_minutes := COALESCE(v_manual_minutes, 0);
    v_extra_minutes := COALESCE(v_extra_minutes, 0);
    v_note := NULLIF(btrim(v_note), '');

    IF v_entry_type = 'weekly' THEN
      SELECT e.planned_minutes, s.id, s.full_name
      INTO v_scheduled_minutes, v_subscriber_id, v_subscriber_name
      FROM public.schedule_entries e
      JOIN public.weekly_schedules ws
        ON ws.id = e.weekly_schedule_id
       AND ws.organization_id = e.organization_id
       AND ws.pump_id = e.pump_id
      JOIN public.subscribers s
        ON s.id = e.subscriber_id
       AND s.organization_id = e.organization_id
       AND s.pump_id = e.pump_id
      WHERE e.id = v_schedule_entry_id
        AND e.organization_id = v_org_id
        AND e.pump_id = p_pump_id
        AND e.subscriber_id = v_subscriber_id
        AND e.weekday = extract(isodow FROM v_work_date)::integer
        AND ws.status IN ('active', 'archived')
        AND v_work_date >= ws.effective_from
        AND (ws.effective_to IS NULL OR v_work_date <= ws.effective_to);
      IF v_scheduled_minutes IS NULL OR v_subscriber_name IS NULL THEN
        RAISE EXCEPTION 'Weekly report item does not match an active schedule entry for this day and pump' USING ERRCODE = '23503';
      END IF;
      SELECT floor(COALESCE(sum(op.actual_seconds), 0) / 60)::integer
      INTO v_app_minutes
      FROM public.pump_operations op
      WHERE op.organization_id = v_org_id
        AND op.pump_id = p_pump_id
        AND op.operation_date = v_work_date
        AND op.subscriber_id = v_subscriber_id
        AND op.status = 'completed';
      IF v_manual_minutes > GREATEST(0, v_scheduled_minutes - v_app_minutes) THEN
        RAISE EXCEPTION 'Manual weekly minutes cannot exceed the remaining scheduled allocation' USING ERRCODE = '22023';
      END IF;
    ELSIF v_entry_type = 'additional_registered' THEN
      SELECT s.full_name INTO v_subscriber_name
      FROM public.subscribers s
      WHERE s.id = v_subscriber_id
        AND s.organization_id = v_org_id
        AND s.pump_id = p_pump_id
        AND s.is_active;
      IF v_subscriber_name IS NULL OR v_schedule_entry_id IS NOT NULL THEN
        RAISE EXCEPTION 'Additional registered item must reference an active subscriber on this pump only' USING ERRCODE = '23503';
      END IF;
      v_scheduled_minutes := 0;
      v_app_minutes := 0;
      v_external_name := NULL;
    ELSIF v_entry_type = 'additional_guest' THEN
      IF v_subscriber_id IS NOT NULL OR v_schedule_entry_id IS NOT NULL
         OR char_length(btrim(COALESCE(v_external_name, ''))) NOT BETWEEN 2 AND 120 THEN
        RAISE EXCEPTION 'Additional guest item requires a name and no subscriber record' USING ERRCODE = '22023';
      END IF;
      v_scheduled_minutes := 0;
      v_app_minutes := 0;
      v_subscriber_name := NULL;
    ELSE
      RAISE EXCEPTION 'Unknown daily work item type' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.daily_work_report_items (
      daily_work_report_id, organization_id, pump_id, schedule_entry_id,
      subscriber_id, subscriber_name_snapshot, external_beneficiary_name,
      entry_type, sort_order, scheduled_minutes, app_recorded_minutes,
      manual_minutes, extra_minutes, note
    ) VALUES (
      v_report.id, v_org_id, p_pump_id, v_schedule_entry_id,
      v_subscriber_id, v_subscriber_name, NULLIF(btrim(v_external_name), ''),
      v_entry_type, v_sort_order, v_scheduled_minutes, v_app_minutes,
      CASE WHEN v_entry_type = 'weekly' THEN v_manual_minutes ELSE 0 END,
      v_extra_minutes, v_note
    );
    v_item_count := v_item_count + 1;
  END LOOP;

  IF p_submit THEN
    IF EXISTS (
      SELECT 1
      FROM public.weekly_schedules ws
      JOIN public.schedule_entries se
        ON se.weekly_schedule_id = ws.id
       AND se.organization_id = ws.organization_id
       AND se.pump_id = ws.pump_id
      WHERE ws.organization_id = v_org_id
        AND ws.pump_id = p_pump_id
        AND ws.status = 'active'
        AND v_work_date >= ws.effective_from
        AND (ws.effective_to IS NULL OR v_work_date <= ws.effective_to)
        AND se.weekday = extract(isodow FROM v_work_date)::integer
        AND NOT EXISTS (
          SELECT 1 FROM public.daily_work_report_items ri
          WHERE ri.daily_work_report_id = v_report.id
            AND ri.schedule_entry_id = se.id
        )
    ) THEN
      RAISE EXCEPTION 'Daily report must include every weekly schedule entry for this pump and date'
        USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.pump_operations op
      WHERE op.organization_id = v_org_id
        AND op.pump_id = p_pump_id
        AND op.operation_date = v_work_date
        AND op.status IN ('running', 'paused')
    ) THEN
      RAISE EXCEPTION 'Complete or pause-resolve active operations before submitting the daily report' USING ERRCODE = '55000';
    END IF;
    IF v_source_minutes <> v_expected_source_minutes THEN
      RAISE EXCEPTION 'Power source totals (%) must equal active work minutes (%)',
        v_source_minutes, v_expected_source_minutes USING ERRCODE = '23514';
    END IF;
    UPDATE public.daily_work_reports
    SET status = 'submitted',
        submitted_at = clock_timestamp(),
        submitted_by = v_user_id,
        updated_at = clock_timestamp()
    WHERE id = v_report.id
    RETURNING * INTO v_report;
    v_event_type := 'submitted';
  END IF;

  INSERT INTO public.daily_work_report_events (
    daily_work_report_id, organization_id, pump_id, actor_id, event_type, metadata
  ) VALUES (
    v_report.id, v_org_id, p_pump_id, v_user_id, v_event_type,
    jsonb_build_object(
      'revision', v_report.revision,
      'source_count', v_source_count,
      'source_minutes', v_source_minutes,
      'item_count', v_item_count,
      'submitted', p_submit
    )
  );

  RETURN v_report;
END;
$$;

REVOKE ALL ON FUNCTION water_management_private.save_daily_work_report_internal(
  uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.save_daily_work_report_internal(
  uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) TO authenticated;

CREATE OR REPLACE FUNCTION public.save_daily_work_report(
  p_pump_id uuid,
  p_work_started_at timestamptz,
  p_work_ended_at timestamptz,
  p_stoppage_minutes integer,
  p_source_totals jsonb,
  p_items jsonb DEFAULT '[]'::jsonb,
  p_submit boolean DEFAULT false,
  p_report_id uuid DEFAULT NULL
)
RETURNS public.daily_work_reports
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT water_management_private.save_daily_work_report_internal(
    p_pump_id, p_work_started_at, p_work_ended_at, p_stoppage_minutes,
    p_source_totals, p_items, p_submit, p_report_id
  )
$$;
REVOKE ALL ON FUNCTION public.save_daily_work_report(
  uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_daily_work_report(
  uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) TO authenticated;

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
        AND ws.status IN ('active', 'archived')
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
REVOKE ALL ON FUNCTION public.get_pump_power_usage(date, date, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pump_power_usage(date, date, text, uuid)
  TO authenticated;

COMMENT ON TABLE public.daily_work_reports IS
  'One operator-submitted end-of-day summary per pump/date. It records work outside the app without manufacturing pump operation sessions.';
COMMENT ON TABLE public.daily_work_source_totals IS
  'Final source totals submitted in the daily survey; they supersede automatic segments for the same pump/date in aggregate reports.';
COMMENT ON TABLE public.daily_work_report_items IS
  'Daily actual subscriber fulfillment snapshot, separating app-recorded minutes, manual weekly minutes, and additional minutes.';
COMMENT ON TABLE public.daily_work_report_events IS
  'Append-only audit events for daily work report drafts and submissions.';
