-- Scope operational reads to the subscriber's responsible operator.
-- Managers retain organization-wide access. Supervisors/collectors retain
-- their existing pump-level read scope where they had it.
--
-- SECURITY DEFINER helpers live in the private schema, pin search_path, and
-- validate auth.uid()/tenant/role explicitly. They exist to avoid RLS recursion
-- when a policy needs to consult subscribers or pump_assignments.

CREATE OR REPLACE FUNCTION water_management_private.can_read_subscriber_scope(
  p_organization_id uuid,
  p_pump_id uuid,
  p_subscriber_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $can_read_subscriber_scope$
  SELECT
    (SELECT auth.uid()) IS NOT NULL
    AND p_organization_id = water_management_private.current_user_organization_id()
    AND p_subscriber_id IS NOT NULL
    AND CASE water_management_private.current_user_role()
      WHEN 'manager'::public.app_role THEN true
      WHEN 'operator'::public.app_role THEN EXISTS (
        SELECT 1
        FROM public.subscribers s
        WHERE s.id = p_subscriber_id
          AND s.organization_id = p_organization_id
          AND s.pump_id = p_pump_id
          AND s.operator_id = (SELECT auth.uid())
      )
      WHEN 'supervisor'::public.app_role THEN EXISTS (
        SELECT 1
        FROM public.pump_assignments pa
        WHERE pa.organization_id = p_organization_id
          AND pa.pump_id = p_pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = 'supervisor'::public.app_role
      )
      WHEN 'collector'::public.app_role THEN EXISTS (
        SELECT 1
        FROM public.pump_assignments pa
        WHERE pa.organization_id = p_organization_id
          AND pa.pump_id = p_pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = 'collector'::public.app_role
      )
      ELSE false
    END
$can_read_subscriber_scope$;
ALTER FUNCTION water_management_private.can_read_subscriber_scope(uuid, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.can_read_subscriber_scope(uuid, uuid, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.can_read_subscriber_scope(uuid, uuid, uuid)
  TO authenticated;


CREATE OR REPLACE FUNCTION water_management_private.can_read_supervisor_pump_scope(
  p_organization_id uuid,
  p_pump_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $can_read_supervisor_pump_scope$
  SELECT
    (SELECT auth.uid()) IS NOT NULL
    AND p_organization_id = water_management_private.current_user_organization_id()
    AND water_management_private.current_user_role() = 'supervisor'::public.app_role
    AND EXISTS (
      SELECT 1
      FROM public.pump_assignments pa
      WHERE pa.organization_id = p_organization_id
        AND pa.pump_id = p_pump_id
        AND pa.user_id = (SELECT auth.uid())
        AND pa.assignment_role = 'supervisor'::public.app_role
    )
$can_read_supervisor_pump_scope$;
ALTER FUNCTION water_management_private.can_read_supervisor_pump_scope(uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.can_read_supervisor_pump_scope(uuid, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.can_read_supervisor_pump_scope(uuid, uuid)
  TO authenticated;

-- Snapshot the responsible operator on each operation when it starts. This
-- keeps historical operations with their original owner after subscriber
-- reassignment, independently of the operation executor (operator_id).
ALTER TABLE public.pump_operations
  ADD COLUMN subscriber_operator_id uuid;

UPDATE public.pump_operations op
SET subscriber_operator_id = s.operator_id
FROM public.subscribers s
WHERE s.id = op.subscriber_id
  AND s.organization_id = op.organization_id
  AND s.pump_id = op.pump_id;

CREATE INDEX pump_operations_subscriber_operator_date_idx
  ON public.pump_operations (organization_id, subscriber_operator_id, operation_date DESC)
  WHERE subscriber_operator_id IS NOT NULL;

CREATE FUNCTION water_management_private.capture_pump_operation_subscriber_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $capture_pump_operation_subscriber_owner$
BEGIN
  IF NEW.subscriber_id IS NULL THEN
    NEW.subscriber_operator_id := NULL;
    RETURN NEW;
  END IF;

  SELECT s.operator_id INTO NEW.subscriber_operator_id
  FROM public.subscribers s
  WHERE s.id = NEW.subscriber_id
    AND s.organization_id = NEW.organization_id
    AND s.pump_id = NEW.pump_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Operation subscriber does not belong to the same organization and pump'
      USING ERRCODE = '23503';
  END IF;

  IF NEW.subscriber_operator_id IS NULL
     AND water_management_private.current_user_role() = 'operator'::public.app_role THEN
    RAISE EXCEPTION 'Registered operation requires an assigned subscriber operator'
      USING ERRCODE = '23503';
  END IF;

  RETURN NEW;
END;
$capture_pump_operation_subscriber_owner$;
REVOKE ALL ON FUNCTION water_management_private.capture_pump_operation_subscriber_owner()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER a_capture_pump_operation_subscriber_owner
  BEFORE INSERT ON public.pump_operations
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.capture_pump_operation_subscriber_owner();

CREATE OR REPLACE FUNCTION water_management_private.can_read_operation_snapshot_scope(
  p_organization_id uuid,
  p_pump_id uuid,
  p_subscriber_id uuid,
  p_subscriber_operator_id uuid,
  p_executor_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $can_read_operation_snapshot_scope$
  SELECT
    (SELECT auth.uid()) IS NOT NULL
    AND p_organization_id = water_management_private.current_user_organization_id()
    AND CASE water_management_private.current_user_role()
      WHEN 'manager'::public.app_role THEN true
      WHEN 'operator'::public.app_role THEN
        CASE
          WHEN p_subscriber_id IS NULL
            THEN p_executor_id = (SELECT auth.uid())
          ELSE p_subscriber_operator_id = (SELECT auth.uid())
        END
      ELSE false
    END
$can_read_operation_snapshot_scope$;
ALTER FUNCTION water_management_private.can_read_operation_snapshot_scope(uuid, uuid, uuid, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.can_read_operation_snapshot_scope(uuid, uuid, uuid, uuid, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.can_read_operation_snapshot_scope(uuid, uuid, uuid, uuid, uuid)
  TO authenticated;

-- Report item ownership is also a historical snapshot. The report author may
-- retain guest rows; registered subscriber rows remain visible to the operator
-- who owned the subscriber when the report item was recorded.
ALTER TABLE public.daily_work_report_items
  ADD COLUMN assigned_operator_id uuid;

UPDATE public.daily_work_report_items ri
SET assigned_operator_id = s.operator_id
FROM public.subscribers s
WHERE s.id = ri.subscriber_id
  AND s.organization_id = ri.organization_id
  AND s.pump_id = ri.pump_id;

CREATE INDEX daily_work_report_items_assigned_operator_idx
  ON public.daily_work_report_items (daily_work_report_id, assigned_operator_id)
  WHERE assigned_operator_id IS NOT NULL;

-- Subscriber master rows: an operator sees only their own assigned subscribers.
DROP POLICY IF EXISTS "members_select_subscribers" ON public.subscribers;
CREATE POLICY members_select_subscribers
  ON public.subscribers
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.can_read_subscriber_scope(
      organization_id, pump_id, id
    ))
  );

-- Each schedule entry and versioned entitlement row inherits the same subscriber
-- responsibility boundary. The schedule header and its version events remain
-- pump-scoped because they contain pump-level schedule metadata, not subscriber
-- fulfillment records.
DROP POLICY IF EXISTS schedule_entries_select_assigned_pumps ON public.schedule_entries;
CREATE POLICY schedule_entries_select_assigned_pumps
  ON public.schedule_entries
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.can_read_subscriber_scope(
      organization_id, pump_id, subscriber_id
    ))
  );

DROP POLICY IF EXISTS weekly_schedule_subscribers_select_assigned ON public.weekly_schedule_subscribers;
CREATE POLICY weekly_schedule_subscribers_select_assigned
  ON public.weekly_schedule_subscribers
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.can_read_subscriber_scope(
      organization_id, pump_id, subscriber_id
    ))
  );

DROP POLICY IF EXISTS weekly_entitlement_cycles_select_assigned ON public.weekly_entitlement_cycles;
CREATE POLICY weekly_entitlement_cycles_select_assigned
  ON public.weekly_entitlement_cycles
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role())
      IN ('manager'::public.app_role, 'operator'::public.app_role, 'supervisor'::public.app_role)
    AND (SELECT water_management_private.can_read_subscriber_scope(
      organization_id, pump_id, subscriber_id
    ))
  );

DROP POLICY IF EXISTS weekly_entitlement_allocations_select_assigned ON public.weekly_entitlement_allocations;
CREATE POLICY weekly_entitlement_allocations_select_assigned
  ON public.weekly_entitlement_allocations
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role())
      IN ('manager'::public.app_role, 'operator'::public.app_role, 'supervisor'::public.app_role)
    AND (SELECT water_management_private.can_read_subscriber_scope(
      organization_id, pump_id, subscriber_id
    ))
  );

DROP POLICY IF EXISTS weekly_entitlement_events_select_assigned ON public.weekly_entitlement_events;
CREATE POLICY weekly_entitlement_events_select_assigned
  ON public.weekly_entitlement_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role())
      IN ('manager'::public.app_role, 'operator'::public.app_role, 'supervisor'::public.app_role)
    AND (SELECT water_management_private.can_read_subscriber_scope(
      organization_id, pump_id, subscriber_id
    ))
  );

-- Operation records are visible to managers and to the responsible operator.
-- Guest/emergency operations (subscriber_id IS NULL) remain visible to the
-- operator who actually executed them. Supervisor access is not expanded here.
DROP POLICY IF EXISTS pump_operations_select_scoped ON public.pump_operations;
CREATE POLICY pump_operations_select_scoped
  ON public.pump_operations
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.can_read_operation_snapshot_scope(
      organization_id, pump_id, subscriber_id,
      subscriber_operator_id, operator_id
    ))
  );

DROP POLICY IF EXISTS pump_operation_events_select_scoped ON public.pump_operation_events;
CREATE POLICY pump_operation_events_select_scoped
  ON public.pump_operation_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1
      FROM public.pump_operations op
      WHERE op.id = pump_operation_events.operation_id
        AND op.organization_id = pump_operation_events.organization_id
        AND op.pump_id = pump_operation_events.pump_id
        AND (SELECT water_management_private.can_read_operation_snapshot_scope(
          op.organization_id, op.pump_id, op.subscriber_id,
          op.subscriber_operator_id, op.operator_id
        ))
    )
  );

-- Supervisors retain their former pump-level read scope for source segments;
-- operators are restricted to operations belonging to their subscribers.
DROP POLICY IF EXISTS pump_operation_power_segments_select_scoped ON public.pump_operation_power_segments;
CREATE POLICY pump_operation_power_segments_select_scoped
  ON public.pump_operation_power_segments
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.can_read_supervisor_pump_scope(
        organization_id, pump_id
      ))
      OR EXISTS (
        SELECT 1
        FROM public.pump_operations op
        WHERE op.id = pump_operation_power_segments.operation_id
          AND op.organization_id = pump_operation_power_segments.organization_id
          AND op.pump_id = pump_operation_power_segments.pump_id
          AND (SELECT water_management_private.can_read_operation_snapshot_scope(
            op.organization_id, op.pump_id, op.subscriber_id,
            op.subscriber_operator_id, op.operator_id
          ))
      )
    )
  );

-- Operators may read only their own queue rows. The global queue order is still
-- needed for correct handoff, so a dedicated RPC below returns redacted
-- placeholders for other operators' rows rather than exposing their details.
DROP POLICY IF EXISTS queue_items_select_assigned ON public.queue_items;
CREATE POLICY queue_items_select_assigned
  ON public.queue_items
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1 FROM public.daily_queues q
      WHERE q.id = queue_items.daily_queue_id
        AND q.organization_id = queue_items.organization_id
        AND q.pump_id = queue_items.pump_id
    )
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR (
        (SELECT water_management_private.current_user_role()) = 'operator'::public.app_role
        AND assigned_operator_id = (SELECT auth.uid())
      )
      OR (SELECT water_management_private.can_read_supervisor_pump_scope(
        organization_id, pump_id
      ))
    )
  );

DROP POLICY IF EXISTS queue_item_events_select_assigned ON public.queue_item_events;
CREATE POLICY queue_item_events_select_assigned
  ON public.queue_item_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR (SELECT water_management_private.can_read_supervisor_pump_scope(
        organization_id, pump_id
      ))
      OR (
        (SELECT water_management_private.current_user_role()) = 'operator'::public.app_role
        AND actor_id = (SELECT auth.uid())
        AND EXISTS (
          SELECT 1
          FROM public.queue_items qi
          WHERE qi.id = queue_item_events.queue_item_id
            AND qi.daily_queue_id = queue_item_events.daily_queue_id
            AND qi.organization_id = queue_item_events.organization_id
            AND qi.pump_id = queue_item_events.pump_id
            AND qi.assigned_operator_id = (SELECT auth.uid())
        )
      )
    )
  );

-- Daily reports are still a single report per pump/day in this version. An
-- operator therefore sees only the report they authored; managers and assigned
-- supervisors retain pump-wide report access. The separate multi-operator
-- report model remains a follow-up before several operators can submit reports
-- for the same pump/day.
DROP POLICY IF EXISTS daily_work_reports_select_scoped ON public.daily_work_reports;
CREATE POLICY daily_work_reports_select_scoped
  ON public.daily_work_reports
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR (SELECT water_management_private.can_read_supervisor_pump_scope(
        organization_id, pump_id
      ))
      OR (
        (SELECT water_management_private.current_user_role()) = 'operator'::public.app_role
        AND operator_id = (SELECT auth.uid())
      )
    )
  );

DROP POLICY IF EXISTS daily_work_source_totals_select_scoped ON public.daily_work_source_totals;
CREATE POLICY daily_work_source_totals_select_scoped
  ON public.daily_work_source_totals
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1
      FROM public.daily_work_reports r
      WHERE r.id = daily_work_source_totals.daily_work_report_id
        AND r.organization_id = daily_work_source_totals.organization_id
        AND r.pump_id = daily_work_source_totals.pump_id
    )
  );

DROP POLICY IF EXISTS daily_work_report_items_select_scoped ON public.daily_work_report_items;
CREATE POLICY daily_work_report_items_select_scoped
  ON public.daily_work_report_items
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1
      FROM public.daily_work_reports r
      WHERE r.id = daily_work_report_items.daily_work_report_id
        AND r.organization_id = daily_work_report_items.organization_id
        AND r.pump_id = daily_work_report_items.pump_id
    )
    AND (
      (SELECT water_management_private.current_user_role()) <> 'operator'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.daily_work_reports r
        WHERE r.id = daily_work_report_items.daily_work_report_id
          AND r.organization_id = daily_work_report_items.organization_id
          AND r.pump_id = daily_work_report_items.pump_id
          AND r.operator_id = (SELECT auth.uid())
      )
    )
    AND (
      (SELECT water_management_private.current_user_role()) <> 'operator'::public.app_role
      OR subscriber_id IS NULL
      OR assigned_operator_id = (SELECT auth.uid())
    )
  );

DROP POLICY IF EXISTS daily_work_report_events_select_scoped ON public.daily_work_report_events;
CREATE POLICY daily_work_report_events_select_scoped
  ON public.daily_work_report_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1
      FROM public.daily_work_reports r
      WHERE r.id = daily_work_report_events.daily_work_report_id
        AND r.organization_id = daily_work_report_events.organization_id
        AND r.pump_id = daily_work_report_events.pump_id
    )
  );

-- A privileged report writer must not be able to smuggle another operator's
-- subscriber into a report item. This trigger complements RLS because the save
-- RPC is SECURITY DEFINER and therefore does not rely on table policies.
CREATE OR REPLACE FUNCTION water_management_private.guard_daily_work_report_item_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $guard_daily_work_report_item_owner$
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

  IF v_role = 'operator'::public.app_role
     AND v_report.operator_id <> auth.uid() THEN
    RAISE EXCEPTION 'Operator can only edit their own daily work report'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.subscriber_id IS NULL THEN
    NEW.assigned_operator_id := NULL;
    RETURN NEW;
  END IF;

  SELECT s.operator_id INTO v_subscriber_operator_id
  FROM public.subscribers s
  WHERE s.id = NEW.subscriber_id
    AND s.organization_id = NEW.organization_id
    AND s.pump_id = NEW.pump_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily report item must reference a subscriber on the same pump'
      USING ERRCODE = '23503';
  END IF;

  IF v_role = 'operator'::public.app_role
     AND v_subscriber_operator_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Daily report item belongs to another operator or has no assigned operator'
      USING ERRCODE = '42501';
  END IF;

  NEW.assigned_operator_id := v_subscriber_operator_id;
  RETURN NEW;
END;
$guard_daily_work_report_item_owner$;
ALTER FUNCTION water_management_private.guard_daily_work_report_item_owner() OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.guard_daily_work_report_item_owner()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER daily_work_report_item_owner_guard
  BEFORE INSERT OR UPDATE ON public.daily_work_report_items
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.guard_daily_work_report_item_owner();

-- Source segments and power-use summaries must follow the same owner boundary.
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
AS $get_pump_power_usage_internal$
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
      AND (
        v_role <> 'operator'
        OR EXISTS (
          SELECT 1
          FROM public.pump_operations op
          WHERE op.id = seg.operation_id
            AND op.organization_id = seg.organization_id
            AND op.pump_id = seg.pump_id
            AND (SELECT water_management_private.can_read_operation_snapshot_scope(
              op.organization_id, op.pump_id, op.subscriber_id,
              op.subscriber_operator_id, op.operator_id
            ))
        )
      )
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
          AND (
            v_role <> 'operator'
            OR report.operator_id = v_user_id
          )
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
        OR (
          v_role = 'operator'
          AND report.operator_id = v_user_id
        )
        OR (
          v_role = 'supervisor'
          AND EXISTS (
            SELECT 1 FROM public.pump_assignments pa
            WHERE pa.organization_id = v_org_id
              AND pa.pump_id = report.pump_id
              AND pa.user_id = v_user_id
              AND pa.assignment_role = 'supervisor'::public.app_role
          )
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
$get_pump_power_usage_internal$;

REVOKE ALL ON FUNCTION water_management_private.get_pump_power_usage_internal(date, date, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.get_pump_power_usage_internal(date, date, text, uuid)
  TO authenticated;

-- Transfer options and transfer actions are SECURITY DEFINER: filter by
-- subscriber ownership explicitly instead of trusting the caller's table RLS.
CREATE OR REPLACE FUNCTION water_management_private.get_daily_queue_operator_view_internal(
  p_queue_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $get_daily_queue_operator_view_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_queue public.daily_queues%ROWTYPE;
  v_items jsonb;
  v_events jsonb;
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role, 'supervisor'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to read this daily queue'
      USING ERRCODE = '42501';
  END IF;

  SELECT q.* INTO v_queue
  FROM public.daily_queues q
  WHERE q.id = p_queue_id
    AND q.organization_id = v_organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily queue not found or not accessible'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_role = 'operator'::public.app_role AND NOT EXISTS (
    SELECT 1 FROM public.pump_assignments pa
    WHERE pa.organization_id = v_organization_id
      AND pa.pump_id = v_queue.pump_id
      AND pa.user_id = v_user_id
      AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump'
      USING ERRCODE = '42501';
  END IF;

  IF v_role = 'supervisor'::public.app_role
     AND NOT (SELECT water_management_private.can_read_supervisor_pump_scope(
       v_organization_id, v_queue.pump_id
     )) THEN
    RAISE EXCEPTION 'Supervisor is not assigned to this pump'
      USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(jsonb_agg(item_payload ORDER BY sort_order, item_id), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT qi.sort_order, qi.id AS item_id,
      CASE
        WHEN v_role IN ('manager'::public.app_role, 'supervisor'::public.app_role)
          OR qi.assigned_operator_id = v_user_id
        THEN jsonb_build_object(
          'id', qi.id,
          'daily_queue_id', qi.daily_queue_id,
          'source_type', qi.source_type,
          'schedule_entry_id', qi.schedule_entry_id,
          'subscriber_id', qi.subscriber_id,
          'subscriber_name_snapshot', qi.subscriber_name_snapshot,
          'branch_id', qi.branch_id,
          'branch_name_snapshot', qi.branch_name_snapshot,
          'planned_minutes', qi.planned_minutes,
          'sort_order', qi.sort_order,
          'status', qi.status,
          'operation_id', qi.operation_id,
          'started_at', qi.started_at,
          'completed_at', qi.completed_at,
          'weekly_entitlement_allocation_id', qi.weekly_entitlement_allocation_id,
          'is_owned', true
        )
        ELSE jsonb_build_object(
          'id', qi.id,
          'daily_queue_id', qi.daily_queue_id,
          'source_type', 'other',
          'schedule_entry_id', NULL,
          'subscriber_id', NULL,
          'subscriber_name_snapshot', 'دور لمشغّل آخر',
          'branch_id', NULL,
          'branch_name_snapshot', NULL,
          'planned_minutes', 0,
          'sort_order', qi.sort_order,
          'status', qi.status,
          'operation_id', NULL,
          'started_at', NULL,
          'completed_at', NULL,
          'weekly_entitlement_allocation_id', NULL,
          'is_owned', false
        )
      END AS item_payload
    FROM public.queue_items qi
    WHERE qi.daily_queue_id = p_queue_id
      AND qi.organization_id = v_organization_id
      AND qi.pump_id = v_queue.pump_id
  ) visible_items;

  SELECT COALESCE(jsonb_agg(event_payload ORDER BY event_sequence DESC), '[]'::jsonb)
  INTO v_events
  FROM (
    SELECT e.event_sequence,
      jsonb_build_object(
        'id', e.id,
        'event_type', e.event_type,
        'actor_id', CASE
          WHEN v_role IN ('manager'::public.app_role, 'supervisor'::public.app_role)
            OR e.actor_id = v_user_id
          THEN e.actor_id ELSE NULL END,
        'occurred_at', e.occurred_at,
        'reason', CASE
          WHEN v_role IN ('manager'::public.app_role, 'supervisor'::public.app_role)
            OR e.actor_id = v_user_id
          THEN e.reason ELSE NULL END,
        'metadata', CASE
          WHEN v_role IN ('manager'::public.app_role, 'supervisor'::public.app_role)
          THEN e.metadata ELSE '{}'::jsonb END
      ) AS event_payload
    FROM public.queue_item_events e
    WHERE e.daily_queue_id = p_queue_id
      AND e.organization_id = v_organization_id
      AND e.pump_id = v_queue.pump_id
      AND (
        v_role IN ('manager'::public.app_role, 'supervisor'::public.app_role)
        OR (
          v_role = 'operator'::public.app_role
          AND EXISTS (
            SELECT 1 FROM public.queue_items qi
            WHERE qi.id = e.queue_item_id
              AND qi.daily_queue_id = e.daily_queue_id
              AND qi.assigned_operator_id = v_user_id
          )
          AND (
            e.actor_id = v_user_id
            OR e.event_type = 'item_operator_reassigned'
          )
        )
      )
    ORDER BY e.event_sequence DESC
    LIMIT 8
  ) visible_events;

  RETURN jsonb_build_object(
    'items', v_items,
    'events', v_events
  );
END;
$get_daily_queue_operator_view_internal$;
ALTER FUNCTION water_management_private.get_daily_queue_operator_view_internal(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.get_daily_queue_operator_view_internal(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.get_daily_queue_operator_view_internal(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_daily_queue_operator_view(p_queue_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $get_daily_queue_operator_view_rpc$
  SELECT water_management_private.get_daily_queue_operator_view_internal(p_queue_id)
$get_daily_queue_operator_view_rpc$;
REVOKE ALL ON FUNCTION public.get_daily_queue_operator_view(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_daily_queue_operator_view(uuid)
  TO authenticated;


-- Replace the invoker wrapper so the selected allocation must be visible to
-- this operator under RLS and match the subscriber owner before the definer
-- implementation can perform any transfer.
CREATE OR REPLACE FUNCTION public.transfer_weekly_entitlement_minutes(
  p_source_allocation_id uuid,
  p_target_date date,
  p_minutes integer,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $transfer_weekly_entitlement_minutes_scoped$
DECLARE
  v_source public.weekly_entitlement_allocations%ROWTYPE;
BEGIN
  SELECT a.* INTO v_source
  FROM public.weekly_entitlement_allocations a
  WHERE a.id = p_source_allocation_id
    AND a.organization_id = water_management_private.current_user_organization_id();

  IF NOT FOUND OR NOT (SELECT water_management_private.can_read_subscriber_scope(
    v_source.organization_id, v_source.pump_id, v_source.subscriber_id
  )) THEN
    RAISE EXCEPTION 'Source weekly allocation is not assigned to the current operator'
      USING ERRCODE = '42501';
  END IF;

  RETURN water_management_private.transfer_weekly_entitlement_minutes_internal(
    p_source_allocation_id, p_target_date, p_minutes, p_reason
  );
END;
$transfer_weekly_entitlement_minutes_scoped$;

REVOKE ALL ON FUNCTION public.transfer_weekly_entitlement_minutes(uuid, date, integer, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_weekly_entitlement_minutes(uuid, date, integer, text)
  TO authenticated;

-- The internal definer can see every allocation, so filter its result set again
-- in the invoker wrapper before it is returned over the Data API.
CREATE OR REPLACE FUNCTION public.get_weekly_entitlement_transfer_options(
  p_pump_id uuid,
  p_target_date date
)
RETURNS TABLE (
  allocation_id uuid,
  subscriber_id uuid,
  subscriber_name text,
  source_date date,
  original_minutes integer,
  allocated_minutes integer,
  consumed_minutes integer,
  available_minutes integer,
  target_allocated_minutes integer,
  weekly_quota_minutes integer,
  weekly_consumed_minutes integer,
  weekly_remaining_minutes integer,
  cycle_start date,
  cycle_end date
)
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $get_weekly_entitlement_transfer_options_scoped$
  SELECT options.*
  FROM water_management_private.get_weekly_entitlement_transfer_options_internal(
    p_pump_id, p_target_date
  ) AS options
  WHERE (SELECT water_management_private.can_read_subscriber_scope(
    water_management_private.current_user_organization_id(),
    p_pump_id,
    options.subscriber_id
  ))
$get_weekly_entitlement_transfer_options_scoped$;

REVOKE ALL ON FUNCTION public.get_weekly_entitlement_transfer_options(uuid, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_weekly_entitlement_transfer_options(uuid, date)
  TO authenticated;


-- Cancelling an auto-advance changes the handoff to a specific operator's
-- waiting turn. Only the manager or that target item's owner may cancel it.
CREATE OR REPLACE FUNCTION water_management_private.cancel_daily_queue_auto_advance_internal(
  p_queue_id uuid,
  p_auto_advance_token uuid,
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $cancel_daily_queue_auto_advance_scoped$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_queue public.daily_queues%ROWTYPE;
  v_target public.queue_items%ROWTYPE;
  v_now timestamptz := clock_timestamp();
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to cancel queue auto-advance' USING ERRCODE = '42501';
  END IF;
  IF v_reason IS NOT NULL AND char_length(v_reason) > 240 THEN
    RAISE EXCEPTION 'Cancellation reason must not exceed 240 characters' USING ERRCODE = '22023';
  END IF;

  SELECT q.* INTO v_queue
  FROM public.daily_queues q
  WHERE q.id = p_queue_id
    AND q.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily queue not found or not accessible' USING ERRCODE = 'P0002';
  END IF;

  IF v_role = 'operator'::public.app_role AND NOT EXISTS (
    SELECT 1 FROM public.pump_assignments pa
    WHERE pa.organization_id = v_organization_id
      AND pa.pump_id = v_queue.pump_id
      AND pa.user_id = v_user_id
      AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump' USING ERRCODE = '42501';
  END IF;

  IF p_auto_advance_token IS NULL
     OR v_queue.auto_advance_token IS DISTINCT FROM p_auto_advance_token
     OR v_queue.auto_advance_queue_item_id IS NULL THEN
    RAISE EXCEPTION 'Auto-advance was already consumed or replaced' USING ERRCODE = 'P0002';
  END IF;

  SELECT qi.* INTO v_target
  FROM public.queue_items qi
  WHERE qi.id = v_queue.auto_advance_queue_item_id
    AND qi.daily_queue_id = p_queue_id
    AND qi.organization_id = v_organization_id
    AND qi.pump_id = v_queue.pump_id
  FOR UPDATE;
  IF NOT FOUND OR v_target.status <> 'queued' THEN
    RAISE EXCEPTION 'Auto-advance target is no longer waiting' USING ERRCODE = 'P0002';
  END IF;

  IF v_role = 'operator'::public.app_role
     AND v_target.assigned_operator_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'Only the target operator or manager may cancel this handoff'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.daily_queues
  SET auto_advance_queue_item_id = NULL,
      auto_advance_at = NULL,
      auto_advance_token = NULL,
      auto_advance_cancelled_at = v_now,
      queue_version = queue_version + 1,
      updated_at = v_now
  WHERE id = p_queue_id;

  PERFORM water_management_private.append_queue_item_event(
    p_queue_id, v_queue.auto_advance_queue_item_id, v_organization_id, v_queue.pump_id,
    'auto_advance_cancelled', v_user_id, v_reason,
    jsonb_build_object('cancelled_at', v_now, 'previous_token_consumed', true)
  );

  RETURN true;
END;
$cancel_daily_queue_auto_advance_scoped$;
ALTER FUNCTION water_management_private.cancel_daily_queue_auto_advance_internal(uuid, uuid, text)
  OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.cancel_daily_queue_auto_advance_internal(uuid, uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.cancel_daily_queue_auto_advance_internal(uuid, uuid, text)
  TO authenticated;
