-- Persistent daily queue integration coverage. This file is included by
-- tenant_isolation.sql inside the same rollback-only PostgreSQL transaction.

DO $activate_queue_test_schedule$
DECLARE
  v_weekday smallint := extract(isodow FROM (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date)::smallint;
BEGIN
  UPDATE public.schedule_entries
  SET weekday = v_weekday
  WHERE id = '60000000-0000-4000-8000-000000000001';

  UPDATE public.weekly_schedules
  SET status = 'active'
  WHERE id = '50000000-0000-4000-8000-000000000001';
END;
$activate_queue_test_schedule$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $queue_generation_operator$
DECLARE
  v_queue_id uuid;
  v_duplicate_queue_id uuid;
  v_item_count bigint;
BEGIN
  v_queue_id := public.generate_daily_queue(
    '20000000-0000-4000-8000-000000000001',
    (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date
  );
  v_duplicate_queue_id := public.generate_daily_queue(
    '20000000-0000-4000-8000-000000000001',
    (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date
  );

  IF v_queue_id IS DISTINCT FROM v_duplicate_queue_id THEN
    RAISE EXCEPTION 'Daily queue generation must be idempotent for the same pump and date';
  END IF;

  SELECT count(*) INTO v_item_count
  FROM public.queue_items
  WHERE daily_queue_id = v_queue_id
    AND source_type = 'weekly'
    AND status = 'queued';

  IF v_item_count <> 1 THEN
    RAISE EXCEPTION 'Daily queue did not snapshot the scheduled item exactly once: %', v_item_count;
  END IF;

  PERFORM set_config('test.daily_queue_id', v_queue_id::text, true);
END;
$queue_generation_operator$;
RESET ROLE;

DO $queue_item_fixtures$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
  v_subscriber public.subscribers%ROWTYPE;
BEGIN
  SELECT * INTO v_subscriber
  FROM public.subscribers
  WHERE id = '30000000-0000-4000-8000-000000000001';

  INSERT INTO public.queue_items (
    id, daily_queue_id, organization_id, pump_id, source_type,
    subscriber_id, subscriber_name_snapshot, branch_id, branch_name_snapshot,
    planned_minutes, sort_order
  ) VALUES (
    '70000000-0000-4000-8000-000000000001',
    v_queue_id, v_subscriber.organization_id, v_subscriber.pump_id,
    'additional_registered', v_subscriber.id, v_subscriber.full_name,
    v_subscriber.branch_id, 'تفرع أ 1', 12, 1
  );

  INSERT INTO public.queue_items (
    id, daily_queue_id, organization_id, pump_id, source_type,
    subscriber_name_snapshot, planned_minutes, sort_order
  ) VALUES (
    '70000000-0000-4000-8000-000000000002',
    v_queue_id, v_subscriber.organization_id, v_subscriber.pump_id,
    'emergency', 'مستفيد طارئ للاختبار', 7, 2
  );
END;
$queue_item_fixtures$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $queue_reorder_and_lifecycle$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
  v_weekly_item_id uuid;
  v_source_id uuid;
  v_additional_item_id uuid := '70000000-0000-4000-8000-000000000001';
  v_guest_item_id uuid := '70000000-0000-4000-8000-000000000002';
  v_version integer;
  v_result jsonb;
  v_operation public.pump_operations%ROWTYPE;
  v_next_item_id uuid;
  v_token uuid;
  v_previous_token uuid;
  v_rejected boolean := false;
  v_count bigint;
BEGIN
  SELECT id INTO v_weekly_item_id
  FROM public.queue_items
  WHERE daily_queue_id = v_queue_id
    AND source_type = 'weekly';

  SELECT id INTO v_source_id
  FROM public.pump_power_sources
  WHERE pump_id = '20000000-0000-4000-8000-000000000001'
    AND name = 'طاقة شمسية – مزود 1'
    AND is_active;

  SELECT queue_version INTO v_version
  FROM public.daily_queues
  WHERE id = v_queue_id;

  BEGIN
    PERFORM public.reorder_daily_queue(
      v_queue_id,
      v_version,
      ARRAY[v_weekly_item_id, v_additional_item_id, v_guest_item_id]::uuid[],
      NULL
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Consecutive items from the same branch must require an override reason';
  END IF;

  v_result := public.reorder_daily_queue(
    v_queue_id,
    v_version,
    ARRAY[v_weekly_item_id, v_additional_item_id, v_guest_item_id]::uuid[],
    'الحفاظ على ترتيب تعبئة خاص بطلب المشترك'
  );
  IF (v_result->>'branch_conflict_count')::integer <> 1
     OR (v_result->>'queue_version')::integer <> v_version + 1 THEN
    RAISE EXCEPTION 'Branch override or optimistic queue version was not recorded';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.reorder_daily_queue(
      v_queue_id,
      v_version,
      ARRAY[v_weekly_item_id, v_additional_item_id, v_guest_item_id]::uuid[],
      'إعادة إرسال إصدار قديم'
    );
  EXCEPTION WHEN serialization_failure THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Stale queue version was accepted';
  END IF;

  v_operation := public.start_daily_queue_item(v_queue_id, v_weekly_item_id, v_source_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.queue_items
    WHERE id = v_weekly_item_id
      AND status = 'running'
      AND operation_id = v_operation.id
  ) THEN
    RAISE EXCEPTION 'Starting a queue item did not link its pump operation atomically';
  END IF;

  PERFORM public.complete_pump_operation(v_operation.id);

  SELECT auto_advance_queue_item_id, auto_advance_token
  INTO v_next_item_id, v_token
  FROM public.daily_queues
  WHERE id = v_queue_id;

  IF v_next_item_id IS DISTINCT FROM v_additional_item_id OR v_token IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM public.daily_queues
       WHERE id = v_queue_id
         AND auto_advance_at > clock_timestamp()
         AND auto_advance_at <= clock_timestamp() + interval '3 seconds'
     ) THEN
    RAISE EXCEPTION 'Completion did not persist a three-second auto-advance deadline';
  END IF;

  v_previous_token := v_token;
  SELECT queue_version INTO v_version
  FROM public.daily_queues
  WHERE id = v_queue_id;

  v_result := public.reorder_daily_queue(
    v_queue_id,
    v_version,
    ARRAY[v_additional_item_id, v_guest_item_id]::uuid[],
    NULL
  );
  SELECT auto_advance_queue_item_id, auto_advance_token
  INTO v_next_item_id, v_token
  FROM public.daily_queues
  WHERE id = v_queue_id;

  IF v_result->>'branch_conflict_count' <> '0'
     OR v_next_item_id IS DISTINCT FROM v_additional_item_id
     OR v_token IS NULL
     OR v_token = v_previous_token
     OR NOT EXISTS (
       SELECT 1 FROM public.queue_items
       WHERE id = v_weekly_item_id AND sort_order = 0 AND status = 'completed'
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.queue_items
       WHERE id = v_additional_item_id AND sort_order = 1 AND status = 'queued'
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.queue_items
       WHERE id = v_guest_item_id AND sort_order = 2 AND status = 'queued'
     ) THEN
    RAISE EXCEPTION 'Reordering the waiting tail changed completed history or failed to retarget the auto-advance token';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.start_next_daily_queue_item(
      v_queue_id, v_additional_item_id, v_previous_token, v_source_id
    );
  EXCEPTION WHEN no_data_found THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'The superseded auto-advance token was accepted after reordering';
  END IF;

  PERFORM public.cancel_daily_queue_auto_advance(
    v_queue_id, v_token, 'توقف المشغّل قبل بدء الدور التالي'
  );
  IF EXISTS (
    SELECT 1 FROM public.daily_queues
    WHERE id = v_queue_id
      AND (auto_advance_token IS NOT NULL OR auto_advance_at IS NOT NULL
           OR auto_advance_queue_item_id IS NOT NULL
           OR auto_advance_cancelled_at IS NULL)
  ) THEN
    RAISE EXCEPTION 'Cancelling auto-advance did not persist the cancelled state';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.start_next_daily_queue_item(
      v_queue_id, v_additional_item_id, v_token, v_source_id
    );
  EXCEPTION WHEN no_data_found THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A cancelled auto-advance token was accepted';
  END IF;

  v_operation := public.start_daily_queue_item(v_queue_id, v_additional_item_id, v_source_id);
  PERFORM public.complete_pump_operation(v_operation.id);

  SELECT auto_advance_queue_item_id, auto_advance_token
  INTO v_next_item_id, v_token
  FROM public.daily_queues
  WHERE id = v_queue_id;
  IF v_next_item_id IS DISTINCT FROM v_guest_item_id OR v_token IS NULL THEN
    RAISE EXCEPTION 'Second completion did not schedule the next queued item';
  END IF;

  PERFORM pg_sleep(3.1);
  v_operation := public.start_next_daily_queue_item(
    v_queue_id, v_guest_item_id, v_token, v_source_id
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.queue_items
    WHERE id = v_guest_item_id
      AND status = 'running'
      AND operation_id = v_operation.id
  ) THEN
    RAISE EXCEPTION 'Due auto-advance did not start the expected queue item';
  END IF;

  PERFORM public.complete_pump_operation(v_operation.id);

  IF NOT EXISTS (
    SELECT 1 FROM public.daily_queues
    WHERE id = v_queue_id AND status = 'closed' AND closed_at IS NOT NULL
      AND auto_advance_token IS NULL
  ) THEN
    RAISE EXCEPTION 'Queue must close after the final item completes';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.queue_item_events
  WHERE daily_queue_id = v_queue_id
    AND event_type = 'auto_advance_scheduled';
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Queue event ledger did not record both persisted auto-advance schedules';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.queue_item_events
  WHERE daily_queue_id = v_queue_id
    AND event_type = 'auto_advance_cancelled';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Queue event ledger did not record the cancelled countdown exactly once';
  END IF;
END;
$queue_reorder_and_lifecycle$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);
DO $supervisor_queue_read$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
  v_queue_count bigint;
  v_item_count bigint;
BEGIN
  SELECT count(*) INTO v_queue_count
  FROM public.daily_queues WHERE id = v_queue_id;
  SELECT count(*) INTO v_item_count
  FROM public.queue_items WHERE daily_queue_id = v_queue_id;
  IF v_queue_count <> 1 OR v_item_count <> 3 THEN
    RAISE EXCEPTION 'Assigned supervisor must read the daily queue and its items';
  END IF;
END;
$supervisor_queue_read$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000004', true);
DO $collector_queue_denied$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM public.daily_queues WHERE id = v_queue_id)
     OR EXISTS (SELECT 1 FROM public.queue_items WHERE daily_queue_id = v_queue_id) THEN
    RAISE EXCEPTION 'Collector must not inherit queue access from collection assignment';
  END IF;
END;
$collector_queue_denied$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000007', true);
DO $other_tenant_queue_denied$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM public.daily_queues WHERE id = v_queue_id)
     OR EXISTS (SELECT 1 FROM public.queue_items WHERE daily_queue_id = v_queue_id) THEN
    RAISE EXCEPTION 'Queue items leaked across organizations';
  END IF;
END;
$other_tenant_queue_denied$;
RESET ROLE;

DO $daily_queue_acl$
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_queues'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.queue_items'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.queue_item_events'::regclass) THEN
    RAISE EXCEPTION 'RLS must be enabled on all daily queue tables';
  END IF;
  IF pg_catalog.has_table_privilege('anon', 'public.daily_queues', 'SELECT')
     OR pg_catalog.has_table_privilege('anon', 'public.queue_items', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.daily_queues', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.queue_items', 'UPDATE')
     OR pg_catalog.has_table_privilege('authenticated', 'public.queue_item_events', 'DELETE') THEN
    RAISE EXCEPTION 'Daily queue state and event writes must remain RPC-only';
  END IF;
  IF pg_catalog.has_function_privilege('anon', 'public.generate_daily_queue(uuid,date)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.reorder_daily_queue(uuid,integer,uuid[],text)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.start_daily_queue_item(uuid,uuid,uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.start_next_daily_queue_item(uuid,uuid,uuid,uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.cancel_daily_queue_auto_advance(uuid,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Queue RPCs must not be executable by anon';
  END IF;
END;
$daily_queue_acl$;
