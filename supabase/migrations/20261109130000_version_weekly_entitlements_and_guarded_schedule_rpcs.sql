-- Keep weekly quota/default-day snapshots with each schedule version.
-- Subscriber columns remain a convenience snapshot of the schedule currently in force;
-- historic and future versions read their own weekly_schedule_subscribers rows.

CREATE TABLE public.weekly_schedule_subscribers (
  weekly_schedule_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  subscriber_id uuid NOT NULL,
  weekly_quota_minutes integer NOT NULL CHECK (weekly_quota_minutes BETWEEN 1 AND 10080),
  default_weekday smallint NOT NULL CHECK (default_weekday BETWEEN 1 AND 7),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (weekly_schedule_id, subscriber_id),
  CONSTRAINT weekly_schedule_subscribers_scope_fkey
    FOREIGN KEY (weekly_schedule_id, organization_id, pump_id)
    REFERENCES public.weekly_schedules (id, organization_id, pump_id) ON DELETE CASCADE,
  CONSTRAINT weekly_schedule_subscribers_subscriber_fkey
    FOREIGN KEY (subscriber_id)
    REFERENCES public.subscribers (id) ON DELETE RESTRICT
);

CREATE INDEX weekly_schedule_subscribers_subscriber_idx
  ON public.weekly_schedule_subscribers (organization_id, pump_id, subscriber_id, weekly_schedule_id);

-- Upgrade path: preserve schedules created after the initial weekly schema
-- migration by capturing their current quota/day before enforcing the new FK.
INSERT INTO public.weekly_schedule_subscribers (
  weekly_schedule_id, organization_id, pump_id, subscriber_id,
  weekly_quota_minutes, default_weekday
)
SELECT
  e.weekly_schedule_id,
  e.organization_id,
  e.pump_id,
  e.subscriber_id,
  s.weekly_quota_minutes,
  s.default_weekday
FROM public.schedule_entries e
JOIN public.subscribers s
  ON s.id = e.subscriber_id
 AND s.organization_id = e.organization_id
 AND s.pump_id = e.pump_id
GROUP BY e.weekly_schedule_id, e.organization_id, e.pump_id,
         e.subscriber_id, s.weekly_quota_minutes, s.default_weekday
ON CONFLICT (weekly_schedule_id, subscriber_id) DO NOTHING;

ALTER TABLE public.schedule_entries
  ADD CONSTRAINT schedule_entries_weekly_member_fkey
  FOREIGN KEY (weekly_schedule_id, subscriber_id)
  REFERENCES public.weekly_schedule_subscribers (weekly_schedule_id, subscriber_id)
  ON DELETE CASCADE;


COMMENT ON TABLE public.weekly_schedule_subscribers IS
  'Versioned weekly quota and preferred weekday snapshots. Updating a future schedule cannot rewrite the entitlement history of a previously active week.';
COMMENT ON COLUMN public.subscribers.weekly_quota_minutes IS
  'Convenience snapshot of the weekly quota in the schedule currently in force. Each schedule version stores its own authoritative entitlement in weekly_schedule_subscribers.';

CREATE TABLE public.weekly_schedule_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  weekly_schedule_id uuid NOT NULL REFERENCES public.weekly_schedules(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('draft_created', 'draft_updated', 'activated', 'archived')),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT weekly_schedule_events_scope_fkey
    FOREIGN KEY (weekly_schedule_id, organization_id, pump_id)
    REFERENCES public.weekly_schedules (id, organization_id, pump_id) ON DELETE CASCADE
);

CREATE INDEX weekly_schedule_events_scope_time_idx
  ON public.weekly_schedule_events (organization_id, pump_id, occurred_at DESC);

ALTER TABLE public.weekly_schedule_subscribers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_schedule_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.weekly_schedule_subscribers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.weekly_schedule_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.weekly_schedule_subscribers TO authenticated;
GRANT SELECT ON public.weekly_schedule_events TO authenticated;

CREATE POLICY weekly_schedule_subscribers_select_assigned
  ON public.weekly_schedule_subscribers
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = weekly_schedule_subscribers.organization_id
          AND pa.pump_id = weekly_schedule_subscribers.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
          AND pa.assignment_role IN ('operator'::public.app_role, 'supervisor'::public.app_role)
      )
    )
  );

CREATE POLICY weekly_schedule_events_select_assigned
  ON public.weekly_schedule_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = weekly_schedule_events.organization_id
          AND pa.pump_id = weekly_schedule_events.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
          AND pa.assignment_role IN ('operator'::public.app_role, 'supervisor'::public.app_role)
      )
    )
  );

CREATE FUNCTION water_management_private.prepare_weekly_schedule_subscriber_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $prepare_weekly_schedule_subscriber_scope$
DECLARE
  v_schedule public.weekly_schedules%ROWTYPE;
  v_subscriber public.subscribers%ROWTYPE;
BEGIN
  IF TG_OP = 'UPDATE'
     AND (NEW.weekly_schedule_id IS DISTINCT FROM OLD.weekly_schedule_id
       OR NEW.subscriber_id IS DISTINCT FROM OLD.subscriber_id
       OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
       OR NEW.pump_id IS DISTINCT FROM OLD.pump_id) THEN
    RAISE EXCEPTION 'A weekly entitlement cannot be moved to another schedule, subscriber, organization, or pump'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_schedule
  FROM public.weekly_schedules
  WHERE id = NEW.weekly_schedule_id
    AND status = 'draft';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Weekly entitlements can only be edited in a draft schedule'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_subscriber
  FROM public.subscribers
  WHERE id = NEW.subscriber_id
    AND organization_id = v_schedule.organization_id
    AND pump_id = v_schedule.pump_id
    AND is_active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Weekly schedule subscriber must be active on the same pump and organization'
      USING ERRCODE = '23503';
  END IF;

  NEW.organization_id := v_schedule.organization_id;
  NEW.pump_id := v_schedule.pump_id;
  RETURN NEW;
END;
$prepare_weekly_schedule_subscriber_scope$;

REVOKE ALL ON FUNCTION water_management_private.prepare_weekly_schedule_subscriber_scope()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER prepare_weekly_schedule_subscriber_scope
  BEFORE INSERT OR UPDATE ON public.weekly_schedule_subscribers
  FOR EACH ROW EXECUTE FUNCTION water_management_private.prepare_weekly_schedule_subscriber_scope();

-- Schedule entries must reference an entitlement snapshot in the same version.
CREATE OR REPLACE FUNCTION water_management_private.prepare_schedule_entry_scope()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $prepare_schedule_entry_scope$
DECLARE
  v_organization_id uuid;
  v_pump_id uuid;
  v_member_exists boolean;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.weekly_schedule_id IS DISTINCT FROM OLD.weekly_schedule_id THEN
    RAISE EXCEPTION 'A schedule entry cannot be moved to another weekly schedule'
      USING ERRCODE = '42501';
  END IF;

  SELECT ws.organization_id, ws.pump_id
    INTO v_organization_id, v_pump_id
  FROM public.weekly_schedules ws
  WHERE ws.id = NEW.weekly_schedule_id
    AND ws.status = 'draft';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Weekly schedule not found or not editable'
      USING ERRCODE = '23503';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.weekly_schedule_subscribers m
    WHERE m.weekly_schedule_id = NEW.weekly_schedule_id
      AND m.subscriber_id = NEW.subscriber_id
      AND m.organization_id = v_organization_id
      AND m.pump_id = v_pump_id
  ) INTO v_member_exists;

  IF NOT v_member_exists THEN
    RAISE EXCEPTION 'Schedule entry requires an entitlement snapshot for this subscriber in the same schedule version'
      USING ERRCODE = '23503';
  END IF;

  NEW.organization_id := v_organization_id;
  NEW.pump_id := v_pump_id;
  RETURN NEW;
END;
$prepare_schedule_entry_scope$;

REVOKE ALL ON FUNCTION water_management_private.prepare_schedule_entry_scope()
  FROM PUBLIC, anon, authenticated, service_role;

-- The authoritative activation invariant compares schedule entries with the
-- versioned entitlement snapshot, not the mutable current subscriber columns.
CREATE OR REPLACE FUNCTION water_management_private.validate_weekly_schedule_quota()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $validate_weekly_schedule_quota$
DECLARE
  v_member_count bigint;
  v_bad_subscriber uuid;
BEGIN
  IF NEW.status <> 'active' OR
     (TG_OP = 'UPDATE' AND OLD.status = 'active') THEN
    RETURN NEW;
  END IF;

  SELECT count(*) INTO v_member_count
  FROM public.weekly_schedule_subscribers m
  WHERE m.weekly_schedule_id = NEW.id;

  IF v_member_count = 0 THEN
    RAISE EXCEPTION 'A weekly schedule cannot be activated without any subscriber entitlement snapshots'
      USING ERRCODE = '23514';
  END IF;

  SELECT m.subscriber_id INTO v_bad_subscriber
  FROM public.weekly_schedule_subscribers m
  LEFT JOIN LATERAL (
    SELECT count(*) AS entry_count, COALESCE(sum(e.planned_minutes), 0)::integer AS allocated_minutes
    FROM public.schedule_entries e
    WHERE e.weekly_schedule_id = m.weekly_schedule_id
      AND e.subscriber_id = m.subscriber_id
  ) allocations ON true
  WHERE m.weekly_schedule_id = NEW.id
    AND (
      allocations.entry_count = 0
      OR allocations.allocated_minutes <> m.weekly_quota_minutes
    )
  LIMIT 1;

  IF v_bad_subscriber IS NOT NULL THEN
    RAISE EXCEPTION 'Allocated weekly minutes must exactly equal the versioned subscriber quota: %',
      v_bad_subscriber
      USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.schedule_entries e
    WHERE e.weekly_schedule_id = NEW.id
      AND NOT EXISTS (
        SELECT 1 FROM public.weekly_schedule_subscribers m
        WHERE m.weekly_schedule_id = e.weekly_schedule_id
          AND m.subscriber_id = e.subscriber_id
      )
  ) THEN
    RAISE EXCEPTION 'Every schedule entry must have a versioned weekly entitlement snapshot'
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$validate_weekly_schedule_quota$;

REVOKE ALL ON FUNCTION water_management_private.validate_weekly_schedule_quota()
  FROM PUBLIC, anon, authenticated, service_role;

-- Append-only schedule audit events; only the guarded routines write this table.
CREATE FUNCTION water_management_private.append_weekly_schedule_event(
  p_schedule_id uuid,
  p_organization_id uuid,
  p_pump_id uuid,
  p_actor_id uuid,
  p_event_type text,
  p_metadata jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $append_weekly_schedule_event$
BEGIN
  INSERT INTO public.weekly_schedule_events (
    weekly_schedule_id, organization_id, pump_id, actor_id, event_type, metadata
  ) VALUES (
    p_schedule_id, p_organization_id, p_pump_id, p_actor_id, p_event_type, COALESCE(p_metadata, '{}'::jsonb)
  );
END;
$append_weekly_schedule_event$;

REVOKE ALL ON FUNCTION water_management_private.append_weekly_schedule_event(uuid, uuid, uuid, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION water_management_private.save_weekly_schedule_draft_internal(
  p_schedule_id uuid,
  p_pump_id uuid,
  p_name text,
  p_effective_from date,
  p_effective_to date,
  p_week_starts_on smallint,
  p_subscribers jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $save_weekly_schedule_draft_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_schedule public.weekly_schedules%ROWTYPE;
  v_schedule_id uuid;
  v_allocation jsonb;
  v_day jsonb;
  v_subscriber_id uuid;
  v_quota integer;
  v_default_weekday smallint;
  v_allocations jsonb;
  v_allocation_count integer;
  v_distinct_days integer;
  v_allocated_minutes integer;
  v_sort_order integer;
  v_seen_subscribers uuid[] := ARRAY[]::uuid[];
  v_event_type text;
  v_total_allocations integer := 0;
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role <> 'manager'::public.app_role THEN
    RAISE EXCEPTION 'Only a manager can save weekly schedule drafts'
      USING ERRCODE = '42501';
  END IF;
  IF p_pump_id IS NULL OR p_name IS NULL
     OR char_length(btrim(p_name)) NOT BETWEEN 2 AND 100
     OR p_effective_from IS NULL
     OR p_week_starts_on IS NULL
     OR p_week_starts_on NOT BETWEEN 1 AND 7
     OR extract(isodow FROM p_effective_from)::integer <> p_week_starts_on
     OR (p_effective_to IS NOT NULL AND p_effective_to < p_effective_from)
     OR jsonb_typeof(p_subscribers) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_subscribers) = 0 THEN
    RAISE EXCEPTION 'Weekly schedule details or subscriber allocations are invalid'
      USING ERRCODE = '22023';
  END IF;

  PERFORM 1 FROM public.pumps p
  WHERE p.id = p_pump_id
    AND p.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pump not found in the current organization'
      USING ERRCODE = '42501';
  END IF;

  IF p_schedule_id IS NULL THEN
    INSERT INTO public.weekly_schedules (
      pump_id, name, effective_from, effective_to, week_starts_on
    ) VALUES (
      p_pump_id, btrim(p_name), p_effective_from, p_effective_to, p_week_starts_on
    )
    RETURNING id INTO v_schedule_id;
    v_event_type := 'draft_created';
  ELSE
    SELECT * INTO v_schedule
    FROM public.weekly_schedules
    WHERE id = p_schedule_id
      AND organization_id = v_organization_id
      AND pump_id = p_pump_id
    FOR UPDATE;
    IF NOT FOUND OR v_schedule.status <> 'draft' THEN
      RAISE EXCEPTION 'Only an existing draft schedule can be edited'
        USING ERRCODE = 'P0002';
    END IF;
    UPDATE public.weekly_schedules
    SET name = btrim(p_name),
        effective_from = p_effective_from,
        effective_to = p_effective_to,
        week_starts_on = p_week_starts_on
    WHERE id = p_schedule_id;
    v_schedule_id := p_schedule_id;
    v_event_type := 'draft_updated';
  END IF;

  DELETE FROM public.weekly_schedule_subscribers
  WHERE weekly_schedule_id = v_schedule_id;

  FOR v_allocation IN
    SELECT value FROM jsonb_array_elements(p_subscribers)
  LOOP
    v_subscriber_id := NULLIF(v_allocation->>'subscriber_id', '')::uuid;
    v_quota := NULLIF(v_allocation->>'weekly_quota_minutes', '')::integer;
    v_default_weekday := NULLIF(v_allocation->>'default_weekday', '')::smallint;
    v_allocations := v_allocation->'allocations';

    IF v_subscriber_id IS NULL
       OR v_quota IS NULL OR v_quota NOT BETWEEN 1 AND 10080
       OR v_default_weekday IS NULL OR v_default_weekday NOT BETWEEN 1 AND 7
       OR jsonb_typeof(v_allocations) IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_allocations) = 0
       OR v_subscriber_id = ANY(v_seen_subscribers) THEN
      RAISE EXCEPTION 'A subscriber allocation is missing, duplicated, or invalid'
        USING ERRCODE = '22023';
    END IF;
    v_seen_subscribers := array_append(v_seen_subscribers, v_subscriber_id);

    SELECT s.full_name INTO v_subscriber_name
    FROM public.subscribers s
    WHERE s.id = v_subscriber_id
      AND s.organization_id = v_organization_id
      AND s.pump_id = p_pump_id
      AND s.is_active;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Every scheduled subscriber must be active on the selected pump'
        USING ERRCODE = '22023';
    END IF;

    SELECT count(*)::integer,
           count(DISTINCT (day.value->>'weekday')::integer)::integer,
           COALESCE(sum((day.value->>'planned_minutes')::integer), 0)::integer
    INTO v_allocation_count, v_distinct_days, v_allocated_minutes
    FROM jsonb_array_elements(v_allocations) AS day(value);

    IF v_allocation_count <> v_distinct_days
       OR v_allocation_count = 0
       OR EXISTS (
         SELECT 1
         FROM jsonb_array_elements(v_allocations) AS day(value)
         WHERE NULLIF(day.value->>'weekday', '') IS NULL
            OR (day.value->>'weekday')::integer NOT BETWEEN 1 AND 7
            OR NULLIF(day.value->>'planned_minutes', '') IS NULL
            OR (day.value->>'planned_minutes')::integer NOT BETWEEN 1 AND 1440
       )
       OR v_allocated_minutes <> v_quota THEN
      RAISE EXCEPTION 'The sum of this subscriber weekday allocations must exactly equal the weekly quota'
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.weekly_schedule_subscribers (
      weekly_schedule_id, subscriber_id, weekly_quota_minutes, default_weekday
    ) VALUES (
      v_schedule_id, v_subscriber_id, v_quota, v_default_weekday
    );

    FOR v_day IN SELECT value FROM jsonb_array_elements(v_allocations) AS days(value) LOOP
      SELECT count(*)::integer INTO v_sort_order
      FROM public.schedule_entries e
      WHERE e.weekly_schedule_id = v_schedule_id
        AND e.weekday = (v_day->>'weekday')::smallint;

      INSERT INTO public.schedule_entries (
        weekly_schedule_id, subscriber_id, weekday, sort_order, planned_minutes
      ) VALUES (
        v_schedule_id, v_subscriber_id,
        (v_day->>'weekday')::smallint,
        v_sort_order,
        (v_day->>'planned_minutes')::integer
      );
      v_total_allocations := v_total_allocations + 1;
    END LOOP;
  END LOOP;

  PERFORM water_management_private.append_weekly_schedule_event(
    v_schedule_id, v_organization_id, p_pump_id, v_user_id, v_event_type,
    jsonb_build_object(
      'subscriber_count', cardinality(v_seen_subscribers),
      'allocation_count', v_total_allocations,
      'effective_from', p_effective_from,
      'week_starts_on', p_week_starts_on
    )
  );

  RETURN v_schedule_id;
END;
$save_weekly_schedule_draft_internal$;

REVOKE ALL ON FUNCTION water_management_private.save_weekly_schedule_draft_internal(uuid, uuid, text, date, date, smallint, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.save_weekly_schedule_draft_internal(uuid, uuid, text, date, date, smallint, jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.save_weekly_schedule_draft(
  p_schedule_id uuid,
  p_pump_id uuid,
  p_name text,
  p_effective_from date,
  p_effective_to date,
  p_week_starts_on smallint,
  p_subscribers jsonb
)
RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $save_weekly_schedule_draft_rpc$
  SELECT water_management_private.save_weekly_schedule_draft_internal(
    p_schedule_id, p_pump_id, p_name, p_effective_from, p_effective_to, p_week_starts_on, p_subscribers
  )
$save_weekly_schedule_draft_rpc$;

REVOKE ALL ON FUNCTION public.save_weekly_schedule_draft(uuid, uuid, text, date, date, smallint, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_weekly_schedule_draft(uuid, uuid, text, date, date, smallint, jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION water_management_private.activate_weekly_schedule_internal(
  p_schedule_id uuid
)
RETURNS public.weekly_schedules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $activate_weekly_schedule_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_schedule public.weekly_schedules%ROWTYPE;
  v_previous public.weekly_schedules%ROWTYPE;
  v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date;
  v_cycle_start date;
  v_members integer;
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role <> 'manager'::public.app_role THEN
    RAISE EXCEPTION 'Only a manager can activate a weekly schedule'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_schedule
  FROM public.weekly_schedules
  WHERE id = p_schedule_id
    AND organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND OR v_schedule.status <> 'draft' THEN
    RAISE EXCEPTION 'Only an existing draft schedule can be activated'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM 1 FROM public.pumps p
  WHERE p.id = v_schedule.pump_id
    AND p.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Schedule pump not found in the current organization'
      USING ERRCODE = '42501';
  END IF;

  v_cycle_start := v_today - (
    (extract(isodow FROM v_today)::integer - v_schedule.week_starts_on + 7) % 7
  );
  IF v_schedule.effective_from < v_cycle_start THEN
    RAISE EXCEPTION 'A new weekly schedule cannot be activated for an expired week'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_previous
  FROM public.weekly_schedules ws
  WHERE ws.organization_id = v_organization_id
    AND ws.pump_id = v_schedule.pump_id
    AND ws.status = 'active'
  FOR UPDATE;

  IF FOUND THEN
    IF v_schedule.effective_from <= v_previous.effective_from THEN
      RAISE EXCEPTION 'The next schedule version must start after the currently active version'
        USING ERRCODE = '22023';
    END IF;
    UPDATE public.weekly_schedules
    SET status = 'archived',
        effective_to = LEAST(
          COALESCE(effective_to, v_schedule.effective_from - 1),
          v_schedule.effective_from - 1
        )
    WHERE id = v_previous.id;

    PERFORM water_management_private.append_weekly_schedule_event(
      v_previous.id, v_previous.organization_id, v_previous.pump_id, v_user_id, 'archived',
      jsonb_build_object('effective_to', v_schedule.effective_from - 1, 'replaced_by', v_schedule.id)
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.weekly_schedules older
    WHERE older.organization_id = v_organization_id
      AND older.pump_id = v_schedule.pump_id
      AND older.status = 'archived'
      AND older.id <> COALESCE(v_previous.id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND daterange(older.effective_from, COALESCE(older.effective_to, 'infinity'::date), '[]')
        && daterange(v_schedule.effective_from, COALESCE(v_schedule.effective_to, 'infinity'::date), '[]')
  ) THEN
    RAISE EXCEPTION 'The new schedule effective period overlaps an archived schedule version'
      USING ERRCODE = '23P01';
  END IF;

  SELECT count(*)::integer INTO v_members
  FROM public.weekly_schedule_subscribers m
  JOIN public.subscribers s
    ON s.id = m.subscriber_id
   AND s.organization_id = m.organization_id
   AND s.pump_id = m.pump_id
  WHERE m.weekly_schedule_id = v_schedule.id
    AND s.is_active;
  IF v_members = 0 OR EXISTS (
    SELECT 1 FROM public.weekly_schedule_subscribers m
    JOIN public.subscribers s
      ON s.id = m.subscriber_id
     AND s.organization_id = m.organization_id
     AND s.pump_id = m.pump_id
    WHERE m.weekly_schedule_id = v_schedule.id
      AND NOT s.is_active
  ) THEN
    RAISE EXCEPTION 'Every entitlement in the new schedule must reference an active subscriber'
      USING ERRCODE = '23514';
  END IF;

  -- Keep subscribers.weekly_quota_minutes as the current in-force convenience
  -- fields. Future versions do not rewrite today's active quota prematurely.
  IF v_schedule.effective_from <= v_today THEN
    UPDATE public.subscribers s
    SET weekly_quota_minutes = m.weekly_quota_minutes,
        default_weekday = m.default_weekday
    FROM public.weekly_schedule_subscribers m
    WHERE m.weekly_schedule_id = v_schedule.id
      AND s.id = m.subscriber_id
      AND s.organization_id = v_organization_id
      AND s.pump_id = v_schedule.pump_id;

    UPDATE public.subscribers s
    SET weekly_quota_minutes = NULL,
        default_weekday = NULL
    WHERE s.organization_id = v_organization_id
      AND s.pump_id = v_schedule.pump_id
      AND s.is_active
      AND NOT EXISTS (
        SELECT 1 FROM public.weekly_schedule_subscribers m
        WHERE m.weekly_schedule_id = v_schedule.id
          AND m.subscriber_id = s.id
      );
  END IF;

  UPDATE public.weekly_schedules
  SET status = 'active'
  WHERE id = v_schedule.id
  RETURNING * INTO v_schedule;

  PERFORM water_management_private.append_weekly_schedule_event(
    v_schedule.id, v_schedule.organization_id, v_schedule.pump_id, v_user_id, 'activated',
    jsonb_build_object(
      'effective_from', v_schedule.effective_from,
      'effective_to', v_schedule.effective_to,
      'subscriber_count', v_members,
      'previous_schedule_id', v_previous.id
    )
  );

  RETURN v_schedule;
END;
$activate_weekly_schedule_internal$;

REVOKE ALL ON FUNCTION water_management_private.activate_weekly_schedule_internal(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.activate_weekly_schedule_internal(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.activate_weekly_schedule(p_schedule_id uuid)
RETURNS public.weekly_schedules
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $activate_weekly_schedule_rpc$
  SELECT water_management_private.activate_weekly_schedule_internal(p_schedule_id)
$activate_weekly_schedule_rpc$;

REVOKE ALL ON FUNCTION public.activate_weekly_schedule(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.activate_weekly_schedule(uuid) TO authenticated;

-- Synchronize subscriber convenience quota columns only when a daily queue is
-- generated from the matching effective schedule. A future schedule can be
-- activated ahead of its start date without changing this week's quota display.
CREATE OR REPLACE FUNCTION water_management_private.sync_current_weekly_entitlements(
  p_schedule_id uuid,
  p_organization_id uuid,
  p_pump_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $sync_current_weekly_entitlements$
BEGIN
  UPDATE public.subscribers s
  SET weekly_quota_minutes = m.weekly_quota_minutes,
      default_weekday = m.default_weekday
  FROM public.weekly_schedule_subscribers m
  WHERE m.weekly_schedule_id = p_schedule_id
    AND s.id = m.subscriber_id
    AND s.organization_id = p_organization_id
    AND s.pump_id = p_pump_id;

  UPDATE public.subscribers s
  SET weekly_quota_minutes = NULL,
      default_weekday = NULL
  WHERE s.organization_id = p_organization_id
    AND s.pump_id = p_pump_id
    AND s.is_active
    AND NOT EXISTS (
      SELECT 1 FROM public.weekly_schedule_subscribers m
      WHERE m.weekly_schedule_id = p_schedule_id
        AND m.subscriber_id = s.id
    );
END;
$sync_current_weekly_entitlements$;

REVOKE ALL ON FUNCTION water_management_private.sync_current_weekly_entitlements(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

-- Sync current subscriber convenience fields when today's daily queue is
-- first materialized from the effective schedule version.
CREATE FUNCTION water_management_private.sync_weekly_entitlements_on_queue_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $sync_weekly_entitlements_on_queue_insert$
BEGIN
  IF NEW.queue_date = (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date THEN
    PERFORM water_management_private.sync_current_weekly_entitlements(
      NEW.weekly_schedule_id, NEW.organization_id, NEW.pump_id
    );
  END IF;
  RETURN NEW;
END;
$sync_weekly_entitlements_on_queue_insert$;

REVOKE ALL ON FUNCTION water_management_private.sync_weekly_entitlements_on_queue_insert()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER sync_weekly_entitlements_on_queue_insert
  AFTER INSERT ON public.daily_queues
  FOR EACH ROW EXECUTE FUNCTION water_management_private.sync_weekly_entitlements_on_queue_insert();

-- Prevent schedule rotation from changing a day that was already snapshotted
-- in a persistent daily queue.
CREATE OR REPLACE FUNCTION water_management_private.activate_weekly_schedule_internal(
  p_schedule_id uuid
)
RETURNS public.weekly_schedules
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $activate_weekly_schedule_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_schedule public.weekly_schedules%ROWTYPE;
  v_previous public.weekly_schedules%ROWTYPE;
  v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date;
  v_cycle_start date;
  v_members integer;
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role <> 'manager'::public.app_role THEN
    RAISE EXCEPTION 'Only a manager can activate a weekly schedule'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_schedule
  FROM public.weekly_schedules
  WHERE id = p_schedule_id
    AND organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND OR v_schedule.status <> 'draft' THEN
    RAISE EXCEPTION 'Only an existing draft schedule can be activated'
      USING ERRCODE = 'P0002';
  END IF;

  PERFORM 1 FROM public.pumps p
  WHERE p.id = v_schedule.pump_id
    AND p.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Schedule pump not found in the current organization'
      USING ERRCODE = '42501';
  END IF;

  v_cycle_start := v_today - (
    (extract(isodow FROM v_today)::integer - v_schedule.week_starts_on + 7) % 7
  );
  IF v_schedule.effective_from < v_cycle_start THEN
    RAISE EXCEPTION 'A new weekly schedule cannot be activated for an expired week'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_previous
  FROM public.weekly_schedules ws
  WHERE ws.organization_id = v_organization_id
    AND ws.pump_id = v_schedule.pump_id
    AND ws.status = 'active'
  FOR UPDATE;

  IF FOUND THEN
    IF v_schedule.effective_from <= v_previous.effective_from THEN
      RAISE EXCEPTION 'The next schedule version must start after the currently active version'
        USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.daily_queues q
      WHERE q.organization_id = v_organization_id
        AND q.pump_id = v_schedule.pump_id
        AND q.queue_date >= v_schedule.effective_from
        AND q.weekly_schedule_id = v_previous.id
    ) THEN
      RAISE EXCEPTION 'A daily queue already exists for this period; choose the next unsnapshotted weekly cycle'
        USING ERRCODE = '55000';
    END IF;
    UPDATE public.weekly_schedules
    SET status = 'archived',
        effective_to = LEAST(
          COALESCE(effective_to, v_schedule.effective_from - 1),
          v_schedule.effective_from - 1
        )
    WHERE id = v_previous.id;

    PERFORM water_management_private.append_weekly_schedule_event(
      v_previous.id, v_previous.organization_id, v_previous.pump_id, v_user_id, 'archived',
      jsonb_build_object('effective_to', v_schedule.effective_from - 1, 'replaced_by', v_schedule.id)
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.weekly_schedules older
    WHERE older.organization_id = v_organization_id
      AND older.pump_id = v_schedule.pump_id
      AND older.status = 'archived'
      AND older.id <> COALESCE(v_previous.id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND daterange(older.effective_from, COALESCE(older.effective_to, 'infinity'::date), '[]')
        && daterange(v_schedule.effective_from, COALESCE(v_schedule.effective_to, 'infinity'::date), '[]')
  ) THEN
    RAISE EXCEPTION 'The new schedule effective period overlaps an archived schedule version'
      USING ERRCODE = '23P01';
  END IF;

  SELECT count(*)::integer INTO v_members
  FROM public.weekly_schedule_subscribers m
  JOIN public.subscribers s
    ON s.id = m.subscriber_id
   AND s.organization_id = m.organization_id
   AND s.pump_id = m.pump_id
  WHERE m.weekly_schedule_id = v_schedule.id
    AND s.is_active;
  IF v_members = 0 OR EXISTS (
    SELECT 1 FROM public.weekly_schedule_subscribers m
    JOIN public.subscribers s
      ON s.id = m.subscriber_id
     AND s.organization_id = m.organization_id
     AND s.pump_id = m.pump_id
    WHERE m.weekly_schedule_id = v_schedule.id
      AND NOT s.is_active
  ) THEN
    RAISE EXCEPTION 'Every entitlement in the new schedule must reference an active subscriber'
      USING ERRCODE = '23514';
  END IF;

  IF v_schedule.effective_from <= v_today THEN
    PERFORM water_management_private.sync_current_weekly_entitlements(
      v_schedule.id, v_organization_id, v_schedule.pump_id
    );
  END IF;

  UPDATE public.weekly_schedules
  SET status = 'active'
  WHERE id = v_schedule.id
  RETURNING * INTO v_schedule;

  PERFORM water_management_private.append_weekly_schedule_event(
    v_schedule.id, v_schedule.organization_id, v_schedule.pump_id, v_user_id, 'activated',
    jsonb_build_object(
      'effective_from', v_schedule.effective_from,
      'effective_to', v_schedule.effective_to,
      'subscriber_count', v_members,
      'previous_schedule_id', v_previous.id
    )
  );

  RETURN v_schedule;
END;
$activate_weekly_schedule_internal$;

COMMENT ON TABLE public.weekly_schedule_events IS
  'Append-only audit trail for weekly schedule draft changes, activation, and historical version rotation.';

-- Organization teardown: daily queues have RESTRICT references to weekly schedule
-- versions, so remove daily queues first, then let the existing schedule cleanup run.
CREATE FUNCTION water_management_private.delete_organization_daily_queues()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $delete_organization_daily_queues$
BEGIN
  DELETE FROM public.daily_queues WHERE organization_id = OLD.id;
  RETURN OLD;
END;
$delete_organization_daily_queues$;

REVOKE ALL ON FUNCTION water_management_private.delete_organization_daily_queues()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER delete_organization_daily_queues
  BEFORE DELETE ON public.organizations
  FOR EACH ROW EXECUTE FUNCTION water_management_private.delete_organization_daily_queues();

