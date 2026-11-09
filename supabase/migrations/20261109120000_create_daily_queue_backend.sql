-- Persist the operator's daily queue and connect it transactionally to pump operations.
-- The three-second auto-advance is represented by a server timestamp + one-use token;
-- clients must call start_next_daily_queue_item after the deadline.

CREATE TABLE public.daily_queues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  weekly_schedule_id uuid NOT NULL,
  queue_date date NOT NULL,
  week_starts_on smallint NOT NULL CHECK (week_starts_on BETWEEN 1 AND 7),
  weekly_cycle_start date NOT NULL,
  status text NOT NULL DEFAULT 'ready'
    CHECK (status IN ('ready', 'running', 'closed')),
  queue_version integer NOT NULL DEFAULT 1 CHECK (queue_version > 0),
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  closed_at timestamptz,
  auto_advance_queue_item_id uuid,
  auto_advance_at timestamptz,
  auto_advance_token uuid,
  auto_advance_cancelled_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT daily_queues_id_tenant_pump_key UNIQUE (id, organization_id, pump_id),
  CONSTRAINT daily_queues_pump_scope_fkey
    FOREIGN KEY (pump_id, organization_id)
    REFERENCES public.pumps (id, organization_id) ON DELETE CASCADE,
  CONSTRAINT daily_queues_schedule_scope_fkey
    FOREIGN KEY (weekly_schedule_id, organization_id, pump_id)
    REFERENCES public.weekly_schedules (id, organization_id, pump_id) ON DELETE RESTRICT,
  CONSTRAINT daily_queues_date_uidx UNIQUE (organization_id, pump_id, queue_date),
  CONSTRAINT daily_queues_cycle_check CHECK (
    queue_date >= weekly_cycle_start
    AND queue_date < weekly_cycle_start + 7
    AND extract(isodow FROM weekly_cycle_start)::integer = week_starts_on
  ),
  CONSTRAINT daily_queues_lifecycle_check CHECK (
    (status = 'ready' AND started_at IS NULL AND closed_at IS NULL)
    OR (status = 'running' AND started_at IS NOT NULL AND closed_at IS NULL)
    OR (status = 'closed' AND closed_at IS NOT NULL)
  ),
  CONSTRAINT daily_queues_auto_advance_state_check CHECK (
    (
      auto_advance_queue_item_id IS NULL
      AND auto_advance_at IS NULL
      AND auto_advance_token IS NULL
    )
    OR (
      auto_advance_queue_item_id IS NOT NULL
      AND auto_advance_at IS NOT NULL
      AND auto_advance_token IS NOT NULL
      AND auto_advance_cancelled_at IS NULL
    )
  )
);

CREATE INDEX daily_queues_pump_date_idx
  ON public.daily_queues (organization_id, pump_id, queue_date DESC);
CREATE INDEX daily_queues_schedule_idx
  ON public.daily_queues (weekly_schedule_id);

CREATE TABLE public.queue_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  daily_queue_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  source_type text NOT NULL
    CHECK (source_type IN ('weekly', 'weekly_reassigned', 'additional_registered', 'additional_guest', 'emergency')),
  schedule_entry_id uuid,
  subscriber_id uuid,
  subscriber_name_snapshot text NOT NULL
    CHECK (char_length(btrim(subscriber_name_snapshot)) BETWEEN 2 AND 120),
  branch_id uuid,
  branch_name_snapshot text,
  planned_minutes integer NOT NULL CHECK (planned_minutes BETWEEN 1 AND 1440),
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'running', 'completed', 'delayed', 'cancelled')),
  operation_id uuid REFERENCES public.pump_operations(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz,
  CONSTRAINT queue_items_id_queue_scope_key
    UNIQUE (id, daily_queue_id, organization_id, pump_id),
  CONSTRAINT queue_items_queue_order_uidx UNIQUE (daily_queue_id, sort_order),
  CONSTRAINT queue_items_daily_queue_scope_fkey
    FOREIGN KEY (daily_queue_id, organization_id, pump_id)
    REFERENCES public.daily_queues (id, organization_id, pump_id) ON DELETE CASCADE,
  CONSTRAINT queue_items_schedule_scope_fkey
    FOREIGN KEY (schedule_entry_id, organization_id, pump_id)
    REFERENCES public.schedule_entries (id, organization_id, pump_id) ON DELETE RESTRICT,
  CONSTRAINT queue_items_subscriber_scope_fkey
    FOREIGN KEY (subscriber_id, organization_id, pump_id)
    REFERENCES public.subscribers (id, organization_id, pump_id) ON DELETE RESTRICT,
  CONSTRAINT queue_items_branch_scope_fkey
    FOREIGN KEY (branch_id, organization_id, pump_id)
    REFERENCES public.branches (id, organization_id, pump_id) ON DELETE RESTRICT,
  CONSTRAINT queue_items_source_shape_check CHECK (
    (
      source_type IN ('weekly', 'weekly_reassigned')
      AND schedule_entry_id IS NOT NULL
      AND subscriber_id IS NOT NULL
    )
    OR (
      source_type = 'additional_registered'
      AND schedule_entry_id IS NULL
      AND subscriber_id IS NOT NULL
    )
    OR (
      source_type IN ('additional_guest', 'emergency')
      AND schedule_entry_id IS NULL
      AND subscriber_id IS NULL
      AND branch_id IS NULL
    )
  ),
  CONSTRAINT queue_items_state_shape_check CHECK (
    (
      status = 'queued'
      AND operation_id IS NULL
      AND started_at IS NULL
      AND completed_at IS NULL
    )
    OR (
      status = 'running'
      AND operation_id IS NOT NULL
      AND started_at IS NOT NULL
      AND completed_at IS NULL
    )
    OR (
      status = 'completed'
      AND operation_id IS NOT NULL
      AND started_at IS NOT NULL
      AND completed_at IS NOT NULL
    )
    OR (
      status IN ('delayed', 'cancelled')
      AND operation_id IS NULL
      AND started_at IS NULL
      AND completed_at IS NULL
    )
  )
);

CREATE UNIQUE INDEX queue_items_operation_uidx
  ON public.queue_items (operation_id)
  WHERE operation_id IS NOT NULL;
CREATE INDEX queue_items_queue_status_order_idx
  ON public.queue_items (daily_queue_id, status, sort_order, id);
CREATE INDEX queue_items_subscriber_idx
  ON public.queue_items (subscriber_id, daily_queue_id)
  WHERE subscriber_id IS NOT NULL;
CREATE INDEX queue_items_branch_idx
  ON public.queue_items (branch_id, daily_queue_id, sort_order)
  WHERE branch_id IS NOT NULL;
CREATE INDEX queue_items_schedule_entry_idx
  ON public.queue_items (schedule_entry_id)
  WHERE schedule_entry_id IS NOT NULL;

-- Append-only event ledger. Queue state is changed only by the guarded RPCs below.
CREATE TABLE public.queue_item_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  daily_queue_id uuid NOT NULL,
  queue_item_id uuid,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  event_sequence bigint NOT NULL CHECK (event_sequence > 0),
  event_type text NOT NULL CHECK (event_type IN (
    'queue_generated',
    'item_created',
    'reordered',
    'branch_order_override',
    'started',
    'completed',
    'auto_advance_scheduled',
    'auto_advance_retargeted',
    'auto_advance_cancelled',
    'queue_closed'
  )),
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reason text CHECK (reason IS NULL OR char_length(reason) <= 240),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT queue_item_events_sequence_uidx UNIQUE (daily_queue_id, event_sequence),
  CONSTRAINT queue_item_events_queue_scope_fkey
    FOREIGN KEY (daily_queue_id, organization_id, pump_id)
    REFERENCES public.daily_queues (id, organization_id, pump_id) ON DELETE CASCADE,
  CONSTRAINT queue_item_events_item_scope_fkey
    FOREIGN KEY (queue_item_id, daily_queue_id, organization_id, pump_id)
    REFERENCES public.queue_items (id, daily_queue_id, organization_id, pump_id) ON DELETE CASCADE
);

CREATE INDEX queue_item_events_queue_time_idx
  ON public.queue_item_events (daily_queue_id, occurred_at DESC, event_sequence DESC);
CREATE INDEX queue_item_events_item_time_idx
  ON public.queue_item_events (queue_item_id, occurred_at, event_sequence)
  WHERE queue_item_id IS NOT NULL;
CREATE INDEX queue_item_events_actor_idx
  ON public.queue_item_events (actor_id, occurred_at DESC);

-- The queue points at its pending item. No client can write this reference;
-- all updates lock the parent queue and validate the item belongs to it.
COMMENT ON COLUMN public.daily_queues.auto_advance_queue_item_id IS
  'The queued item eligible for one automatic start after auto_advance_at, guarded by the one-use token.';
COMMENT ON COLUMN public.daily_queues.auto_advance_at IS
  'Server timestamp for the persisted three-second delay. A client must invoke the guarded start RPC after this time.';
COMMENT ON TABLE public.queue_item_events IS
  'Append-only audit ledger for daily queue creation, ordering, session transitions, and cancellable auto-advance.';

ALTER TABLE public.daily_queues ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.queue_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.queue_item_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.daily_queues FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.queue_items FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.queue_item_events FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.daily_queues TO authenticated;
GRANT SELECT ON public.queue_items TO authenticated;
GRANT SELECT ON public.queue_item_events TO authenticated;

CREATE POLICY daily_queues_select_assigned
  ON public.daily_queues
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = daily_queues.organization_id
          AND pa.pump_id = daily_queues.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
          AND pa.assignment_role IN ('operator'::public.app_role, 'supervisor'::public.app_role)
      )
    )
  );

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
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = queue_items.organization_id
          AND pa.pump_id = queue_items.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
          AND pa.assignment_role IN ('operator'::public.app_role, 'supervisor'::public.app_role)
      )
    )
  );

CREATE POLICY queue_item_events_select_assigned
  ON public.queue_item_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = queue_item_events.organization_id
          AND pa.pump_id = queue_item_events.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
          AND pa.assignment_role IN ('operator'::public.app_role, 'supervisor'::public.app_role)
      )
    )
  );

-- Fill identity/snapshot columns from their parent records. The composite
-- foreign keys below remain the final protection against cross-pump references.
CREATE FUNCTION water_management_private.prepare_daily_queue_item_scope()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $prepare_daily_queue_item_scope$
DECLARE
  v_queue public.daily_queues%ROWTYPE;
  v_subscriber public.subscribers%ROWTYPE;
  v_branch_name text;
  v_operation public.pump_operations%ROWTYPE;
BEGIN
  SELECT * INTO v_queue
  FROM public.daily_queues
  WHERE id = NEW.daily_queue_id;

  IF NOT FOUND
     OR NEW.organization_id <> v_queue.organization_id
     OR NEW.pump_id <> v_queue.pump_id THEN
    RAISE EXCEPTION 'Queue item must belong to its parent daily queue'
      USING ERRCODE = '23503';
  END IF;

  IF NEW.subscriber_id IS NOT NULL THEN
    SELECT * INTO v_subscriber
    FROM public.subscribers
    WHERE id = NEW.subscriber_id
      AND organization_id = v_queue.organization_id
      AND pump_id = v_queue.pump_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Queue subscriber must belong to the same organization and pump'
        USING ERRCODE = '23503';
    END IF;

    NEW.subscriber_name_snapshot := COALESCE(
      NULLIF(btrim(NEW.subscriber_name_snapshot), ''),
      v_subscriber.full_name
    );
    IF NEW.branch_id IS DISTINCT FROM v_subscriber.branch_id THEN
      RAISE EXCEPTION 'Queue branch must match the subscriber branch snapshot'
        USING ERRCODE = '23514';
    END IF;
    IF NEW.branch_id IS NOT NULL THEN
      SELECT b.name INTO v_branch_name
      FROM public.branches b
      WHERE b.id = NEW.branch_id
        AND b.organization_id = v_queue.organization_id
        AND b.pump_id = v_queue.pump_id;
      NEW.branch_name_snapshot := COALESCE(v_branch_name, NEW.branch_name_snapshot);
    END IF;
  ELSE
    IF NEW.branch_id IS NOT NULL OR NEW.schedule_entry_id IS NOT NULL THEN
      RAISE EXCEPTION 'Unregistered queue items cannot point to a schedule entry or branch'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.operation_id IS NOT NULL THEN
    SELECT * INTO v_operation
    FROM public.pump_operations
    WHERE id = NEW.operation_id
      AND organization_id = v_queue.organization_id
      AND pump_id = v_queue.pump_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Queue operation must belong to the same organization and pump'
        USING ERRCODE = '23503';
    END IF;
  END IF;

  RETURN NEW;
END;
$prepare_daily_queue_item_scope$;

REVOKE ALL ON FUNCTION water_management_private.prepare_daily_queue_item_scope()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER prepare_daily_queue_item_scope
  BEFORE INSERT OR UPDATE ON public.queue_items
  FOR EACH ROW EXECUTE FUNCTION water_management_private.prepare_daily_queue_item_scope();

CREATE OR REPLACE FUNCTION water_management_private.append_queue_item_event(
  p_daily_queue_id uuid,
  p_queue_item_id uuid,
  p_organization_id uuid,
  p_pump_id uuid,
  p_event_type text,
  p_actor_id uuid,
  p_reason text,
  p_metadata jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $append_queue_item_event$
DECLARE
  v_sequence bigint;
BEGIN
  SELECT COALESCE(max(event_sequence), 0) + 1 INTO v_sequence
  FROM public.queue_item_events
  WHERE daily_queue_id = p_daily_queue_id;

  INSERT INTO public.queue_item_events (
    daily_queue_id, queue_item_id, organization_id, pump_id,
    event_sequence, event_type, actor_id, reason, metadata
  ) VALUES (
    p_daily_queue_id, p_queue_item_id, p_organization_id, p_pump_id,
    v_sequence, p_event_type, p_actor_id, NULLIF(btrim(p_reason), ''), COALESCE(p_metadata, '{}'::jsonb)
  );
END;
$append_queue_item_event$;

REVOKE ALL ON FUNCTION water_management_private.append_queue_item_event(uuid, uuid, uuid, uuid, text, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION water_management_private.generate_daily_queue_internal(
  p_pump_id uuid,
  p_queue_date date
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $generate_daily_queue_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_weekly_schedule public.weekly_schedules%ROWTYPE;
  v_queue_id uuid;
  v_weekday smallint;
  v_cycle_start date;
  v_remaining uuid[];
  v_selected_id uuid;
  v_selected_branch_id uuid;
  v_last_branch_id uuid;
  v_has_previous boolean := false;
  v_position integer := 0;
  v_created_count integer := 0;
  v_inserted_count integer := 0;
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to generate daily queues' USING ERRCODE = '42501';
  END IF;
  IF p_pump_id IS NULL OR p_queue_date IS NULL THEN
    RAISE EXCEPTION 'Pump and queue date are required' USING ERRCODE = '22023';
  END IF;

  PERFORM 1
  FROM public.pumps p
  WHERE p.id = p_pump_id
    AND p.organization_id = v_organization_id
    AND p.status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pump is not active or not accessible' USING ERRCODE = '42501';
  END IF;

  IF v_role = 'operator'::public.app_role AND NOT EXISTS (
    SELECT 1 FROM public.pump_assignments pa
    WHERE pa.organization_id = v_organization_id
      AND pa.pump_id = p_pump_id
      AND pa.user_id = v_user_id
      AND pa.assignment_role = 'operator'::public.app_role
  ) THEN
    RAISE EXCEPTION 'Operator is not assigned to this pump' USING ERRCODE = '42501';
  END IF;

  v_weekday := extract(isodow FROM p_queue_date)::smallint;

  SELECT ws.* INTO v_weekly_schedule
  FROM public.weekly_schedules ws
  WHERE ws.organization_id = v_organization_id
    AND ws.pump_id = p_pump_id
    AND ws.status = 'active'
    AND p_queue_date >= ws.effective_from
    AND (ws.effective_to IS NULL OR p_queue_date <= ws.effective_to)
  ORDER BY ws.effective_from DESC, ws.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No active weekly schedule applies to this date'
      USING ERRCODE = 'P0002';
  END IF;

  v_cycle_start := p_queue_date - (
    (v_weekday - v_weekly_schedule.week_starts_on + 7) % 7
  );

  INSERT INTO public.daily_queues (
    organization_id, pump_id, weekly_schedule_id, queue_date,
    week_starts_on, weekly_cycle_start, status, created_by
  ) VALUES (
    v_organization_id, p_pump_id, v_weekly_schedule.id, p_queue_date,
    v_weekly_schedule.week_starts_on, v_cycle_start, 'ready', v_user_id
  )
  ON CONFLICT (organization_id, pump_id, queue_date) DO NOTHING
  RETURNING id INTO v_queue_id;

  IF v_queue_id IS NULL THEN
    SELECT q.id INTO v_queue_id
    FROM public.daily_queues q
    WHERE q.organization_id = v_organization_id
      AND q.pump_id = p_pump_id
      AND q.queue_date = p_queue_date;
    RETURN v_queue_id;
  END IF;

  INSERT INTO public.queue_items (
    daily_queue_id, organization_id, pump_id, source_type,
    schedule_entry_id, subscriber_id, subscriber_name_snapshot,
    branch_id, branch_name_snapshot, planned_minutes, sort_order
  )
  SELECT
    v_queue_id, v_organization_id, p_pump_id, 'weekly',
    e.id, s.id, s.full_name, s.branch_id, b.name, e.planned_minutes,
    row_number() OVER (ORDER BY e.sort_order, e.id)::integer - 1
  FROM public.schedule_entries e
  JOIN public.subscribers s
    ON s.id = e.subscriber_id
   AND s.organization_id = e.organization_id
   AND s.pump_id = e.pump_id
   AND s.is_active
  LEFT JOIN public.branches b
    ON b.id = s.branch_id
   AND b.organization_id = s.organization_id
   AND b.pump_id = s.pump_id
  WHERE e.weekly_schedule_id = v_weekly_schedule.id
    AND e.organization_id = v_organization_id
    AND e.pump_id = p_pump_id
    AND e.weekday = v_weekday;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  SELECT array_agg(qi.id ORDER BY qi.sort_order, qi.id)
  INTO v_remaining
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = v_queue_id
    AND qi.status = 'queued';

  IF COALESCE(cardinality(v_remaining), 0) > 0 THEN
    UPDATE public.queue_items
    SET sort_order = sort_order + 1000000
    WHERE daily_queue_id = v_queue_id
      AND status = 'queued';

    FOR v_position IN 1..cardinality(v_remaining) LOOP
      SELECT qi.id, qi.branch_id
      INTO v_selected_id, v_selected_branch_id
      FROM public.queue_items qi
      WHERE qi.id = ANY(v_remaining)
        AND (
          NOT v_has_previous
          OR qi.branch_id IS NULL
          OR v_last_branch_id IS NULL
          OR qi.branch_id IS DISTINCT FROM v_last_branch_id
        )
      ORDER BY qi.sort_order, qi.id
      LIMIT 1;

      IF NOT FOUND THEN
        SELECT qi.id, qi.branch_id
        INTO v_selected_id, v_selected_branch_id
        FROM public.queue_items qi
        WHERE qi.id = ANY(v_remaining)
        ORDER BY qi.sort_order, qi.id
        LIMIT 1;
      END IF;

      UPDATE public.queue_items
      SET sort_order = v_position - 1
      WHERE id = v_selected_id;

      v_remaining := array_remove(v_remaining, v_selected_id);
      v_last_branch_id := v_selected_branch_id;
      v_has_previous := true;
    END LOOP;
  END IF;

  PERFORM water_management_private.append_queue_item_event(
    v_queue_id, NULL, v_organization_id, p_pump_id,
    'queue_generated', v_user_id, NULL,
    jsonb_build_object(
      'weekly_schedule_id', v_weekly_schedule.id,
      'queue_date', p_queue_date,
      'weekly_cycle_start', v_cycle_start,
      'item_count', v_inserted_count
    )
  );

  INSERT INTO public.queue_item_events (
    daily_queue_id, queue_item_id, organization_id, pump_id,
    event_sequence, event_type, actor_id, metadata
  )
  SELECT
    v_queue_id, qi.id, v_organization_id, p_pump_id,
    row_number() OVER (ORDER BY qi.sort_order, qi.id)::bigint + 1,
    'item_created', v_user_id,
    jsonb_build_object(
      'source_type', qi.source_type,
      'subscriber_id', qi.subscriber_id,
      'planned_minutes', qi.planned_minutes,
      'sort_order', qi.sort_order
    )
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = v_queue_id;

  RETURN v_queue_id;
END;
$generate_daily_queue_internal$;

REVOKE ALL ON FUNCTION water_management_private.generate_daily_queue_internal(uuid, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.generate_daily_queue_internal(uuid, date)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.generate_daily_queue(
  p_pump_id uuid,
  p_queue_date date
)
RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT water_management_private.generate_daily_queue_internal(p_pump_id, p_queue_date)
$$;
REVOKE ALL ON FUNCTION public.generate_daily_queue(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.generate_daily_queue(uuid, date) TO authenticated;

CREATE OR REPLACE FUNCTION water_management_private.reorder_daily_queue_internal(
  p_queue_id uuid,
  p_expected_version integer,
  p_order uuid[],
  p_override_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $reorder_daily_queue$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_queue public.daily_queues%ROWTYPE;
  v_item_count integer;
  v_order_count integer := COALESCE(cardinality(p_order), 0);
  v_duplicate_count integer;
  v_missing_count integer;
  v_conflict_count integer := 0;
  v_base_order integer := 0;
  v_old_order jsonb;
  v_new_order jsonb;
  v_first_queue_item_id uuid;
  v_new_token uuid;
  v_reason text := NULLIF(btrim(COALESCE(p_override_reason, '')), '');
BEGIN
  -- The queue is global across operators. Only the manager may reorder it;
  -- an operator may act only on their own queue items, never on hidden turns.
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role <> 'manager'::public.app_role THEN
    RAISE EXCEPTION 'Only the manager can reorder the global daily queue'
      USING ERRCODE = '42501';
  END IF;

  -- Serialize manual item creation with subscriber reassignment and queue
  -- generation using the same pump -> queue -> subscriber lock order.
  SELECT q.pump_id INTO v_pump_id
  FROM public.daily_queues q
  WHERE q.id = p_queue_id
    AND q.organization_id = v_organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily queue not found or not accessible' USING ERRCODE = 'P0002';
  END IF;

  PERFORM 1
  FROM public.pumps p
  WHERE p.id = v_pump_id
    AND p.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily queue pump is not accessible' USING ERRCODE = 'P0002';
  END IF;

  SELECT q.* INTO v_queue
  FROM public.daily_queues q
  WHERE q.id = p_queue_id
    AND q.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND OR v_queue.pump_id IS DISTINCT FROM v_pump_id THEN
    RAISE EXCEPTION 'Daily queue changed; reload before adding an item'
      USING ERRCODE = '40001';
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

  IF v_queue.status = 'closed' THEN
    RAISE EXCEPTION 'Closed daily queues cannot be reordered' USING ERRCODE = 'P0002';
  END IF;
  IF p_expected_version IS DISTINCT FROM v_queue.queue_version THEN
    RAISE EXCEPTION 'Daily queue changed; reload before reordering'
      USING ERRCODE = '40001';
  END IF;

  SELECT count(*) INTO v_item_count
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id
    AND qi.status = 'queued';

  SELECT count(DISTINCT item_id) INTO v_duplicate_count
  FROM unnest(COALESCE(p_order, ARRAY[]::uuid[])) AS submitted(item_id);

  IF v_order_count <> v_item_count OR v_duplicate_count <> v_order_count THEN
    RAISE EXCEPTION 'Reorder payload must contain every queued item exactly once'
      USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_missing_count
  FROM unnest(COALESCE(p_order, ARRAY[]::uuid[])) AS submitted(item_id)
  LEFT JOIN public.queue_items qi
    ON qi.id = submitted.item_id
   AND qi.daily_queue_id = p_queue_id
   AND qi.status = 'queued'
  WHERE qi.id IS NULL;

  IF v_missing_count <> 0 OR EXISTS (
    SELECT 1
    FROM public.queue_items qi
    WHERE qi.daily_queue_id = p_queue_id
      AND qi.status = 'queued'
      AND NOT (qi.id = ANY(COALESCE(p_order, ARRAY[]::uuid[])))
  ) THEN
    RAISE EXCEPTION 'Reorder payload contains an item outside this queue or omits a queued item'
      USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_conflict_count
  FROM (
    SELECT qi.branch_id,
           lag(qi.branch_id) OVER (ORDER BY submitted.ordinality) AS previous_branch_id
    FROM unnest(COALESCE(p_order, ARRAY[]::uuid[]))
      WITH ORDINALITY AS submitted(item_id, ordinality)
    JOIN public.queue_items qi
      ON qi.id = submitted.item_id
     AND qi.daily_queue_id = p_queue_id
  ) ordered_items
  WHERE ordered_items.branch_id IS NOT NULL
    AND ordered_items.branch_id = ordered_items.previous_branch_id;

  IF v_conflict_count > 0 AND char_length(COALESCE(v_reason, '')) NOT BETWEEN 2 AND 240 THEN
    RAISE EXCEPTION 'A consecutive branch override requires a reason of 2 to 240 characters'
      USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object('id', qi.id, 'from', qi.sort_order)
    ORDER BY qi.sort_order, qi.id
  ) INTO v_old_order
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id
    AND qi.status = 'queued';

  SELECT COALESCE(max(qi.sort_order), -1) + 1
  INTO v_base_order
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id
    AND qi.status <> 'queued';

  SELECT jsonb_agg(
    jsonb_build_object('id', submitted.item_id, 'to', v_base_order + submitted.ordinality - 1)
    ORDER BY submitted.ordinality
  ) INTO v_new_order
  FROM unnest(COALESCE(p_order, ARRAY[]::uuid[]))
    WITH ORDINALITY AS submitted(item_id, ordinality);

  UPDATE public.queue_items
  SET sort_order = sort_order + 1000000
  WHERE daily_queue_id = p_queue_id
    AND status = 'queued';

  UPDATE public.queue_items qi
  SET sort_order = v_base_order + submitted.ordinality - 1
  FROM unnest(COALESCE(p_order, ARRAY[]::uuid[]))
    WITH ORDINALITY AS submitted(item_id, ordinality)
  WHERE qi.id = submitted.item_id
    AND qi.daily_queue_id = p_queue_id
    AND qi.status = 'queued';

  IF v_queue.auto_advance_token IS NOT NULL THEN
    SELECT qi.id INTO v_first_queue_item_id
    FROM public.queue_items qi
    WHERE qi.daily_queue_id = p_queue_id
      AND qi.status = 'queued'
    ORDER BY qi.sort_order, qi.id
    LIMIT 1;

    IF v_first_queue_item_id IS NULL THEN
      UPDATE public.daily_queues
      SET auto_advance_queue_item_id = NULL,
          auto_advance_at = NULL,
          auto_advance_token = NULL,
          auto_advance_cancelled_at = clock_timestamp(),
          queue_version = queue_version + 1,
          updated_at = clock_timestamp()
      WHERE id = p_queue_id;
    ELSE
      v_new_token := gen_random_uuid();
      UPDATE public.daily_queues
      SET auto_advance_queue_item_id = v_first_queue_item_id,
          auto_advance_token = v_new_token,
          queue_version = queue_version + 1,
          updated_at = clock_timestamp()
      WHERE id = p_queue_id;
      PERFORM water_management_private.append_queue_item_event(
        p_queue_id, v_first_queue_item_id, v_organization_id, v_queue.pump_id,
        'auto_advance_retargeted', v_user_id, v_reason,
        jsonb_build_object('previous_token_invalidated', true)
      );
    END IF;
  ELSE
    UPDATE public.daily_queues
    SET queue_version = queue_version + 1,
        updated_at = clock_timestamp()
    WHERE id = p_queue_id;
  END IF;

  PERFORM water_management_private.append_queue_item_event(
    p_queue_id, NULL, v_organization_id, v_queue.pump_id,
    'reordered', v_user_id, v_reason,
    jsonb_build_object(
      'previous_order', COALESCE(v_old_order, '[]'::jsonb),
      'new_order', COALESCE(v_new_order, '[]'::jsonb),
      'queue_version_before', v_queue.queue_version,
      'branch_conflict_count', v_conflict_count
    )
  );

  IF v_conflict_count > 0 THEN
    PERFORM water_management_private.append_queue_item_event(
      p_queue_id, NULL, v_organization_id, v_queue.pump_id,
      'branch_order_override', v_user_id, v_reason,
      jsonb_build_object('branch_conflict_count', v_conflict_count)
    );
  END IF;

  RETURN jsonb_build_object(
    'queue_id', p_queue_id,
    'queue_version', v_queue.queue_version + 1,
    'branch_conflict_count', v_conflict_count,
    'ordered_item_ids', to_jsonb(COALESCE(p_order, ARRAY[]::uuid[]))
  );
END;
$reorder_daily_queue$;
REVOKE ALL ON FUNCTION water_management_private.reorder_daily_queue_internal(uuid, integer, uuid[], text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.reorder_daily_queue_internal(uuid, integer, uuid[], text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.reorder_daily_queue(
  p_queue_id uuid,
  p_expected_version integer,
  p_order uuid[],
  p_override_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $reorder_queue_rpc$
  SELECT water_management_private.reorder_daily_queue_internal(
    p_queue_id, p_expected_version, p_order, p_override_reason
  )
$reorder_queue_rpc$;
REVOKE ALL ON FUNCTION public.reorder_daily_queue(uuid, integer, uuid[], text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reorder_daily_queue(uuid, integer, uuid[], text)
  TO authenticated;

CREATE OR REPLACE FUNCTION water_management_private.start_daily_queue_item_internal(
  p_queue_id uuid,
  p_queue_item_id uuid,
  p_power_source_id uuid,
  p_auto_advance_token uuid
)
RETURNS public.pump_operations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $start_daily_queue_item_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_queue public.daily_queues%ROWTYPE;
  v_item public.queue_items%ROWTYPE;
  v_first_item_id uuid;
  v_operation public.pump_operations%ROWTYPE;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to start daily queue items' USING ERRCODE = '42501';
  END IF;

  -- Serialize manual item creation with subscriber reassignment and queue
  -- generation using the same pump -> queue -> subscriber lock order.
  SELECT q.pump_id INTO v_pump_id
  FROM public.daily_queues q
  WHERE q.id = p_queue_id
    AND q.organization_id = v_organization_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily queue not found or not accessible' USING ERRCODE = 'P0002';
  END IF;

  PERFORM 1
  FROM public.pumps p
  WHERE p.id = v_pump_id
    AND p.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily queue pump is not accessible' USING ERRCODE = '42501';
  END IF;

  SELECT q.* INTO v_queue
  FROM public.daily_queues q
  WHERE q.id = p_queue_id
    AND q.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND OR v_queue.pump_id IS DISTINCT FROM v_pump_id THEN
    RAISE EXCEPTION 'Daily queue changed; reload before adding an item'
      USING ERRCODE = '40001';
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

  IF v_queue.queue_date <> (v_now AT TIME ZONE 'Asia/Hebron')::date THEN
    RAISE EXCEPTION 'Only the current local-day queue can be started'
      USING ERRCODE = '22023';
  END IF;
  IF v_queue.status = 'closed' THEN
    RAISE EXCEPTION 'Daily queue is closed' USING ERRCODE = 'P0002';
  END IF;

  SELECT qi.* INTO v_item
  FROM public.queue_items qi
  WHERE qi.id = p_queue_item_id
    AND qi.daily_queue_id = p_queue_id
    AND qi.organization_id = v_organization_id
    AND qi.pump_id = v_queue.pump_id
  FOR UPDATE;
  IF NOT FOUND OR v_item.status <> 'queued' THEN
    RAISE EXCEPTION 'Queue item is not waiting to start' USING ERRCODE = 'P0002';
  END IF;

  IF v_role = 'operator'::public.app_role
     AND v_item.assigned_operator_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'This queue item is assigned to another operator'
      USING ERRCODE = '42501';
  END IF;

  SELECT qi.id INTO v_first_item_id
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id
    AND qi.status = 'queued'
  ORDER BY qi.sort_order, qi.id
  LIMIT 1;
  IF v_first_item_id IS DISTINCT FROM v_item.id THEN
    RAISE EXCEPTION 'Only the first waiting queue item may start'
      USING ERRCODE = 'P0002';
  END IF;

  IF p_auto_advance_token IS NOT NULL THEN
    IF v_queue.auto_advance_queue_item_id IS DISTINCT FROM v_item.id
       OR v_queue.auto_advance_token IS DISTINCT FROM p_auto_advance_token
       OR v_queue.auto_advance_at IS NULL
       OR v_queue.auto_advance_at > v_now
       OR v_queue.auto_advance_cancelled_at IS NOT NULL THEN
      RAISE EXCEPTION 'Auto-advance is stale, cancelled, or not due yet'
        USING ERRCODE = 'P0002';
    END IF;
  ELSIF v_queue.auto_advance_token IS NOT NULL THEN
    PERFORM water_management_private.append_queue_item_event(
      p_queue_id, v_queue.auto_advance_queue_item_id, v_organization_id, v_queue.pump_id,
      'auto_advance_cancelled', v_user_id, 'بدأ المشغّل العنصر يدويًا قبل انتهاء العد التنازلي',
      jsonb_build_object('cancelled_by_manual_start', true)
    );
  END IF;

  v_operation := water_management_private.start_pump_operation_internal(
    v_queue.pump_id,
    v_item.subscriber_id,
    CASE WHEN v_item.subscriber_id IS NULL THEN v_item.subscriber_name_snapshot ELSE NULL END,
    v_item.planned_minutes,
    p_power_source_id
  );

  UPDATE public.queue_items
  SET status = 'running',
      operation_id = v_operation.id,
      started_at = v_now
  WHERE id = v_item.id;

  UPDATE public.daily_queues
  SET status = 'running',
      started_at = COALESCE(started_at, v_now),
      auto_advance_queue_item_id = NULL,
      auto_advance_at = NULL,
      auto_advance_token = NULL,
      auto_advance_cancelled_at = NULL,
      queue_version = queue_version + 1,
      updated_at = v_now
  WHERE id = p_queue_id;

  PERFORM water_management_private.append_queue_item_event(
    p_queue_id, v_item.id, v_organization_id, v_queue.pump_id,
    'started', v_user_id, NULL,
    jsonb_build_object(
      'operation_id', v_operation.id,
      'power_source_id', p_power_source_id,
      'started_at', v_now
    )
  );

  RETURN v_operation;
END;
$start_daily_queue_item_internal$;

REVOKE ALL ON FUNCTION water_management_private.start_daily_queue_item_internal(uuid, uuid, uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.start_daily_queue_item_internal(uuid, uuid, uuid, uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.start_daily_queue_item(
  p_queue_id uuid,
  p_queue_item_id uuid,
  p_power_source_id uuid
)
RETURNS public.pump_operations
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT water_management_private.start_daily_queue_item_internal(
    p_queue_id, p_queue_item_id, p_power_source_id, NULL
  )
$$;
REVOKE ALL ON FUNCTION public.start_daily_queue_item(uuid, uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_daily_queue_item(uuid, uuid, uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.start_next_daily_queue_item(
  p_queue_id uuid,
  p_queue_item_id uuid,
  p_auto_advance_token uuid,
  p_power_source_id uuid
)
RETURNS public.pump_operations
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT water_management_private.start_daily_queue_item_internal(
    p_queue_id, p_queue_item_id, p_power_source_id, p_auto_advance_token
  )
$$;
REVOKE ALL ON FUNCTION public.start_next_daily_queue_item(uuid, uuid, uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_next_daily_queue_item(uuid, uuid, uuid, uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION water_management_private.cancel_daily_queue_auto_advance_internal(
  p_queue_id uuid,
  p_auto_advance_token uuid,
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $cancel_daily_queue_auto_advance$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_queue public.daily_queues%ROWTYPE;
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
$cancel_daily_queue_auto_advance$;
REVOKE ALL ON FUNCTION water_management_private.cancel_daily_queue_auto_advance_internal(uuid, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.cancel_daily_queue_auto_advance_internal(uuid, uuid, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.cancel_daily_queue_auto_advance(
  p_queue_id uuid,
  p_auto_advance_token uuid,
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $cancel_auto_advance_rpc$
  SELECT water_management_private.cancel_daily_queue_auto_advance_internal(
    p_queue_id, p_auto_advance_token, p_reason
  )
$cancel_auto_advance_rpc$;
REVOKE ALL ON FUNCTION public.cancel_daily_queue_auto_advance(uuid, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_daily_queue_auto_advance(uuid, uuid, text)
  TO authenticated;

-- Add an additional registered, guest, or emergency item at the tail.
-- Appending never retargets or cancels an already-persisted auto-advance.
CREATE OR REPLACE FUNCTION water_management_private.add_daily_queue_item_internal(
  p_queue_id uuid,
  p_source_type text,
  p_subscriber_id uuid,
  p_subscriber_name text,
  p_planned_minutes integer
)
RETURNS public.queue_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $add_daily_queue_item_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_queue public.daily_queues%ROWTYPE;
  v_pump_id uuid;
  v_name text;
  v_branch_id uuid;
  v_branch_name text;
  v_subscriber_operator_id uuid;
  v_sort_order integer;
  v_item public.queue_items%ROWTYPE;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to append daily queue items' USING ERRCODE = '42501';
  END IF;

  IF p_source_type NOT IN ('additional_registered', 'additional_guest', 'emergency') THEN
    RAISE EXCEPTION 'Only additional or emergency queue items may be appended'
      USING ERRCODE = '22023';
  END IF;
  IF p_planned_minutes IS NULL OR p_planned_minutes NOT BETWEEN 1 AND 1440 THEN
    RAISE EXCEPTION 'Planned minutes must be between 1 and 1440'
      USING ERRCODE = '22023';
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

  IF v_queue.queue_date <> (v_now AT TIME ZONE 'Asia/Hebron')::date THEN
    RAISE EXCEPTION 'Only the current local-day queue may receive new items'
      USING ERRCODE = '22023';
  END IF;
  IF v_queue.status = 'closed' THEN
    RAISE EXCEPTION 'Closed daily queues cannot receive new items' USING ERRCODE = 'P0002';
  END IF;

  IF p_source_type = 'additional_registered' THEN
    IF p_subscriber_id IS NULL THEN
      RAISE EXCEPTION 'A registered subscriber is required' USING ERRCODE = '22023';
    END IF;

    SELECT s.full_name, s.branch_id, b.name, s.operator_id
    INTO v_name, v_branch_id, v_branch_name, v_subscriber_operator_id
    FROM public.subscribers s
    LEFT JOIN public.branches b
      ON b.id = s.branch_id
     AND b.organization_id = s.organization_id
     AND b.pump_id = s.pump_id
    WHERE s.id = p_subscriber_id
      AND s.organization_id = v_organization_id
      AND s.pump_id = v_queue.pump_id
      AND s.is_active;

    IF v_name IS NULL THEN
      RAISE EXCEPTION 'Subscriber must be active on the same pump'
        USING ERRCODE = '22023';
    END IF;
    IF v_role = 'operator'::public.app_role
       AND v_subscriber_operator_id IS DISTINCT FROM v_user_id THEN
      RAISE EXCEPTION 'This subscriber is assigned to another operator'
        USING ERRCODE = '42501';
    END IF;
  ELSE
    IF p_subscriber_id IS NOT NULL THEN
      RAISE EXCEPTION 'Guest and emergency items cannot reference a registered subscriber'
        USING ERRCODE = '22023';
    END IF;
    v_name := btrim(COALESCE(p_subscriber_name, ''));
    IF char_length(v_name) NOT BETWEEN 2 AND 120 THEN
      RAISE EXCEPTION 'Guest or emergency beneficiary name is required'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT COALESCE(max(qi.sort_order), -1) + 1
  INTO v_sort_order
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id;

  INSERT INTO public.queue_items (
    daily_queue_id, organization_id, pump_id, source_type,
    subscriber_id, subscriber_name_snapshot, branch_id, branch_name_snapshot,
    planned_minutes, sort_order
  ) VALUES (
    p_queue_id, v_organization_id, v_queue.pump_id, p_source_type,
    p_subscriber_id, v_name, v_branch_id, v_branch_name,
    p_planned_minutes, v_sort_order
  )
  RETURNING * INTO v_item;

  UPDATE public.daily_queues
  SET queue_version = queue_version + 1,
      updated_at = v_now
  WHERE id = p_queue_id;

  PERFORM water_management_private.append_queue_item_event(
    p_queue_id, v_item.id, v_organization_id, v_queue.pump_id,
    'item_created', v_user_id, NULL,
    jsonb_build_object(
      'source_type', p_source_type,
      'subscriber_id', p_subscriber_id,
      'subscriber_name_snapshot', v_name,
      'planned_minutes', p_planned_minutes,
      'sort_order', v_sort_order,
      'appended_to_end', true,
      'auto_advance_preserved', v_queue.auto_advance_token IS NOT NULL
    )
  );

  RETURN v_item;
END;
$add_daily_queue_item_internal$;

REVOKE ALL ON FUNCTION water_management_private.add_daily_queue_item_internal(uuid, text, uuid, text, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.add_daily_queue_item_internal(uuid, text, uuid, text, integer)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.add_daily_queue_item(
  p_queue_id uuid,
  p_source_type text,
  p_subscriber_id uuid,
  p_subscriber_name text,
  p_planned_minutes integer
)
RETURNS public.queue_items
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $add_daily_queue_item_rpc$
  SELECT water_management_private.add_daily_queue_item_internal(
    p_queue_id, p_source_type, p_subscriber_id, p_subscriber_name, p_planned_minutes
  )
$add_daily_queue_item_rpc$;

REVOKE ALL ON FUNCTION public.add_daily_queue_item(uuid, text, uuid, text, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_daily_queue_item(uuid, text, uuid, text, integer)
  TO authenticated;

-- Completion closes the linked queue item and schedules, but does not execute,
-- the next item. A client (or a future scheduler worker) must consume the token.
CREATE OR REPLACE FUNCTION water_management_private.complete_pump_operation_internal(
  p_operation_id uuid
)
RETURNS public.pump_operations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $complete_pump_operation_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_now timestamptz := clock_timestamp();
  v_operation public.pump_operations%ROWTYPE;
  v_queue public.daily_queues%ROWTYPE;
  v_queue_id uuid;
  v_completed_queue_item_id uuid;
  v_next_queue_item_id uuid;
  v_next_token uuid;
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to control pump operations' USING ERRCODE = '42501';
  END IF;

  SELECT qi.daily_queue_id, qi.id
  INTO v_queue_id, v_completed_queue_item_id
  FROM public.queue_items qi
  WHERE qi.operation_id = p_operation_id
    AND qi.organization_id = v_organization_id;

  IF v_queue_id IS NOT NULL THEN
    SELECT q.* INTO v_queue
    FROM public.daily_queues q
    WHERE q.id = v_queue_id
      AND q.organization_id = v_organization_id
    FOR UPDATE;
  END IF;

  UPDATE public.pump_operations op
  SET status = 'completed',
      ended_at = v_now,
      actual_seconds = GREATEST(
        0,
        floor(extract(epoch FROM (v_now - op.started_at)))::integer
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
  WHERE op.id = p_operation_id AND op.organization_id = v_organization_id
    AND op.status IN ('running', 'paused')
    AND (v_role = 'manager' OR (
      op.operator_id = v_user_id AND EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.organization_id = v_organization_id AND pa.pump_id = op.pump_id
          AND pa.user_id = v_user_id AND pa.assignment_role = 'operator'::public.app_role
      )
    ))
  RETURNING op.* INTO v_operation;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Operation is already completed or is not accessible' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.pump_operation_power_segments
  SET ended_at = v_now
  WHERE operation_id = v_operation.id
    AND ended_at IS NULL;

  IF v_queue_id IS NOT NULL AND v_completed_queue_item_id IS NOT NULL THEN
    UPDATE public.queue_items
    SET status = 'completed',
        completed_at = v_now
    WHERE id = v_completed_queue_item_id
      AND daily_queue_id = v_queue_id
      AND status = 'running';

    PERFORM water_management_private.append_queue_item_event(
      v_queue_id, v_completed_queue_item_id, v_operation.organization_id, v_operation.pump_id,
      'completed', v_user_id, NULL,
      jsonb_build_object(
        'operation_id', v_operation.id,
        'actual_seconds', v_operation.actual_seconds,
        'completed_at', v_now
      )
    );

    SELECT qi.id INTO v_next_queue_item_id
    FROM public.queue_items qi
    WHERE qi.daily_queue_id = v_queue_id
      AND qi.status = 'queued'
    ORDER BY qi.sort_order, qi.id
    LIMIT 1
    FOR UPDATE;

    IF v_next_queue_item_id IS NOT NULL THEN
      v_next_token := gen_random_uuid();
      UPDATE public.daily_queues
      SET auto_advance_queue_item_id = v_next_queue_item_id,
          auto_advance_at = v_now + interval '3 seconds',
          auto_advance_token = v_next_token,
          auto_advance_cancelled_at = NULL,
          queue_version = queue_version + 1,
          updated_at = v_now
      WHERE id = v_queue_id;

      PERFORM water_management_private.append_queue_item_event(
        v_queue_id, v_next_queue_item_id, v_operation.organization_id, v_operation.pump_id,
        'auto_advance_scheduled', v_user_id, NULL,
        jsonb_build_object(
          'auto_advance_at', v_now + interval '3 seconds',
          'auto_advance_token', v_next_token,
          'completed_operation_id', v_operation.id
        )
      );
    ELSE
      UPDATE public.daily_queues
      SET status = 'closed',
          closed_at = v_now,
          auto_advance_queue_item_id = NULL,
          auto_advance_at = NULL,
          auto_advance_token = NULL,
          queue_version = queue_version + 1,
          updated_at = v_now
      WHERE id = v_queue_id;

      PERFORM water_management_private.append_queue_item_event(
        v_queue_id, NULL, v_operation.organization_id, v_operation.pump_id,
        'queue_closed', v_user_id, NULL,
        jsonb_build_object('closed_at', v_now, 'completed_operation_id', v_operation.id)
      );
    END IF;
  END IF;

  RETURN v_operation;
END;
$complete_pump_operation_internal$;

REVOKE ALL ON FUNCTION water_management_private.complete_pump_operation_internal(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION water_management_private.complete_pump_operation_internal(uuid)
  TO authenticated;

COMMENT ON TABLE public.daily_queues IS
  'Immutable daily snapshots of a pump weekly schedule; idempotently generated and separately versioned from the recurring template.';
COMMENT ON TABLE public.queue_items IS
  'Daily ordered queue entries. Only guarded RPCs can change order, state, or linked operation.';
