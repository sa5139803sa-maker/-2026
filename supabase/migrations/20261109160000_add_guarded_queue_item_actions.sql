-- Guarded queue-item deferral and cancellation with an append-only audit trail.
-- Deferral means moving a waiting item to the end of the same day's queue.
-- Moving an entitlement to another date remains the responsibility of the
-- weekly-entitlement transfer RPC, never a silent mutation of this snapshot.

ALTER TABLE public.queue_item_events
  DROP CONSTRAINT queue_item_events_event_type_check;

ALTER TABLE public.queue_item_events
  ADD CONSTRAINT queue_item_events_event_type_check CHECK (event_type IN (
    'queue_generated',
    'item_created',
    'item_deferred',
    'item_cancelled',
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

CREATE OR REPLACE FUNCTION water_management_private.manage_daily_queue_item_internal(
  p_queue_id uuid,
  p_queue_item_id uuid,
  p_expected_version integer,
  p_action text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $manage_daily_queue_item_internal$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_queue public.daily_queues%ROWTYPE;
  v_item public.queue_items%ROWTYPE;
  v_now timestamptz := clock_timestamp();
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_max_order integer;
  v_base_order integer;
  v_queued_count integer;
  v_new_order integer;
  v_new_auto_item_id uuid;
  v_new_auto_token uuid;
  v_new_auto_at timestamptz;
  v_auto_cancelled_at timestamptz;
  v_old_order jsonb;
  v_new_order_json jsonb;
  v_running_count integer;
  v_closed boolean := false;
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL OR v_role IS NULL
     OR v_role NOT IN ('manager'::public.app_role, 'operator'::public.app_role) THEN
    RAISE EXCEPTION 'Not authorized to manage daily queue items'
      USING ERRCODE = '42501';
  END IF;

  IF p_action NOT IN ('defer', 'cancel') THEN
    RAISE EXCEPTION 'Unsupported queue item action'
      USING ERRCODE = '22023';
  END IF;
  IF p_queue_id IS NULL OR p_queue_item_id IS NULL
     OR p_expected_version IS NULL OR p_expected_version < 1 THEN
    RAISE EXCEPTION 'Queue, item, and expected version are required'
      USING ERRCODE = '22023';
  END IF;
  IF char_length(COALESCE(v_reason, '')) NOT BETWEEN 2 AND 240 THEN
    RAISE EXCEPTION 'A reason of 2 to 240 characters is required'
      USING ERRCODE = '22023';
  END IF;

  SELECT q.* INTO v_queue
  FROM public.daily_queues q
  WHERE q.id = p_queue_id
    AND q.organization_id = v_organization_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Daily queue not found or not accessible'
      USING ERRCODE = 'P0002';
  END IF;

  IF v_queue.queue_version <> p_expected_version THEN
    RAISE EXCEPTION 'Daily queue changed; reload before retrying'
      USING ERRCODE = '40001';
  END IF;
  IF v_queue.status = 'closed' THEN
    RAISE EXCEPTION 'Closed daily queues cannot be changed'
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

  SELECT qi.* INTO v_item
  FROM public.queue_items qi
  WHERE qi.id = p_queue_item_id
    AND qi.daily_queue_id = p_queue_id
    AND qi.organization_id = v_organization_id
    AND qi.pump_id = v_queue.pump_id
  FOR UPDATE;
  IF NOT FOUND OR v_item.status <> 'queued' THEN
    RAISE EXCEPTION 'Only waiting queue items can be deferred or cancelled'
      USING ERRCODE = 'P0002';
  END IF;

  SELECT count(*)::integer INTO v_queued_count
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id
    AND qi.status = 'queued';

  SELECT COALESCE(max(qi.sort_order), -1)
  INTO v_max_order
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id;

  SELECT COALESCE(max(qi.sort_order), -1) + 1
  INTO v_base_order
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id
    AND qi.status <> 'queued';

  SELECT jsonb_agg(
    jsonb_build_object('id', qi.id, 'sort_order', qi.sort_order, 'status', qi.status)
    ORDER BY qi.sort_order, qi.id
  ) INTO v_old_order
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id;

  v_new_auto_item_id := v_queue.auto_advance_queue_item_id;
  v_new_auto_token := v_queue.auto_advance_token;
  v_new_auto_at := v_queue.auto_advance_at;
  v_auto_cancelled_at := v_queue.auto_advance_cancelled_at;

  IF p_action = 'defer' THEN
    IF v_queued_count < 2 THEN
      RAISE EXCEPTION 'At least two waiting items are required to defer one to the end'
        USING ERRCODE = '22023';
    END IF;

    -- Move the selected item behind every other waiting item. A temporary
    -- high range avoids collisions with the unique (queue_id, sort_order) key.
    UPDATE public.queue_items
    SET sort_order = sort_order + v_max_order + 1000001
    WHERE daily_queue_id = p_queue_id
      AND status = 'queued';

    WITH ordered AS (
      SELECT qi.id,
             row_number() OVER (
               ORDER BY CASE WHEN qi.id = p_queue_item_id THEN 1 ELSE 0 END,
                        qi.sort_order, qi.id
             )::integer - 1 AS position
      FROM public.queue_items qi
      WHERE qi.daily_queue_id = p_queue_id
        AND qi.status = 'queued'
    )
    UPDATE public.queue_items qi
    SET sort_order = v_base_order + ordered.position
    FROM ordered
    WHERE qi.id = ordered.id;

    SELECT qi.sort_order INTO v_new_order
    FROM public.queue_items qi
    WHERE qi.id = p_queue_item_id;

    IF v_queue.auto_advance_queue_item_id = p_queue_item_id THEN
      SELECT qi.id INTO v_new_auto_item_id
      FROM public.queue_items qi
      WHERE qi.daily_queue_id = p_queue_id
        AND qi.status = 'queued'
      ORDER BY qi.sort_order, qi.id
      LIMIT 1;

      v_new_auto_token := gen_random_uuid();
      v_auto_cancelled_at := NULL;

      PERFORM water_management_private.append_queue_item_event(
        p_queue_id, v_new_auto_item_id, v_organization_id, v_queue.pump_id,
        'auto_advance_retargeted', v_user_id, v_reason,
        jsonb_build_object(
          'previous_queue_item_id', p_queue_item_id,
          'previous_token_invalidated', true,
          'retargeted_by', 'item_deferred'
        )
      );
    END IF;

    PERFORM water_management_private.append_queue_item_event(
      p_queue_id, p_queue_item_id, v_organization_id, v_queue.pump_id,
      'item_deferred', v_user_id, v_reason,
      jsonb_build_object(
        'previous_sort_order', v_item.sort_order,
        'new_sort_order', v_new_order,
        'deferred_to', 'end_of_same_day_queue',
        'weekly_entitlement_allocation_id', v_item.weekly_entitlement_allocation_id
      )
    );
  ELSE
    -- Keep the cancelled record in place as history, then compact only the
    -- remaining queued rows after the immutable/non-queued portion.
    UPDATE public.queue_items
    SET status = 'cancelled',
        sort_order = v_max_order + 1
    WHERE id = p_queue_item_id
      AND daily_queue_id = p_queue_id;

    UPDATE public.queue_items
    SET sort_order = sort_order + v_max_order + 1000001
    WHERE daily_queue_id = p_queue_id
      AND status = 'queued';

    WITH ordered AS (
      SELECT qi.id,
             row_number() OVER (ORDER BY qi.sort_order, qi.id)::integer - 1 AS position
      FROM public.queue_items qi
      WHERE qi.daily_queue_id = p_queue_id
        AND qi.status = 'queued'
    )
    UPDATE public.queue_items qi
    SET sort_order = v_base_order + ordered.position
    FROM ordered
    WHERE qi.id = ordered.id;

    IF v_queue.auto_advance_queue_item_id = p_queue_item_id THEN
      SELECT qi.id INTO v_new_auto_item_id
      FROM public.queue_items qi
      WHERE qi.daily_queue_id = p_queue_id
        AND qi.status = 'queued'
      ORDER BY qi.sort_order, qi.id
      LIMIT 1;

      IF v_new_auto_item_id IS NULL THEN
        v_new_auto_token := NULL;
        v_new_auto_at := NULL;
        v_auto_cancelled_at := v_now;
        PERFORM water_management_private.append_queue_item_event(
          p_queue_id, p_queue_item_id, v_organization_id, v_queue.pump_id,
          'auto_advance_cancelled', v_user_id, v_reason,
          jsonb_build_object('cancelled_by_item_action', true)
        );
      ELSE
        v_new_auto_token := gen_random_uuid();
        v_auto_cancelled_at := NULL;
        PERFORM water_management_private.append_queue_item_event(
          p_queue_id, v_new_auto_item_id, v_organization_id, v_queue.pump_id,
          'auto_advance_retargeted', v_user_id, v_reason,
          jsonb_build_object(
            'previous_queue_item_id', p_queue_item_id,
            'previous_token_invalidated', true,
            'retargeted_by', 'item_cancelled'
          )
        );
      END IF;
    END IF;

    PERFORM water_management_private.append_queue_item_event(
      p_queue_id, p_queue_item_id, v_organization_id, v_queue.pump_id,
      'item_cancelled', v_user_id, v_reason,
      jsonb_build_object(
        'previous_sort_order', v_item.sort_order,
        'weekly_entitlement_allocation_id', v_item.weekly_entitlement_allocation_id,
        'weekly_minutes_consumed', 0
      )
    );

    SELECT count(*)::integer INTO v_queued_count
    FROM public.queue_items qi
    WHERE qi.daily_queue_id = p_queue_id
      AND qi.status = 'queued';

    SELECT count(*)::integer INTO v_running_count
    FROM public.queue_items qi
    WHERE qi.daily_queue_id = p_queue_id
      AND qi.status = 'running';

    IF v_queued_count = 0 AND v_running_count = 0 THEN
      v_closed := true;
      PERFORM water_management_private.append_queue_item_event(
        p_queue_id, NULL, v_organization_id, v_queue.pump_id,
        'queue_closed', v_user_id, v_reason,
        jsonb_build_object('closed_at', v_now, 'closed_by_item_cancellation', true)
      );
    END IF;
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object('id', qi.id, 'sort_order', qi.sort_order, 'status', qi.status)
    ORDER BY qi.sort_order, qi.id
  ) INTO v_new_order_json
  FROM public.queue_items qi
  WHERE qi.daily_queue_id = p_queue_id;

  UPDATE public.daily_queues
  SET auto_advance_queue_item_id = v_new_auto_item_id,
      auto_advance_at = v_new_auto_at,
      auto_advance_token = v_new_auto_token,
      auto_advance_cancelled_at = v_auto_cancelled_at,
      status = CASE WHEN v_closed THEN 'closed' ELSE status END,
      closed_at = CASE WHEN v_closed THEN v_now ELSE closed_at END,
      queue_version = queue_version + 1,
      updated_at = v_now
  WHERE id = p_queue_id;

  RETURN jsonb_build_object(
    'queue_id', p_queue_id,
    'queue_item_id', p_queue_item_id,
    'action', p_action,
    'queue_version', v_queue.queue_version + 1,
    'new_sort_order', v_new_order,
    'closed', v_closed,
    'auto_advance_queue_item_id', v_new_auto_item_id,
    'auto_advance_retargeted', v_new_auto_token IS DISTINCT FROM v_queue.auto_advance_token,
    'previous_order', COALESCE(v_old_order, '[]'::jsonb),
    'new_order', COALESCE(v_new_order_json, '[]'::jsonb)
  );
END;
$manage_daily_queue_item_internal$;

REVOKE ALL ON FUNCTION water_management_private.manage_daily_queue_item_internal(uuid, uuid, integer, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.manage_daily_queue_item_internal(uuid, uuid, integer, text, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.defer_daily_queue_item(
  p_queue_id uuid,
  p_queue_item_id uuid,
  p_expected_version integer,
  p_reason text
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $defer_daily_queue_item$
  SELECT water_management_private.manage_daily_queue_item_internal(
    p_queue_id, p_queue_item_id, p_expected_version, 'defer', p_reason
  )
$defer_daily_queue_item$;

REVOKE ALL ON FUNCTION public.defer_daily_queue_item(uuid, uuid, integer, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.defer_daily_queue_item(uuid, uuid, integer, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.cancel_daily_queue_item(
  p_queue_id uuid,
  p_queue_item_id uuid,
  p_expected_version integer,
  p_reason text
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $cancel_daily_queue_item$
  SELECT water_management_private.manage_daily_queue_item_internal(
    p_queue_id, p_queue_item_id, p_expected_version, 'cancel', p_reason
  )
$cancel_daily_queue_item$;

REVOKE ALL ON FUNCTION public.cancel_daily_queue_item(uuid, uuid, integer, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_daily_queue_item(uuid, uuid, integer, text)
  TO authenticated;

COMMENT ON FUNCTION public.defer_daily_queue_item(uuid, uuid, integer, text) IS
  'Moves a waiting item to the end of the same-day queue, requiring an actor-attributed reason and optimistic queue version.';
COMMENT ON FUNCTION public.cancel_daily_queue_item(uuid, uuid, integer, text) IS
  'Cancels a waiting item without deleting its history or consuming its weekly entitlement allocation.';
