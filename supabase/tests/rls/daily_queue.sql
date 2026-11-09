-- Persistent daily queue integration coverage. This file is included by
-- tenant_isolation.sql inside the same rollback-only PostgreSQL transaction.

DO $activate_queue_test_schedule$
DECLARE
  v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date;
  v_weekday smallint := extract(isodow FROM (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date)::smallint;
  v_source_weekday smallint := (extract(isodow FROM (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date)::integer % 7 + 1)::smallint;
BEGIN
  -- Split the same 45-minute weekly quota across today and another day so
  -- transfer/partial-consumption behavior is exercised without altering quota.
  UPDATE public.schedule_entries
  SET weekday = v_weekday,
      planned_minutes = 30
  WHERE id = '60000000-0000-4000-8000-000000000001';

  INSERT INTO public.schedule_entries (
    id, weekly_schedule_id, organization_id, pump_id, subscriber_id,
    weekday, sort_order, planned_minutes
  ) VALUES (
    '60000000-0000-4000-8000-000000000004',
    '50000000-0000-4000-8000-000000000001',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '20000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000001',
    v_source_weekday, 20, 15
  );

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

  IF (SELECT planned_minutes FROM public.queue_items
      WHERE daily_queue_id = v_queue_id AND source_type = 'weekly') <> 30
     OR (SELECT weekly_entitlement_allocation_id FROM public.queue_items
         WHERE daily_queue_id = v_queue_id AND source_type = 'weekly') IS NULL THEN
    RAISE EXCEPTION 'Generated weekly queue item was not attached to its 30-minute entitlement allocation';
  END IF;

  IF (SELECT sum(a.allocated_minutes) FROM public.weekly_entitlement_allocations a
      JOIN public.weekly_entitlement_cycles c ON c.id = a.weekly_entitlement_cycle_id
      WHERE c.weekly_schedule_id = '50000000-0000-4000-8000-000000000001'
        AND c.subscriber_id = '30000000-0000-4000-8000-000000000001'
        AND c.cycle_start = (SELECT weekly_cycle_start FROM public.daily_queues WHERE id = v_queue_id)) <> 45 THEN
    RAISE EXCEPTION 'Provisioned daily allocations do not equal the full weekly quota';
  END IF;

  PERFORM set_config('test.daily_queue_id', v_queue_id::text, true);
END;
$queue_generation_operator$;
RESET ROLE;

-- Managers must not materialize registered subscriber queue rows without a
-- responsible operator; otherwise no operator can safely see or execute them.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DO $queue_reject_unassigned_subscriber$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
  v_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM public.add_daily_queue_item(
      v_queue_id,
      'additional_registered',
      '30000000-0000-4000-8000-000000000002',
      NULL,
      5
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Manager added a registered subscriber to the daily queue without a responsible operator';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.queue_items
    WHERE daily_queue_id = v_queue_id
      AND subscriber_id = '30000000-0000-4000-8000-000000000002'
  ) THEN
    RAISE EXCEPTION 'Unassigned registered subscriber queue row persisted after rejection';
  END IF;
END;
$queue_reject_unassigned_subscriber$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $weekly_entitlement_transfer$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
  v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date;
  v_source_date date;
  v_source_allocation_id uuid;
  v_target_allocation_id uuid;
  v_cycle_id uuid;
  v_result jsonb;
  v_rejected boolean := false;
BEGIN
  SELECT weekly_cycle_start INTO v_source_date
  FROM public.daily_queues
  WHERE id = v_queue_id;
  v_source_date := v_source_date
    + ((extract(isodow FROM v_today)::integer % 7));

  SELECT a.id, a.weekly_entitlement_cycle_id
  INTO v_source_allocation_id, v_cycle_id
  FROM public.weekly_entitlement_allocations a
  WHERE a.allocation_date = v_source_date
    AND a.subscriber_id = '30000000-0000-4000-8000-000000000001'
    AND a.weekly_entitlement_cycle_id IN (
      SELECT c.id FROM public.weekly_entitlement_cycles c
      WHERE c.weekly_schedule_id = '50000000-0000-4000-8000-000000000001'
        AND c.cycle_start = (SELECT weekly_cycle_start FROM public.daily_queues WHERE id = v_queue_id)
    );

  IF v_source_allocation_id IS NULL THEN
    RAISE EXCEPTION 'Expected a 15-minute source-day entitlement allocation';
  END IF;

  v_result := public.transfer_weekly_entitlement_minutes(
    v_source_allocation_id, v_today, 5,
    'اختبار نقل خمس دقائق غير مستخدمة إلى طابور اليوم'
  );

  SELECT id INTO v_target_allocation_id
  FROM public.weekly_entitlement_allocations
  WHERE weekly_entitlement_cycle_id = v_cycle_id
    AND allocation_date = v_today;

  IF (SELECT allocated_minutes FROM public.weekly_entitlement_allocations
      WHERE id = v_source_allocation_id) <> 10
     OR (SELECT allocated_minutes FROM public.weekly_entitlement_allocations
         WHERE id = v_target_allocation_id) <> 35
     OR (SELECT planned_minutes FROM public.queue_items
         WHERE daily_queue_id = v_queue_id
           AND weekly_entitlement_allocation_id = v_target_allocation_id) <> 35
     OR (v_result->>'transferred_minutes')::integer <> 5 THEN
    RAISE EXCEPTION 'Weekly transfer did not atomically move five minutes into today';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.transfer_weekly_entitlement_minutes(
      v_source_allocation_id, v_today, 11,
      'يجب رفض نقل دقائق أكثر من المتبقي'
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Weekly transfer allowed spending the same source minutes twice';
  END IF;

  IF (SELECT count(*) FROM public.weekly_entitlement_events
      WHERE weekly_entitlement_cycle_id = v_cycle_id
        AND event_type = 'minutes_transferred'
        AND actor_id = auth.uid()) <> 1 THEN
    RAISE EXCEPTION 'Weekly transfer event ledger did not record one actor-attributed transfer';
  END IF;
END;
$weekly_entitlement_transfer$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $weekly_entitlement_future_day_transfer$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
  v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date;
  v_future_date date := v_today + 3;
  v_cycle_start date;
  v_cycle_id uuid;
  v_source_id uuid;
  v_target_id uuid;
  v_options record;
  v_result jsonb;
BEGIN
  SELECT weekly_cycle_start INTO v_cycle_start
  FROM public.daily_queues WHERE id = v_queue_id;
  IF v_future_date > v_cycle_start + 6 THEN
    RAISE EXCEPTION 'Test future target is outside the current weekly cycle';
  END IF;

  SELECT a.id, a.weekly_entitlement_cycle_id INTO v_source_id, v_cycle_id
  FROM public.weekly_entitlement_allocations a
  WHERE a.subscriber_id = '30000000-0000-4000-8000-000000000001'
    AND a.allocation_date = v_today + 1
    AND a.available_minutes >= 2
    AND a.weekly_entitlement_cycle_id IN (
      SELECT c.id FROM public.weekly_entitlement_cycles c
      WHERE c.weekly_schedule_id = '50000000-0000-4000-8000-000000000001'
        AND c.cycle_start = v_cycle_start
    );

  IF v_source_id IS NULL THEN
    RAISE EXCEPTION 'Future-day transfer test source allocation is unavailable';
  END IF;

  SELECT * INTO v_options
  FROM public.get_weekly_entitlement_transfer_options(
    '20000000-0000-4000-8000-000000000001',
    v_future_date
  )
  WHERE allocation_id = v_source_id;

  IF v_options.allocation_id IS NULL
     OR v_options.available_minutes < 2
     OR v_options.cycle_end < v_future_date THEN
    RAISE EXCEPTION 'Future target transfer options did not return the current-cycle source allocation';
  END IF;

  v_result := public.transfer_weekly_entitlement_minutes(
    v_source_id, v_future_date, 2,
    'اختبار نقل دقيقتين إلى يوم قادم داخل الدورة'
  );

  SELECT id INTO v_target_id
  FROM public.weekly_entitlement_allocations
  WHERE weekly_entitlement_cycle_id = v_cycle_id
    AND allocation_date = v_future_date;

  IF (SELECT allocated_minutes FROM public.weekly_entitlement_allocations WHERE id = v_source_id) <> 8
     OR (SELECT allocated_minutes FROM public.weekly_entitlement_allocations WHERE id = v_target_id) <> 2
     OR (v_result->>'transferred_minutes')::integer <> 2
     OR (SELECT sum(allocated_minutes) FROM public.weekly_entitlement_allocations
         WHERE weekly_entitlement_cycle_id = v_cycle_id) <> 45 THEN
    RAISE EXCEPTION 'Future-day transfer changed the weekly total or failed to move the requested minutes';
  END IF;
END;
$weekly_entitlement_future_day_transfer$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $queue_item_fixtures$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
  v_item public.queue_items%ROWTYPE;
BEGIN
  v_item := public.add_daily_queue_item(
    v_queue_id,
    'additional_registered',
    '30000000-0000-4000-8000-000000000001',
    NULL,
    12
  );
  PERFORM set_config('test.additional_queue_item_id', v_item.id::text, true);
  IF v_item.sort_order <> 1 OR v_item.branch_id <> '40000000-0000-4000-8000-000000000001' THEN
    RAISE EXCEPTION 'Registered additional queue item was not appended with the subscriber branch snapshot';
  END IF;

  v_item := public.add_daily_queue_item(
    v_queue_id,
    'emergency',
    NULL,
    'مستفيد طارئ للاختبار',
    7
  );
  PERFORM set_config('test.guest_queue_item_id', v_item.id::text, true);
  IF v_item.sort_order <> 2 OR v_item.subscriber_id IS NOT NULL THEN
    RAISE EXCEPTION 'Emergency beneficiary must append to the tail without creating a subscriber record';
  END IF;
END;
$queue_item_fixtures$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $queue_reorder_and_lifecycle$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
  v_weekly_item_id uuid;
  v_source_id uuid;
  v_additional_item_id uuid := current_setting('test.additional_queue_item_id')::uuid;
  v_guest_item_id uuid := current_setting('test.guest_queue_item_id')::uuid;
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

  -- Global queue reordering is a manager action; switch only the JWT identity
  -- for these manager operations, then restore the operator for the fill lifecycle.
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
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
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Consecutive items from the same branch must require an override reason';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  v_result := public.reorder_daily_queue(
    v_queue_id,
    v_version,
    ARRAY[v_weekly_item_id, v_additional_item_id, v_guest_item_id]::uuid[],
    'الحفاظ على ترتيب تعبئة خاص بطلب المشترك'
  );
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
  IF (v_result->>'branch_conflict_count')::integer <> 1
     OR (v_result->>'queue_version')::integer <> v_version + 1 THEN
    RAISE EXCEPTION 'Branch override or optimistic queue version was not recorded';
  END IF;

  v_rejected := false;
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
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
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
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

  -- Simulate two real minutes without waiting in CI. Only the test owner can
  -- alter the persisted start timestamp; the completion RPC remains operator-scoped.
  RESET ROLE;
  UPDATE public.pump_operations
  SET started_at = clock_timestamp() - interval '2 minutes'
  WHERE id = v_operation.id;
  SET LOCAL ROLE authenticated;

  PERFORM public.complete_pump_operation(v_operation.id);

  IF (SELECT consumed_minutes FROM public.weekly_entitlement_allocations
      WHERE id = (SELECT weekly_entitlement_allocation_id
                  FROM public.queue_items WHERE id = v_weekly_item_id)) <> 2
     OR (SELECT consumed_minutes FROM public.weekly_entitlement_cycles
         WHERE id = (SELECT weekly_entitlement_cycle_id
                     FROM public.weekly_entitlement_allocations
                     WHERE id = (SELECT weekly_entitlement_allocation_id
                                 FROM public.queue_items WHERE id = v_weekly_item_id))) <> 2
     OR (SELECT count(*) FROM public.weekly_entitlement_events
         WHERE event_type = 'minutes_consumed'
           AND metadata->>'queue_item_id' = v_weekly_item_id::text
           AND minutes = 2) <> 1 THEN
    RAISE EXCEPTION 'Completed weekly operation did not consume its two actual minutes exactly once';
  END IF;

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

  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  v_result := public.reorder_daily_queue(
    v_queue_id,
    v_version,
    ARRAY[v_additional_item_id, v_guest_item_id]::uuid[],
    NULL
  );
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
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

  -- Deferring the current auto-advance target moves it to the tail and
  -- atomically retargets the one-use token to the next waiting item.
  SELECT queue_version INTO v_version
  FROM public.daily_queues WHERE id = v_queue_id;
  v_previous_token := v_token;
  v_result := public.defer_daily_queue_item(
    v_queue_id, v_additional_item_id, v_version,
    'تأجيل الدور إلى نهاية طابور اليوم'
  );
  SELECT auto_advance_queue_item_id, auto_advance_token
  INTO v_next_item_id, v_token
  FROM public.daily_queues WHERE id = v_queue_id;

  IF v_next_item_id IS DISTINCT FROM v_guest_item_id
     OR v_token IS NULL OR v_token = v_previous_token
     OR (SELECT sort_order FROM public.queue_items WHERE id = v_guest_item_id) <> 1
     OR (SELECT sort_order FROM public.queue_items WHERE id = v_additional_item_id) <> 2
     OR NOT EXISTS (
       SELECT 1 FROM public.queue_item_events
       WHERE daily_queue_id = v_queue_id
         AND queue_item_id = v_additional_item_id
         AND event_type = 'item_deferred'
         AND actor_id = auth.uid()
         AND reason = 'تأجيل الدور إلى نهاية طابور اليوم'
     ) THEN
    RAISE EXCEPTION 'Deferring a waiting item did not move it to the tail and retarget auto-advance with an audit event';
  END IF;

  -- Cancellation preserves the item row and audit reason, and never starts
  -- or consumes an entitlement for the cancelled queue entry.
  SELECT queue_version INTO v_version
  FROM public.daily_queues WHERE id = v_queue_id;

  v_rejected := false;
  BEGIN
    PERFORM public.cancel_daily_queue_item(
      v_queue_id, v_additional_item_id, v_version - 1,
      'محاولة إلغاء بإصدار طابور قديم'
    );
  EXCEPTION WHEN serialization_failure THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Queue item cancellation accepted a stale queue version';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.cancel_daily_queue_item(
      v_queue_id, v_additional_item_id, v_version, ''
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Queue item cancellation accepted a missing audit reason';
  END IF;

  PERFORM public.cancel_daily_queue_item(
    v_queue_id, v_additional_item_id, v_version,
    'إلغاء الدور بناءً على طلب المستفيد'
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.queue_items
    WHERE id = v_additional_item_id
      AND status = 'cancelled'
      AND operation_id IS NULL
      AND started_at IS NULL
      AND completed_at IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.queue_item_events
    WHERE daily_queue_id = v_queue_id
      AND queue_item_id = v_additional_item_id
      AND event_type = 'item_cancelled'
      AND actor_id = auth.uid()
      AND reason = 'إلغاء الدور بناءً على طلب المستفيد'
  ) OR (SELECT auto_advance_queue_item_id FROM public.daily_queues WHERE id = v_queue_id)
       IS DISTINCT FROM v_guest_item_id
     OR (SELECT consumed_minutes FROM public.weekly_entitlement_allocations
         WHERE id = (SELECT weekly_entitlement_allocation_id
                     FROM public.queue_items WHERE id = v_weekly_item_id)) <> 2 THEN
    RAISE EXCEPTION 'Cancelling a waiting item did not preserve history, weekly consumption, or the remaining auto-advance target';
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

  v_operation := public.start_daily_queue_item(v_queue_id, v_guest_item_id, v_source_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.queue_items
    WHERE id = v_guest_item_id
      AND status = 'running'
      AND operation_id = v_operation.id
  ) THEN
    RAISE EXCEPTION 'The remaining waiting item could not start after the deferred item was cancelled';
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
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Queue event ledger did not record the persisted auto-advance schedule';
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

-- Reconcile the manual part of today's weekly filling against the same
-- entitlement allocation already linked to the completed queue item.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $weekly_entitlement_manual_report_reconciliation$
DECLARE
  v_queue_id uuid := current_setting('test.daily_queue_id')::uuid;
  v_work_date date;
  v_started_at timestamptz;
  v_ended_at timestamptz;
  v_source_id uuid;
  v_report public.daily_work_reports%ROWTYPE;
  v_cycle_id uuid;
  v_allocation_id uuid;
  v_rejected boolean := false;
BEGIN
  SELECT queue_date INTO v_work_date
  FROM public.daily_queues
  WHERE id = v_queue_id;

  v_started_at := (v_work_date + time '07:00') AT TIME ZONE 'Asia/Hebron';
  v_ended_at := (v_work_date + time '08:00') AT TIME ZONE 'Asia/Hebron';

  SELECT id INTO v_source_id
  FROM public.pump_power_sources
  WHERE pump_id = '20000000-0000-4000-8000-000000000001'
    AND name = 'طاقة شمسية – مزود 1'
    AND is_active;

  v_report := public.save_daily_work_report(
    '20000000-0000-4000-8000-000000000001',
    v_started_at,
    v_ended_at,
    0,
    jsonb_build_array(jsonb_build_object(
      'power_source_id', v_source_id,
      'minutes', 60
    )),
    jsonb_build_array(jsonb_build_object(
      'entry_type', 'weekly',
      'schedule_entry_id', '60000000-0000-4000-8000-000000000001',
      'subscriber_id', '30000000-0000-4000-8000-000000000001',
      'sort_order', 0,
      'manual_minutes', 7,
      'extra_minutes', 0,
      'note', 'اختبار مصالحة الجزء المنفذ خارج التطبيق'
    )),
    true,
    NULL
  );

  SELECT ri.weekly_entitlement_allocation_id
  INTO v_allocation_id
  FROM public.daily_work_report_items ri
  WHERE ri.daily_work_report_id = v_report.id;

  SELECT a.weekly_entitlement_cycle_id
  INTO v_cycle_id
  FROM public.weekly_entitlement_allocations a
  WHERE a.id = v_allocation_id;

  IF v_report.status <> 'submitted'
     OR v_allocation_id IS NULL
     OR (SELECT scheduled_minutes FROM public.daily_work_report_items
         WHERE daily_work_report_id = v_report.id) <> 35
     OR (SELECT weekly_minutes_consumed FROM public.daily_work_report_items
         WHERE daily_work_report_id = v_report.id) <> 9
     OR (SELECT consumed_minutes FROM public.weekly_entitlement_allocations
         WHERE id = v_allocation_id) <> 9
     OR (SELECT consumed_minutes FROM public.weekly_entitlement_cycles
         WHERE id = v_cycle_id) <> 9
     OR (SELECT remaining_minutes FROM public.weekly_entitlement_cycles
         WHERE id = v_cycle_id) <> 36 THEN
    RAISE EXCEPTION 'Submitted daily report did not reconcile seven manual weekly minutes exactly once';
  END IF;

  IF (SELECT count(*) FROM public.weekly_entitlement_events
      WHERE weekly_entitlement_cycle_id = v_cycle_id
        AND event_type = 'manual_reconciliation'
        AND minutes = 7
        AND actor_id = auth.uid()) <> 1 THEN
    RAISE EXCEPTION 'Manual reconciliation was not recorded once with the authenticated actor';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.save_daily_work_report(
      '20000000-0000-4000-8000-000000000001',
      v_started_at,
      v_ended_at,
      0,
      jsonb_build_array(jsonb_build_object('power_source_id', v_source_id, 'minutes', 60)),
      jsonb_build_array(jsonb_build_object(
        'entry_type', 'weekly',
        'schedule_entry_id', '60000000-0000-4000-8000-000000000001',
        'subscriber_id', '30000000-0000-4000-8000-000000000001',
        'sort_order', 0,
        'manual_minutes', 7,
        'extra_minutes', 0
      )),
      true,
      v_report.id
    );
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A submitted daily report was mutable and could reconcile entitlement minutes twice';
  END IF;

  IF (SELECT consumed_minutes FROM public.weekly_entitlement_cycles
      WHERE id = v_cycle_id) <> 9
     OR (SELECT consumed_minutes FROM public.weekly_entitlement_allocations
         WHERE id = v_allocation_id) <> 9 THEN
    RAISE EXCEPTION 'Resubmitting a daily report consumed weekly minutes more than once';
  END IF;
END;
$weekly_entitlement_manual_report_reconciliation$;
RESET ROLE;

-- A weekly allocation moved to a day with no template entry must still appear
-- in the daily report and reconcile against that same weekly cycle.
-- The fixture transfer is prepared by the migration-test owner; the report itself
-- is then submitted under the assigned operator role and its RLS grants.
DO $weekly_entitlement_reassigned_allocation_fixture$
DECLARE
  v_cycle_id uuid;
  v_cycle_start date;
  v_source_allocation_id uuid;
  v_target_allocation_id uuid;
BEGIN
  SELECT c.id, c.cycle_start
  INTO v_cycle_id, v_cycle_start
  FROM public.weekly_entitlement_cycles c
  WHERE c.weekly_schedule_id = '50000000-0000-4000-8000-000000000001'
    AND c.subscriber_id = '30000000-0000-4000-8000-000000000001';

  SELECT a.id INTO v_source_allocation_id
  FROM public.weekly_entitlement_allocations a
  WHERE a.weekly_entitlement_cycle_id = v_cycle_id
    AND a.allocation_date = v_cycle_start + 1
    AND a.available_minutes >= 5;

  IF v_source_allocation_id IS NULL THEN
    RAISE EXCEPTION 'Expected source-day remaining entitlement for reassigned report test';
  END IF;

  UPDATE public.weekly_entitlement_allocations
  SET allocated_minutes = allocated_minutes - 5,
      updated_at = clock_timestamp()
  WHERE id = v_source_allocation_id;

  INSERT INTO public.weekly_entitlement_allocations (
    weekly_entitlement_cycle_id, organization_id, pump_id, subscriber_id,
    allocation_date, source_schedule_entry_id, original_minutes,
    allocated_minutes, consumed_minutes
  )
  VALUES (
    v_cycle_id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '20000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000001',
    v_cycle_start + 2, NULL, 0, 5, 0
  )
  RETURNING id INTO v_target_allocation_id;

  PERFORM set_config('test.reassigned_cycle_id', v_cycle_id::text, true);
  PERFORM set_config('test.reassigned_target_date', (v_cycle_start + 2)::text, true);
  PERFORM set_config('test.reassigned_allocation_id', v_target_allocation_id::text, true);
END;
$weekly_entitlement_reassigned_allocation_fixture$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $weekly_entitlement_reassigned_report$
DECLARE
  v_target_date date := current_setting('test.reassigned_target_date')::date;
  v_cycle_id uuid := current_setting('test.reassigned_cycle_id')::uuid;
  v_target_allocation_id uuid := current_setting('test.reassigned_allocation_id')::uuid;
  v_source_id uuid;
  v_report public.daily_work_reports%ROWTYPE;
  v_started_at timestamptz;
  v_ended_at timestamptz;
BEGIN
  SELECT id INTO v_source_id
  FROM public.pump_power_sources
  WHERE pump_id = '20000000-0000-4000-8000-000000000001'
    AND name = 'طاقة شمسية – مزود 1'
    AND is_active;

  v_started_at := (v_target_date + time '07:00') AT TIME ZONE 'Asia/Hebron';
  v_ended_at := (v_target_date + time '08:00') AT TIME ZONE 'Asia/Hebron';

  v_report := public.save_daily_work_report(
    '20000000-0000-4000-8000-000000000001',
    v_started_at,
    v_ended_at,
    0,
    jsonb_build_array(jsonb_build_object('power_source_id', v_source_id, 'minutes', 60)),
    jsonb_build_array(jsonb_build_object(
      'entry_type', 'weekly_reassigned',
      'schedule_entry_id', NULL,
      'subscriber_id', '30000000-0000-4000-8000-000000000001',
      'sort_order', 0,
      'manual_minutes', 3,
      'extra_minutes', 0,
      'note', 'اختبار تقرير حصة منقولة إلى يوم بلا موعد أصلي'
    )),
    true,
    NULL
  );

  IF (SELECT count(*) FROM public.daily_work_report_items
      WHERE daily_work_report_id = v_report.id
        AND entry_type = 'weekly_reassigned'
        AND weekly_entitlement_allocation_id = v_target_allocation_id
        AND scheduled_minutes = 5
        AND weekly_minutes_consumed = 3
        AND fulfillment_status = 'partial') <> 1
     OR (SELECT consumed_minutes FROM public.weekly_entitlement_allocations
         WHERE id = v_target_allocation_id) <> 3
     OR (SELECT consumed_minutes FROM public.weekly_entitlement_cycles
         WHERE id = v_cycle_id) <> 12
     OR (SELECT remaining_minutes FROM public.weekly_entitlement_cycles
         WHERE id = v_cycle_id) <> 33 THEN
    RAISE EXCEPTION 'Reassigned weekly minutes were not included and reconciled as part of the same entitlement cycle';
  END IF;
END;
$weekly_entitlement_reassigned_report$;
RESET ROLE;

-- A prior seven-day cycle is closed on demand, and every unused minute expires
-- rather than becoming part of the next week's transferable balance.
DO $weekly_entitlement_expiry$
DECLARE
  v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date;
  v_cycle_start date;
  v_old_cycle_start date;
  v_old_cycle_id uuid;
  v_old_allocation_id uuid;
  v_actor_id uuid := '10000000-0000-4000-8000-000000000002';
  v_rejected boolean := false;
BEGIN
  SELECT weekly_cycle_start INTO v_cycle_start
  FROM public.daily_queues
  WHERE id = current_setting('test.daily_queue_id')::uuid;
  v_old_cycle_start := v_cycle_start - 7;

  PERFORM water_management_private.ensure_weekly_entitlement_cycle(
    '50000000-0000-4000-8000-000000000001',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '20000000-0000-4000-8000-000000000001',
    v_old_cycle_start,
    v_actor_id
  );

  PERFORM water_management_private.expire_due_weekly_entitlement_cycles(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '20000000-0000-4000-8000-000000000001',
    v_today,
    v_actor_id
  );

  SELECT id INTO v_old_cycle_id
  FROM public.weekly_entitlement_cycles
  WHERE weekly_schedule_id = '50000000-0000-4000-8000-000000000001'
    AND subscriber_id = '30000000-0000-4000-8000-000000000001'
    AND cycle_start = v_old_cycle_start;

  SELECT id INTO v_old_allocation_id
  FROM public.weekly_entitlement_allocations
  WHERE weekly_entitlement_cycle_id = v_old_cycle_id
    AND allocation_date = v_old_cycle_start + 1;

  IF NOT EXISTS (
    SELECT 1 FROM public.weekly_entitlement_cycles
    WHERE id = v_old_cycle_id
      AND status = 'expired'
      AND consumed_minutes = 0
      AND expired_minutes = quota_minutes
      AND remaining_minutes = 0
      AND expired_at IS NOT NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.weekly_entitlement_events
    WHERE weekly_entitlement_cycle_id = v_old_cycle_id
      AND event_type = 'cycle_expired'
      AND minutes = 45
      AND actor_id = v_actor_id
  ) THEN
    RAISE EXCEPTION 'Unused weekly minutes were not expired and recorded at cycle close';
  END IF;

  PERFORM set_config('test.expired_cycle_id', v_old_cycle_id::text, true);
  PERFORM set_config('test.expired_allocation_id', v_old_allocation_id::text, true);
END;
$weekly_entitlement_expiry$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $weekly_entitlement_expired_transfer_denied$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM public.transfer_weekly_entitlement_minutes(
      current_setting('test.expired_allocation_id')::uuid,
      (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date,
      1,
      'محاولة نقل رصيد من دورة أسبوعية منتهية'
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An expired weekly balance was transferable into the current cycle';
  END IF;
END;
$weekly_entitlement_expired_transfer_denied$;

DO $weekly_entitlement_direct_write_denied$
DECLARE
  v_allocation_id uuid;
  v_rejected boolean := false;
BEGIN
  SELECT id INTO v_allocation_id
  FROM public.weekly_entitlement_allocations
  WHERE weekly_entitlement_cycle_id = (
    SELECT id FROM public.weekly_entitlement_cycles
    WHERE weekly_schedule_id = '50000000-0000-4000-8000-000000000001'
      AND cycle_start = (SELECT weekly_cycle_start FROM public.daily_queues
                         WHERE id = current_setting('test.daily_queue_id')::uuid)
      AND subscriber_id = '30000000-0000-4000-8000-000000000001'
  )
  ORDER BY allocation_date
  LIMIT 1;

  BEGIN
    UPDATE public.weekly_entitlement_allocations
    SET allocated_minutes = allocated_minutes + 1
    WHERE id = v_allocation_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Authenticated client directly modified weekly entitlement allocation minutes';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.weekly_entitlement_cycles
    SET quota_minutes = quota_minutes + 1
    WHERE id = (
      SELECT weekly_entitlement_cycle_id
      FROM public.weekly_entitlement_allocations
      WHERE id = v_allocation_id
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Authenticated client directly changed the weekly quota cycle';
  END IF;
END;
$weekly_entitlement_direct_write_denied$;
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
  IF v_queue_count <> 1 OR v_item_count <> 3
     OR NOT EXISTS (
       SELECT 1 FROM public.weekly_entitlement_cycles
       WHERE pump_id = '20000000-0000-4000-8000-000000000001'
         AND cycle_start = (SELECT weekly_cycle_start FROM public.daily_queues WHERE id = v_queue_id)
         AND subscriber_id = '30000000-0000-4000-8000-000000000001'
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.weekly_entitlement_allocations
       WHERE pump_id = '20000000-0000-4000-8000-000000000001'
         AND allocation_date = (SELECT queue_date FROM public.daily_queues WHERE id = v_queue_id)
         AND subscriber_id = '30000000-0000-4000-8000-000000000001'
     ) THEN
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
     OR EXISTS (SELECT 1 FROM public.queue_items WHERE daily_queue_id = v_queue_id)
     OR EXISTS (
       SELECT 1 FROM public.weekly_entitlement_cycles
       WHERE pump_id = '20000000-0000-4000-8000-000000000001'
     )
     OR EXISTS (
       SELECT 1 FROM public.weekly_entitlement_allocations
       WHERE pump_id = '20000000-0000-4000-8000-000000000001'
     ) THEN
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
     OR EXISTS (SELECT 1 FROM public.queue_items WHERE daily_queue_id = v_queue_id)
     OR EXISTS (
       SELECT 1 FROM public.weekly_entitlement_cycles
       WHERE pump_id = '20000000-0000-4000-8000-000000000001'
     )
     OR EXISTS (
       SELECT 1 FROM public.weekly_entitlement_allocations
       WHERE pump_id = '20000000-0000-4000-8000-000000000001'
     ) THEN
    RAISE EXCEPTION 'Queue items or weekly entitlement balances leaked across organizations';
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
     OR pg_catalog.has_function_privilege('anon', 'public.cancel_daily_queue_auto_advance(uuid,uuid,text)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.add_daily_queue_item(uuid,text,uuid,text,integer)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.defer_daily_queue_item(uuid,uuid,integer,text)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.cancel_daily_queue_item(uuid,uuid,integer,text)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'water_management_private.manage_daily_queue_item_internal(uuid,uuid,integer,text,text)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'public.defer_daily_queue_item(uuid,uuid,integer,text)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'public.cancel_daily_queue_item(uuid,uuid,integer,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Queue item action RPC grants are not correctly restricted';
  END IF;
END;
$daily_queue_acl$;

DO $weekly_entitlement_acl$
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.weekly_entitlement_cycles'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.weekly_entitlement_allocations'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.weekly_entitlement_events'::regclass) THEN
    RAISE EXCEPTION 'RLS must be enabled on every weekly entitlement table';
  END IF;

  IF pg_catalog.has_table_privilege('anon', 'public.weekly_entitlement_cycles', 'SELECT')
     OR pg_catalog.has_table_privilege('anon', 'public.weekly_entitlement_allocations', 'SELECT')
     OR pg_catalog.has_table_privilege('anon', 'public.weekly_entitlement_events', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.weekly_entitlement_cycles', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.weekly_entitlement_cycles', 'UPDATE')
     OR pg_catalog.has_table_privilege('authenticated', 'public.weekly_entitlement_allocations', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.weekly_entitlement_allocations', 'UPDATE')
     OR pg_catalog.has_table_privilege('authenticated', 'public.weekly_entitlement_allocations', 'DELETE')
     OR pg_catalog.has_table_privilege('authenticated', 'public.weekly_entitlement_events', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.weekly_entitlement_events', 'UPDATE')
     OR pg_catalog.has_table_privilege('authenticated', 'public.weekly_entitlement_events', 'DELETE') THEN
    RAISE EXCEPTION 'Weekly entitlement writes must remain private RPC/trigger-only';
  END IF;

  IF pg_catalog.has_function_privilege(
       'authenticated',
       'water_management_private.ensure_weekly_entitlement_cycle(uuid,uuid,uuid,date,uuid)',
       'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'authenticated',
       'water_management_private.expire_due_weekly_entitlement_cycles(uuid,uuid,date,uuid)',
       'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon',
       'public.transfer_weekly_entitlement_minutes(uuid,date,integer,text)',
       'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon',
       'public.get_weekly_entitlement_transfer_options(uuid,date)',
       'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated',
       'public.transfer_weekly_entitlement_minutes(uuid,date,integer,text)',
       'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated',
       'public.get_weekly_entitlement_transfer_options(uuid,date)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Weekly entitlement helper/RPC execution grants are not correctly restricted';
  END IF;
END;
$weekly_entitlement_acl$;
