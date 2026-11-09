#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required}"

readonly ORG_ID="26000000-0000-4000-8000-000000000001"
readonly PUMP_ID="26000000-0000-4000-8000-000000000002"
readonly SOURCE_ID="26000000-0000-4000-8000-000000000003"
readonly OPERATOR_ONE="10000000-0000-4000-8000-000000000002"
readonly OPERATOR_TWO="10000000-0000-4000-8000-000000000003"
readonly WORK_DATE="2026-11-10"

operator_one_pid=""
operator_two_pid=""

cleanup() {
  if [[ -n "$operator_one_pid" ]] && kill -0 "$operator_one_pid" 2>/dev/null; then
    kill "$operator_one_pid" 2>/dev/null || true
  fi
  if [[ -n "$operator_two_pid" ]] && kill -0 "$operator_two_pid" 2>/dev/null; then
    kill "$operator_two_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Session one takes the pump-row mutex as the database test owner, then switches
# to operator one. This deliberately keeps the mutex held while session two
# enters the guarded report RPC.
PGAPPNAME="daily-report-concurrency-operator-one" \
psql "$DATABASE_URL" --no-psqlrc --set ON_ERROR_STOP=1 --quiet <<SQL &
BEGIN;
SELECT id
FROM public.pumps
WHERE id = '$PUMP_ID'
FOR UPDATE;
SELECT pg_sleep(3);
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$OPERATOR_ONE', true);
SELECT (public.save_daily_work_report(
  '$PUMP_ID',
  '$OPERATOR_ONE',
  ('$WORK_DATE 07:00:00+02')::timestamptz,
  ('$WORK_DATE 08:00:00+02')::timestamptz,
  0,
  jsonb_build_array(jsonb_build_object('power_source_id', '$SOURCE_ID', 'minutes', 60)),
  '[]'::jsonb,
  false,
  NULL
)).id;
SELECT pg_sleep(0.25);
COMMIT;
SQL
operator_one_pid=$!

# Wait until session one is connected and sleeping after it has acquired the
# pump lock; otherwise the test could pass without exercising a lock conflict.
owner_lock_ready="f"
for _ in $(seq 1 40); do
  owner_lock_ready="$(psql "$DATABASE_URL" --no-psqlrc --tuples-only --no-align --quiet --command "
    SELECT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_stat_activity
      WHERE application_name = 'daily-report-concurrency-operator-one'
        AND state = 'active'
        AND query ILIKE '%pg_sleep(3)%'
    );
  ")"
  [[ "$owner_lock_ready" == "t" ]] && break
  sleep 0.05
done

if [[ "$owner_lock_ready" != "t" ]]; then
  echo "First session did not acquire and hold the pump-row lock." >&2
  wait "$operator_one_pid" || true
  exit 1
fi

PGAPPNAME="daily-report-concurrency-operator-two" \
psql "$DATABASE_URL" --no-psqlrc --set ON_ERROR_STOP=1 --quiet <<SQL &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$OPERATOR_TWO', true);
SELECT (public.save_daily_work_report(
  '$PUMP_ID',
  '$OPERATOR_TWO',
  ('$WORK_DATE 07:00:00+02')::timestamptz,
  ('$WORK_DATE 08:00:00+02')::timestamptz,
  0,
  jsonb_build_array(jsonb_build_object('power_source_id', '$SOURCE_ID', 'minutes', 60)),
  '[]'::jsonb,
  false,
  NULL
)).id;
COMMIT;
SQL
operator_two_pid=$!

# Confirm that session two really waited on a PostgreSQL lock while session
# one owned the pump mutex. A merely sequential test is not accepted.
second_session_blocked="f"
for _ in $(seq 1 40); do
  second_session_blocked="$(psql "$DATABASE_URL" --no-psqlrc --tuples-only --no-align --quiet --command "
    SELECT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_stat_activity
      WHERE application_name = 'daily-report-concurrency-operator-two'
        AND wait_event_type = 'Lock'
    );
  ")"
  [[ "$second_session_blocked" == "t" ]] && break
  sleep 0.05
done

if [[ "$second_session_blocked" != "t" ]]; then
  echo "Second session never waited on the first session's PostgreSQL lock." >&2
  wait "$operator_one_pid" || true
  wait "$operator_two_pid" || true
  exit 1
fi

wait "$operator_one_pid"
operator_one_pid=""
wait "$operator_two_pid"
operator_two_pid=""

psql "$DATABASE_URL" --no-psqlrc --set ON_ERROR_STOP=1 <<SQL
DO \$assert_concurrent_daily_reports\$
DECLARE
  v_report_count integer;
  v_energy_report_count integer;
  v_energy_total_count integer;
BEGIN
  SELECT count(*)::integer INTO v_report_count
  FROM public.daily_work_reports
  WHERE organization_id = '$ORG_ID'
    AND pump_id = '$PUMP_ID'
    AND work_date = DATE '$WORK_DATE';

  SELECT count(*)::integer INTO v_energy_report_count
  FROM public.daily_pump_energy_reports
  WHERE organization_id = '$ORG_ID'
    AND pump_id = '$PUMP_ID'
    AND work_date = DATE '$WORK_DATE';

  SELECT count(*)::integer INTO v_energy_total_count
  FROM public.daily_pump_energy_source_totals totals
  JOIN public.daily_pump_energy_reports energy
    ON energy.id = totals.daily_pump_energy_report_id
   AND energy.organization_id = totals.organization_id
   AND energy.pump_id = totals.pump_id
  WHERE energy.organization_id = '$ORG_ID'
    AND energy.pump_id = '$PUMP_ID'
    AND energy.work_date = DATE '$WORK_DATE';

  IF v_report_count <> 2
     OR v_energy_report_count <> 1
     OR v_energy_total_count <> 1 THEN
    RAISE EXCEPTION
      'Concurrent operator reports were not serialized correctly: reports %, energy reports %, source totals %',
      v_report_count, v_energy_report_count, v_energy_total_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.daily_work_reports
    WHERE organization_id = '$ORG_ID'
      AND pump_id = '$PUMP_ID'
      AND work_date = DATE '$WORK_DATE'
      AND operator_id = '$OPERATOR_ONE'
      AND created_by = '$OPERATOR_ONE'
      AND status = 'draft'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.daily_work_reports
    WHERE organization_id = '$ORG_ID'
      AND pump_id = '$PUMP_ID'
      AND work_date = DATE '$WORK_DATE'
      AND operator_id = '$OPERATOR_TWO'
      AND created_by = '$OPERATOR_TWO'
      AND status = 'draft'
  ) THEN
    RAISE EXCEPTION 'Concurrent report ownership or creator identity was not preserved';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.daily_pump_energy_reports energy
    JOIN public.daily_pump_energy_source_totals totals
      ON totals.daily_pump_energy_report_id = energy.id
     AND totals.organization_id = energy.organization_id
     AND totals.pump_id = energy.pump_id
    WHERE energy.organization_id = '$ORG_ID'
      AND energy.pump_id = '$PUMP_ID'
      AND energy.work_date = DATE '$WORK_DATE'
      AND energy.created_by = '$OPERATOR_ONE'
      AND energy.status = 'draft'
      AND totals.power_source_id = '$SOURCE_ID'
      AND totals.minutes = 60
  ) THEN
    RAISE EXCEPTION 'The shared pump-energy draft was duplicated or overwritten during concurrent saves';
  END IF;
END;
\$assert_concurrent_daily_reports\$;
SQL

echo "Concurrent multi-operator report test passed: 2 operator reports, 1 shared energy report."
