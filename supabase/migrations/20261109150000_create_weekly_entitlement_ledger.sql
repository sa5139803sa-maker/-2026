-- Weekly entitlements are a per-subscriber, per-cycle balance with dated
-- allocations. Transfers move only unconsumed minutes inside the same cycle.
-- Consumption is recorded from completed weekly queue operations and reconciled
-- against the submitted daily report without charging the same minutes twice.

CREATE TABLE public.weekly_entitlement_cycles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  weekly_schedule_id uuid NOT NULL,
  subscriber_id uuid NOT NULL,
  cycle_start date NOT NULL,
  cycle_end date NOT NULL,
  week_starts_on smallint NOT NULL CHECK (week_starts_on BETWEEN 1 AND 7),
  quota_minutes integer NOT NULL CHECK (quota_minutes BETWEEN 1 AND 10080),
  consumed_minutes integer NOT NULL DEFAULT 0 CHECK (consumed_minutes >= 0),
  expired_minutes integer NOT NULL DEFAULT 0 CHECK (expired_minutes >= 0),
  remaining_minutes integer GENERATED ALWAYS AS (
    quota_minutes - consumed_minutes - expired_minutes
  ) STORED,
  status text NOT NULL DEFAULT 'open',
  last_event_sequence bigint NOT NULL DEFAULT 0 CHECK (last_event_sequence >= 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expired_at timestamptz,
  CONSTRAINT weekly_entitlement_cycles_dates_check CHECK (
    cycle_end = cycle_start + 6
    AND extract(isodow FROM cycle_start)::integer = week_starts_on
  ),
  CONSTRAINT weekly_entitlement_cycles_balance_check CHECK (
    consumed_minutes + expired_minutes <= quota_minutes
  ),
  CONSTRAINT weekly_entitlement_cycles_status_check CHECK (
    (status = 'open' AND expired_at IS NULL AND expired_minutes = 0)
    OR (status = 'expired' AND expired_at IS NOT NULL
        AND expired_minutes = quota_minutes - consumed_minutes)
  ),
  CONSTRAINT weekly_entitlement_cycles_scope_fkey
    FOREIGN KEY (pump_id, organization_id)
    REFERENCES public.pumps (id, organization_id) ON DELETE CASCADE,
  CONSTRAINT weekly_entitlement_cycles_schedule_member_fkey
    FOREIGN KEY (weekly_schedule_id, subscriber_id)
    REFERENCES public.weekly_schedule_subscribers (weekly_schedule_id, subscriber_id)
    ON DELETE RESTRICT,
  CONSTRAINT weekly_entitlement_cycles_subscriber_scope_fkey
    FOREIGN KEY (subscriber_id, organization_id, pump_id)
    REFERENCES public.subscribers (id, organization_id, pump_id) ON DELETE RESTRICT,
  CONSTRAINT weekly_entitlement_cycles_uidx
    UNIQUE (weekly_schedule_id, subscriber_id, cycle_start),
  CONSTRAINT weekly_entitlement_cycles_id_scope_key
    UNIQUE (id, organization_id, pump_id, subscriber_id)
);

CREATE INDEX weekly_entitlement_cycles_pump_cycle_idx
  ON public.weekly_entitlement_cycles (organization_id, pump_id, cycle_start DESC, status);

CREATE TABLE public.weekly_entitlement_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  weekly_entitlement_cycle_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  subscriber_id uuid NOT NULL,
  allocation_date date NOT NULL,
  source_schedule_entry_id uuid,
  original_minutes integer NOT NULL DEFAULT 0 CHECK (original_minutes BETWEEN 0 AND 1440),
  allocated_minutes integer NOT NULL DEFAULT 0 CHECK (allocated_minutes BETWEEN 0 AND 1440),
  consumed_minutes integer NOT NULL DEFAULT 0 CHECK (consumed_minutes >= 0),
  available_minutes integer GENERATED ALWAYS AS (allocated_minutes - consumed_minutes) STORED,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT weekly_entitlement_allocations_balance_check CHECK (
    consumed_minutes <= allocated_minutes
  ),
  CONSTRAINT weekly_entitlement_allocations_cycle_scope_fkey
    FOREIGN KEY (weekly_entitlement_cycle_id, organization_id, pump_id, subscriber_id)
    REFERENCES public.weekly_entitlement_cycles (id, organization_id, pump_id, subscriber_id)
    ON DELETE CASCADE,
  CONSTRAINT weekly_entitlement_allocations_schedule_entry_fkey
    FOREIGN KEY (source_schedule_entry_id, organization_id, pump_id)
    REFERENCES public.schedule_entries (id, organization_id, pump_id) ON DELETE RESTRICT,
  CONSTRAINT weekly_entitlement_allocations_date_uidx
    UNIQUE (weekly_entitlement_cycle_id, allocation_date),
  CONSTRAINT weekly_entitlement_allocations_id_scope_key
    UNIQUE (id, organization_id, pump_id, subscriber_id)
);

CREATE INDEX weekly_entitlement_allocations_available_idx
  ON public.weekly_entitlement_allocations
    (organization_id, pump_id, allocation_date, subscriber_id)
  WHERE allocated_minutes > consumed_minutes;

CREATE TABLE public.weekly_entitlement_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  weekly_entitlement_cycle_id uuid NOT NULL,
  allocation_id uuid,
  related_allocation_id uuid,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  subscriber_id uuid NOT NULL,
  event_sequence bigint NOT NULL CHECK (event_sequence > 0),
  event_type text NOT NULL CHECK (event_type IN (
    'cycle_opened',
    'minutes_consumed',
    'minutes_transferred',
    'manual_reconciliation',
    'cycle_expired'
  )),
  minutes integer CHECK (minutes IS NULL OR minutes > 0),
  from_date date,
  to_date date,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reason text CHECK (reason IS NULL OR char_length(reason) BETWEEN 2 AND 240),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT weekly_entitlement_events_sequence_uidx
    UNIQUE (weekly_entitlement_cycle_id, event_sequence),
  CONSTRAINT weekly_entitlement_events_cycle_scope_fkey
    FOREIGN KEY (weekly_entitlement_cycle_id, organization_id, pump_id, subscriber_id)
    REFERENCES public.weekly_entitlement_cycles (id, organization_id, pump_id, subscriber_id)
    ON DELETE CASCADE,
  CONSTRAINT weekly_entitlement_events_allocation_scope_fkey
    FOREIGN KEY (allocation_id, organization_id, pump_id, subscriber_id)
    REFERENCES public.weekly_entitlement_allocations (id, organization_id, pump_id, subscriber_id)
    ON DELETE RESTRICT,
  CONSTRAINT weekly_entitlement_events_related_allocation_scope_fkey
    FOREIGN KEY (related_allocation_id, organization_id, pump_id, subscriber_id)
    REFERENCES public.weekly_entitlement_allocations (id, organization_id, pump_id, subscriber_id)
    ON DELETE RESTRICT
);

CREATE INDEX weekly_entitlement_events_cycle_time_idx
  ON public.weekly_entitlement_events (weekly_entitlement_cycle_id, event_sequence DESC);
CREATE INDEX weekly_entitlement_events_scope_time_idx
  ON public.weekly_entitlement_events (organization_id, pump_id, occurred_at DESC);
CREATE INDEX weekly_entitlement_events_subscriber_time_idx
  ON public.weekly_entitlement_events (subscriber_id, occurred_at DESC);

ALTER TABLE public.weekly_entitlement_cycles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_entitlement_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_entitlement_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.weekly_entitlement_cycles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.weekly_entitlement_allocations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.weekly_entitlement_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.weekly_entitlement_cycles TO authenticated;
GRANT SELECT ON public.weekly_entitlement_allocations TO authenticated;
GRANT SELECT ON public.weekly_entitlement_events TO authenticated;

CREATE POLICY weekly_entitlement_cycles_select_assigned
  ON public.weekly_entitlement_cycles
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = weekly_entitlement_cycles.organization_id
          AND pa.pump_id = weekly_entitlement_cycles.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
          AND pa.assignment_role IN ('operator'::public.app_role, 'supervisor'::public.app_role)
      )
    )
  );

CREATE POLICY weekly_entitlement_allocations_select_assigned
  ON public.weekly_entitlement_allocations
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = weekly_entitlement_allocations.organization_id
          AND pa.pump_id = weekly_entitlement_allocations.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
          AND pa.assignment_role IN ('operator'::public.app_role, 'supervisor'::public.app_role)
      )
    )
  );

CREATE POLICY weekly_entitlement_events_select_assigned
  ON public.weekly_entitlement_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = weekly_entitlement_events.organization_id
          AND pa.pump_id = weekly_entitlement_events.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
          AND pa.assignment_role IN ('operator'::public.app_role, 'supervisor'::public.app_role)
      )
    )
  );

CREATE OR REPLACE FUNCTION water_management_private.append_weekly_entitlement_event(
  p_cycle_id uuid,
  p_allocation_id uuid,
  p_related_allocation_id uuid,
  p_event_type text,
  p_minutes integer,
  p_from_date date,
  p_to_date date,
  p_actor_id uuid,
  p_reason text,
  p_metadata jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $append_weekly_entitlement_event$
DECLARE
  v_cycle public.weekly_entitlement_cycles%ROWTYPE;
  v_sequence bigint;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'Weekly entitlement events require an authenticated actor'
      USING ERRCODE = '42501';
  END IF;

  UPDATE public.weekly_entitlement_cycles
  SET last_event_sequence = last_event_sequence + 1
  WHERE id = p_cycle_id
  RETURNING * INTO v_cycle;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Weekly entitlement cycle not found' USING ERRCODE = 'P0002';
  END IF;

  v_sequence := v_cycle.last_event_sequence;

  INSERT INTO public.weekly_entitlement_events (
    weekly_entitlement_cycle_id, allocation_id, related_allocation_id,
    organization_id, pump_id, subscriber_id, event_sequence,
    event_type, minutes, from_date, to_date, actor_id, reason, metadata
  ) VALUES (
    v_cycle.id, p_allocation_id, p_related_allocation_id,
    v_cycle.organization_id, v_cycle.pump_id, v_cycle.subscriber_id, v_sequence,
    p_event_type, p_minutes, p_from_date, p_to_date, p_actor_id,
    NULLIF(btrim(p_reason), ''), COALESCE(p_metadata, '{}'::jsonb)
  );
END;
$append_weekly_entitlement_event$;

REVOKE ALL ON FUNCTION water_management_private.append_weekly_entitlement_event(
  uuid, uuid, uuid, text, integer, date, date, uuid, text, jsonb
) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION water_management_private.ensure_weekly_entitlement_cycle(
  p_schedule_id uuid,
  p_organization_id uuid,
  p_pump_id uuid,
  p_cycle_start date,
  p_actor_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $ensure_weekly_entitlement_cycle$
DECLARE
  v_schedule public.weekly_schedules%ROWTYPE;
  v_member public.weekly_schedule_subscribers%ROWTYPE;
  v_cycle_id uuid;
  v_cycle_new boolean;
  v_total_allocated integer;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'Weekly entitlement provisioning requires an authenticated actor'
      USING ERRCODE = '42501';
  END IF;

  SELECT ws.* INTO v_schedule
  FROM public.weekly_schedules ws
  WHERE ws.id = p_schedule_id
    AND ws.organization_id = p_organization_id
    AND ws.pump_id = p_pump_id
    AND ws.status IN ('active', 'archived');

  IF NOT FOUND
     OR p_cycle_start IS NULL
     OR extract(isodow FROM p_cycle_start)::integer <> v_schedule.week_starts_on
     OR p_cycle_start < v_schedule.effective_from
     OR (v_schedule.effective_to IS NOT NULL AND p_cycle_start + 6 > v_schedule.effective_to) THEN
    RAISE EXCEPTION 'Weekly entitlement cycle does not match an effective weekly schedule period'
      USING ERRCODE = '22023';
  END IF;

  FOR v_member IN
    SELECT m.*
    FROM public.weekly_schedule_subscribers m
    WHERE m.weekly_schedule_id = p_schedule_id
      AND m.organization_id = p_organization_id
      AND m.pump_id = p_pump_id
    ORDER BY m.subscriber_id
  LOOP
    v_cycle_id := NULL;
    INSERT INTO public.weekly_entitlement_cycles (
      organization_id, pump_id, weekly_schedule_id, subscriber_id,
      cycle_start, cycle_end, week_starts_on, quota_minutes
    ) VALUES (
      p_organization_id, p_pump_id, p_schedule_id, v_member.subscriber_id,
      p_cycle_start, p_cycle_start + 6, v_schedule.week_starts_on,
      v_member.weekly_quota_minutes
    )
    ON CONFLICT (weekly_schedule_id, subscriber_id, cycle_start) DO NOTHING
    RETURNING id INTO v_cycle_id;

    v_cycle_new := v_cycle_id IS NOT NULL;
    IF v_cycle_id IS NULL THEN
      SELECT c.id INTO v_cycle_id
      FROM public.weekly_entitlement_cycles c
      WHERE c.weekly_schedule_id = p_schedule_id
        AND c.subscriber_id = v_member.subscriber_id
        AND c.cycle_start = p_cycle_start;
    ELSE
      PERFORM water_management_private.append_weekly_entitlement_event(
        v_cycle_id, NULL, NULL, 'cycle_opened', NULL,
        p_cycle_start, p_cycle_start + 6, p_actor_id, NULL,
        jsonb_build_object('quota_minutes', v_member.weekly_quota_minutes)
      );
    END IF;

    INSERT INTO public.weekly_entitlement_allocations (
      weekly_entitlement_cycle_id, organization_id, pump_id, subscriber_id,
      allocation_date, source_schedule_entry_id,
      original_minutes, allocated_minutes, consumed_minutes
    )
    SELECT
      v_cycle_id, p_organization_id, p_pump_id, v_member.subscriber_id,
      p_cycle_start + ((e.weekday - v_schedule.week_starts_on + 7) % 7),
      e.id, e.planned_minutes, e.planned_minutes, 0
    FROM public.schedule_entries e
    WHERE e.weekly_schedule_id = p_schedule_id
      AND e.organization_id = p_organization_id
      AND e.pump_id = p_pump_id
      AND e.subscriber_id = v_member.subscriber_id
    ON CONFLICT (weekly_entitlement_cycle_id, allocation_date) DO NOTHING;

    SELECT COALESCE(sum(a.original_minutes), 0)::integer INTO v_total_allocated
    FROM public.weekly_entitlement_allocations a
    WHERE a.weekly_entitlement_cycle_id = v_cycle_id;

    IF v_total_allocated <> v_member.weekly_quota_minutes THEN
      RAISE EXCEPTION 'Weekly entitlement allocations (%) must equal the cycle quota (%) for subscriber %',
        v_total_allocated, v_member.weekly_quota_minutes, v_member.subscriber_id
        USING ERRCODE = '23514';
    END IF;
  END LOOP;
END;
$ensure_weekly_entitlement_cycle$;

REVOKE ALL ON FUNCTION water_management_private.ensure_weekly_entitlement_cycle(
  uuid, uuid, uuid, date, uuid
) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION water_management_private.expire_due_weekly_entitlement_cycles(
  p_organization_id uuid,
  p_pump_id uuid,
  p_today date,
  p_actor_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $expire_due_weekly_entitlement_cycles$
DECLARE
  v_cycle public.weekly_entitlement_cycles%ROWTYPE;
  v_expired_minutes integer;
BEGIN
  FOR v_cycle IN
    SELECT c.*
    FROM public.weekly_entitlement_cycles c
    WHERE c.organization_id = p_organization_id
      AND c.pump_id = p_pump_id
      AND c.status = 'open'
      AND c.cycle_end < p_today
      AND NOT EXISTS (
        SELECT 1
        FROM public.weekly_entitlement_allocations a
        JOIN public.queue_items qi
          ON qi.weekly_entitlement_allocation_id = a.id
        WHERE a.weekly_entitlement_cycle_id = c.id
          AND qi.status = 'running'
      )
    ORDER BY c.cycle_start, c.subscriber_id
    FOR UPDATE
  LOOP
    v_expired_minutes := v_cycle.quota_minutes - v_cycle.consumed_minutes;

    UPDATE public.weekly_entitlement_cycles
    SET status = 'expired',
        expired_minutes = v_expired_minutes,
        expired_at = clock_timestamp()
    WHERE id = v_cycle.id;

    PERFORM water_management_private.append_weekly_entitlement_event(
      v_cycle.id, NULL, NULL, 'cycle_expired',
      CASE WHEN v_expired_minutes > 0 THEN v_expired_minutes ELSE NULL END,
      v_cycle.cycle_start, v_cycle.cycle_end, p_actor_id, NULL,
      jsonb_build_object(
        'quota_minutes', v_cycle.quota_minutes,
        'consumed_minutes', v_cycle.consumed_minutes,
        'expired_minutes', v_expired_minutes
      )
    );
  END LOOP;
END;
$expire_due_weekly_entitlement_cycles$;

REVOKE ALL ON FUNCTION water_management_private.expire_due_weekly_entitlement_cycles(
  uuid, uuid, date, uuid
) FROM PUBLIC, anon, authenticated, service_role;

-- Keep the existing subscriber convenience snapshots, but initialize the
-- authoritative per-cycle ledger before queue item rows are materialized.
CREATE OR REPLACE FUNCTION water_management_private.sync_weekly_entitlements_on_queue_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $sync_weekly_entitlements_on_queue_insert$
BEGIN
  PERFORM water_management_private.ensure_weekly_entitlement_cycle(
    NEW.weekly_schedule_id, NEW.organization_id, NEW.pump_id,
    NEW.weekly_cycle_start, auth.uid()
  );

  IF NEW.queue_date = (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date THEN
    PERFORM water_management_private.sync_current_weekly_entitlements(
      NEW.weekly_schedule_id, NEW.organization_id, NEW.pump_id
    );
    PERFORM water_management_private.expire_due_weekly_entitlement_cycles(
      NEW.organization_id, NEW.pump_id,
      (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date,
      auth.uid()
    );
  END IF;

  -- A transfer may be made before the target day's queue exists. Materialize
  -- allocations with no original template entry as reassigned weekly items.
  INSERT INTO public.queue_items (
    daily_queue_id, organization_id, pump_id, source_type,
    schedule_entry_id, subscriber_id, subscriber_name_snapshot,
    branch_id, branch_name_snapshot, planned_minutes, sort_order,
    weekly_entitlement_allocation_id
  )
  SELECT
    NEW.id, NEW.organization_id, NEW.pump_id, 'weekly_reassigned',
    NULL, a.subscriber_id, s.full_name, s.branch_id, b.name,
    a.allocated_minutes,
    1000000 + row_number() OVER (ORDER BY a.allocation_date, s.full_name, a.id)::integer - 1,
    a.id
  FROM public.weekly_entitlement_allocations a
  JOIN public.weekly_entitlement_cycles c
    ON c.id = a.weekly_entitlement_cycle_id
  JOIN public.subscribers s
    ON s.id = a.subscriber_id
   AND s.organization_id = a.organization_id
   AND s.pump_id = a.pump_id
  LEFT JOIN public.branches b
    ON b.id = s.branch_id
   AND b.organization_id = s.organization_id
   AND b.pump_id = s.pump_id
  WHERE c.weekly_schedule_id = NEW.weekly_schedule_id
    AND c.cycle_start = NEW.weekly_cycle_start
    AND a.allocation_date = NEW.queue_date
    AND a.source_schedule_entry_id IS NULL
    AND a.allocated_minutes > 0
    AND NOT EXISTS (
      SELECT 1 FROM public.queue_items qi
      WHERE qi.weekly_entitlement_allocation_id = a.id
    );

  RETURN NEW;
END;
$sync_weekly_entitlements_on_queue_insert$;

REVOKE ALL ON FUNCTION water_management_private.sync_weekly_entitlements_on_queue_insert()
  FROM PUBLIC, anon, authenticated, service_role;

ALTER TABLE public.queue_items
  ADD COLUMN weekly_entitlement_allocation_id uuid;

ALTER TABLE public.queue_items
  DROP CONSTRAINT queue_items_source_shape_check;

ALTER TABLE public.queue_items
  ADD CONSTRAINT queue_items_source_shape_check CHECK (
    (
      source_type = 'weekly'
      AND schedule_entry_id IS NOT NULL
      AND subscriber_id IS NOT NULL
      AND weekly_entitlement_allocation_id IS NOT NULL
    )
    OR (
      source_type = 'weekly_reassigned'
      AND subscriber_id IS NOT NULL
      AND weekly_entitlement_allocation_id IS NOT NULL
    )
    OR (
      source_type = 'additional_registered'
      AND schedule_entry_id IS NULL
      AND subscriber_id IS NOT NULL
      AND weekly_entitlement_allocation_id IS NULL
    )
    OR (
      source_type IN ('additional_guest', 'emergency')
      AND schedule_entry_id IS NULL
      AND subscriber_id IS NULL
      AND branch_id IS NULL
      AND weekly_entitlement_allocation_id IS NULL
    )
  );

ALTER TABLE public.queue_items
  ADD CONSTRAINT queue_items_weekly_entitlement_scope_fkey
  FOREIGN KEY (weekly_entitlement_allocation_id, organization_id, pump_id, subscriber_id)
  REFERENCES public.weekly_entitlement_allocations (id, organization_id, pump_id, subscriber_id)
  ON DELETE RESTRICT;

CREATE UNIQUE INDEX queue_items_weekly_entitlement_allocation_uidx
  ON public.queue_items (weekly_entitlement_allocation_id)
  WHERE weekly_entitlement_allocation_id IS NOT NULL;

CREATE OR REPLACE FUNCTION water_management_private.attach_weekly_entitlement_queue_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $attach_weekly_entitlement_queue_item$
DECLARE
  v_queue public.daily_queues%ROWTYPE;
  v_allocation public.weekly_entitlement_allocations%ROWTYPE;
BEGIN
  SELECT q.* INTO v_queue
  FROM public.daily_queues q
  WHERE q.id = NEW.daily_queue_id
    AND q.organization_id = NEW.organization_id
    AND q.pump_id = NEW.pump_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily queue not found for weekly allocation'
      USING ERRCODE = '23503';
  END IF;

  IF NEW.source_type IN ('weekly', 'weekly_reassigned') THEN
    IF NEW.weekly_entitlement_allocation_id IS NULL THEN
      SELECT a.* INTO v_allocation
      FROM public.weekly_entitlement_allocations a
      WHERE a.subscriber_id = NEW.subscriber_id
        AND a.organization_id = NEW.organization_id
        AND a.pump_id = NEW.pump_id
        AND a.allocation_date = v_queue.queue_date
        AND a.weekly_entitlement_cycle_id IN (
          SELECT c.id FROM public.weekly_entitlement_cycles c
          WHERE c.weekly_schedule_id = v_queue.weekly_schedule_id
            AND c.cycle_start = v_queue.weekly_cycle_start
        )
        AND a.source_schedule_entry_id = NEW.schedule_entry_id
      FOR UPDATE;
    ELSE
      SELECT a.* INTO v_allocation
      FROM public.weekly_entitlement_allocations a
      WHERE a.id = NEW.weekly_entitlement_allocation_id
        AND a.organization_id = NEW.organization_id
        AND a.pump_id = NEW.pump_id
        AND a.subscriber_id = NEW.subscriber_id
        AND a.allocation_date = v_queue.queue_date
        AND a.weekly_entitlement_cycle_id IN (
          SELECT c.id FROM public.weekly_entitlement_cycles c
          WHERE c.weekly_schedule_id = v_queue.weekly_schedule_id
            AND c.cycle_start = v_queue.weekly_cycle_start
        )
      FOR UPDATE;
    END IF;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Weekly queue item has no matching cycle allocation'
        USING ERRCODE = '23503';
    END IF;

    IF v_allocation.allocated_minutes = 0 THEN
      RETURN NULL;
    END IF;

    NEW.weekly_entitlement_allocation_id := v_allocation.id;
    NEW.planned_minutes := v_allocation.allocated_minutes;
    NEW.schedule_entry_id := v_allocation.source_schedule_entry_id;
    NEW.source_type := CASE
      WHEN v_allocation.source_schedule_entry_id IS NULL THEN 'weekly_reassigned'
      ELSE 'weekly'
    END;
  ELSE
    IF NEW.weekly_entitlement_allocation_id IS NOT NULL THEN
      RAISE EXCEPTION 'Additional queue items cannot consume a weekly entitlement allocation'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$attach_weekly_entitlement_queue_item$;

REVOKE ALL ON FUNCTION water_management_private.attach_weekly_entitlement_queue_item()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER attach_weekly_entitlement_queue_item
  BEFORE INSERT ON public.queue_items
  FOR EACH ROW EXECUTE FUNCTION water_management_private.attach_weekly_entitlement_queue_item();

CREATE OR REPLACE FUNCTION water_management_private.consume_weekly_entitlement_on_queue_completion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $consume_weekly_entitlement_on_queue_completion$
DECLARE
  v_operation public.pump_operations%ROWTYPE;
  v_allocation public.weekly_entitlement_allocations%ROWTYPE;
  v_cycle public.weekly_entitlement_cycles%ROWTYPE;
  v_actual_minutes integer;
  v_target_consumed integer;
  v_delta integer;
BEGIN
  IF OLD.status <> 'running' OR NEW.status <> 'completed'
     OR NEW.weekly_entitlement_allocation_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT op.* INTO v_operation
  FROM public.pump_operations op
  WHERE op.id = NEW.operation_id
    AND op.organization_id = NEW.organization_id
    AND op.pump_id = NEW.pump_id;

  IF NOT FOUND OR v_operation.actual_seconds IS NULL THEN
    RAISE EXCEPTION 'Completed weekly queue item must reference a completed operation'
      USING ERRCODE = '23514';
  END IF;

  SELECT c.* INTO v_cycle
  FROM public.weekly_entitlement_cycles c
  JOIN public.weekly_entitlement_allocations a
    ON a.weekly_entitlement_cycle_id = c.id
  WHERE a.id = NEW.weekly_entitlement_allocation_id
    AND a.organization_id = NEW.organization_id
    AND a.pump_id = NEW.pump_id
    AND a.subscriber_id = NEW.subscriber_id
  FOR UPDATE OF c;

  IF NOT FOUND OR v_cycle.status <> 'open' THEN
    RAISE EXCEPTION 'Weekly entitlement cycle is not open for operation consumption'
      USING ERRCODE = '55000';
  END IF;

  SELECT a.* INTO v_allocation
  FROM public.weekly_entitlement_allocations a
  WHERE a.id = NEW.weekly_entitlement_allocation_id
  FOR UPDATE;

  v_actual_minutes := floor(GREATEST(0, v_operation.actual_seconds)::numeric / 60)::integer;
  v_target_consumed := LEAST(v_allocation.allocated_minutes, v_actual_minutes);
  v_delta := GREATEST(0, v_target_consumed - v_allocation.consumed_minutes);

  IF v_delta > 0 THEN
    UPDATE public.weekly_entitlement_allocations
    SET consumed_minutes = consumed_minutes + v_delta,
        updated_at = clock_timestamp()
    WHERE id = v_allocation.id;

    UPDATE public.weekly_entitlement_cycles
    SET consumed_minutes = consumed_minutes + v_delta
    WHERE id = v_cycle.id;

    PERFORM water_management_private.append_weekly_entitlement_event(
      v_cycle.id, v_allocation.id, NULL, 'minutes_consumed', v_delta,
      v_allocation.allocation_date, NULL, auth.uid(), NULL,
      jsonb_build_object(
        'queue_item_id', NEW.id,
        'operation_id', NEW.operation_id,
        'actual_seconds', v_operation.actual_seconds,
        'actual_minutes', v_actual_minutes,
        'allocated_minutes', v_allocation.allocated_minutes,
        'weekly_minutes_consumed', v_allocation.consumed_minutes + v_delta,
        'minutes_over_allocation', GREATEST(0, v_actual_minutes - v_allocation.allocated_minutes),
        'source', 'pump_operation'
      )
    );
  END IF;

  RETURN NEW;
END;
$consume_weekly_entitlement_on_queue_completion$;

REVOKE ALL ON FUNCTION water_management_private.consume_weekly_entitlement_on_queue_completion()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER consume_weekly_entitlement_on_queue_completion
  AFTER UPDATE OF status ON public.queue_items
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION water_management_private.consume_weekly_entitlement_on_queue_completion();

-- Attach the authoritative allocation to each weekly daily-report row.
ALTER TABLE public.daily_work_report_items
  ADD COLUMN weekly_entitlement_allocation_id uuid;

ALTER TABLE public.daily_work_report_items
  DROP CONSTRAINT daily_work_report_items_entry_type_check;

ALTER TABLE public.daily_work_report_items
  ADD CONSTRAINT daily_work_report_items_entry_type_check CHECK (
    entry_type IN ('weekly', 'weekly_reassigned', 'additional_registered', 'additional_guest')
  );

ALTER TABLE public.daily_work_report_items
  DROP CONSTRAINT daily_work_report_items_type_check;

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
  );

ALTER TABLE public.daily_work_report_items
  DROP COLUMN fulfillment_status;

ALTER TABLE public.daily_work_report_items
  ADD COLUMN fulfillment_status text GENERATED ALWAYS AS (
    CASE
      WHEN entry_type NOT IN ('weekly', 'weekly_reassigned') THEN 'additional'
      WHEN app_recorded_minutes + manual_minutes = 0 THEN 'not_done'
      WHEN app_recorded_minutes + manual_minutes >= scheduled_minutes THEN 'complete'
      ELSE 'partial'
    END
  ) STORED;

ALTER TABLE public.daily_work_report_items
  ADD CONSTRAINT daily_work_report_items_weekly_entitlement_scope_fkey
  FOREIGN KEY (weekly_entitlement_allocation_id, organization_id, pump_id, subscriber_id)
  REFERENCES public.weekly_entitlement_allocations (id, organization_id, pump_id, subscriber_id)
  ON DELETE RESTRICT;

CREATE UNIQUE INDEX daily_work_report_items_weekly_allocation_uidx
  ON public.daily_work_report_items (daily_work_report_id, weekly_entitlement_allocation_id)
  WHERE weekly_entitlement_allocation_id IS NOT NULL;

CREATE OR REPLACE FUNCTION water_management_private.prepare_weekly_entitlement_report_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $prepare_weekly_entitlement_report_item$
DECLARE
  v_report public.daily_work_reports%ROWTYPE;
  v_schedule_entry public.schedule_entries%ROWTYPE;
  v_schedule public.weekly_schedules%ROWTYPE;
  v_cycle_start date;
  v_allocation public.weekly_entitlement_allocations%ROWTYPE;
  v_app_minutes integer := 0;
BEGIN
  IF NEW.entry_type NOT IN ('weekly', 'weekly_reassigned') THEN
    NEW.weekly_entitlement_allocation_id := NULL;
    RETURN NEW;
  END IF;

  SELECT r.* INTO v_report
  FROM public.daily_work_reports r
  WHERE r.id = NEW.daily_work_report_id
    AND r.organization_id = NEW.organization_id
    AND r.pump_id = NEW.pump_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily report not found for weekly entitlement reconciliation'
      USING ERRCODE = '23503';
  END IF;

  IF NEW.entry_type = 'weekly' THEN
    SELECT e.* INTO v_schedule_entry
    FROM public.schedule_entries e
    WHERE e.id = NEW.schedule_entry_id
      AND e.organization_id = NEW.organization_id
      AND e.pump_id = NEW.pump_id
      AND e.subscriber_id = NEW.subscriber_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Weekly report item does not match its schedule entry'
        USING ERRCODE = '23503';
    END IF;

    SELECT ws.* INTO v_schedule
    FROM public.weekly_schedules ws
    WHERE ws.id = v_schedule_entry.weekly_schedule_id
      AND ws.organization_id = NEW.organization_id
      AND ws.pump_id = NEW.pump_id
      AND ws.status IN ('active', 'archived')
      AND v_report.work_date >= ws.effective_from
      AND (ws.effective_to IS NULL OR v_report.work_date <= ws.effective_to);
  ELSE
    IF NEW.schedule_entry_id IS NOT NULL OR NEW.subscriber_id IS NULL THEN
      RAISE EXCEPTION 'A reassigned weekly report row requires a subscriber and no template schedule entry'
        USING ERRCODE = '23514';
    END IF;

    SELECT ws.* INTO v_schedule
    FROM public.weekly_schedules ws
    JOIN public.weekly_schedule_subscribers m
      ON m.weekly_schedule_id = ws.id
     AND m.organization_id = ws.organization_id
     AND m.pump_id = ws.pump_id
    WHERE ws.organization_id = NEW.organization_id
      AND ws.pump_id = NEW.pump_id
      AND ws.status IN ('active', 'archived')
      AND m.subscriber_id = NEW.subscriber_id
      AND v_report.work_date >= ws.effective_from
      AND (ws.effective_to IS NULL OR v_report.work_date <= ws.effective_to)
    ORDER BY ws.effective_from DESC, ws.created_at DESC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Weekly report schedule is not effective on the report date'
      USING ERRCODE = '23503';
  END IF;

  v_cycle_start := v_report.work_date - (
    (extract(isodow FROM v_report.work_date)::integer - v_schedule.week_starts_on + 7) % 7
  );

  PERFORM water_management_private.ensure_weekly_entitlement_cycle(
    v_schedule.id, NEW.organization_id, NEW.pump_id,
    v_cycle_start, auth.uid()
  );

  SELECT a.* INTO v_allocation
  FROM public.weekly_entitlement_allocations a
  JOIN public.weekly_entitlement_cycles c
    ON c.id = a.weekly_entitlement_cycle_id
  WHERE c.weekly_schedule_id = v_schedule.id
    AND c.cycle_start = v_cycle_start
    AND c.subscriber_id = NEW.subscriber_id
    AND a.organization_id = NEW.organization_id
    AND a.pump_id = NEW.pump_id
    AND a.allocation_date = v_report.work_date
    AND (
      (NEW.entry_type = 'weekly' AND a.source_schedule_entry_id = NEW.schedule_entry_id)
      OR (NEW.entry_type = 'weekly_reassigned' AND a.source_schedule_entry_id IS NULL)
    )
  FOR UPDATE OF a;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No weekly entitlement allocation exists for this report date and subscriber'
      USING ERRCODE = '23503';
  END IF;

  NEW.weekly_entitlement_allocation_id := v_allocation.id;
  NEW.scheduled_minutes := v_allocation.allocated_minutes;

  -- Only operations attached to this weekly allocation are weekly minutes.
  -- Additional registered fills for the same subscriber remain additional.
  SELECT floor(COALESCE(sum(op.actual_seconds), 0) / 60)::integer
  INTO v_app_minutes
  FROM public.queue_items qi
  JOIN public.pump_operations op
    ON op.id = qi.operation_id
   AND op.organization_id = qi.organization_id
   AND op.pump_id = qi.pump_id
  WHERE qi.weekly_entitlement_allocation_id = v_allocation.id
    AND qi.status = 'completed'
    AND op.status = 'completed';

  NEW.app_recorded_minutes := COALESCE(v_app_minutes, 0);
  RETURN NEW;
END;
$prepare_weekly_entitlement_report_item$;

REVOKE ALL ON FUNCTION water_management_private.prepare_weekly_entitlement_report_item()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER prepare_weekly_entitlement_report_item
  BEFORE INSERT OR UPDATE ON public.daily_work_report_items
  FOR EACH ROW EXECUTE FUNCTION water_management_private.prepare_weekly_entitlement_report_item();

CREATE OR REPLACE FUNCTION water_management_private.reconcile_weekly_entitlements_on_report_submit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $reconcile_weekly_entitlements_on_report_submit$
DECLARE
  v_item public.daily_work_report_items%ROWTYPE;
  v_allocation public.weekly_entitlement_allocations%ROWTYPE;
  v_cycle public.weekly_entitlement_cycles%ROWTYPE;
  v_delta integer;
  v_target integer;
BEGIN
  IF OLD.status <> 'draft' OR NEW.status <> 'submitted' THEN
    RETURN NEW;
  END IF;

  FOR v_item IN
    SELECT ri.*
    FROM public.daily_work_report_items ri
    WHERE ri.daily_work_report_id = NEW.id
      AND ri.organization_id = NEW.organization_id
      AND ri.pump_id = NEW.pump_id
      AND ri.entry_type IN ('weekly', 'weekly_reassigned')
    ORDER BY ri.weekly_entitlement_allocation_id
  LOOP
    SELECT c.* INTO v_cycle
    FROM public.weekly_entitlement_cycles c
    JOIN public.weekly_entitlement_allocations a
      ON a.weekly_entitlement_cycle_id = c.id
    WHERE a.id = v_item.weekly_entitlement_allocation_id
    FOR UPDATE OF c;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Weekly entitlement cycle not found for report reconciliation'
        USING ERRCODE = '55000';
    END IF;

    SELECT a.* INTO v_allocation
    FROM public.weekly_entitlement_allocations a
    WHERE a.id = v_item.weekly_entitlement_allocation_id
    FOR UPDATE;

    v_target := v_item.weekly_minutes_consumed;
    IF v_target > v_allocation.allocated_minutes THEN
      RAISE EXCEPTION 'Reported weekly minutes exceed the current allocation for this day'
        USING ERRCODE = '23514';
    END IF;
    IF v_target < v_allocation.consumed_minutes THEN
      RAISE EXCEPTION 'Submitted report cannot reduce weekly minutes already recorded from completed operations'
        USING ERRCODE = '23514';
    END IF;

    v_delta := v_target - v_allocation.consumed_minutes;
    IF v_cycle.status = 'expired' AND v_delta > v_cycle.expired_minutes THEN
      RAISE EXCEPTION 'Late report exceeds the minutes that expired in this weekly cycle'
        USING ERRCODE = '23514';
    END IF;
    IF v_delta > 0 THEN
      UPDATE public.weekly_entitlement_allocations
      SET consumed_minutes = consumed_minutes + v_delta,
          updated_at = clock_timestamp()
      WHERE id = v_allocation.id;

      UPDATE public.weekly_entitlement_cycles
      SET consumed_minutes = consumed_minutes + v_delta,
          expired_minutes = CASE WHEN status = 'expired' THEN expired_minutes - v_delta ELSE expired_minutes END
      WHERE id = v_cycle.id;

      PERFORM water_management_private.append_weekly_entitlement_event(
        v_cycle.id, v_allocation.id, NULL, 'manual_reconciliation', v_delta,
        v_allocation.allocation_date, NULL, auth.uid(), NULL,
        jsonb_build_object(
          'daily_work_report_id', NEW.id,
          'daily_work_report_item_id', v_item.id,
          'app_recorded_minutes', v_item.app_recorded_minutes,
          'manual_minutes', v_item.manual_minutes,
          'weekly_minutes_consumed', v_target,
          'source', 'submitted_daily_report'
        )
      );
    END IF;
  END LOOP;

  RETURN NEW;
END;
$reconcile_weekly_entitlements_on_report_submit$;

REVOKE ALL ON FUNCTION water_management_private.reconcile_weekly_entitlements_on_report_submit()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER reconcile_weekly_entitlements_on_report_submit
  AFTER UPDATE OF status ON public.daily_work_reports
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION water_management_private.reconcile_weekly_entitlements_on_report_submit();

CREATE OR REPLACE FUNCTION water_management_private.transfer_weekly_entitlement_minutes_internal(
  p_source_allocation_id uuid,
  p_target_date date,
  p_minutes integer,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $transfer_weekly_entitlement_minutes_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date;
  v_source public.weekly_entitlement_allocations%ROWTYPE;
  v_target public.weekly_entitlement_allocations%ROWTYPE;
  v_cycle public.weekly_entitlement_cycles%ROWTYPE;
  v_source_queue public.daily_queues%ROWTYPE;
  v_target_queue public.daily_queues%ROWTYPE;
  v_source_item public.queue_items%ROWTYPE;
  v_target_item public.queue_items%ROWTYPE;
  v_subscriber public.subscribers%ROWTYPE;
  v_source_queue_id uuid;
  v_target_queue_id uuid;
  v_target_schedule_entry_id uuid;
  v_target_sort_order integer;
  v_source_available integer;
  v_source_after integer;
  v_target_after integer;
  v_target_source_type text;
  v_has_source_item boolean := false;
  v_has_target_item boolean := false;
  v_lock_id uuid;
  v_source_next_item_id uuid;
  v_source_new_token uuid;
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to transfer weekly entitlement minutes'
      USING ERRCODE = '42501';
  END IF;

  IF p_minutes IS NULL OR p_minutes NOT BETWEEN 1 AND 1440
     OR p_target_date IS DISTINCT FROM v_today
     OR char_length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 2 AND 240 THEN
    RAISE EXCEPTION 'Transfer target must be today, minutes must be positive, and a reason is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT a.* INTO v_source
  FROM public.weekly_entitlement_allocations a
  WHERE a.id = p_source_allocation_id
    AND a.organization_id = v_organization_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source weekly allocation is not accessible'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_role = 'operator'::public.app_role AND NOT EXISTS (
    SELECT 1 FROM public.pump_assignments pa
    WHERE pa.organization_id = v_organization_id
      AND pa.pump_id = v_source.pump_id
      AND pa.user_id = v_user_id
      AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump'
      USING ERRCODE = '42501';
  END IF;

  -- Expire prior cycles on demand as well as during daily queue generation.
  PERFORM water_management_private.expire_due_weekly_entitlement_cycles(
    v_organization_id, v_source.pump_id, v_today, v_user_id
  );

  IF v_source.allocation_date = p_target_date THEN
    RAISE EXCEPTION 'Source and target day must be different'
      USING ERRCODE = '22023';
  END IF;

  SELECT q.id INTO v_source_queue_id
  FROM public.daily_queues q
  WHERE q.organization_id = v_organization_id
    AND q.pump_id = v_source.pump_id
    AND q.queue_date = v_source.allocation_date;

  SELECT q.id INTO v_target_queue_id
  FROM public.daily_queues q
  WHERE q.organization_id = v_organization_id
    AND q.pump_id = v_source.pump_id
    AND q.queue_date = p_target_date;

  -- Lock queue rows before the cycle row, matching the queue-completion path.
  FOR v_lock_id IN
    SELECT q.id
    FROM public.daily_queues q
    WHERE q.id IN (v_source_queue_id, v_target_queue_id)
    ORDER BY q.id
    FOR UPDATE
  LOOP
    NULL;
  END LOOP;

  IF v_source_queue_id IS NOT NULL THEN
    SELECT q.* INTO v_source_queue
    FROM public.daily_queues q
    WHERE q.id = v_source_queue_id;
  END IF;

  SELECT c.* INTO v_cycle
  FROM public.weekly_entitlement_cycles c
  WHERE c.id = v_source.weekly_entitlement_cycle_id
    AND c.organization_id = v_organization_id
    AND c.pump_id = v_source.pump_id
    AND c.subscriber_id = v_source.subscriber_id
  FOR UPDATE;

  IF NOT FOUND OR v_cycle.status <> 'open'
     OR p_target_date NOT BETWEEN v_cycle.cycle_start AND v_cycle.cycle_end
     OR v_source.allocation_date NOT BETWEEN v_cycle.cycle_start AND v_cycle.cycle_end
     OR p_target_date < v_cycle.cycle_start
     OR p_target_date > v_cycle.cycle_end THEN
    RAISE EXCEPTION 'Transfer must remain inside the same open weekly entitlement cycle'
      USING ERRCODE = '22023';
  END IF;

  IF v_cycle.cycle_end < v_today OR v_cycle.remaining_minutes <= 0 THEN
    RAISE EXCEPTION 'Weekly entitlement cycle has expired or has no remaining minutes'
      USING ERRCODE = '55000';
  END IF;

  SELECT a.* INTO v_source
  FROM public.weekly_entitlement_allocations a
  WHERE a.id = p_source_allocation_id
  FOR UPDATE;

  v_source_available := v_source.allocated_minutes - v_source.consumed_minutes;
  IF p_minutes > v_source_available THEN
    RAISE EXCEPTION 'Transfer exceeds the unconsumed source-day balance (%)', v_source_available
      USING ERRCODE = '22023';
  END IF;

  SELECT s.* INTO v_subscriber
  FROM public.subscribers s
  WHERE s.id = v_source.subscriber_id
    AND s.organization_id = v_organization_id
    AND s.pump_id = v_source.pump_id
    AND s.is_active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Weekly entitlement subscriber is not active on this pump'
      USING ERRCODE = '23503';
  END IF;

  IF v_target_queue_id IS NOT NULL THEN
    SELECT q.* INTO v_target_queue
    FROM public.daily_queues q
    WHERE q.id = v_target_queue_id;

    IF v_target_queue.status = 'closed' THEN
      RAISE EXCEPTION 'The current daily queue is closed'
        USING ERRCODE = '55000';
    END IF;
  END IF;

  SELECT e.id INTO v_target_schedule_entry_id
  FROM public.schedule_entries e
  JOIN public.weekly_entitlement_cycles c
    ON c.weekly_schedule_id = e.weekly_schedule_id
   AND c.organization_id = e.organization_id
   AND c.pump_id = e.pump_id
  WHERE c.id = v_cycle.id
    AND e.subscriber_id = v_source.subscriber_id
    AND e.weekday = extract(isodow FROM p_target_date)::integer
  LIMIT 1;

  SELECT a.* INTO v_target
  FROM public.weekly_entitlement_allocations a
  WHERE a.weekly_entitlement_cycle_id = v_cycle.id
    AND a.allocation_date = p_target_date
  FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO public.weekly_entitlement_allocations (
      weekly_entitlement_cycle_id, organization_id, pump_id, subscriber_id,
      allocation_date, source_schedule_entry_id, original_minutes,
      allocated_minutes, consumed_minutes
    ) VALUES (
      v_cycle.id, v_cycle.organization_id, v_cycle.pump_id, v_cycle.subscriber_id,
      p_target_date, v_target_schedule_entry_id, 0, 0, 0
    )
    RETURNING * INTO v_target;
  END IF;

  SELECT qi.* INTO v_source_item
  FROM public.queue_items qi
  WHERE qi.weekly_entitlement_allocation_id = v_source.id
  FOR UPDATE;
  v_has_source_item := FOUND;

  SELECT qi.* INTO v_target_item
  FROM public.queue_items qi
  WHERE qi.weekly_entitlement_allocation_id = v_target.id
  FOR UPDATE;
  v_has_target_item := FOUND;

  IF v_has_source_item AND v_source_item.status = 'running' THEN
    RAISE EXCEPTION 'A running source-day item cannot be transferred'
      USING ERRCODE = '55000';
  END IF;
  IF v_has_target_item AND v_target_item.status IN ('running', 'completed') THEN
    RAISE EXCEPTION 'A current-day weekly item that has started or completed cannot receive transferred minutes'
      USING ERRCODE = '55000';
  END IF;

  v_source_after := v_source.allocated_minutes - p_minutes;
  v_target_after := v_target.allocated_minutes + p_minutes;
  IF v_target_after > 1440 THEN
    RAISE EXCEPTION 'The current-day allocation cannot exceed 1440 minutes'
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.weekly_entitlement_allocations
  SET allocated_minutes = v_source_after,
      updated_at = clock_timestamp()
  WHERE id = v_source.id;

  UPDATE public.weekly_entitlement_allocations
  SET allocated_minutes = v_target_after,
      updated_at = clock_timestamp()
  WHERE id = v_target.id;

  IF v_has_source_item AND v_source_item.status = 'queued' THEN
    IF v_source_after = 0 THEN
      UPDATE public.queue_items
      SET status = 'delayed'
      WHERE id = v_source_item.id;
    ELSE
      UPDATE public.queue_items
      SET planned_minutes = v_source_after
      WHERE id = v_source_item.id;
    END IF;

    IF v_source_after = 0
       AND v_source_queue.auto_advance_queue_item_id = v_source_item.id
       AND v_source_queue.auto_advance_token IS NOT NULL THEN
      SELECT qi.id INTO v_source_next_item_id
      FROM public.queue_items qi
      WHERE qi.daily_queue_id = v_source_queue_id
        AND qi.status = 'queued'
      ORDER BY qi.sort_order, qi.id
      LIMIT 1;

      IF v_source_next_item_id IS NOT NULL THEN
        v_source_new_token := gen_random_uuid();
        UPDATE public.daily_queues
        SET auto_advance_queue_item_id = v_source_next_item_id,
            auto_advance_token = v_source_new_token,
            auto_advance_at = v_source_queue.auto_advance_at,
            auto_advance_cancelled_at = NULL,
            queue_version = queue_version + 1,
            updated_at = clock_timestamp()
        WHERE id = v_source_queue_id;

        PERFORM water_management_private.append_queue_item_event(
          v_source_queue_id, v_source_next_item_id, v_organization_id, v_source.pump_id,
          'auto_advance_retargeted', v_user_id, p_reason,
          jsonb_build_object(
            'previous_queue_item_id', v_source_item.id,
            'previous_token', v_source_queue.auto_advance_token,
            'auto_advance_token', v_source_new_token,
            'auto_advance_at', v_source_queue.auto_advance_at,
            'reason', 'The previous weekly item was moved to another day'
          )
        );
      ELSE
        UPDATE public.daily_queues
        SET auto_advance_queue_item_id = NULL,
            auto_advance_token = NULL,
            auto_advance_at = NULL,
            auto_advance_cancelled_at = clock_timestamp(),
            queue_version = queue_version + 1,
            updated_at = clock_timestamp()
        WHERE id = v_source_queue_id;

        PERFORM water_management_private.append_queue_item_event(
          v_source_queue_id, v_source_item.id, v_organization_id, v_source.pump_id,
          'auto_advance_cancelled', v_user_id, p_reason,
          jsonb_build_object(
            'previous_token', v_source_queue.auto_advance_token,
            'reason', 'No queued item remained after the weekly item was moved'
          )
        );
      END IF;
    ELSE
      UPDATE public.daily_queues
      SET queue_version = queue_version + 1,
          updated_at = clock_timestamp()
      WHERE id = v_source_queue_id;
    END IF;

    PERFORM water_management_private.append_queue_item_event(
      v_source_queue_id, v_source_item.id, v_organization_id, v_source.pump_id,
      'weekly_minutes_transferred', v_user_id, p_reason,
      jsonb_build_object(
        'direction', 'out',
        'weekly_entitlement_allocation_id', v_source.id,
        'minutes', p_minutes,
        'allocated_minutes_after', v_source_after
      )
    );
  END IF;

  IF v_target_queue_id IS NOT NULL THEN
    v_target_source_type := CASE
      WHEN v_target.source_schedule_entry_id IS NULL THEN 'weekly_reassigned'
      ELSE 'weekly'
    END;

    IF v_has_target_item THEN
      UPDATE public.queue_items
      SET source_type = v_target_source_type,
          schedule_entry_id = v_target.source_schedule_entry_id,
          planned_minutes = v_target_after,
          status = 'queued'
      WHERE id = v_target_item.id;
    ELSE
      SELECT COALESCE(max(qi.sort_order), -1) + 1 INTO v_target_sort_order
      FROM public.queue_items qi
      WHERE qi.daily_queue_id = v_target_queue_id;

      INSERT INTO public.queue_items (
        daily_queue_id, organization_id, pump_id, source_type,
        schedule_entry_id, subscriber_id, subscriber_name_snapshot,
        branch_id, branch_name_snapshot, planned_minutes, sort_order,
        weekly_entitlement_allocation_id
      ) VALUES (
        v_target_queue_id, v_organization_id, v_source.pump_id, v_target_source_type,
        v_target.source_schedule_entry_id, v_subscriber.id, v_subscriber.full_name,
        v_subscriber.branch_id,
        CASE WHEN v_subscriber.branch_id IS NULL THEN NULL
             ELSE (SELECT b.name FROM public.branches b
                   WHERE b.id = v_subscriber.branch_id
                     AND b.organization_id = v_organization_id
                     AND b.pump_id = v_source.pump_id)
        END,
        v_target_after, v_target_sort_order, v_target.id
      )
      RETURNING * INTO v_target_item;
      v_has_target_item := true;

      PERFORM water_management_private.append_queue_item_event(
        v_target_queue_id, v_target_item.id, v_organization_id, v_source.pump_id,
        'item_created', v_user_id, NULL,
        jsonb_build_object(
          'source_type', v_target_source_type,
          'weekly_entitlement_allocation_id', v_target.id,
          'planned_minutes', v_target_after,
          'created_by_transfer', true
        )
      );
    END IF;

    UPDATE public.daily_queues
    SET queue_version = queue_version + 1,
        updated_at = clock_timestamp()
    WHERE id = v_target_queue_id;

    PERFORM water_management_private.append_queue_item_event(
      v_target_queue_id, v_target_item.id, v_organization_id, v_source.pump_id,
      'weekly_minutes_transferred', v_user_id, p_reason,
      jsonb_build_object(
        'direction', 'in',
        'weekly_entitlement_allocation_id', v_target.id,
        'minutes', p_minutes,
        'allocated_minutes_after', v_target_after
      )
    );
  END IF;

  PERFORM water_management_private.append_weekly_entitlement_event(
    v_cycle.id, v_source.id, v_target.id, 'minutes_transferred', p_minutes,
    v_source.allocation_date, p_target_date, v_user_id, p_reason,
    jsonb_build_object(
      'source_allocation_before', v_source.allocated_minutes,
      'source_allocation_after', v_source_after,
      'source_consumed_minutes', v_source.consumed_minutes,
      'target_allocation_before', v_target.allocated_minutes,
      'target_allocation_after', v_target_after,
      'cycle_quota_minutes', v_cycle.quota_minutes,
      'cycle_consumed_minutes', v_cycle.consumed_minutes,
      'cycle_remaining_minutes', v_cycle.remaining_minutes
    )
  );

  RETURN jsonb_build_object(
    'weekly_entitlement_cycle_id', v_cycle.id,
    'source_allocation_id', v_source.id,
    'target_allocation_id', v_target.id,
    'source_date', v_source.allocation_date,
    'target_date', p_target_date,
    'transferred_minutes', p_minutes,
    'source_available_after', v_source_after - v_source.consumed_minutes,
    'target_allocated_minutes_after', v_target_after,
    'cycle_remaining_minutes', v_cycle.remaining_minutes
  );
END;
$transfer_weekly_entitlement_minutes_internal$;

REVOKE ALL ON FUNCTION water_management_private.transfer_weekly_entitlement_minutes_internal(
  uuid, date, integer, text
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.transfer_weekly_entitlement_minutes_internal(
  uuid, date, integer, text
) TO authenticated;

CREATE OR REPLACE FUNCTION public.transfer_weekly_entitlement_minutes(
  p_source_allocation_id uuid,
  p_target_date date,
  p_minutes integer,
  p_reason text
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $transfer_weekly_entitlement_minutes_rpc$
  SELECT water_management_private.transfer_weekly_entitlement_minutes_internal(
    p_source_allocation_id, p_target_date, p_minutes, p_reason
  )
$transfer_weekly_entitlement_minutes_rpc$;

REVOKE ALL ON FUNCTION public.transfer_weekly_entitlement_minutes(uuid, date, integer, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_weekly_entitlement_minutes(uuid, date, integer, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION water_management_private.get_weekly_entitlement_transfer_options_internal(
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $get_weekly_entitlement_transfer_options_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date;
  v_schedule public.weekly_schedules%ROWTYPE;
  v_cycle_start date;
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to read weekly transfer options'
      USING ERRCODE = '42501';
  END IF;
  IF p_pump_id IS NULL OR p_target_date IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'Weekly transfer options are available only for the current local date'
      USING ERRCODE = '22023';
  END IF;
  IF v_role = 'operator'::public.app_role AND NOT EXISTS (
    SELECT 1 FROM public.pump_assignments pa
    WHERE pa.organization_id = v_organization_id
      AND pa.pump_id = p_pump_id
      AND pa.user_id = v_user_id
      AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump'
      USING ERRCODE = '42501';
  END IF;

  SELECT ws.* INTO v_schedule
  FROM public.weekly_schedules ws
  WHERE ws.organization_id = v_organization_id
    AND ws.pump_id = p_pump_id
    AND ws.status IN ('active', 'archived')
    AND p_target_date >= ws.effective_from
    AND (ws.effective_to IS NULL OR p_target_date <= ws.effective_to)
  ORDER BY ws.effective_from DESC, ws.created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No effective weekly schedule applies to today'
      USING ERRCODE = 'P0002';
  END IF;

  v_cycle_start := p_target_date - (
    (extract(isodow FROM p_target_date)::integer - v_schedule.week_starts_on + 7) % 7
  );

  PERFORM water_management_private.ensure_weekly_entitlement_cycle(
    v_schedule.id, v_organization_id, p_pump_id,
    v_cycle_start, v_user_id
  );
  PERFORM water_management_private.expire_due_weekly_entitlement_cycles(
    v_organization_id, p_pump_id, v_today, v_user_id
  );

  RETURN QUERY
  SELECT
    a.id,
    a.subscriber_id,
    s.full_name,
    a.allocation_date,
    a.original_minutes,
    a.allocated_minutes,
    a.consumed_minutes,
    a.available_minutes,
    COALESCE(target.allocated_minutes, 0),
    c.quota_minutes,
    c.consumed_minutes,
    c.remaining_minutes,
    c.cycle_start,
    c.cycle_end
  FROM public.weekly_entitlement_allocations a
  JOIN public.weekly_entitlement_cycles c
    ON c.id = a.weekly_entitlement_cycle_id
  JOIN public.subscribers s
    ON s.id = a.subscriber_id
   AND s.organization_id = a.organization_id
   AND s.pump_id = a.pump_id
  LEFT JOIN public.weekly_entitlement_allocations target
    ON target.weekly_entitlement_cycle_id = a.weekly_entitlement_cycle_id
   AND target.allocation_date = p_target_date
  WHERE c.weekly_schedule_id = v_schedule.id
    AND c.cycle_start = v_cycle_start
    AND c.status = 'open'
    AND a.allocation_date <> p_target_date
    AND a.available_minutes > 0
    AND NOT EXISTS (
      SELECT 1 FROM public.queue_items qi
      WHERE qi.weekly_entitlement_allocation_id = a.id
        AND qi.status = 'running'
    )
  ORDER BY a.allocation_date, s.full_name, a.id;
END;
$get_weekly_entitlement_transfer_options_internal$;

REVOKE ALL ON FUNCTION water_management_private.get_weekly_entitlement_transfer_options_internal(uuid, date)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.get_weekly_entitlement_transfer_options_internal(uuid, date)
  TO authenticated;

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
AS $get_weekly_entitlement_transfer_options_rpc$
  SELECT * FROM water_management_private.get_weekly_entitlement_transfer_options_internal(
    p_pump_id, p_target_date
  )
$get_weekly_entitlement_transfer_options_rpc$;

REVOKE ALL ON FUNCTION public.get_weekly_entitlement_transfer_options(uuid, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_weekly_entitlement_transfer_options(uuid, date)
  TO authenticated;

-- Queue event types now explicitly distinguish the outgoing and incoming
-- sides of a weekly allocation transfer.
ALTER TABLE public.queue_item_events
  DROP CONSTRAINT queue_item_events_event_type_check;

ALTER TABLE public.queue_item_events
  ADD CONSTRAINT queue_item_events_event_type_check CHECK (event_type IN (
    'queue_generated',
    'item_created',
    'reordered',
    'branch_order_override',
    'started',
    'completed',
    'auto_advance_scheduled',
    'auto_advance_retargeted',
    'auto_advance_cancelled',
    'queue_closed',
    'weekly_minutes_transferred'
  ));

COMMENT ON TABLE public.weekly_entitlement_cycles IS
  'One immutable quota snapshot and live consumption/expiry balance for each subscriber and seven-day weekly cycle.';
COMMENT ON TABLE public.weekly_entitlement_allocations IS
  'Current daily allocation ledger. Transfers decrease one date and increase another in the same cycle; consumed minutes cannot be moved.';
COMMENT ON TABLE public.weekly_entitlement_events IS
  'Append-only audit ledger for weekly quota initialization, operation consumption, manual report reconciliation, transfers, and expiry.';


-- Reassigned weekly allocations are first-class weekly report rows; they
-- remain part of the weekly quota rather than being treated as extra fills.
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
  v_weekly_schedule public.weekly_schedules%ROWTYPE;
  v_cycle_start date;
  v_allocation public.weekly_entitlement_allocations%ROWTYPE;
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
      SELECT e.planned_minutes, s.id, s.full_name, ws.id, ws.week_starts_on
      INTO v_scheduled_minutes, v_subscriber_id, v_subscriber_name,
           v_weekly_schedule.id, v_weekly_schedule.week_starts_on
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

      v_cycle_start := v_work_date - (
        (extract(isodow FROM v_work_date)::integer - v_weekly_schedule.week_starts_on + 7) % 7
      );
      PERFORM water_management_private.ensure_weekly_entitlement_cycle(
        v_weekly_schedule.id, v_org_id, p_pump_id, v_cycle_start, v_user_id
      );

      SELECT a.* INTO v_allocation
      FROM public.weekly_entitlement_allocations a
      JOIN public.weekly_entitlement_cycles c
        ON c.id = a.weekly_entitlement_cycle_id
      WHERE c.weekly_schedule_id = v_weekly_schedule.id
        AND c.cycle_start = v_cycle_start
        AND c.subscriber_id = v_subscriber_id
        AND a.allocation_date = v_work_date
        AND a.source_schedule_entry_id = v_schedule_entry_id
      FOR UPDATE OF a;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Weekly entitlement allocation was not found for the scheduled item' USING ERRCODE = '23503';
      END IF;

      v_scheduled_minutes := v_allocation.allocated_minutes;
      SELECT floor(COALESCE(sum(op.actual_seconds), 0) / 60)::integer
      INTO v_app_minutes
      FROM public.queue_items qi
      JOIN public.pump_operations op
        ON op.id = qi.operation_id
       AND op.organization_id = qi.organization_id
       AND op.pump_id = qi.pump_id
      WHERE qi.weekly_entitlement_allocation_id = v_allocation.id
        AND qi.status = 'completed'
        AND op.status = 'completed';
      IF v_manual_minutes > GREATEST(0, v_scheduled_minutes - v_app_minutes) THEN
        RAISE EXCEPTION 'Manual weekly minutes cannot exceed the remaining daily entitlement allocation' USING ERRCODE = '22023';
      END IF;
    ELSIF v_entry_type = 'weekly_reassigned' THEN
      IF v_schedule_entry_id IS NOT NULL THEN
        RAISE EXCEPTION 'A reassigned weekly report item cannot reference a template schedule entry' USING ERRCODE = '22023';
      END IF;

      SELECT s.full_name INTO v_subscriber_name
      FROM public.subscribers s
      WHERE s.id = v_subscriber_id
        AND s.organization_id = v_org_id
        AND s.pump_id = p_pump_id
        AND s.is_active;
      IF v_subscriber_name IS NULL THEN
        RAISE EXCEPTION 'Reassigned weekly item must reference an active subscriber on this pump' USING ERRCODE = '23503';
      END IF;

      SELECT ws.* INTO v_weekly_schedule
      FROM public.weekly_schedules ws
      JOIN public.weekly_schedule_subscribers m
        ON m.weekly_schedule_id = ws.id
       AND m.organization_id = ws.organization_id
       AND m.pump_id = ws.pump_id
      WHERE ws.organization_id = v_org_id
        AND ws.pump_id = p_pump_id
        AND ws.status IN ('active', 'archived')
        AND m.subscriber_id = v_subscriber_id
        AND v_work_date >= ws.effective_from
        AND (ws.effective_to IS NULL OR v_work_date <= ws.effective_to)
      ORDER BY ws.effective_from DESC, ws.created_at DESC
      LIMIT 1;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'No effective weekly schedule exists for the reassigned weekly subscriber' USING ERRCODE = '23503';
      END IF;

      v_cycle_start := v_work_date - (
        (extract(isodow FROM v_work_date)::integer - v_weekly_schedule.week_starts_on + 7) % 7
      );
      PERFORM water_management_private.ensure_weekly_entitlement_cycle(
        v_weekly_schedule.id, v_org_id, p_pump_id, v_cycle_start, v_user_id
      );

      SELECT a.* INTO v_allocation
      FROM public.weekly_entitlement_allocations a
      JOIN public.weekly_entitlement_cycles c
        ON c.id = a.weekly_entitlement_cycle_id
      WHERE c.weekly_schedule_id = v_weekly_schedule.id
        AND c.cycle_start = v_cycle_start
        AND c.subscriber_id = v_subscriber_id
        AND a.allocation_date = v_work_date
        AND a.source_schedule_entry_id IS NULL
      FOR UPDATE OF a;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'No reassigned weekly allocation exists for this subscriber and day' USING ERRCODE = '23503';
      END IF;

      v_scheduled_minutes := v_allocation.allocated_minutes;
      SELECT floor(COALESCE(sum(op.actual_seconds), 0) / 60)::integer
      INTO v_app_minutes
      FROM public.queue_items qi
      JOIN public.pump_operations op
        ON op.id = qi.operation_id
       AND op.organization_id = qi.organization_id
       AND op.pump_id = qi.pump_id
      WHERE qi.weekly_entitlement_allocation_id = v_allocation.id
        AND qi.status = 'completed'
        AND op.status = 'completed';
      IF v_manual_minutes > GREATEST(0, v_scheduled_minutes - v_app_minutes) THEN
        RAISE EXCEPTION 'Manual weekly minutes cannot exceed the remaining reassigned daily allocation' USING ERRCODE = '22023';
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
      CASE WHEN v_entry_type IN ('weekly', 'weekly_reassigned') THEN v_manual_minutes ELSE 0 END,
      v_extra_minutes, v_note
    );
    v_item_count := v_item_count + 1;
  END LOOP;

  IF p_submit THEN
    -- Provision every effective weekly cycle for the report date before
    -- validating completeness. This keeps the report invariant independent
    -- of whether today's daily queue was opened earlier.
    FOR v_weekly_schedule IN
      SELECT ws.*
      FROM public.weekly_schedules ws
      WHERE ws.organization_id = v_org_id
        AND ws.pump_id = p_pump_id
        AND ws.status = 'active'
        AND v_work_date >= ws.effective_from
        AND (ws.effective_to IS NULL OR v_work_date <= ws.effective_to)
      ORDER BY ws.id
    LOOP
      v_cycle_start := v_work_date - (
        (extract(isodow FROM v_work_date)::integer - v_weekly_schedule.week_starts_on + 7) % 7
      );
      PERFORM water_management_private.ensure_weekly_entitlement_cycle(
        v_weekly_schedule.id, v_org_id, p_pump_id, v_cycle_start, v_user_id
      );
    END LOOP;

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
        AND EXISTS (
          SELECT 1
          FROM public.weekly_entitlement_cycles c
          JOIN public.weekly_entitlement_allocations a
            ON a.weekly_entitlement_cycle_id = c.id
          WHERE c.weekly_schedule_id = ws.id
            AND c.organization_id = ws.organization_id
            AND c.pump_id = ws.pump_id
            AND c.cycle_start = v_work_date - (
              (extract(isodow FROM v_work_date)::integer - ws.week_starts_on + 7) % 7
            )
            AND a.subscriber_id = se.subscriber_id
            AND a.allocation_date = v_work_date
            AND a.source_schedule_entry_id = se.id
            AND a.allocated_minutes > 0
        )
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
      SELECT 1
      FROM public.weekly_entitlement_cycles c
      JOIN public.weekly_entitlement_allocations a
        ON a.weekly_entitlement_cycle_id = c.id
      WHERE c.organization_id = v_org_id
        AND c.pump_id = p_pump_id
        AND c.status = 'open'
        AND a.allocation_date = v_work_date
        AND a.source_schedule_entry_id IS NULL
        AND a.allocated_minutes > 0
        AND NOT EXISTS (
          SELECT 1 FROM public.daily_work_report_items ri
          WHERE ri.daily_work_report_id = v_report.id
            AND ri.weekly_entitlement_allocation_id = a.id
        )
    ) THEN
      RAISE EXCEPTION 'Daily report must include every reassigned weekly entitlement allocation for this pump and date'
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


