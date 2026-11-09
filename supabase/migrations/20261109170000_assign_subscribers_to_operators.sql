-- Assign each registered subscriber to exactly one operator within the same
-- organization and pump. A pump may have multiple operators.
--
-- This migration establishes the assignment record and immutable audit history.
-- Queue visibility/report isolation is intentionally handled by follow-up
-- migrations; do not treat this migration alone as the completed access boundary.

DROP INDEX IF EXISTS public.pump_assignments_one_operator_per_pump_idx;

ALTER TABLE public.pump_assignments
  ADD CONSTRAINT pump_assignments_user_tenant_pump_role_key
  UNIQUE (user_id, organization_id, pump_id, assignment_role);

ALTER TABLE public.subscribers
  ADD COLUMN operator_id uuid,
  ADD COLUMN operator_assignment_role public.app_role
    GENERATED ALWAYS AS ('operator'::public.app_role) STORED,
  ADD CONSTRAINT subscribers_operator_requires_pump_check
    CHECK (operator_id IS NULL OR pump_id IS NOT NULL),
  ADD CONSTRAINT subscribers_operator_assignment_fkey
    FOREIGN KEY (operator_id, organization_id, pump_id, operator_assignment_role)
    REFERENCES public.pump_assignments (user_id, organization_id, pump_id, assignment_role)
    ON DELETE RESTRICT;

CREATE INDEX subscribers_operator_scope_idx
  ON public.subscribers (organization_id, pump_id, operator_id)
  WHERE operator_id IS NOT NULL;

-- Before this migration there could only be one operator per pump, so existing
-- subscribers can be backfilled without guessing between multiple operators.
UPDATE public.subscribers s
SET operator_id = pa.user_id
FROM public.pump_assignments pa
WHERE pa.organization_id = s.organization_id
  AND pa.pump_id = s.pump_id
  AND pa.assignment_role = 'operator'::public.app_role;

COMMENT ON COLUMN public.subscribers.operator_id IS
  'The single operator responsible for this subscriber. Distinct from pump_operations.operator_id, which records the session executor.';
COMMENT ON COLUMN public.subscribers.operator_assignment_role IS
  'Generated role discriminator used by the composite FK to prove that operator_id is assigned to this same pump and organization.';

-- Queue ownership is a snapshot. Reassignment may move waiting items to the
-- new operator, but running/completed items preserve their historical owner.
ALTER TABLE public.queue_items
  ADD COLUMN assigned_operator_id uuid;

UPDATE public.queue_items qi
SET assigned_operator_id = s.operator_id
FROM public.subscribers s
WHERE s.id = qi.subscriber_id
  AND qi.status = 'queued';

CREATE INDEX queue_items_operator_order_idx
  ON public.queue_items (daily_queue_id, assigned_operator_id, status, sort_order)
  WHERE assigned_operator_id IS NOT NULL;

CREATE FUNCTION water_management_private.assign_queue_item_operator()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $assign_queue_item_operator$
BEGIN
  IF NEW.subscriber_id IS NULL THEN
    NEW.assigned_operator_id := NULL;
    RETURN NEW;
  END IF;

  SELECT s.operator_id
  INTO NEW.assigned_operator_id
  FROM public.subscribers s
  WHERE s.id = NEW.subscriber_id
    AND s.organization_id = NEW.organization_id
    AND s.pump_id = NEW.pump_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscriber does not belong to this organization and pump'
      USING ERRCODE = '23503';
  END IF;

  RETURN NEW;
END;
$assign_queue_item_operator$;

REVOKE ALL ON FUNCTION water_management_private.assign_queue_item_operator()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER a_assign_queue_item_operator
  BEFORE INSERT ON public.queue_items
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.assign_queue_item_operator();

-- Append-only history of responsibility changes.
CREATE TABLE public.subscriber_operator_assignment_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subscriber_id uuid NOT NULL REFERENCES public.subscribers(id) ON DELETE RESTRICT,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  pump_id uuid NOT NULL REFERENCES public.pumps(id) ON DELETE RESTRICT,
  previous_operator_id uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  previous_operator_name text,
  new_operator_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  new_operator_name text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 2 AND 240),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT subscriber_operator_assignment_events_scope_fkey
    FOREIGN KEY (subscriber_id, organization_id, pump_id)
    REFERENCES public.subscribers (id, organization_id, pump_id) ON DELETE RESTRICT
);

CREATE INDEX subscriber_operator_assignment_events_subscriber_time_idx
  ON public.subscriber_operator_assignment_events (subscriber_id, occurred_at DESC, id DESC);
CREATE INDEX subscriber_operator_assignment_events_org_time_idx
  ON public.subscriber_operator_assignment_events (organization_id, occurred_at DESC);

ALTER TABLE public.subscriber_operator_assignment_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.subscriber_operator_assignment_events FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.subscriber_operator_assignment_events TO authenticated;

CREATE POLICY subscriber_operator_assignment_events_manager_select
  ON public.subscriber_operator_assignment_events
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

CREATE FUNCTION water_management_private.reject_subscriber_operator_history_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $reject_subscriber_operator_history_mutation$
BEGIN
  RAISE EXCEPTION 'Subscriber operator assignment history is append-only'
    USING ERRCODE = '42501';
END;
$reject_subscriber_operator_history_mutation$;
REVOKE ALL ON FUNCTION water_management_private.reject_subscriber_operator_history_mutation()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER subscriber_operator_assignment_events_append_only
  BEFORE UPDATE OR DELETE ON public.subscriber_operator_assignment_events
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.reject_subscriber_operator_history_mutation();

-- Do not permit a direct table update to bypass the manager-only assignment RPC.
CREATE FUNCTION water_management_private.guard_subscriber_operator_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $guard_subscriber_operator_change$
BEGIN
  IF NEW.operator_id IS DISTINCT FROM OLD.operator_id
     AND COALESCE(current_setting('water_management.allow_subscriber_operator_change', true), '') <> 'on' THEN
    RAISE EXCEPTION 'Use assign_subscriber_operator to change subscriber responsibility'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$guard_subscriber_operator_change$;
REVOKE ALL ON FUNCTION water_management_private.guard_subscriber_operator_change()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER subscribers_operator_change_guard
  BEFORE UPDATE OF operator_id ON public.subscribers
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.guard_subscriber_operator_change();

-- The history event is written in the same transaction as the subscriber change.
CREATE FUNCTION water_management_private.record_subscriber_operator_assignment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $record_subscriber_operator_assignment$
DECLARE
  v_previous_name text;
  v_new_name text;
  v_reason text;
  v_actor_id uuid := auth.uid();
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.operator_id IS NOT DISTINCT FROM OLD.operator_id THEN
    RETURN NEW;
  END IF;
  IF NEW.operator_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF OLD.operator_id IS NOT NULL THEN
    SELECT p.display_name INTO v_previous_name
    FROM public.profiles p WHERE p.id = OLD.operator_id;
  END IF;

  SELECT p.display_name INTO v_new_name
  FROM public.profiles p WHERE p.id = NEW.operator_id;

  v_reason := NULLIF(btrim(COALESCE(
    current_setting('water_management.subscriber_operator_reason', true), ''
  )), '');
  IF v_reason IS NULL THEN
    v_reason := CASE WHEN TG_OP = 'INSERT'
      THEN 'إسناد عند إنشاء المشترك'
      ELSE 'تحديث إسناد المشترك'
    END;
  END IF;

  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'An authenticated actor is required to record subscriber assignment'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.subscriber_operator_assignment_events (
    subscriber_id, organization_id, pump_id,
    previous_operator_id, previous_operator_name,
    new_operator_id, new_operator_name, actor_id, reason
  ) VALUES (
    NEW.id, NEW.organization_id, NEW.pump_id,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.operator_id ELSE NULL END,
    v_previous_name,
    NEW.operator_id, COALESCE(v_new_name, 'مشغّل غير معروف'),
    v_actor_id, v_reason
  );

  RETURN NEW;
END;
$record_subscriber_operator_assignment$;
ALTER FUNCTION water_management_private.record_subscriber_operator_assignment() OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.record_subscriber_operator_assignment()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER subscribers_operator_assignment_history
  AFTER INSERT OR UPDATE OF operator_id ON public.subscribers
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.record_subscriber_operator_assignment();

-- Managers can change responsibility only when no operation for this subscriber
-- is running or paused. Waiting queue items move atomically; running and completed
-- queue items and their operation executor remain unchanged.
CREATE OR REPLACE FUNCTION water_management_private.assign_subscriber_operator_internal(
  p_subscriber_id uuid,
  p_operator_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $assign_subscriber_operator_internal$
DECLARE
  v_actor_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_subscriber public.subscribers%ROWTYPE;
  v_operator_name text;
  v_previous_operator_id uuid;
  v_updated_items integer := 0;
  v_queue_id uuid;
  v_item record;
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  IF v_actor_id IS NULL OR v_organization_id IS NULL
     OR v_role <> 'manager'::public.app_role THEN
    RAISE EXCEPTION 'Only the organization manager can assign subscriber operators'
      USING ERRCODE = '42501';
  END IF;

  IF p_subscriber_id IS NULL OR p_operator_id IS NULL
     OR char_length(COALESCE(v_reason, '')) NOT BETWEEN 2 AND 240 THEN
    RAISE EXCEPTION 'Subscriber, operator, and a reason of 2 to 240 characters are required'
      USING ERRCODE = '22023';
  END IF;

  SELECT s.* INTO v_subscriber
  FROM public.subscribers s
  WHERE s.id = p_subscriber_id
    AND s.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND OR v_subscriber.pump_id IS NULL THEN
    RAISE EXCEPTION 'Subscriber is not linked to a pump in the current organization'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT p.display_name INTO v_operator_name
  FROM public.profiles p
  JOIN public.pump_assignments pa
    ON pa.user_id = p.id
   AND pa.organization_id = p.organization_id
   AND pa.assignment_role = p.role
  WHERE p.id = p_operator_id
    AND p.organization_id = v_organization_id
    AND p.role = 'operator'::public.app_role
    AND pa.pump_id = v_subscriber.pump_id
    AND pa.assignment_role = 'operator'::public.app_role;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Selected operator is not assigned to this subscriber pump'
      USING ERRCODE = '23503';
  END IF;

  v_previous_operator_id := v_subscriber.operator_id;
  IF v_previous_operator_id = p_operator_id THEN
    RETURN jsonb_build_object(
      'subscriber_id', p_subscriber_id,
      'operator_id', p_operator_id,
      'changed', false,
      'updated_queue_items', 0
    );
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.pump_operations op
    WHERE op.organization_id = v_organization_id
      AND op.pump_id = v_subscriber.pump_id
      AND op.subscriber_id = p_subscriber_id
      AND op.status IN ('running', 'paused')
  ) THEN
    RAISE EXCEPTION 'Cannot reassign a subscriber while a pump operation is running or paused'
      USING ERRCODE = '55000';
  END IF;

  PERFORM set_config('water_management.allow_subscriber_operator_change', 'on', true);
  PERFORM set_config('water_management.subscriber_operator_reason', v_reason, true);

  UPDATE public.subscribers
  SET operator_id = p_operator_id
  WHERE id = p_subscriber_id;

  FOR v_queue_id IN
    SELECT DISTINCT qi.daily_queue_id
    FROM public.queue_items qi
    WHERE qi.subscriber_id = p_subscriber_id
      AND qi.status = 'queued'
      AND qi.assigned_operator_id IS DISTINCT FROM p_operator_id
    ORDER BY qi.daily_queue_id
  LOOP
    UPDATE public.queue_items
    SET assigned_operator_id = p_operator_id
    WHERE daily_queue_id = v_queue_id
      AND subscriber_id = p_subscriber_id
      AND status = 'queued'
      AND assigned_operator_id IS DISTINCT FROM p_operator_id;

    GET DIAGNOSTICS v_updated_items = ROW_COUNT;
    UPDATE public.daily_queues
    SET queue_version = queue_version + 1,
        updated_at = clock_timestamp()
    WHERE id = v_queue_id;

    FOR v_item IN
      SELECT qi.id, qi.pump_id, qi.organization_id, qi.assigned_operator_id
      FROM public.queue_items qi
      WHERE qi.daily_queue_id = v_queue_id
        AND qi.subscriber_id = p_subscriber_id
        AND qi.status = 'queued'
        AND qi.assigned_operator_id = p_operator_id
    LOOP
      PERFORM water_management_private.append_queue_item_event(
        v_queue_id, v_item.id, v_item.organization_id, v_item.pump_id,
        'item_operator_reassigned', v_actor_id, v_reason,
        jsonb_build_object(
          'previous_operator_id', v_previous_operator_id,
          'new_operator_id', p_operator_id
        )
      );
    END LOOP;
  END LOOP;

  SELECT count(*)::integer INTO v_updated_items
  FROM public.queue_items qi
  WHERE qi.subscriber_id = p_subscriber_id
    AND qi.status = 'queued'
    AND qi.assigned_operator_id = p_operator_id;

  RETURN jsonb_build_object(
    'subscriber_id', p_subscriber_id,
    'previous_operator_id', v_previous_operator_id,
    'operator_id', p_operator_id,
    'changed', true,
    'updated_queue_items', v_updated_items
  );
END;
$assign_subscriber_operator_internal$;

REVOKE ALL ON FUNCTION water_management_private.assign_subscriber_operator_internal(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.assign_subscriber_operator_internal(uuid, uuid, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.assign_subscriber_operator(
  p_subscriber_id uuid,
  p_operator_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $assign_subscriber_operator_rpc$
  SELECT water_management_private.assign_subscriber_operator_internal(
    p_subscriber_id, p_operator_id, p_reason
  )
$assign_subscriber_operator_rpc$;

REVOKE ALL ON FUNCTION public.assign_subscriber_operator(uuid, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assign_subscriber_operator(uuid, uuid, text)
  TO authenticated;

-- A pump operation is executed by its operator_id, while responsibility is
-- stored separately on subscribers.operator_id. Enforce that these two identities
-- match when an operator starts a registered subscriber's fill.
CREATE FUNCTION water_management_private.enforce_subscriber_operation_operator()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $enforce_subscriber_operation_operator$
DECLARE
  v_role public.app_role := water_management_private.current_user_role();
  v_subscriber_operator_id uuid;
BEGIN
  IF NEW.subscriber_id IS NULL OR v_role <> 'operator'::public.app_role THEN
    RETURN NEW;
  END IF;

  SELECT s.operator_id INTO v_subscriber_operator_id
  FROM public.subscribers s
  WHERE s.id = NEW.subscriber_id
    AND s.organization_id = NEW.organization_id
    AND s.pump_id = NEW.pump_id;

  IF v_subscriber_operator_id IS NULL OR v_subscriber_operator_id IS DISTINCT FROM NEW.operator_id THEN
    RAISE EXCEPTION 'This subscriber is assigned to another operator'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$enforce_subscriber_operation_operator$;
ALTER FUNCTION water_management_private.enforce_subscriber_operation_operator() OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.enforce_subscriber_operation_operator()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER pump_operations_subscriber_operator_guard
  BEFORE INSERT ON public.pump_operations
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.enforce_subscriber_operation_operator();

-- Extend the existing append-only queue event vocabulary.
ALTER TABLE public.queue_item_events
  DROP CONSTRAINT IF EXISTS queue_item_events_event_type_check;
ALTER TABLE public.queue_item_events
  ADD CONSTRAINT queue_item_events_event_type_check
  CHECK (event_type IN (
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
    'weekly_minutes_transferred',
    'item_deferred',
    'item_cancelled',
    'item_operator_reassigned'
  ));
