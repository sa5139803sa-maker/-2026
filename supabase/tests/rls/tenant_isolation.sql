\set ON_ERROR_STOP on
BEGIN;

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
END;
$roles$;

CREATE SCHEMA auth;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text,
  raw_user_meta_data jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE FUNCTION auth.uid()
RETURNS uuid LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

\ir ../../migrations/20261104120358_create_water_management_foundation.sql
\ir ../../migrations/20261104120514_tighten_water_management_grants.sql
\ir ../../migrations/20261104160000_secure_tenant_boundaries.sql

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('10000000-0000-4000-8000-000000000001', 'manager-a@example.test', '{"display_name":"مدير المؤسسة أ"}'),
  ('10000000-0000-4000-8000-000000000002', 'operator-a@example.test', '{"display_name":"مشغّل أ"}'),
  ('10000000-0000-4000-8000-000000000003', 'operator-a2@example.test', '{"display_name":"مشغّل أ 2"}'),
  ('10000000-0000-4000-8000-000000000004', 'collector-a@example.test', '{"display_name":"محصّل أ"}'),
  ('10000000-0000-4000-8000-000000000005', 'supervisor-a@example.test', '{"display_name":"مشرف أ"}'),
  ('10000000-0000-4000-8000-000000000006', 'manager-b@example.test', '{"display_name":"مدير المؤسسة ب"}'),
  ('10000000-0000-4000-8000-000000000007', 'operator-b@example.test', '{"display_name":"مشغّل ب"}'),
  ('10000000-0000-4000-8000-000000000008', 'unassigned@example.test', '{"display_name":"A"}'),
  ('10000000-0000-4000-8000-000000000009', 'onboarding@example.test', '{"display_name":"مستخدم التهيئة"}');

INSERT INTO public.organizations (id, name, created_by) VALUES
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'المؤسسة أ', '10000000-0000-4000-8000-000000000001'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'المؤسسة ب', '10000000-0000-4000-8000-000000000006');

UPDATE public.profiles
SET organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    role = CASE id
      WHEN '10000000-0000-4000-8000-000000000001' THEN 'manager'::public.app_role
      WHEN '10000000-0000-4000-8000-000000000002' THEN 'operator'::public.app_role
      WHEN '10000000-0000-4000-8000-000000000003' THEN 'operator'::public.app_role
      WHEN '10000000-0000-4000-8000-000000000004' THEN 'collector'::public.app_role
      WHEN '10000000-0000-4000-8000-000000000005' THEN 'supervisor'::public.app_role
      ELSE role
    END
WHERE id IN (
  '10000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000003',
  '10000000-0000-4000-8000-000000000004',
  '10000000-0000-4000-8000-000000000005'
);

UPDATE public.profiles
SET organization_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    role = CASE id
      WHEN '10000000-0000-4000-8000-000000000006' THEN 'manager'::public.app_role
      WHEN '10000000-0000-4000-8000-000000000007' THEN 'operator'::public.app_role
      ELSE role
    END
WHERE id IN (
  '10000000-0000-4000-8000-000000000006',
  '10000000-0000-4000-8000-000000000007'
);

INSERT INTO public.pumps (id, organization_id, name, code) VALUES
  ('20000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'غطاس أ 1', 'A-1'),
  ('20000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'غطاس أ 2', 'A-2'),
  ('20000000-0000-4000-8000-000000000003', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'غطاس ب 1', 'B-1');

INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role) VALUES
  ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'operator'),
  ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000004', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'collector'),
  ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000005', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'supervisor'),
  ('20000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000007', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'operator');

INSERT INTO public.subscribers (id, organization_id, pump_id, full_name) VALUES
  ('30000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000001', 'مشترك أ 1'),
  ('30000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000002', 'مشترك أ 2'),
  ('30000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', NULL, 'مشترك أ دون غطاس'),
  ('30000000-0000-4000-8000-000000000004', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '20000000-0000-4000-8000-000000000003', 'مشترك ب 1');

CREATE FUNCTION pg_temp.assert_scope(
  p_label text, p_organizations bigint, p_pumps bigint,
  p_subscribers bigint, p_assignments bigint, p_profiles bigint
)
RETURNS void LANGUAGE plpgsql
AS $$
DECLARE
  v_organizations bigint;
  v_pumps bigint;
  v_subscribers bigint;
  v_assignments bigint;
  v_profiles bigint;
BEGIN
  SELECT count(id) INTO v_organizations FROM public.organizations;
  SELECT count(id) INTO v_pumps FROM public.pumps;
  SELECT count(id) INTO v_subscribers FROM public.subscribers;
  SELECT count(id) INTO v_assignments FROM public.pump_assignments;
  SELECT count(id) INTO v_profiles FROM public.profiles;

  IF (v_organizations, v_pumps, v_subscribers, v_assignments, v_profiles)
     IS DISTINCT FROM
     (p_organizations, p_pumps, p_subscribers, p_assignments, p_profiles) THEN
    RAISE EXCEPTION 'RLS mismatch for %: orgs %, pumps %, subscribers %, assignments %, profiles %',
      p_label, v_organizations, v_pumps, v_subscribers, v_assignments, v_profiles;
  END IF;
END;
$$;

-- Manager A has organization-wide management visibility and can update their own pump.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
SELECT pg_temp.assert_scope('manager A', 1, 2, 3, 3, 5);
DO $manager_a_write$
DECLARE v_rows bigint;
BEGIN
  UPDATE public.pumps SET status = 'paused'
  WHERE id = '20000000-0000-4000-8000-000000000001';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'Manager could not update an organization pump'; END IF;
  UPDATE public.pumps SET status = 'active'
  WHERE id = '20000000-0000-4000-8000-000000000001';
END;
$manager_a_write$;

DO $manager_a_negative$
DECLARE v_rejected boolean;
BEGIN
  v_rejected := false;
  BEGIN
    INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
    VALUES ('20000000-0000-4000-8000-000000000001',
            '10000000-0000-4000-8000-000000000007',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'operator');
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Cross-organization assignment INSERT was not rejected'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.subscribers (organization_id, pump_id, full_name)
    VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '20000000-0000-4000-8000-000000000003', 'مشترك عابر للمؤسسات');
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Cross-organization subscriber INSERT was not rejected'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.subscribers SET pump_id = '20000000-0000-4000-8000-000000000003'
    WHERE id = '30000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Cross-organization subscriber UPDATE was not rejected'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.pump_assignments SET user_id = '10000000-0000-4000-8000-000000000007'
    WHERE pump_id = '20000000-0000-4000-8000-000000000001'
      AND user_id = '10000000-0000-4000-8000-000000000002';
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Cross-organization assignment UPDATE was not rejected'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
    VALUES ('20000000-0000-4000-8000-000000000002',
            '10000000-0000-4000-8000-000000000005',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'operator');
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Assignment role mismatch was not rejected'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
    VALUES ('20000000-0000-4000-8000-000000000001',
            '10000000-0000-4000-8000-000000000003',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'operator');
  EXCEPTION WHEN unique_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Second operator for a pump was not rejected'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
    VALUES ('20000000-0000-4000-8000-000000000002',
            '10000000-0000-4000-8000-000000000001',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'manager');
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Manager profile was accepted as a staff assignment'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.profiles SET role = 'manager'
    WHERE id = (SELECT auth.uid());
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Client-side role escalation was not rejected'; END IF;
END;
$manager_a_negative$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
SELECT pg_temp.assert_scope('operator A', 1, 1, 1, 1, 1);
DO $operator_write$
DECLARE v_rows bigint;
BEGIN
  UPDATE public.pumps SET status = 'paused'
  WHERE id = '20000000-0000-4000-8000-000000000001';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'Operator unexpectedly modified a pump'; END IF;
END;
$operator_write$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);
SELECT pg_temp.assert_scope('unassigned employee A', 1, 0, 0, 0, 1);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000004', true);
SELECT pg_temp.assert_scope('collector A', 1, 1, 1, 1, 1);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);
SELECT pg_temp.assert_scope('supervisor A', 1, 1, 1, 1, 1);
DO $supervisor_write$
DECLARE v_rows bigint;
BEGIN
  UPDATE public.subscribers SET full_name = 'محاولة تعديل غير مسموحة'
  WHERE id = '30000000-0000-4000-8000-000000000001';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'Supervisor unexpectedly modified a subscriber'; END IF;
END;
$supervisor_write$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000006', true);
SELECT pg_temp.assert_scope('manager B', 1, 1, 1, 1, 2);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000008', true);
SELECT pg_temp.assert_scope('unassigned user', 0, 0, 0, 0, 1);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000009', true);
DO $onboarding$
DECLARE v_organization_id uuid;
BEGIN
  v_organization_id := public.create_organization('مؤسسة التهيئة');
  IF v_organization_id IS NULL
     OR (SELECT private.current_user_role()) <> 'manager'::public.app_role
     OR (SELECT private.current_user_organization_id()) <> v_organization_id THEN
    RAISE EXCEPTION 'Secure onboarding did not establish the manager profile correctly';
  END IF;
END;
$onboarding$;
SELECT pg_temp.assert_scope('onboarded manager', 1, 0, 0, 0, 1);
RESET ROLE;

DELETE FROM public.pumps WHERE id = '20000000-0000-4000-8000-000000000003';
DO $delete_behavior$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.subscribers
    WHERE id = '30000000-0000-4000-8000-000000000004'
      AND pump_id IS NULL
      AND organization_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  ) THEN
    RAISE EXCEPTION 'Pump deletion did not preserve subscriber tenant and null pump_id';
  END IF;
END;
$delete_behavior$;

-- Organization deletion must cascade organization-owned rows while retaining auth profiles.
DELETE FROM public.organizations
WHERE id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

DO $organization_delete$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.pumps
    WHERE organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  ) OR EXISTS (
    SELECT 1 FROM public.subscribers
    WHERE organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  ) OR EXISTS (
    SELECT 1 FROM public.pump_assignments
    WHERE organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  ) THEN
    RAISE EXCEPTION 'Deleting an organization did not cascade its tenant-owned records';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id IN (
      '10000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000002',
      '10000000-0000-4000-8000-000000000003',
      '10000000-0000-4000-8000-000000000004',
      '10000000-0000-4000-8000-000000000005'
    )
    AND organization_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Deleting an organization did not detach member profiles safely';
  END IF;
END;
$organization_delete$;

ROLLBACK;
