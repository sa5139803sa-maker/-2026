-- Multi-operator daily reports with one shared pump-energy survey per pump/day.
-- The report owner (operator_id) is distinct from the user who creates/submits it.

ALTER TABLE public.daily_work_reports
  ADD COLUMN created_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT;

UPDATE public.daily_work_reports
SET created_by = COALESCE(submitted_by, operator_id)
WHERE created_by IS NULL;

ALTER TABLE public.daily_work_reports
  ALTER COLUMN created_by SET NOT NULL;

ALTER TABLE public.daily_work_reports
  DROP CONSTRAINT daily_work_reports_pump_date_uidx;

CREATE UNIQUE INDEX daily_work_reports_operator_date_uidx
  ON public.daily_work_reports (organization_id, pump_id, work_date, operator_id);

COMMENT ON COLUMN public.daily_work_reports.operator_id IS
  'Responsible operator for this subscriber-work report; distinct from created_by/submitted_by.';
COMMENT ON COLUMN public.daily_work_reports.created_by IS
  'Authenticated user who created the report; may be a manager creating it for an assigned operator.';

-- A pump has one physical energy breakdown for a local work date, regardless
-- of how many independent operator work reports are submitted for that date.
CREATE TABLE public.daily_pump_energy_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  work_date date NOT NULL,
  work_started_at timestamptz NOT NULL,
  work_ended_at timestamptz NOT NULL,
  stoppage_minutes integer NOT NULL DEFAULT 0 CHECK (stoppage_minutes >= 0),
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'submitted')),
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  submitted_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  submitted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  revision integer NOT NULL DEFAULT 1 CHECK (revision > 0),
  CONSTRAINT daily_pump_energy_reports_scope_key UNIQUE (id, organization_id, pump_id),
  CONSTRAINT daily_pump_energy_reports_pump_fkey
    FOREIGN KEY (pump_id, organization_id)
    REFERENCES public.pumps (id, organization_id) ON DELETE CASCADE,
  CONSTRAINT daily_pump_energy_reports_pump_date_uidx
    UNIQUE (organization_id, pump_id, work_date),
  CONSTRAINT daily_pump_energy_reports_date_check CHECK (
    work_date = (work_started_at AT TIME ZONE 'Asia/Hebron')::date
    AND work_date = (work_ended_at AT TIME ZONE 'Asia/Hebron')::date
    AND work_ended_at > work_started_at
    AND stoppage_minutes <= floor(extract(epoch FROM (work_ended_at - work_started_at)) / 60)::integer
  ),
  CONSTRAINT daily_pump_energy_reports_submit_check CHECK (
    (status = 'draft' AND submitted_at IS NULL AND submitted_by IS NULL)
    OR (status = 'submitted' AND submitted_at IS NOT NULL AND submitted_by IS NOT NULL)
  )
);

CREATE INDEX daily_pump_energy_reports_org_date_idx
  ON public.daily_pump_energy_reports (organization_id, work_date DESC, pump_id);

CREATE TABLE public.daily_pump_energy_source_totals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  daily_pump_energy_report_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  power_source_id uuid NOT NULL,
  source_name_snapshot text NOT NULL
    CHECK (char_length(btrim(source_name_snapshot)) BETWEEN 2 AND 100),
  minutes integer NOT NULL CHECK (minutes > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT daily_pump_energy_source_totals_report_source_uidx
    UNIQUE (daily_pump_energy_report_id, power_source_id),
  CONSTRAINT daily_pump_energy_source_totals_report_fkey
    FOREIGN KEY (daily_pump_energy_report_id, organization_id, pump_id)
    REFERENCES public.daily_pump_energy_reports (id, organization_id, pump_id) ON DELETE CASCADE,
  CONSTRAINT daily_pump_energy_source_totals_source_fkey
    FOREIGN KEY (power_source_id, organization_id, pump_id)
    REFERENCES public.pump_power_sources (id, organization_id, pump_id) ON DELETE RESTRICT
);

CREATE INDEX daily_pump_energy_source_totals_source_idx
  ON public.daily_pump_energy_source_totals (power_source_id, daily_pump_energy_report_id);

CREATE TABLE public.daily_pump_energy_report_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  daily_pump_energy_report_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('draft_created', 'draft_updated', 'submitted', 'migrated')),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT daily_pump_energy_report_events_report_fkey
    FOREIGN KEY (daily_pump_energy_report_id, organization_id, pump_id)
    REFERENCES public.daily_pump_energy_reports (id, organization_id, pump_id) ON DELETE CASCADE
);

CREATE INDEX daily_pump_energy_report_events_report_time_idx
  ON public.daily_pump_energy_report_events (daily_pump_energy_report_id, occurred_at, id);

ALTER TABLE public.daily_pump_energy_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_pump_energy_source_totals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_pump_energy_report_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.daily_pump_energy_reports FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.daily_pump_energy_source_totals FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.daily_pump_energy_report_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.daily_pump_energy_reports TO authenticated;
GRANT SELECT ON public.daily_pump_energy_source_totals TO authenticated;
GRANT SELECT ON public.daily_pump_energy_report_events TO authenticated;

CREATE POLICY daily_pump_energy_reports_select_scoped
  ON public.daily_pump_energy_reports
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = daily_pump_energy_reports.organization_id
          AND pa.pump_id = daily_pump_energy_reports.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role::text = (SELECT water_management_private.current_user_role())::text
          AND pa.assignment_role::text IN ('operator', 'supervisor')
      )
    )
  );

CREATE POLICY daily_pump_energy_source_totals_select_scoped
  ON public.daily_pump_energy_source_totals
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1 FROM public.daily_pump_energy_reports er
      WHERE er.id = daily_pump_energy_source_totals.daily_pump_energy_report_id
        AND er.organization_id = daily_pump_energy_source_totals.organization_id
        AND er.pump_id = daily_pump_energy_source_totals.pump_id
    )
  );

CREATE POLICY daily_pump_energy_report_events_select_scoped
  ON public.daily_pump_energy_report_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1 FROM public.daily_pump_energy_reports er
      WHERE er.id = daily_pump_energy_report_events.daily_pump_energy_report_id
        AND er.organization_id = daily_pump_energy_report_events.organization_id
        AND er.pump_id = daily_pump_energy_report_events.pump_id
    )
  );

-- Preserve pre-existing daily pump energy values. The old schema allowed only
-- one report per pump/date, so this copy creates exactly one shared energy row.
INSERT INTO public.daily_pump_energy_reports (
  organization_id, pump_id, work_date, work_started_at, work_ended_at,
  stoppage_minutes, status, created_by, submitted_by, submitted_at,
  created_at, updated_at, revision
)
SELECT
  r.organization_id, r.pump_id, r.work_date, r.work_started_at, r.work_ended_at,
  r.stoppage_minutes, r.status, r.created_by, r.submitted_by, r.submitted_at,
  r.created_at, r.updated_at, r.revision
FROM public.daily_work_reports r;

INSERT INTO public.daily_pump_energy_source_totals (
  daily_pump_energy_report_id, organization_id, pump_id,
  power_source_id, source_name_snapshot, minutes, created_at
)
SELECT
  er.id, old_totals.organization_id, old_totals.pump_id,
  old_totals.power_source_id, old_totals.source_name_snapshot,
  old_totals.minutes, old_totals.created_at
FROM public.daily_work_reports old_report
JOIN public.daily_pump_energy_reports er
  ON er.organization_id = old_report.organization_id
 AND er.pump_id = old_report.pump_id
 AND er.work_date = old_report.work_date
JOIN public.daily_work_source_totals old_totals
  ON old_totals.daily_work_report_id = old_report.id
 AND old_totals.organization_id = old_report.organization_id
 AND old_totals.pump_id = old_report.pump_id;

INSERT INTO public.daily_pump_energy_report_events (
  daily_pump_energy_report_id, organization_id, pump_id, actor_id,
  event_type, occurred_at, metadata
)
SELECT
  er.id, er.organization_id, er.pump_id,
  COALESCE(er.submitted_by, er.created_by),
  'migrated', clock_timestamp(),
  jsonb_build_object('source', 'daily_work_reports', 'legacy_report_id', r.id)
FROM public.daily_pump_energy_reports er
JOIN public.daily_work_reports r
  ON r.organization_id = er.organization_id
 AND r.pump_id = er.pump_id
 AND r.work_date = er.work_date;

COMMENT ON TABLE public.daily_work_source_totals IS
  'Legacy per-report source snapshot retained for migration history. New pump-day energy totals are stored once in daily_pump_energy_source_totals.';

-- Weekly entitlements are the authoritative daily allocation. A moved quota
-- has no schedule_entry_id and is identified by its allocation row instead.
-- The weekly entitlement ledger migration already introduced the allocation
-- column, tenant-scoped FK, partial unique index and row preparation trigger.
-- This migration tightens report semantics without duplicating that schema.

ALTER TABLE public.daily_work_report_items
  DROP CONSTRAINT daily_work_report_items_type_check,
  DROP COLUMN weekly_minutes_consumed,
  DROP COLUMN app_over_quota_minutes,
  DROP COLUMN fulfillment_status;

ALTER TABLE public.daily_work_report_items
  ADD CONSTRAINT daily_work_report_items_type_check CHECK (
    (
      entry_type = 'weekly'
      AND schedule_entry_id IS NOT NULL
      AND subscriber_id IS NOT NULL
      AND external_beneficiary_name IS NULL
      AND scheduled_minutes > 0
    )
    OR (
      entry_type = 'weekly_reassigned'
      AND schedule_entry_id IS NULL
      AND subscriber_id IS NOT NULL
      AND weekly_entitlement_allocation_id IS NOT NULL
      AND external_beneficiary_name IS NULL
      AND scheduled_minutes > 0
    )
    OR (
      entry_type = 'additional_registered'
      AND schedule_entry_id IS NULL
      AND subscriber_id IS NOT NULL
      AND weekly_entitlement_allocation_id IS NULL
      AND external_beneficiary_name IS NULL
      AND scheduled_minutes = 0
    )
    OR (
      entry_type = 'additional_guest'
      AND schedule_entry_id IS NULL
      AND subscriber_id IS NULL
      AND weekly_entitlement_allocation_id IS NULL
      AND char_length(btrim(COALESCE(external_beneficiary_name, ''))) BETWEEN 2 AND 120
      AND scheduled_minutes = 0
      AND app_recorded_minutes = 0
      AND manual_minutes = 0
    )
  );

ALTER TABLE public.daily_work_report_items
  ADD COLUMN weekly_minutes_consumed integer
    GENERATED ALWAYS AS (
      CASE WHEN entry_type IN ('weekly', 'weekly_reassigned')
        THEN LEAST(scheduled_minutes, app_recorded_minutes + manual_minutes)
        ELSE 0
      END
    ) STORED,
  ADD COLUMN app_over_quota_minutes integer
    GENERATED ALWAYS AS (
      CASE WHEN entry_type IN ('weekly', 'weekly_reassigned')
        THEN GREATEST(0, app_recorded_minutes + manual_minutes - scheduled_minutes)
        ELSE 0
      END
    ) STORED,
  ADD COLUMN fulfillment_status text
    GENERATED ALWAYS AS (
      CASE
        WHEN entry_type NOT IN ('weekly', 'weekly_reassigned') THEN 'additional'
        WHEN app_recorded_minutes + manual_minutes = 0 THEN 'not_done'
        WHEN app_recorded_minutes + manual_minutes >= scheduled_minutes THEN 'complete'
        ELSE 'partial'
      END
    ) STORED;

-- Resolve responsibility at the end of the requested local work date. If a
-- later reassignment is the only event, its previous_operator_id is the owner
-- for the historical date. This avoids reclassifying old work after reassignment.
CREATE OR REPLACE FUNCTION water_management_private.subscriber_operator_for_work_date(
  p_subscriber_id uuid,
  p_organization_id uuid,
  p_pump_id uuid,
  p_work_date date
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $subscriber_operator_for_work_date$
DECLARE
  v_operator_id uuid;
  v_found boolean := false;
  v_day_end timestamptz := ((p_work_date + 1)::timestamp AT TIME ZONE 'Asia/Hebron');
BEGIN
  IF p_subscriber_id IS NULL OR p_organization_id IS NULL
     OR p_pump_id IS NULL OR p_work_date IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT e.new_operator_id, true
  INTO v_operator_id, v_found
  FROM public.subscriber_operator_assignment_events e
  WHERE e.subscriber_id = p_subscriber_id
    AND e.organization_id = p_organization_id
    AND e.pump_id = p_pump_id
    AND e.occurred_at < v_day_end
  ORDER BY e.occurred_at DESC, e.id DESC
  LIMIT 1;

  IF v_found THEN
    RETURN v_operator_id;
  END IF;

  SELECT e.previous_operator_id, true
  INTO v_operator_id, v_found
  FROM public.subscriber_operator_assignment_events e
  WHERE e.subscriber_id = p_subscriber_id
    AND e.organization_id = p_organization_id
    AND e.pump_id = p_pump_id
    AND e.occurred_at >= v_day_end
  ORDER BY e.occurred_at, e.id
  LIMIT 1;

  IF v_found THEN
    RETURN v_operator_id;
  END IF;

  SELECT s.operator_id INTO v_operator_id
  FROM public.subscribers s
  WHERE s.id = p_subscriber_id
    AND s.organization_id = p_organization_id
    AND s.pump_id = p_pump_id;

  RETURN v_operator_id;
END;
$subscriber_operator_for_work_date$;

ALTER FUNCTION water_management_private.subscriber_operator_for_work_date(uuid, uuid, uuid, date)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.subscriber_operator_for_work_date(uuid, uuid, uuid, date)
  FROM PUBLIC, anon, authenticated, service_role;

-- The trigger is an independent owner-boundary guard because the save RPC is
-- SECURITY DEFINER and does not rely on row-level policies for its own writes.
CREATE OR REPLACE FUNCTION water_management_private.guard_daily_work_report_item_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $guard_daily_work_report_item_owner_multi$
DECLARE
  v_role public.app_role := water_management_private.current_user_role();
  v_report public.daily_work_reports%ROWTYPE;
  v_subscriber_operator_id uuid;
BEGIN
  SELECT r.* INTO v_report
  FROM public.daily_work_reports r
  WHERE r.id = NEW.daily_work_report_id
    AND r.organization_id = NEW.organization_id
    AND r.pump_id = NEW.pump_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily report does not exist in the submitted organization and pump'
      USING ERRCODE = '23503';
  END IF;

  IF v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Only a manager or the responsible operator can write report items'
      USING ERRCODE = '42501';
  END IF;

  IF v_role = 'operator'::public.app_role
     AND v_report.operator_id <> auth.uid() THEN
    RAISE EXCEPTION 'Operator can only edit their own daily work report'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.subscriber_id IS NULL THEN
    NEW.assigned_operator_id := v_report.operator_id;
    RETURN NEW;
  END IF;

  SELECT water_management_private.subscriber_operator_for_work_date(
    s.id, s.organization_id, s.pump_id, v_report.work_date
  )
  INTO v_subscriber_operator_id
  FROM public.subscribers s
  WHERE s.id = NEW.subscriber_id
    AND s.organization_id = NEW.organization_id
    AND s.pump_id = NEW.pump_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily report item must reference a subscriber on the same pump'
      USING ERRCODE = '23503';
  END IF;

  IF v_subscriber_operator_id IS DISTINCT FROM v_report.operator_id THEN
    RAISE EXCEPTION 'Daily report item belongs to a different operator for this work date'
      USING ERRCODE = '42501';
  END IF;

  NEW.assigned_operator_id := v_report.operator_id;
  RETURN NEW;
END;
$guard_daily_work_report_item_owner_multi$;

ALTER FUNCTION water_management_private.guard_daily_work_report_item_owner() OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.guard_daily_work_report_item_owner()
  FROM PUBLIC, anon, authenticated, service_role;

-- Shared source totals are upserted under a pump-row lock. Once submitted,
-- every later operator report must present the exact same pump-day values.
CREATE OR REPLACE FUNCTION water_management_private.save_daily_pump_energy_report_internal(
  p_pump_id uuid,
  p_work_started_at timestamptz,
  p_work_ended_at timestamptz,
  p_stoppage_minutes integer,
  p_source_totals jsonb,
  p_submit boolean
)
RETURNS public.daily_pump_energy_reports
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $save_daily_pump_energy_report_internal$
DECLARE
  v_actor_id uuid := auth.uid();
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_work_date date;
  v_expected_minutes integer;
  v_source_minutes integer := 0;
  v_source_count integer := 0;
  v_source_id uuid;
  v_minutes integer;
  v_source_name text;
  v_report public.daily_pump_energy_reports%ROWTYPE;
  v_exists boolean := false;
  v_input jsonb;
  v_existing jsonb;
  v_event_type text;
BEGIN
  IF v_actor_id IS NULL OR v_org_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to save pump energy survey' USING ERRCODE = '42501';
  END IF;

  IF p_pump_id IS NULL OR p_work_started_at IS NULL OR p_work_ended_at IS NULL
     OR p_work_ended_at <= p_work_started_at
     OR p_stoppage_minutes IS NULL OR p_stoppage_minutes < 0
     OR COALESCE(jsonb_typeof(p_source_totals), '') <> 'array'
     OR jsonb_array_length(p_source_totals) > 30 THEN
    RAISE EXCEPTION 'Invalid pump energy survey payload' USING ERRCODE = '22023';
  END IF;

  IF v_role = 'operator'::public.app_role AND NOT EXISTS (
    SELECT 1 FROM public.pump_assignments pa
    WHERE pa.organization_id = v_org_id
      AND pa.pump_id = p_pump_id
      AND pa.user_id = v_actor_id
      AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump' USING ERRCODE = '42501';
  END IF;

  PERFORM 1 FROM public.pumps p
  WHERE p.id = p_pump_id AND p.organization_id = v_org_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pump is not accessible' USING ERRCODE = '42501';
  END IF;

  v_work_date := (p_work_started_at AT TIME ZONE 'Asia/Hebron')::date;
  IF v_work_date <> (p_work_ended_at AT TIME ZONE 'Asia/Hebron')::date THEN
    RAISE EXCEPTION 'Pump energy survey must start and end on the same local date' USING ERRCODE = '22023';
  END IF;

  v_expected_minutes :=
    floor(extract(epoch FROM (p_work_ended_at - p_work_started_at)) / 60)::integer
    - p_stoppage_minutes;
  IF v_expected_minutes < 0 THEN
    RAISE EXCEPTION 'Stoppage minutes exceed the pump work duration' USING ERRCODE = '22023';
  END IF;

  FOR v_source_id, v_minutes IN
    SELECT (item->>'power_source_id')::uuid, (item->>'minutes')::integer
    FROM jsonb_array_elements(p_source_totals) AS item
  LOOP
    IF v_source_id IS NULL OR v_minutes IS NULL OR v_minutes <= 0 THEN
      RAISE EXCEPTION 'Each power source requires a positive whole-minute total' USING ERRCODE = '22023';
    END IF;

    SELECT s.name INTO v_source_name
    FROM public.pump_power_sources s
    WHERE s.id = v_source_id
      AND s.organization_id = v_org_id
      AND s.pump_id = p_pump_id;

    IF v_source_name IS NULL THEN
      RAISE EXCEPTION 'Selected power source does not belong to this pump' USING ERRCODE = '23503';
    END IF;

    v_source_minutes := v_source_minutes + v_minutes;
    v_source_count := v_source_count + 1;
  END LOOP;

  IF p_submit AND v_source_minutes <> v_expected_minutes THEN
    RAISE EXCEPTION 'Power source totals (%) must equal active pump minutes (%)',
      v_source_minutes, v_expected_minutes USING ERRCODE = '23514';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'power_source_id', (item->>'power_source_id')::uuid,
        'minutes', (item->>'minutes')::integer
      )
      ORDER BY (item->>'power_source_id')::uuid
    ),
    '[]'::jsonb
  )
  INTO v_input
  FROM jsonb_array_elements(p_source_totals) AS item;

  SELECT * INTO v_report
  FROM public.daily_pump_energy_reports er
  WHERE er.organization_id = v_org_id
    AND er.pump_id = p_pump_id
    AND er.work_date = v_work_date
  FOR UPDATE;
  v_exists := FOUND;

  IF v_exists AND v_report.status = 'submitted' THEN
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'power_source_id', totals.power_source_id,
          'minutes', totals.minutes
        )
        ORDER BY totals.power_source_id
      ),
      '[]'::jsonb
    )
    INTO v_existing
    FROM public.daily_pump_energy_source_totals totals
    WHERE totals.daily_pump_energy_report_id = v_report.id;

    IF v_report.work_started_at IS DISTINCT FROM p_work_started_at
       OR v_report.work_ended_at IS DISTINCT FROM p_work_ended_at
       OR v_report.stoppage_minutes IS DISTINCT FROM p_stoppage_minutes
       OR v_existing IS DISTINCT FROM v_input THEN
      RAISE EXCEPTION 'Submitted pump energy survey is immutable; all operator reports must reuse its exact values'
        USING ERRCODE = '55000';
    END IF;

    RETURN v_report;
  END IF;

  IF v_exists THEN
    UPDATE public.daily_pump_energy_reports
    SET work_started_at = p_work_started_at,
        work_ended_at = p_work_ended_at,
        stoppage_minutes = p_stoppage_minutes,
        updated_at = clock_timestamp(),
        revision = revision + 1
    WHERE id = v_report.id
    RETURNING * INTO v_report;

    DELETE FROM public.daily_pump_energy_source_totals
    WHERE daily_pump_energy_report_id = v_report.id;
    v_event_type := 'draft_updated';
  ELSE
    INSERT INTO public.daily_pump_energy_reports (
      organization_id, pump_id, work_date, work_started_at, work_ended_at,
      stoppage_minutes, created_by
    ) VALUES (
      v_org_id, p_pump_id, v_work_date, p_work_started_at, p_work_ended_at,
      p_stoppage_minutes, v_actor_id
    )
    RETURNING * INTO v_report;
    v_event_type := 'draft_created';
  END IF;

  FOR v_source_id, v_minutes IN
    SELECT (item->>'power_source_id')::uuid, (item->>'minutes')::integer
    FROM jsonb_array_elements(p_source_totals) AS item
  LOOP
    SELECT s.name INTO v_source_name
    FROM public.pump_power_sources s
    WHERE s.id = v_source_id
      AND s.organization_id = v_org_id
      AND s.pump_id = p_pump_id;

    INSERT INTO public.daily_pump_energy_source_totals (
      daily_pump_energy_report_id, organization_id, pump_id,
      power_source_id, source_name_snapshot, minutes
    ) VALUES (
      v_report.id, v_org_id, p_pump_id,
      v_source_id, v_source_name, v_minutes
    );
  END LOOP;

  IF p_submit THEN
    UPDATE public.daily_pump_energy_reports
    SET status = 'submitted',
        submitted_at = clock_timestamp(),
        submitted_by = v_actor_id,
        updated_at = clock_timestamp()
    WHERE id = v_report.id
    RETURNING * INTO v_report;
    v_event_type := 'submitted';
  END IF;

  -- Keep any already-created operator drafts aligned with this shared
  -- pump-day work interval. Energy totals belong to the pump, not a single
  -- operator; all drafts therefore display the same shared interval.
  UPDATE public.daily_work_reports r
  SET work_started_at = v_report.work_started_at,
      work_ended_at = v_report.work_ended_at,
      stoppage_minutes = v_report.stoppage_minutes,
      updated_at = clock_timestamp(),
      revision = r.revision + 1
  WHERE r.organization_id = v_org_id
    AND r.pump_id = p_pump_id
    AND r.work_date = v_work_date
    AND r.status = 'draft'
    AND (
      r.work_started_at IS DISTINCT FROM v_report.work_started_at
      OR r.work_ended_at IS DISTINCT FROM v_report.work_ended_at
      OR r.stoppage_minutes IS DISTINCT FROM v_report.stoppage_minutes
    );

  INSERT INTO public.daily_pump_energy_report_events (
    daily_pump_energy_report_id, organization_id, pump_id,
    actor_id, event_type, metadata
  ) VALUES (
    v_report.id, v_org_id, p_pump_id, v_actor_id, v_event_type,
    jsonb_build_object(
      'revision', v_report.revision,
      'source_count', v_source_count,
      'source_minutes', v_source_minutes,
      'submitted', p_submit
    )
  );

  RETURN v_report;
END;
$save_daily_pump_energy_report_internal$;

ALTER FUNCTION water_management_private.save_daily_pump_energy_report_internal(
  uuid, timestamptz, timestamptz, integer, jsonb, boolean
) OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.save_daily_pump_energy_report_internal(
  uuid, timestamptz, timestamptz, integer, jsonb, boolean
) FROM PUBLIC, anon, authenticated, service_role;

-- The target operator is always explicit for manager-created reports. An
-- operator may target only themself. Each target has one report per pump/date.
CREATE OR REPLACE FUNCTION water_management_private.save_daily_work_report_internal(
  p_pump_id uuid,
  p_target_operator_id uuid,
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
AS $save_daily_work_report_internal_multi$
DECLARE
  v_actor_id uuid := auth.uid();
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_work_date date;
  v_report public.daily_work_reports%ROWTYPE;
  v_existing boolean := false;
  v_item_count integer := 0;
  v_sort_order integer;
  v_entry_type text;
  v_schedule_entry_id uuid;
  v_allocation_id uuid;
  v_subscriber_id uuid;
  v_external_name text;
  v_manual_minutes integer;
  v_extra_minutes integer;
  v_note text;
  v_scheduled_minutes integer;
  v_app_minutes integer;
  v_subscriber_name text;
  v_subscriber_operator_id uuid;
  v_event_type text;
  v_schedule record;
  v_cycle_start date;
  v_energy_report public.daily_pump_energy_reports%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR v_org_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to save daily work reports' USING ERRCODE = '42501';
  END IF;

  IF p_pump_id IS NULL OR p_target_operator_id IS NULL THEN
    RAISE EXCEPTION 'Pump and target operator are required' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles p
    JOIN public.pump_assignments pa
      ON pa.user_id = p.id
     AND pa.organization_id = p.organization_id
     AND pa.assignment_role = p.role
    WHERE p.id = p_target_operator_id
      AND p.organization_id = v_org_id
      AND p.role = 'operator'::public.app_role
      AND pa.pump_id = p_pump_id
      AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Target operator is not assigned to this pump in the current organization'
      USING ERRCODE = '42501';
  END IF;

  IF v_role = 'operator'::public.app_role
     AND p_target_operator_id <> v_actor_id THEN
    RAISE EXCEPTION 'Operator can only create or edit their own report'
      USING ERRCODE = '42501';
  END IF;

  IF p_work_started_at IS NULL OR p_work_ended_at IS NULL
     OR p_work_ended_at <= p_work_started_at
     OR p_stoppage_minutes IS NULL OR p_stoppage_minutes < 0
     OR COALESCE(jsonb_typeof(p_source_totals), '') <> 'array'
     OR COALESCE(jsonb_typeof(p_items), '') <> 'array'
     OR jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Invalid daily work report payload' USING ERRCODE = '22023';
  END IF;

  v_work_date := (p_work_started_at AT TIME ZONE 'Asia/Hebron')::date;
  IF v_work_date <> (p_work_ended_at AT TIME ZONE 'Asia/Hebron')::date THEN
    RAISE EXCEPTION 'A daily work report must begin and end on the same local date' USING ERRCODE = '22023';
  END IF;

  -- Serialize report and energy creation/editing with reassignment and with
  -- concurrent report writers by using the same pump row as the mutex.
  PERFORM 1 FROM public.pumps p
  WHERE p.id = p_pump_id AND p.organization_id = v_org_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pump is not accessible' USING ERRCODE = '42501';
  END IF;

  -- Ensure every weekly entitlement that applies to this historical work date
  -- exists before validating report completeness. This also serializes the
  -- daily survey against queue generation and quota transfer on the pump row.
  FOR v_schedule IN
    SELECT ws.id, ws.week_starts_on
    FROM public.weekly_schedules ws
    WHERE ws.organization_id = v_org_id
      AND ws.pump_id = p_pump_id
      AND ws.status IN ('active', 'archived')
      AND v_work_date >= ws.effective_from
      AND (ws.effective_to IS NULL OR v_work_date <= ws.effective_to)
    ORDER BY ws.effective_from DESC, ws.id
  LOOP
    v_cycle_start := v_work_date - (
      (extract(isodow FROM v_work_date)::integer - v_schedule.week_starts_on + 7) % 7
    );
    PERFORM water_management_private.ensure_weekly_entitlement_cycle(
      v_schedule.id, v_org_id, p_pump_id, v_cycle_start, v_actor_id
    );
  END LOOP;

  v_energy_report := water_management_private.save_daily_pump_energy_report_internal(
    p_pump_id, p_work_started_at, p_work_ended_at,
    p_stoppage_minutes, p_source_totals, p_submit
  );

  SELECT * INTO v_report
  FROM public.daily_work_reports r
  WHERE r.organization_id = v_org_id
    AND r.pump_id = p_pump_id
    AND r.work_date = v_work_date
    AND r.operator_id = p_target_operator_id
  FOR UPDATE;
  v_existing := FOUND;

  IF v_existing THEN
    IF p_report_id IS NOT NULL AND p_report_id <> v_report.id THEN
      RAISE EXCEPTION 'Daily report identifier does not match pump, date, and target operator'
        USING ERRCODE = '22023';
    END IF;
    IF v_report.status <> 'draft' THEN
      RAISE EXCEPTION 'Submitted daily reports are immutable; use a reviewed correction workflow'
        USING ERRCODE = '55000';
    END IF;

    UPDATE public.daily_work_reports
    SET work_started_at = p_work_started_at,
        work_ended_at = p_work_ended_at,
        stoppage_minutes = p_stoppage_minutes,
        updated_at = clock_timestamp(),
        revision = revision + 1
    WHERE id = v_report.id
    RETURNING * INTO v_report;

    DELETE FROM public.daily_work_report_items
    WHERE daily_work_report_id = v_report.id;
    v_event_type := 'draft_updated';
  ELSE
    IF p_report_id IS NOT NULL THEN
      RAISE EXCEPTION 'Daily report was not found for this operator and work date'
        USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO public.daily_work_reports (
      organization_id, pump_id, work_date, operator_id, created_by,
      work_started_at, work_ended_at, stoppage_minutes
    ) VALUES (
      v_org_id, p_pump_id, v_work_date, p_target_operator_id, v_actor_id,
      p_work_started_at, p_work_ended_at, p_stoppage_minutes
    )
    RETURNING * INTO v_report;
    v_event_type := 'draft_created';
  END IF;

  FOR v_entry_type, v_schedule_entry_id, v_allocation_id, v_subscriber_id,
      v_external_name, v_sort_order, v_manual_minutes, v_extra_minutes, v_note
  IN
    SELECT entry_type, schedule_entry_id, weekly_entitlement_allocation_id,
           subscriber_id, external_beneficiary_name, sort_order,
           manual_minutes, extra_minutes, note
    FROM jsonb_to_recordset(p_items) AS item(
      entry_type text,
      schedule_entry_id uuid,
      weekly_entitlement_allocation_id uuid,
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
    v_scheduled_minutes := 0;
    v_app_minutes := 0;
    v_subscriber_name := NULL;

    IF v_entry_type = 'weekly' THEN
      IF v_schedule_entry_id IS NULL OR v_subscriber_id IS NULL THEN
        RAISE EXCEPTION 'Weekly items require a schedule entry and subscriber'
          USING ERRCODE = '22023';
      END IF;

      SELECT s.full_name INTO v_subscriber_name
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

      IF v_subscriber_name IS NULL THEN
        RAISE EXCEPTION 'Weekly report item does not match an effective schedule entry for this day and pump'
          USING ERRCODE = '23503';
      END IF;

      IF v_allocation_id IS NULL THEN
        SELECT a.id INTO v_allocation_id
        FROM public.weekly_entitlement_allocations a
        WHERE a.organization_id = v_org_id
          AND a.pump_id = p_pump_id
          AND a.subscriber_id = v_subscriber_id
          AND a.allocation_date = v_work_date
          AND a.source_schedule_entry_id = v_schedule_entry_id
        ORDER BY a.created_at DESC, a.id
        LIMIT 1;
      END IF;

      SELECT a.allocated_minutes INTO v_scheduled_minutes
      FROM public.weekly_entitlement_allocations a
      WHERE a.id = v_allocation_id
        AND a.organization_id = v_org_id
        AND a.pump_id = p_pump_id
        AND a.subscriber_id = v_subscriber_id
        AND a.allocation_date = v_work_date
        AND a.source_schedule_entry_id = v_schedule_entry_id
        AND a.allocated_minutes > 0;

      IF v_scheduled_minutes IS NULL THEN
        RAISE EXCEPTION 'Weekly entitlement allocation does not match the schedule entry and work date'
          USING ERRCODE = '23503';
      END IF;

      v_subscriber_operator_id := water_management_private.subscriber_operator_for_work_date(
        v_subscriber_id, v_org_id, p_pump_id, v_work_date
      );
      IF v_subscriber_operator_id IS DISTINCT FROM p_target_operator_id THEN
        RAISE EXCEPTION 'Weekly subscriber is not assigned to the selected report operator on this work date'
          USING ERRCODE = '42501';
      END IF;

      SELECT floor(COALESCE(sum(op.actual_seconds), 0) / 60)::integer
      INTO v_app_minutes
      FROM public.queue_items qi
      JOIN public.pump_operations op
        ON op.id = qi.operation_id
       AND op.organization_id = qi.organization_id
       AND op.pump_id = qi.pump_id
      WHERE qi.weekly_entitlement_allocation_id = v_allocation_id
        AND qi.status = 'completed'
        AND op.status = 'completed';

    ELSIF v_entry_type = 'weekly_reassigned' THEN
      IF v_schedule_entry_id IS NOT NULL OR v_subscriber_id IS NULL THEN
        RAISE EXCEPTION 'Reassigned weekly items require a subscriber and no template schedule entry'
          USING ERRCODE = '22023';
      END IF;

      IF v_allocation_id IS NULL THEN
        SELECT a.id INTO v_allocation_id
        FROM public.weekly_entitlement_allocations a
        JOIN public.weekly_entitlement_cycles c
          ON c.id = a.weekly_entitlement_cycle_id
         AND c.organization_id = a.organization_id
         AND c.pump_id = a.pump_id
        JOIN public.weekly_schedules ws
          ON ws.id = c.weekly_schedule_id
         AND ws.organization_id = c.organization_id
         AND ws.pump_id = c.pump_id
        JOIN public.weekly_schedule_subscribers membership
          ON membership.weekly_schedule_id = ws.id
         AND membership.organization_id = ws.organization_id
         AND membership.pump_id = ws.pump_id
         AND membership.subscriber_id = a.subscriber_id
        WHERE a.organization_id = v_org_id
          AND a.pump_id = p_pump_id
          AND a.subscriber_id = v_subscriber_id
          AND a.allocation_date = v_work_date
          AND a.source_schedule_entry_id IS NULL
          AND ws.status IN ('active', 'archived')
          AND v_work_date >= ws.effective_from
          AND (ws.effective_to IS NULL OR v_work_date <= ws.effective_to)
        ORDER BY ws.effective_from DESC, ws.created_at DESC, a.created_at DESC
        LIMIT 1;
      END IF;

      SELECT a.allocated_minutes, s.full_name
      INTO v_scheduled_minutes, v_subscriber_name
      FROM public.weekly_entitlement_allocations a
      JOIN public.subscribers s
        ON s.id = a.subscriber_id
       AND s.organization_id = a.organization_id
       AND s.pump_id = a.pump_id
      WHERE a.id = v_allocation_id
        AND a.organization_id = v_org_id
        AND a.pump_id = p_pump_id
        AND a.subscriber_id = v_subscriber_id
        AND a.allocation_date = v_work_date
        AND a.source_schedule_entry_id IS NULL
        AND a.allocated_minutes > 0;

      IF v_scheduled_minutes IS NULL OR v_subscriber_name IS NULL THEN
        RAISE EXCEPTION 'Reassigned weekly allocation does not match this subscriber and work date'
          USING ERRCODE = '23503';
      END IF;

      v_subscriber_operator_id := water_management_private.subscriber_operator_for_work_date(
        v_subscriber_id, v_org_id, p_pump_id, v_work_date
      );
      IF v_subscriber_operator_id IS DISTINCT FROM p_target_operator_id THEN
        RAISE EXCEPTION 'Reassigned subscriber is not assigned to the selected report operator on this work date'
          USING ERRCODE = '42501';
      END IF;

      SELECT floor(COALESCE(sum(op.actual_seconds), 0) / 60)::integer
      INTO v_app_minutes
      FROM public.queue_items qi
      JOIN public.pump_operations op
        ON op.id = qi.operation_id
       AND op.organization_id = qi.organization_id
       AND op.pump_id = qi.pump_id
      WHERE qi.weekly_entitlement_allocation_id = v_allocation_id
        AND qi.status = 'completed'
        AND op.status = 'completed';

    ELSIF v_entry_type = 'additional_registered' THEN
      IF v_subscriber_id IS NULL OR v_schedule_entry_id IS NOT NULL OR v_allocation_id IS NOT NULL THEN
        RAISE EXCEPTION 'Additional registered item must reference only a registered subscriber'
          USING ERRCODE = '22023';
      END IF;

      SELECT s.full_name INTO v_subscriber_name
      FROM public.subscribers s
      WHERE s.id = v_subscriber_id
        AND s.organization_id = v_org_id
        AND s.pump_id = p_pump_id
        AND s.is_active;

      IF v_subscriber_name IS NULL THEN
        RAISE EXCEPTION 'Additional registered item must reference an active subscriber on this pump'
          USING ERRCODE = '23503';
      END IF;

      v_subscriber_operator_id := water_management_private.subscriber_operator_for_work_date(
        v_subscriber_id, v_org_id, p_pump_id, v_work_date
      );
      IF v_subscriber_operator_id IS DISTINCT FROM p_target_operator_id THEN
        RAISE EXCEPTION 'Additional subscriber belongs to a different report operator'
          USING ERRCODE = '42501';
      END IF;

      v_app_minutes := 0;

      v_external_name := NULL;

    ELSIF v_entry_type = 'additional_guest' THEN
      IF v_subscriber_id IS NOT NULL OR v_schedule_entry_id IS NOT NULL
         OR v_allocation_id IS NOT NULL
         OR char_length(btrim(COALESCE(v_external_name, ''))) NOT BETWEEN 2 AND 120 THEN
        RAISE EXCEPTION 'Additional guest item requires a name and no registered subscriber or allocation'
          USING ERRCODE = '22023';
      END IF;

      v_scheduled_minutes := 0;
      v_app_minutes := 0;
      v_subscriber_name := NULL;

    ELSE
      RAISE EXCEPTION 'Unknown daily work item type' USING ERRCODE = '22023';
    END IF;

    IF v_entry_type IN ('weekly', 'weekly_reassigned')
       AND v_manual_minutes > GREATEST(0, v_scheduled_minutes - v_app_minutes) THEN
      RAISE EXCEPTION 'Manual weekly minutes cannot exceed the remaining daily allocation'
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.daily_work_report_items (
      daily_work_report_id, organization_id, pump_id,
      schedule_entry_id, weekly_entitlement_allocation_id,
      subscriber_id, subscriber_name_snapshot, external_beneficiary_name,
      entry_type, sort_order, scheduled_minutes, app_recorded_minutes,
      manual_minutes, extra_minutes, note
    ) VALUES (
      v_report.id, v_org_id, p_pump_id,
      v_schedule_entry_id, v_allocation_id,
      v_subscriber_id, v_subscriber_name, NULLIF(btrim(v_external_name), ''),
      v_entry_type, v_sort_order, v_scheduled_minutes, v_app_minutes,
      v_manual_minutes, v_extra_minutes, v_note
    );

    v_item_count := v_item_count + 1;
  END LOOP;

  IF p_submit THEN
    IF EXISTS (
      SELECT 1
      FROM public.weekly_entitlement_allocations a
      WHERE a.organization_id = v_org_id
        AND a.pump_id = p_pump_id
        AND a.allocation_date = v_work_date
        AND a.allocated_minutes > 0
        AND water_management_private.subscriber_operator_for_work_date(
          a.subscriber_id, a.organization_id, a.pump_id, a.allocation_date
        ) = p_target_operator_id
        AND NOT EXISTS (
          SELECT 1 FROM public.daily_work_report_items ri
          WHERE ri.daily_work_report_id = v_report.id
            AND ri.weekly_entitlement_allocation_id = a.id
        )
    ) THEN
      RAISE EXCEPTION 'Daily report must include every positive weekly allocation for the selected operator and date'
        USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.pump_operations op
      WHERE op.organization_id = v_org_id
        AND op.pump_id = p_pump_id
        AND op.operation_date = v_work_date
        AND op.status IN ('running', 'paused')
        AND (
          op.subscriber_operator_id = p_target_operator_id
          OR (op.subscriber_id IS NULL AND op.operator_id = p_target_operator_id)
        )
    ) THEN
      RAISE EXCEPTION 'Resolve this operator active operations before submitting their daily report'
        USING ERRCODE = '55000';
    END IF;

    UPDATE public.daily_work_reports
    SET status = 'submitted',
        submitted_at = clock_timestamp(),
        submitted_by = v_actor_id,
        updated_at = clock_timestamp()
    WHERE id = v_report.id
    RETURNING * INTO v_report;
    v_event_type := 'submitted';
  END IF;

  INSERT INTO public.daily_work_report_events (
    daily_work_report_id, organization_id, pump_id, actor_id, event_type, metadata
  ) VALUES (
    v_report.id, v_org_id, p_pump_id, v_actor_id, v_event_type,
    jsonb_build_object(
      'revision', v_report.revision,
      'operator_id', p_target_operator_id,
      'energy_report_id', v_energy_report.id,
      'item_count', v_item_count,
      'submitted', p_submit
    )
  );

  RETURN v_report;
END;
$save_daily_work_report_internal_multi$;

ALTER FUNCTION water_management_private.save_daily_work_report_internal(
  uuid, uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.save_daily_work_report_internal(
  uuid, uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.save_daily_work_report_internal(
  uuid, uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) TO authenticated;

-- Close the obsolete private eight-argument implementation. The public
-- compatibility overload below is operator-self only and delegates to v2.
REVOKE ALL ON FUNCTION water_management_private.save_daily_work_report_internal(
  uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.save_daily_work_report(
  p_pump_id uuid,
  p_target_operator_id uuid,
  p_work_started_at timestamptz,
  p_work_ended_at timestamptz,
  p_stoppage_minutes integer,
  p_source_totals jsonb,
  p_items jsonb,
  p_submit boolean,
  p_report_id uuid
)
RETURNS public.daily_work_reports
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $save_daily_work_report_multi$
  SELECT water_management_private.save_daily_work_report_internal(
    p_pump_id, p_target_operator_id, p_work_started_at, p_work_ended_at,
    p_stoppage_minutes, p_source_totals, p_items, p_submit, p_report_id
  )
$save_daily_work_report_multi$;

REVOKE ALL ON FUNCTION public.save_daily_work_report(
  uuid, uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_daily_work_report(
  uuid, uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
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
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $save_daily_work_report_compat$
BEGIN
  IF water_management_private.current_user_role() <> 'operator'::public.app_role THEN
    RAISE EXCEPTION 'A target operator must be selected when a manager saves a daily report'
      USING ERRCODE = '22023';
  END IF;

  RETURN water_management_private.save_daily_work_report_internal(
    p_pump_id, auth.uid(), p_work_started_at, p_work_ended_at,
    p_stoppage_minutes, p_source_totals, p_items, p_submit, p_report_id
  );
END;
$save_daily_work_report_compat$;

REVOKE ALL ON FUNCTION public.save_daily_work_report(
  uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_daily_work_report(
  uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid
) TO authenticated;

-- Power consumption is a pump-level physical metric, not an operator-level
-- counter. It is returned once for each pump/source/day to every assigned
-- operator and supervisor; item-level workload remains operator-scoped.
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
AS $get_pump_power_usage_multi$
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
          WHERE pa.organization_id = v_org_id
            AND pa.pump_id = r.pump_id
            AND pa.user_id = v_user_id
            AND pa.assignment_role::text = v_role::text
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.daily_pump_energy_reports er
        WHERE er.organization_id = v_org_id
          AND er.pump_id = r.pump_id
          AND er.work_date = r.work_day
          AND er.status = 'submitted'
      )
    GROUP BY r.pump_id, r.power_source_id, r.source_name_snapshot, r.work_day
  ),
  submitted_days AS (
    SELECT er.pump_id, totals.power_source_id,
           totals.source_name_snapshot AS source_name,
           er.work_date,
           (totals.minutes::bigint * 60) AS seconds,
           'daily_survey'::text AS data_source
    FROM public.daily_pump_energy_reports er
    JOIN public.daily_pump_energy_source_totals totals
      ON totals.daily_pump_energy_report_id = er.id
     AND totals.organization_id = er.organization_id
     AND totals.pump_id = er.pump_id
    WHERE er.organization_id = v_org_id
      AND er.status = 'submitted'
      AND er.work_date BETWEEN p_from AND p_to
      AND (p_pump_id IS NULL OR er.pump_id = p_pump_id)
      AND (
        v_role = 'manager'
        OR EXISTS (
          SELECT 1 FROM public.pump_assignments pa
          WHERE pa.organization_id = v_org_id
            AND pa.pump_id = er.pump_id
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
  ORDER BY b.pump_id, b.bucket_start, b.source_name, b.data_source;
END;
$get_pump_power_usage_multi$;

ALTER FUNCTION water_management_private.get_pump_power_usage_internal(date, date, text, uuid)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.get_pump_power_usage_internal(date, date, text, uuid)
  FROM PUBLIC, anon;

-- The old private eight-argument function must not remain executable by API roles.
-- The compatibility public wrapper is the only supported legacy call surface.
COMMENT ON FUNCTION public.save_daily_work_report(uuid, uuid, timestamptz, timestamptz, integer, jsonb, jsonb, boolean, uuid) IS
  'Creates/updates one workload report for the selected operator and one shared pump energy survey per pump/date.';


-- Return the correct operator ownership for the requested work date, not the
-- subscriber's mutable current operator_id. This powers the historical report UI
-- after a subscriber has moved to a different operator.
CREATE OR REPLACE FUNCTION water_management_private.get_daily_work_report_allocations_internal(
  p_pump_id uuid,
  p_work_date date
)
RETURNS TABLE (
  id uuid,
  subscriber_id uuid,
  allocation_date date,
  source_schedule_entry_id uuid,
  original_minutes integer,
  allocated_minutes integer,
  consumed_minutes integer,
  available_minutes integer,
  weekday smallint,
  sort_order integer,
  full_name text,
  subscriber_number integer,
  branch_id uuid,
  operator_id uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $get_daily_work_report_allocations_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
BEGIN
  IF v_user_id IS NULL OR v_org_id IS NULL
     OR v_role NOT IN (
       'manager'::public.app_role,
       'operator'::public.app_role,
       'supervisor'::public.app_role
     ) THEN
    RAISE EXCEPTION 'Not authorized to read daily report allocations'
      USING ERRCODE = '42501';
  END IF;

  IF p_pump_id IS NULL OR p_work_date IS NULL THEN
    RAISE EXCEPTION 'Pump and work date are required'
      USING ERRCODE = '22023';
  END IF;

  IF v_role <> 'manager'::public.app_role AND NOT EXISTS (
    SELECT 1
    FROM public.pump_assignments pa
    WHERE pa.organization_id = v_org_id
      AND pa.pump_id = p_pump_id
      AND pa.user_id = v_user_id
      AND pa.assignment_role = v_role
  ) THEN
    RAISE EXCEPTION 'User is not assigned to this pump'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.pumps p
    WHERE p.id = p_pump_id
      AND p.organization_id = v_org_id
  ) THEN
    RAISE EXCEPTION 'Pump is not accessible'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    a.id,
    a.subscriber_id,
    a.allocation_date,
    a.source_schedule_entry_id,
    a.original_minutes,
    a.allocated_minutes,
    a.consumed_minutes,
    a.available_minutes,
    COALESCE(e.weekday, extract(isodow FROM p_work_date)::smallint)::smallint,
    COALESCE(e.sort_order, 2147483647)::integer,
    s.full_name,
    s.subscriber_number,
    s.branch_id,
    water_management_private.subscriber_operator_for_work_date(
      s.id, s.organization_id, s.pump_id, p_work_date
    ) AS operator_id
  FROM public.weekly_entitlement_allocations a
  JOIN public.subscribers s
    ON s.id = a.subscriber_id
   AND s.organization_id = a.organization_id
   AND s.pump_id = a.pump_id
  LEFT JOIN public.schedule_entries e
    ON e.id = a.source_schedule_entry_id
   AND e.organization_id = a.organization_id
   AND e.pump_id = a.pump_id
   AND e.subscriber_id = a.subscriber_id
  WHERE a.organization_id = v_org_id
    AND a.pump_id = p_pump_id
    AND a.allocation_date = p_work_date
    AND a.allocated_minutes > 0
    AND (
      v_role <> 'operator'::public.app_role
      OR water_management_private.subscriber_operator_for_work_date(
        s.id, s.organization_id, s.pump_id, p_work_date
      ) = v_user_id
    )
  ORDER BY
    COALESCE(e.sort_order, 2147483647),
    s.subscriber_number,
    a.id;
END;
$get_daily_work_report_allocations_internal$;

ALTER FUNCTION water_management_private.get_daily_work_report_allocations_internal(uuid, date)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.get_daily_work_report_allocations_internal(uuid, date)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.get_daily_work_report_allocations_internal(uuid, date)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_daily_work_report_allocations(
  p_pump_id uuid,
  p_work_date date
)
RETURNS TABLE (
  id uuid,
  subscriber_id uuid,
  allocation_date date,
  source_schedule_entry_id uuid,
  original_minutes integer,
  allocated_minutes integer,
  consumed_minutes integer,
  available_minutes integer,
  weekday smallint,
  sort_order integer,
  full_name text,
  subscriber_number integer,
  branch_id uuid,
  operator_id uuid
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $get_daily_work_report_allocations$
  SELECT *
  FROM water_management_private.get_daily_work_report_allocations_internal(
    p_pump_id, p_work_date
  )
$get_daily_work_report_allocations$;

REVOKE ALL ON FUNCTION public.get_daily_work_report_allocations(uuid, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_daily_work_report_allocations(uuid, date)
  TO authenticated;



-- Prepare the weekly entitlement snapshot for a report date without generating
-- a daily queue. Reporting an idle/rest day must not create runnable queue rows.
CREATE OR REPLACE FUNCTION water_management_private.prepare_daily_work_report_internal(
  p_pump_id uuid,
  p_work_date date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $prepare_daily_work_report_internal$
DECLARE
  v_actor_id uuid := auth.uid();
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_schedule record;
  v_cycle_start date;
  v_prepared_count integer := 0;
BEGIN
  IF v_actor_id IS NULL OR v_org_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to prepare a daily work report'
      USING ERRCODE = '42501';
  END IF;

  IF p_pump_id IS NULL OR p_work_date IS NULL THEN
    RAISE EXCEPTION 'Pump and work date are required'
      USING ERRCODE = '22023';
  END IF;

  IF v_role = 'operator'::public.app_role AND NOT EXISTS (
    SELECT 1 FROM public.pump_assignments pa
    WHERE pa.organization_id = v_org_id
      AND pa.pump_id = p_pump_id
      AND pa.user_id = v_actor_id
      AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump'
      USING ERRCODE = '42501';
  END IF;

  PERFORM 1
  FROM public.pumps p
  WHERE p.id = p_pump_id
    AND p.organization_id = v_org_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pump is not accessible'
      USING ERRCODE = '42501';
  END IF;

  FOR v_schedule IN
    SELECT ws.id, ws.week_starts_on
    FROM public.weekly_schedules ws
    WHERE ws.organization_id = v_org_id
      AND ws.pump_id = p_pump_id
      AND ws.status IN ('active', 'archived')
      AND p_work_date >= ws.effective_from
      AND (ws.effective_to IS NULL OR p_work_date <= ws.effective_to)
    ORDER BY ws.effective_from DESC, ws.id
  LOOP
    v_cycle_start := p_work_date - (
      (extract(isodow FROM p_work_date)::integer - v_schedule.week_starts_on + 7) % 7
    );

    PERFORM water_management_private.ensure_weekly_entitlement_cycle(
      v_schedule.id, v_org_id, p_pump_id, v_cycle_start, v_actor_id
    );
    v_prepared_count := v_prepared_count + 1;
  END LOOP;

  RETURN v_prepared_count;
END;
$prepare_daily_work_report_internal$;

ALTER FUNCTION water_management_private.prepare_daily_work_report_internal(uuid, date)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.prepare_daily_work_report_internal(uuid, date)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.prepare_daily_work_report_internal(uuid, date)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.prepare_daily_work_report(
  p_pump_id uuid,
  p_work_date date
)
RETURNS integer
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $prepare_daily_work_report$
  SELECT water_management_private.prepare_daily_work_report_internal(
    p_pump_id, p_work_date
  )
$prepare_daily_work_report$;

REVOKE ALL ON FUNCTION public.prepare_daily_work_report(uuid, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prepare_daily_work_report(uuid, date)
  TO authenticated;
