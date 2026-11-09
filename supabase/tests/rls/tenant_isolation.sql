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
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END;
$roles$;
ALTER ROLE service_role BYPASSRLS;

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
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $jwt$
  SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$jwt$;
GRANT EXECUTE ON FUNCTION auth.jwt() TO anon, authenticated;

\ir ../../migrations/20261104120358_create_water_management_foundation.sql
\ir ../../migrations/20261104120514_tighten_water_management_grants.sql
\ir ../../migrations/20261104160000_secure_tenant_boundaries.sql
\ir ../../migrations/20261106104135_secure_request_identity_bridge_for_authz.sql
\ir ../../migrations/20261106143808_add_tenant_foreign_key_indexes.sql
\ir ../../migrations/20261106160000_harden_onboarding_function.sql
\ir ../../migrations/20261106170000_add_managed_accounts_and_password_reset.sql
\ir ../../migrations/20261106171000_enforce_temporary_password_access_gate.sql
\ir ../../migrations/20261106172000_fence_sessions_after_password_reset.sql
\ir ../../migrations/20261106173000_serialize_organization_account_limit_updates.sql
\ir ../../migrations/20261106174000_scope_account_audit_log_policy.sql
\ir ../../migrations/20261106175000_index_account_audit_log_foreign_keys.sql
\ir ../../migrations/20261106180000_create_platform_organization_admin_rpc.sql
\ir ../../migrations/20261106190000_add_global_subscriber_number_and_public_lookup.sql
\ir ../../migrations/20261107010000_enable_private_schema_rls.sql
\ir ../../migrations/20261107020000_grant_profile_select_to_authenticated.sql
\ir ../../migrations/20261109065108_allow_multiple_collectors_and_create_pump_operations.sql
\ir ../../migrations/20261109065908_harden_pump_operations_grants_and_indexes.sql
\ir ../../migrations/20261109070000_restrict_pump_operation_lifecycle_to_guarded_rpcs.sql
\ir ../../migrations/20261109071000_revoke_direct_pump_operation_state_column_updates.sql
\ir ../../migrations/20261109072000_move_pump_operation_definers_to_private_schema.sql
\ir ../../migrations/20261109073000_add_rls_scoped_operations_dashboard_aggregate.sql
\ir ../../migrations/20261109074000_add_append_only_pump_operation_event_ledger.sql
\ir ../../migrations/20261109075000_add_monotonic_event_sequence_to_pump_operation_ledger.sql
\ir ../../migrations/20261109076000_index_pump_operation_events_foreign_keys.sql
\ir ../../migrations/20261109077000_route_pump_operation_creation_through_guarded_rpc.sql
\ir ../../migrations/20261109081000_create_pump_branches.sql
\ir ../../migrations/20261109093000_create_weekly_schedules.sql
\ir ../../migrations/20261109110000_add_pump_power_sources.sql
\ir ../../migrations/20261109111000_create_daily_work_reports.sql
\ir ../../migrations/20261109120000_create_daily_queue_backend.sql
\ir ../../migrations/20261109130000_version_weekly_entitlements_and_guarded_schedule_rpcs.sql
\ir ../../migrations/20261109140000_add_pump_operation_time_extension.sql
\ir ../../migrations/20261109150000_create_weekly_entitlement_ledger.sql
\ir ../../migrations/20261109160000_add_guarded_queue_item_actions.sql
\ir ../../migrations/20261109170000_assign_subscribers_to_operators.sql
\ir ../../migrations/20261109181500_scope_operator_data_access.sql
\ir ../../migrations/20261109190000_clear_subscriber_operator_on_pump_delete.sql
\ir ../../migrations/20261109195700_multi_operator_daily_work_reports.sql

GRANT USAGE ON SCHEMA public TO service_role;
GRANT SELECT, UPDATE ON public.profiles TO service_role;
GRANT SELECT ON public.organizations TO service_role;
GRANT UPDATE (account_limit) ON public.organizations TO service_role;

-- Future helper functions must inherit the dedicated owner's closed default ACL.
SET LOCAL ROLE water_management_authz;
CREATE FUNCTION water_management_private.default_acl_probe()
RETURNS boolean
LANGUAGE sql
AS $$ SELECT true $$;
RESET ROLE;

DO $private_schema_acl$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = 'water_management_authz'
      AND rolcanlogin = false
      AND rolbypassrls = true
  ) THEN
    RAISE EXCEPTION 'Authorization function owner must be NOLOGIN and BYPASSRLS';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'water_management_private'
      AND p.proname = 'current_user_role'
      AND pg_catalog.pg_get_userbyid(p.proowner) = 'water_management_authz'
  ) THEN
    RAISE EXCEPTION 'Private authorization helper has an unexpected owner';
  END IF;
  IF NOT pg_catalog.has_schema_privilege('water_management_authz', 'water_management_private', 'USAGE') THEN
    RAISE EXCEPTION 'Authorization function owner cannot use its private schema';
  END IF;
  IF pg_catalog.has_schema_privilege('water_management_authz', 'auth', 'USAGE') THEN
    RAISE EXCEPTION 'Authorization owner unexpectedly has direct auth schema access';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'water_management_private'
      AND p.proname = 'request_user_id'
      AND pg_catalog.pg_get_userbyid(p.proowner) = 'postgres'
  ) THEN
    RAISE EXCEPTION 'Request identity bridge must be owned by postgres';
  END IF;
  IF NOT pg_catalog.has_function_privilege(
    'water_management_authz', 'water_management_private.request_user_id()', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Authorization owner cannot call the restricted request identity bridge';
  END IF;
  IF pg_catalog.has_function_privilege(
       'anon', 'water_management_private.request_user_id()', 'EXECUTE'
     ) OR pg_catalog.has_function_privilege(
       'authenticated', 'water_management_private.request_user_id()', 'EXECUTE'
     ) OR pg_catalog.has_function_privilege(
       'service_role', 'water_management_private.request_user_id()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'API role can execute the restricted request identity bridge';
  END IF;

  IF NOT pg_catalog.has_schema_privilege('authenticated', 'water_management_private', 'USAGE') THEN
    RAISE EXCEPTION 'Authenticated role cannot use the private authorization schema';
  END IF;

  IF NOT pg_catalog.has_table_privilege(
    'authenticated', 'public.profiles', 'SELECT'
  ) THEN
    RAISE EXCEPTION 'Authenticated web users cannot read their RLS-scoped profile';
  END IF;
  IF pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'UPDATE')
     OR pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'DELETE')
     OR pg_catalog.has_table_privilege('anon', 'public.profiles', 'SELECT') THEN
    RAISE EXCEPTION 'Profile access must remain read-only for authenticated users and denied to anon';
  END IF;
  IF pg_catalog.has_schema_privilege('anon', 'water_management_private', 'USAGE')
     OR NOT pg_catalog.has_schema_privilege('service_role', 'water_management_private', 'USAGE') THEN
    RAISE EXCEPTION 'Private schema USAGE must be limited to the trusted service role and denied to anon';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated', 'water_management_private.current_user_role()', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Authenticated role cannot execute the explicitly granted authorization helper';
  END IF;
  IF pg_catalog.has_function_privilege(
       'anon', 'water_management_private.current_user_role()', 'EXECUTE'
     ) OR pg_catalog.has_function_privilege(
       'service_role', 'water_management_private.current_user_role()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Untrusted API role can execute the private authorization helper';
  END IF;

  IF pg_catalog.has_function_privilege(
       'anon', 'water_management_private.default_acl_probe()', 'EXECUTE'
     ) OR pg_catalog.has_function_privilege(
       'authenticated', 'water_management_private.default_acl_probe()', 'EXECUTE'
     ) OR pg_catalog.has_function_privilege(
       'service_role', 'water_management_private.default_acl_probe()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'A new private helper inherited EXECUTE for an API role';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = 'water_management_onboarding'
      AND rolcanlogin = false
      AND rolsuper = false
      AND rolcreatedb = false
      AND rolcreaterole = false
      AND rolbypassrls = false
      AND rolinherit = false
  ) THEN
    RAISE EXCEPTION 'Onboarding function owner must be a non-login, non-BYPASSRLS role';
  END IF;
  IF pg_catalog.pg_has_role('authenticated', 'water_management_onboarding', 'MEMBER')
     OR pg_catalog.pg_has_role('anon', 'water_management_onboarding', 'MEMBER')
     OR pg_catalog.pg_has_role('service_role', 'water_management_onboarding', 'MEMBER') THEN
    RAISE EXCEPTION 'An API role can assume the onboarding function owner';
  END IF;
  IF pg_catalog.has_schema_privilege('water_management_onboarding', 'water_management_private', 'CREATE') THEN
    RAISE EXCEPTION 'Onboarding owner retained CREATE on the private schema';
  END IF;
  IF NOT pg_catalog.has_column_privilege(
    'water_management_onboarding', 'public.profiles', 'organization_id', 'UPDATE'
  ) OR NOT pg_catalog.has_column_privilege(
    'water_management_onboarding', 'public.profiles', 'role', 'UPDATE'
  ) OR pg_catalog.has_column_privilege(
    'water_management_onboarding', 'public.profiles', 'display_name', 'UPDATE'
  ) THEN
    RAISE EXCEPTION 'Onboarding owner profile column grants are not least-privilege';
  END IF;
  IF NOT pg_catalog.has_column_privilege(
    'water_management_onboarding', 'public.organizations', 'name', 'INSERT'
  ) OR pg_catalog.has_column_privilege(
    'water_management_onboarding', 'public.organizations', 'name', 'UPDATE'
  ) OR pg_catalog.has_table_privilege(
    'water_management_onboarding', 'public.organizations', 'DELETE'
  ) THEN
    RAISE EXCEPTION 'Onboarding owner organization grants are not least-privilege';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'water_management_private'
      AND p.proname = 'create_organization'
      AND pg_catalog.pg_get_userbyid(p.proowner) = 'water_management_onboarding'
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']
  ) THEN
    RAISE EXCEPTION 'Private onboarding implementation has an unexpected owner or function configuration';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'create_organization'
      AND p.prosecdef
  ) THEN
    RAISE EXCEPTION 'Public onboarding RPC must use SECURITY INVOKER';
  END IF;
  IF NOT pg_catalog.has_function_privilege(
    'authenticated', 'water_management_private.create_organization(text)', 'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon', 'water_management_private.create_organization(text)', 'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'service_role', 'water_management_private.create_organization(text)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Private onboarding function EXECUTE grants are incorrect';
  END IF;
  IF pg_catalog.has_column_privilege(
    'authenticated', 'public.profiles', 'organization_id', 'UPDATE'
  ) OR pg_catalog.has_column_privilege(
    'authenticated', 'public.profiles', 'role', 'UPDATE'
  ) OR pg_catalog.has_table_privilege(
    'authenticated', 'public.organizations', 'INSERT'
  ) THEN
    RAISE EXCEPTION 'Authenticated clients can directly change onboarding-protected fields';
  END IF;
END;
$private_schema_acl$;

DO $private_portal_rls$
BEGIN
  -- Defense in depth: all private portal tables must enforce RLS without
  -- introducing policies or direct client table access.
  IF (
    SELECT count(*)
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'water_management_private'
      AND c.relkind = 'r'
      AND c.relname IN (
        'subscriber_number_registry',
        'portal_rate_limit_secret',
        'portal_rate_limits'
      )
      AND c.relrowsecurity
  ) <> 3 THEN
    RAISE EXCEPTION 'RLS must be enabled on all three private portal tables';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.pg_policies
    WHERE schemaname = 'water_management_private'
      AND tablename IN (
        'subscriber_number_registry',
        'portal_rate_limit_secret',
        'portal_rate_limits'
      )
  ) THEN
    RAISE EXCEPTION 'Private portal tables must not have client-access policies';
  END IF;

  IF
    pg_catalog.has_table_privilege('anon', 'water_management_private.subscriber_number_registry', 'SELECT')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.subscriber_number_registry', 'INSERT')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.subscriber_number_registry', 'UPDATE')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.subscriber_number_registry', 'DELETE')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.subscriber_number_registry', 'SELECT')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.subscriber_number_registry', 'INSERT')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.subscriber_number_registry', 'UPDATE')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.subscriber_number_registry', 'DELETE')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.portal_rate_limit_secret', 'SELECT')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.portal_rate_limit_secret', 'INSERT')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.portal_rate_limit_secret', 'UPDATE')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.portal_rate_limit_secret', 'DELETE')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.portal_rate_limit_secret', 'SELECT')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.portal_rate_limit_secret', 'INSERT')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.portal_rate_limit_secret', 'UPDATE')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.portal_rate_limit_secret', 'DELETE')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.portal_rate_limits', 'SELECT')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.portal_rate_limits', 'INSERT')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.portal_rate_limits', 'UPDATE')
    OR pg_catalog.has_table_privilege('anon', 'water_management_private.portal_rate_limits', 'DELETE')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.portal_rate_limits', 'SELECT')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.portal_rate_limits', 'INSERT')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.portal_rate_limits', 'UPDATE')
    OR pg_catalog.has_table_privilege('authenticated', 'water_management_private.portal_rate_limits', 'DELETE')
  THEN
    RAISE EXCEPTION 'anon/authenticated must not have direct privileges on private portal tables';
  END IF;

  IF NOT pg_catalog.has_table_privilege(
       'service_role', 'water_management_private.portal_rate_limit_secret', 'SELECT'
     )
     OR NOT pg_catalog.has_table_privilege(
       'service_role', 'water_management_private.portal_rate_limits', 'SELECT'
     )
     OR NOT pg_catalog.has_table_privilege(
       'service_role', 'water_management_private.portal_rate_limits', 'INSERT'
     )
     OR NOT pg_catalog.has_table_privilege(
       'service_role', 'water_management_private.portal_rate_limits', 'UPDATE'
     )
     OR NOT pg_catalog.has_table_privilege(
       'service_role', 'water_management_private.portal_rate_limits', 'DELETE'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'water_management_private.subscriber_number_registry', 'SELECT'
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_roles
       WHERE rolname = 'service_role' AND rolbypassrls
     ) THEN
    RAISE EXCEPTION 'Trusted service_role grants/BYPASSRLS changed unexpectedly';
  END IF;
END;
$private_portal_rls$;

DROP FUNCTION water_management_private.default_acl_probe();

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

INSERT INTO public.subscribers (id, organization_id, pump_id, full_name, phone) VALUES
  ('30000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000001', 'مشترك أ 1', '+970599111111'),
  ('30000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000002', 'مشترك أ 2', '+970599111112'),
  ('30000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', NULL, 'مشترك أ دون غطاس', '+970599111113'),
  ('30000000-0000-4000-8000-000000000004', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '20000000-0000-4000-8000-000000000003', 'مشترك ب 1', '+970599111114');

-- The migrations run before the test fixtures are inserted. Explicitly create
-- the legacy-owner assignment for tenant B after both rows exist.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000006', true);
SELECT public.assign_subscriber_operator(
  '30000000-0000-4000-8000-000000000004',
  '10000000-0000-4000-8000-000000000007',
  'تهيئة مسؤول المشترك في اختبار المؤسسة ب'
);
RESET ROLE;

-- Establish the organization A subscriber owner before the RLS read matrix.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
SELECT public.assign_subscriber_operator(
  '30000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000002',
  'تهيئة مسؤول المشترك في اختبار المؤسسة أ'
);
RESET ROLE;

INSERT INTO public.branches (id, organization_id, pump_id, name, code, sort_order) VALUES
  ('40000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000001', 'تفرع أ 1', 'A-1', 0),
  ('40000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000002', 'تفرع أ 2', 'A-2', 0),
  ('40000000-0000-4000-8000-000000000003', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '20000000-0000-4000-8000-000000000003', 'تفرع ب 1', 'B-1', 0);

UPDATE public.subscribers SET branch_id = '40000000-0000-4000-8000-000000000001'
WHERE id = '30000000-0000-4000-8000-000000000001';
UPDATE public.subscribers SET branch_id = '40000000-0000-4000-8000-000000000002'
WHERE id = '30000000-0000-4000-8000-000000000002';
UPDATE public.subscribers SET branch_id = '40000000-0000-4000-8000-000000000003'
WHERE id = '30000000-0000-4000-8000-000000000004';

UPDATE public.subscribers SET weekly_quota_minutes=45, default_weekday=1
WHERE id='30000000-0000-4000-8000-000000000001';
UPDATE public.subscribers SET weekly_quota_minutes=60, default_weekday=3
WHERE id='30000000-0000-4000-8000-000000000002';
UPDATE public.subscribers SET weekly_quota_minutes=90, default_weekday=5
WHERE id='30000000-0000-4000-8000-000000000004';

INSERT INTO public.weekly_schedules (
  id, organization_id, pump_id, name, effective_from, effective_to, week_starts_on, status, created_by
) VALUES
  ('50000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '20000000-0000-4000-8000-000000000001', 'جدول أ 1', '2026-01-05', NULL, 1, 'draft',
   '10000000-0000-4000-8000-000000000001'),
  ('50000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '20000000-0000-4000-8000-000000000002', 'جدول أ 2', '2026-01-05', NULL, 1, 'draft',
   '10000000-0000-4000-8000-000000000001'),
  ('50000000-0000-4000-8000-000000000003', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   '20000000-0000-4000-8000-000000000003', 'جدول ب 1', '2026-01-05', NULL, 1, 'draft',
   '10000000-0000-4000-8000-000000000006');

INSERT INTO public.weekly_schedule_subscribers (
  weekly_schedule_id, organization_id, pump_id, subscriber_id,
  weekly_quota_minutes, default_weekday
) VALUES
  ('50000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 45, 1),
  ('50000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000002', '30000000-0000-4000-8000-000000000002', 60, 3),
  ('50000000-0000-4000-8000-000000000003', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '20000000-0000-4000-8000-000000000003', '30000000-0000-4000-8000-000000000004', 90, 5);

INSERT INTO public.schedule_entries (
  id, weekly_schedule_id, organization_id, pump_id, subscriber_id, weekday, sort_order, planned_minutes
) VALUES
  ('60000000-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000001',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000001',
   '30000000-0000-4000-8000-000000000001', 1, 10, 45),
  ('60000000-0000-4000-8000-000000000002', '50000000-0000-4000-8000-000000000002',
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', '20000000-0000-4000-8000-000000000002',
   '30000000-0000-4000-8000-000000000002', 3, 10, 60),
  ('60000000-0000-4000-8000-000000000003', '50000000-0000-4000-8000-000000000003',
   'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '20000000-0000-4000-8000-000000000003',
   '30000000-0000-4000-8000-000000000004', 5, 10, 90);

UPDATE public.weekly_schedules SET status='active'
WHERE id='50000000-0000-4000-8000-000000000003';

DO $weekly_active_unique$
DECLARE v_rejected boolean := false; v_duplicate_schedule_id uuid;
BEGIN
  BEGIN
    INSERT INTO public.weekly_schedules (
      organization_id, pump_id, name, effective_from, week_starts_on, status, created_by
    ) VALUES (
      'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      '20000000-0000-4000-8000-000000000003',
      'جدول نشط مكرر', '2026-01-05', 1, 'draft',
      '10000000-0000-4000-8000-000000000006'
    ) RETURNING id INTO v_duplicate_schedule_id;

    INSERT INTO public.weekly_schedule_subscribers (
      weekly_schedule_id, subscriber_id, weekly_quota_minutes, default_weekday
    ) VALUES (
      v_duplicate_schedule_id, '30000000-0000-4000-8000-000000000004', 90, 5
    );

    INSERT INTO public.schedule_entries (
      weekly_schedule_id, organization_id, pump_id, subscriber_id, weekday, sort_order, planned_minutes
    ) VALUES (
      v_duplicate_schedule_id, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      '20000000-0000-4000-8000-000000000003',
      '30000000-0000-4000-8000-000000000004', 5, 10, 90
    );
    UPDATE public.weekly_schedules SET status='active'
    WHERE id=v_duplicate_schedule_id;
  EXCEPTION WHEN unique_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A second active weekly schedule for the same pump was accepted';
  END IF;
END;
$weekly_active_unique$;

DO $subscriber_number_global$
DECLARE v_count bigint; v_distinct bigint; v_bad bigint;
BEGIN
  SELECT count(*), count(DISTINCT subscriber_number),
         count(*) FILTER (WHERE subscriber_number NOT BETWEEN 100000 AND 999999)
    INTO v_count, v_distinct, v_bad
  FROM public.subscribers;

  IF v_count <> 4 OR v_distinct <> v_count OR v_bad <> 0 THEN
    RAISE EXCEPTION 'Subscriber numbers are not six-digit and globally unique across organizations';
  END IF;

  IF (SELECT count(*) FROM water_management_private.subscriber_number_registry) <> v_count THEN
    RAISE EXCEPTION 'Subscriber number registry does not reserve every issued number';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.subscribers
    WHERE id='30000000-0000-4000-8000-000000000001'
      AND phone_normalized='0599111111'
  ) THEN
    RAISE EXCEPTION 'Palestinian international phone normalization failed';
  END IF;
END;
$subscriber_number_global$;

DO $subscriber_portal_privileges$
BEGIN
  IF pg_catalog.has_function_privilege('anon','public.lookup_subscriber_portal(integer,text,text)','EXECUTE')
     OR pg_catalog.has_function_privilege('authenticated','public.lookup_subscriber_portal(integer,text,text)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('service_role','public.lookup_subscriber_portal(integer,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Subscriber portal RPC must be executable by service_role only';
  END IF;

  IF pg_catalog.has_table_privilege('anon','public.subscribers','SELECT') THEN
    RAISE EXCEPTION 'Anonymous users must never read the subscribers table directly';
  END IF;

  IF pg_catalog.has_table_privilege('anon','water_management_private.portal_rate_limits','SELECT')
     OR pg_catalog.has_table_privilege('authenticated','water_management_private.portal_rate_limits','SELECT') THEN
    RAISE EXCEPTION 'Portal rate limit hashes must remain private';
  END IF;
END;
$subscriber_portal_privileges$;


CREATE SCHEMA test_support;
GRANT USAGE ON SCHEMA test_support TO authenticated;

CREATE FUNCTION test_support.assert_scope(
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
REVOKE ALL ON FUNCTION test_support.assert_scope(text, bigint, bigint, bigint, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION test_support.assert_scope(text, bigint, bigint, bigint, bigint, bigint) TO authenticated;

DO $branch_table_acl$
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid = 'public.branches'::regclass) THEN
    RAISE EXCEPTION 'RLS is not enabled on public.branches';
  END IF;
  IF pg_catalog.has_table_privilege('anon', 'public.branches', 'SELECT')
     OR pg_catalog.has_table_privilege('anon', 'public.branches', 'INSERT')
     OR pg_catalog.has_table_privilege('anon', 'public.branches', 'UPDATE')
     OR pg_catalog.has_table_privilege('anon', 'public.branches', 'DELETE') THEN
    RAISE EXCEPTION 'Anonymous access was granted to public.branches';
  END IF;
  IF NOT pg_catalog.has_table_privilege('authenticated', 'public.branches', 'SELECT')
     OR NOT pg_catalog.has_table_privilege('authenticated', 'public.branches', 'DELETE')
     OR pg_catalog.has_table_privilege('authenticated', 'public.branches', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.branches', 'UPDATE')
     OR NOT pg_catalog.has_column_privilege('authenticated', 'public.branches', 'pump_id', 'INSERT')
     OR NOT pg_catalog.has_column_privilege('authenticated', 'public.branches', 'name', 'INSERT')
     OR NOT pg_catalog.has_column_privilege('authenticated', 'public.branches', 'name', 'UPDATE')
     OR pg_catalog.has_column_privilege('authenticated', 'public.branches', 'organization_id', 'INSERT')
     OR pg_catalog.has_column_privilege('authenticated', 'public.branches', 'organization_id', 'UPDATE')
     OR pg_catalog.has_column_privilege('authenticated', 'public.branches', 'pump_id', 'UPDATE') THEN
    RAISE EXCEPTION 'Authenticated branch grants are not least-privilege column grants';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger t
    WHERE t.tgname = 'clear_subscriber_branches_before_pump_delete'
      AND t.tgrelid = 'public.pumps'::regclass
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'Pump deletion branch cleanup trigger is missing';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'water_management_private'
      AND p.proname = 'clear_subscriber_branches_before_pump_delete'
      AND (p.prosecdef OR NOT p.proconfig @> ARRAY['search_path=""'])
  ) THEN
    RAISE EXCEPTION 'Pump deletion cleanup trigger must be SECURITY INVOKER with an empty search_path';
  END IF;
  IF pg_catalog.has_function_privilege('authenticated', 'water_management_private.clear_subscriber_branches_before_pump_delete()', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'water_management_private.clear_subscriber_branches_before_pump_delete()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Private pump branch cleanup trigger function must not be executable from the Data API';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger t
    WHERE t.tgname = 'clear_subscriber_operator_assignments_before_pump_delete'
      AND t.tgrelid = 'public.pumps'::regclass
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'Pump deletion operator cleanup trigger is missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'water_management_private'
      AND p.proname = 'clear_subscriber_operator_assignments_before_pump_delete'
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']
      AND pg_catalog.pg_get_userbyid(p.proowner) = 'postgres'
  ) THEN
    RAISE EXCEPTION 'Pump operator cleanup trigger must be SECURITY DEFINER, postgres-owned, and pin an empty search_path';
  END IF;
  IF pg_catalog.has_function_privilege('authenticated', 'water_management_private.clear_subscriber_operator_assignments_before_pump_delete()', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'water_management_private.clear_subscriber_operator_assignments_before_pump_delete()', 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', 'water_management_private.clear_subscriber_operator_assignments_before_pump_delete()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Private pump operator cleanup trigger function must not be executable from the Data API';
  END IF;
END;
$branch_table_acl$;

DO $weekly_schedule_acl$
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.weekly_schedules'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.schedule_entries'::regclass) THEN
    RAISE EXCEPTION 'RLS is not enabled on both weekly schedule tables';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
    WHERE table_schema='public' AND table_name IN ('weekly_schedules','schedule_entries')
      AND grantee='anon'
  ) THEN
    RAISE EXCEPTION 'Anonymous table privileges were granted on weekly schedule tables';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.weekly_schedule_subscribers'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.weekly_schedule_events'::regclass)
     OR NOT pg_catalog.has_table_privilege('authenticated','public.weekly_schedule_subscribers','SELECT')
     OR NOT pg_catalog.has_table_privilege('authenticated','public.weekly_schedule_events','SELECT')
     OR pg_catalog.has_table_privilege('authenticated','public.weekly_schedule_subscribers','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.weekly_schedule_subscribers','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.weekly_schedule_subscribers','DELETE')
     OR pg_catalog.has_table_privilege('authenticated','public.weekly_schedule_events','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.weekly_schedule_events','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.weekly_schedule_events','DELETE') THEN
    RAISE EXCEPTION 'Versioned entitlements and schedule audit must be read-only through the Data API';
  END IF;

  IF pg_catalog.has_function_privilege('anon','public.save_weekly_schedule_draft(uuid,uuid,text,date,date,smallint,jsonb)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','public.activate_weekly_schedule(uuid)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','public.save_weekly_schedule_draft(uuid,uuid,text,date,date,smallint,jsonb)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','public.activate_weekly_schedule(uuid)','EXECUTE')
     OR pg_catalog.has_function_privilege('authenticated','water_management_private.prepare_weekly_schedule_subscriber_scope()','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','water_management_private.prepare_weekly_schedule_subscriber_scope()','EXECUTE') THEN
    RAISE EXCEPTION 'Weekly schedule save/activation RPCs and private trigger grants are not least-privileged';
  END IF;
  IF NOT pg_catalog.has_table_privilege('authenticated','public.weekly_schedules','SELECT')
     OR NOT pg_catalog.has_table_privilege('authenticated','public.weekly_schedules','DELETE')
     OR pg_catalog.has_table_privilege('authenticated','public.weekly_schedules','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.weekly_schedules','UPDATE')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.weekly_schedules','pump_id','INSERT')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.weekly_schedules','name','INSERT')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.weekly_schedules','name','UPDATE')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.weekly_schedules','effective_from','INSERT')
     OR pg_catalog.has_column_privilege('authenticated','public.weekly_schedules','organization_id','INSERT')
     OR pg_catalog.has_column_privilege('authenticated','public.weekly_schedules','created_by','INSERT')
     OR pg_catalog.has_column_privilege('authenticated','public.weekly_schedules','status','INSERT')
     OR pg_catalog.has_column_privilege('authenticated','public.weekly_schedules','status','UPDATE')
     OR pg_catalog.has_column_privilege('authenticated','public.weekly_schedules','pump_id','UPDATE') THEN
    RAISE EXCEPTION 'Weekly schedule grants do not enforce least-privilege columns';
  END IF;
  IF NOT pg_catalog.has_table_privilege('authenticated','public.schedule_entries','SELECT')
     OR NOT pg_catalog.has_table_privilege('authenticated','public.schedule_entries','DELETE')
     OR pg_catalog.has_table_privilege('authenticated','public.schedule_entries','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.schedule_entries','UPDATE')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.schedule_entries','weekly_schedule_id','INSERT')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.schedule_entries','subscriber_id','INSERT')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.schedule_entries','planned_minutes','UPDATE')
     OR pg_catalog.has_column_privilege('authenticated','public.schedule_entries','organization_id','INSERT')
     OR pg_catalog.has_column_privilege('authenticated','public.schedule_entries','pump_id','INSERT')
     OR pg_catalog.has_column_privilege('authenticated','public.schedule_entries','organization_id','UPDATE')
     OR pg_catalog.has_column_privilege('authenticated','public.schedule_entries','pump_id','UPDATE')
     OR pg_catalog.has_column_privilege('authenticated','public.schedule_entries','weekly_schedule_id','UPDATE') THEN
    RAISE EXCEPTION 'Schedule entry grants do not enforce derived tenant scope';
  END IF;
  IF pg_catalog.has_function_privilege('authenticated','water_management_private.prepare_schedule_entry_scope()','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','water_management_private.prepare_schedule_entry_scope()','EXECUTE') THEN
    RAISE EXCEPTION 'Clients can execute the private schedule entry trigger function';
  END IF;
  IF pg_catalog.has_function_privilege('authenticated','water_management_private.delete_organization_weekly_schedules()','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','water_management_private.delete_organization_weekly_schedules()','EXECUTE')
     OR pg_catalog.has_function_privilege('authenticated','water_management_private.delete_organization_daily_queues()','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','water_management_private.delete_organization_daily_queues()','EXECUTE')
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_trigger
       WHERE tgname='delete_organization_weekly_schedules'
         AND tgrelid='public.organizations'::regclass
         AND NOT tgisinternal
     )
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_trigger
       WHERE tgname='delete_organization_daily_queues'
         AND tgrelid='public.organizations'::regclass
         AND NOT tgisinternal
     ) THEN
    RAISE EXCEPTION 'Organization teardown must remove daily queues and weekly schedules through private triggers only';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='water_management_private'
      AND p.proname='prepare_schedule_entry_scope'
      AND NOT p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']
  ) THEN
    RAISE EXCEPTION 'Schedule entry scope trigger must be SECURITY INVOKER with an empty search_path';
  END IF;
END;
$weekly_schedule_acl$;

-- Manager A has organization-wide management visibility and can update their own pump.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
SELECT test_support.assert_scope('manager A', 1, 2, 3, 3, 5);
DO $manager_branch_scope$
BEGIN
  IF (SELECT count(*) FROM public.branches) <> 2 THEN
    RAISE EXCEPTION 'Manager A must read all branches within organization A only';
  END IF;
  IF EXISTS (SELECT 1 FROM public.branches WHERE organization_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') THEN
    RAISE EXCEPTION 'Manager A read a branch from organization B';
  END IF;
END;
$manager_branch_scope$;
DO $manager_weekly_schedule_scope$
BEGIN
  IF (SELECT count(*) FROM public.weekly_schedules) <> 2
     OR EXISTS (SELECT 1 FROM public.weekly_schedules WHERE organization_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') THEN
    RAISE EXCEPTION 'Manager A must see only the schedules in organization A';
  END IF;
  IF (SELECT count(*) FROM public.schedule_entries) <> 2 THEN
    RAISE EXCEPTION 'Manager A must see the entries for both organization A pumps';
  END IF;
END;
$manager_weekly_schedule_scope$;
DO $subscriber_number_immutable$
DECLARE v_rejected boolean := false;
BEGIN
  BEGIN
    UPDATE public.subscribers
    SET subscriber_number = CASE
      WHEN subscriber_number = 999999 THEN 999998 ELSE subscriber_number + 1
    END
    WHERE id = '30000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN raise_exception THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A manager changed an immutable global subscriber number';
  END IF;
END;
$subscriber_number_immutable$;
SET CONSTRAINTS pump_assignments_user_tenant_role_fkey IMMEDIATE;
DO $manager_a_write$
DECLARE v_rows bigint; v_branch_id uuid;
BEGIN
  UPDATE public.pumps SET status = 'paused'
  WHERE id = '20000000-0000-4000-8000-000000000001';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'Manager could not update an organization pump'; END IF;
  UPDATE public.pumps SET status = 'active'
  WHERE id = '20000000-0000-4000-8000-000000000001';

  INSERT INTO public.branches (pump_id, name, code, sort_order)
  VALUES ('20000000-0000-4000-8000-000000000001', 'تفرع مؤقت', 'TEMP', 9)
  RETURNING id INTO v_branch_id;
  UPDATE public.branches SET name = 'تفرع مؤقت معدل'
  WHERE id = v_branch_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN RAISE EXCEPTION 'Manager could not update a branch in their organization'; END IF;
  DELETE FROM public.branches WHERE id = v_branch_id;

  INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
  VALUES ('20000000-0000-4000-8000-000000000002',
          '10000000-0000-4000-8000-000000000003',
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'operator');
  DELETE FROM public.pump_assignments
  WHERE pump_id = '20000000-0000-4000-8000-000000000002'
    AND user_id = '10000000-0000-4000-8000-000000000003'
    AND assignment_role = 'operator';
END;
$manager_a_write$;

DO $manager_weekly_schedule_write$
DECLARE
  v_schedule_id uuid;
  v_rows bigint;
  v_entry_count bigint;
  v_total_minutes integer;
BEGIN
  v_schedule_id := public.save_weekly_schedule_draft(
    NULL,
    '20000000-0000-4000-8000-000000000001',
    'مسودة اختبار مدير',
    DATE '2026-11-02',
    DATE '2026-12-31',
    1::smallint,
    jsonb_build_array(jsonb_build_object(
      'subscriber_id', '30000000-0000-4000-8000-000000000001',
      'weekly_quota_minutes', 35,
      'default_weekday', 2,
      'allocations', jsonb_build_array(
        jsonb_build_object('weekday', 2, 'planned_minutes', 20),
        jsonb_build_object('weekday', 4, 'planned_minutes', 15)
      )
    ))
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.weekly_schedules
    WHERE id=v_schedule_id
      AND organization_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      AND pump_id='20000000-0000-4000-8000-000000000001'
      AND created_by='10000000-0000-4000-8000-000000000001'
      AND status='draft'
  ) THEN RAISE EXCEPTION 'Weekly schedule tenant, creator, or draft status was not derived safely'; END IF;

  SELECT count(*), sum(e.planned_minutes)::integer
  INTO v_entry_count, v_total_minutes
  FROM public.schedule_entries e
  WHERE e.weekly_schedule_id=v_schedule_id
    AND e.subscriber_id='30000000-0000-4000-8000-000000000001';
  IF v_entry_count <> 2 OR v_total_minutes <> 35 THEN
    RAISE EXCEPTION 'Weekly draft RPC did not preserve the multi-day split exactly';
  END IF;

  IF (SELECT weekly_quota_minutes FROM public.subscribers
      WHERE id='30000000-0000-4000-8000-000000000001') <> 45 THEN
    RAISE EXCEPTION 'Saving a draft must not change the current active subscriber quota';
  END IF;

  PERFORM public.save_weekly_schedule_draft(
    v_schedule_id,
    '20000000-0000-4000-8000-000000000001',
    'مسودة اختبار مدير معدلة',
    DATE '2026-11-02',
    DATE '2027-01-31',
    1::smallint,
    jsonb_build_array(jsonb_build_object(
      'subscriber_id', '30000000-0000-4000-8000-000000000001',
      'weekly_quota_minutes', 35,
      'default_weekday', 2,
      'allocations', jsonb_build_array(
        jsonb_build_object('weekday', 3, 'planned_minutes', 35)
      )
    ))
  );

  IF NOT EXISTS (
    SELECT 1 FROM public.weekly_schedules
    WHERE id=v_schedule_id AND name='مسودة اختبار مدير معدلة' AND effective_to=DATE '2027-01-31'
  ) OR EXISTS (
    SELECT 1 FROM public.schedule_entries
    WHERE weekly_schedule_id=v_schedule_id AND weekday=2
  ) THEN
    RAISE EXCEPTION 'Saving an existing draft did not replace its allocation snapshot atomically';
  END IF;

  DELETE FROM public.weekly_schedules WHERE id=v_schedule_id;
  IF EXISTS (SELECT 1 FROM public.weekly_schedule_subscribers WHERE weekly_schedule_id=v_schedule_id)
     OR EXISTS (SELECT 1 FROM public.schedule_entries WHERE weekly_schedule_id=v_schedule_id) THEN
    RAISE EXCEPTION 'Deleting a draft schedule did not cascade its entitlement snapshots and entries';
  END IF;
END;
$manager_weekly_schedule_write$;

DO $weekly_schedule_activation$
DECLARE
  v_today date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date;
  v_cycle_start date;
  v_next_cycle_start date;
  v_current_schedule_id uuid;
  v_future_schedule_id uuid;
  v_previous_quota integer;
  v_invalid_rejected boolean := false;
  v_rejected boolean := false;
BEGIN
  v_cycle_start := v_today - (extract(isodow FROM v_today)::integer - 1);
  v_next_cycle_start := v_cycle_start + 7;
  v_previous_quota := (SELECT weekly_quota_minutes FROM public.subscribers
    WHERE id='30000000-0000-4000-8000-000000000002');

  BEGIN
    PERFORM public.save_weekly_schedule_draft(
      NULL,
      '20000000-0000-4000-8000-000000000002',
      'جدول غير متوازن',
      v_cycle_start,
      NULL,
    1::smallint,
      jsonb_build_array(jsonb_build_object(
        'subscriber_id','30000000-0000-4000-8000-000000000002',
        'weekly_quota_minutes',55,
        'default_weekday',3,
        'allocations',jsonb_build_array(
          jsonb_build_object('weekday',3,'planned_minutes',54)
        )
      ))
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_invalid_rejected := true;
  END;
  IF NOT v_invalid_rejected THEN
    RAISE EXCEPTION 'A draft with a weekday allocation sum different from the weekly quota was accepted';
  END IF;

  v_current_schedule_id := public.save_weekly_schedule_draft(
    NULL,
    '20000000-0000-4000-8000-000000000002',
    'جدول مشترك ب 2 الحالي',
    v_cycle_start,
    NULL,
    1::smallint,
    jsonb_build_array(jsonb_build_object(
      'subscriber_id','30000000-0000-4000-8000-000000000002',
      'weekly_quota_minutes',55,
      'default_weekday',3,
      'allocations',jsonb_build_array(
        jsonb_build_object('weekday',3,'planned_minutes',25),
        jsonb_build_object('weekday',5,'planned_minutes',30)
      )
    ))
  );

  IF (SELECT weekly_quota_minutes FROM public.subscribers
      WHERE id='30000000-0000-4000-8000-000000000002') IS DISTINCT FROM v_previous_quota THEN
    RAISE EXCEPTION 'Saving a draft changed the current subscriber quota before activation';
  END IF;

  PERFORM public.activate_weekly_schedule(v_current_schedule_id);

  IF NOT EXISTS (
    SELECT 1 FROM public.weekly_schedules
    WHERE id=v_current_schedule_id AND status='active'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.subscribers
    WHERE id='30000000-0000-4000-8000-000000000002'
      AND weekly_quota_minutes=55 AND default_weekday=3
  ) THEN
    RAISE EXCEPTION 'Activating the current-cycle schedule did not set the in-force subscriber quota';
  END IF;

  v_future_schedule_id := public.save_weekly_schedule_draft(
    NULL,
    '20000000-0000-4000-8000-000000000002',
    'جدول مشترك ب 2 القادم',
    v_next_cycle_start,
    NULL,
    1::smallint,
    jsonb_build_array(jsonb_build_object(
      'subscriber_id','30000000-0000-4000-8000-000000000002',
      'weekly_quota_minutes',70,
      'default_weekday',2,
      'allocations',jsonb_build_array(
        jsonb_build_object('weekday',2,'planned_minutes',40),
        jsonb_build_object('weekday',6,'planned_minutes',30)
      )
    ))
  );

  PERFORM set_config('test.weekly_current_schedule_id', v_current_schedule_id::text, true);
  PERFORM set_config('test.weekly_future_schedule_id', v_future_schedule_id::text, true);

  PERFORM public.activate_weekly_schedule(v_future_schedule_id);

  IF NOT EXISTS (
    SELECT 1 FROM public.weekly_schedules
    WHERE id=v_current_schedule_id
      AND status='archived'
      AND effective_to=v_next_cycle_start - 1
  ) OR NOT EXISTS (
    SELECT 1 FROM public.weekly_schedule_subscribers
    WHERE weekly_schedule_id=v_current_schedule_id
      AND subscriber_id='30000000-0000-4000-8000-000000000002'
      AND weekly_quota_minutes=55
  ) OR NOT EXISTS (
    SELECT 1 FROM public.weekly_schedules
    WHERE id=v_future_schedule_id AND status='active'
  ) THEN
    RAISE EXCEPTION 'Weekly rotation did not archive the prior version and preserve its quota snapshot';
  END IF;

  IF (SELECT weekly_quota_minutes FROM public.subscribers
      WHERE id='30000000-0000-4000-8000-000000000002') <> 55 THEN
    RAISE EXCEPTION 'Activating a future schedule prematurely changed the current weekly subscriber quota';
  END IF;

  SELECT count(*) INTO v_previous_quota
  FROM public.weekly_schedule_events
  WHERE weekly_schedule_id IN (v_current_schedule_id, v_future_schedule_id)
    AND event_type IN ('draft_created','activated','archived');
  IF v_previous_quota <> 5 THEN
    RAISE EXCEPTION 'Weekly schedule audit events were not recorded for draft creation and rotation';
  END IF;
END;
$weekly_schedule_activation$;

DO $manager_a_negative$
DECLARE v_rejected boolean;
BEGIN
  v_rejected := false;
  BEGIN
    INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
    VALUES ('20000000-0000-4000-8000-000000000002',
            '10000000-0000-4000-8000-000000000007',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'operator');
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Cross-organization assignment INSERT was not rejected'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.subscribers (organization_id, pump_id, full_name, phone)
    VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            '20000000-0000-4000-8000-000000000003', 'مشترك عابر للمؤسسات', '0590000000');
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
    INSERT INTO public.branches (pump_id, name, code)
    VALUES ('20000000-0000-4000-8000-000000000003', 'تفرع عابر', 'CROSS');
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Cross-organization branch INSERT was not rejected'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.branches (organization_id, pump_id, name)
    VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            '20000000-0000-4000-8000-000000000003', 'تفرع بمؤسسة خارج النطاق');
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Manager was allowed to supply an organization_id for branch creation'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.branches SET pump_id = '20000000-0000-4000-8000-000000000002'
    WHERE id = '40000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Manager was allowed to move a branch to another pump'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.subscribers SET branch_id = '40000000-0000-4000-8000-000000000001'
    WHERE id = '30000000-0000-4000-8000-000000000002';
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Subscriber was assigned to a branch belonging to another pump'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.subscribers SET branch_id = '40000000-0000-4000-8000-000000000001'
    WHERE id = '30000000-0000-4000-8000-000000000003';
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Subscriber without a pump was assigned to a branch'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.pump_assignments
    SET pump_id = '20000000-0000-4000-8000-000000000002',
        user_id = '10000000-0000-4000-8000-000000000007'
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
            '10000000-0000-4000-8000-000000000002',
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'operator');
  EXCEPTION WHEN unique_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'The same operator was assigned twice to one pump';
  END IF;

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

  v_rejected := false;
  BEGIN
    UPDATE public.profiles
    SET organization_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    WHERE id = (SELECT auth.uid());
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Client-side organization reassignment was not rejected'; END IF;
END;
$manager_a_negative$;

DO $manager_weekly_schedule_negative$
DECLARE v_rejected boolean := false;
BEGIN
  BEGIN
    INSERT INTO public.weekly_schedules (pump_id, name, effective_from, week_starts_on)
    VALUES ('20000000-0000-4000-8000-000000000003', 'جدول عابر', '2026-11-01', 7);
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Manager A created a schedule for a pump in another organization'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.weekly_schedules (organization_id, pump_id, name, effective_from, week_starts_on)
    VALUES ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '20000000-0000-4000-8000-000000000003', 'جدول بنطاق مزور', '2026-11-01', 7);
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Manager A supplied organization_id while creating a schedule'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.weekly_schedules SET pump_id='20000000-0000-4000-8000-000000000002'
    WHERE id='50000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Manager changed weekly schedule pump_id'; END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.weekly_schedules SET status='active'
    WHERE id='50000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Manager activated a schedule outside the guarded publish RPC'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.schedule_entries (weekly_schedule_id, subscriber_id, weekday, sort_order, planned_minutes)
    VALUES ('50000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002', 1, 20, 45);
  EXCEPTION WHEN foreign_key_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Schedule entry linked a subscriber from another pump'; END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.schedule_entries (weekly_schedule_id, organization_id, pump_id, subscriber_id, weekday, sort_order, planned_minutes)
    VALUES ('50000000-0000-4000-8000-000000000001',
            'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '20000000-0000-4000-8000-000000000003',
            '30000000-0000-4000-8000-000000000004', 1, 20, 45);
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Client supplied schedule entry tenant scope'; END IF;
END;
$manager_weekly_schedule_negative$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $operator_branch_scope$
DECLARE v_rows bigint; v_rejected boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.branches) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = '40000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Operator A must read only the branch on the assigned pump';
  END IF;
  UPDATE public.branches SET name = 'تعديل ممنوع'
  WHERE id = '40000000-0000-4000-8000-000000000001';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'Operator updated a branch'; END IF;
  BEGIN
    INSERT INTO public.branches (pump_id, name)
    VALUES ('20000000-0000-4000-8000-000000000001', 'فرع من المشغل');
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Operator inserted a branch without manager permission'; END IF;
END;
$operator_branch_scope$;
DO $operator_schedule_scope$
BEGIN
  IF (SELECT count(*) FROM public.weekly_schedules) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.weekly_schedules WHERE id='50000000-0000-4000-8000-000000000001')
     OR (SELECT count(*) FROM public.schedule_entries) <> 1 THEN
    RAISE EXCEPTION 'Operator A must read only the weekly schedule and entries for the assigned pump';
  END IF;
END;
$operator_schedule_scope$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000004', true);
DO $collector_branch_scope$
BEGIN
  IF (SELECT count(*) FROM public.branches) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = '40000000-0000-4000-8000-000000000002') THEN
    RAISE EXCEPTION 'Collector A must read only the branch on the assigned pump';
  END IF;
END;
$collector_branch_scope$;
DO $collector_schedule_scope$
BEGIN
  IF (SELECT count(*) FROM public.weekly_schedules) <> 3
     OR NOT EXISTS (SELECT 1 FROM public.weekly_schedules WHERE id='50000000-0000-4000-8000-000000000002')
     OR NOT EXISTS (
       SELECT 1 FROM public.weekly_schedules
       WHERE id=current_setting('test.weekly_current_schedule_id')::uuid
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.weekly_schedules
       WHERE id=current_setting('test.weekly_future_schedule_id')::uuid
     )
     OR (SELECT count(*) FROM public.schedule_entries) <> 5
     OR (SELECT count(*) FROM public.weekly_schedule_subscribers) <> 3 THEN
    RAISE EXCEPTION 'Collector A must read only the historical, current, and future versions for the assigned pump';
  END IF;
END;
$collector_schedule_scope$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);
DO $supervisor_branch_scope$
BEGIN
  IF (SELECT count(*) FROM public.branches) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = '40000000-0000-4000-8000-000000000001') THEN
    RAISE EXCEPTION 'Supervisor A must read only the branch on the assigned pump';
  END IF;
END;
$supervisor_branch_scope$;
DO $supervisor_schedule_scope$
BEGIN
  IF (SELECT count(*) FROM public.weekly_schedules) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.weekly_schedules WHERE id='50000000-0000-4000-8000-000000000001')
     OR (SELECT count(*) FROM public.schedule_entries) <> 1 THEN
    RAISE EXCEPTION 'Supervisor A must read only the schedule and entries for the assigned pump';
  END IF;
END;
$supervisor_schedule_scope$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000007', true);
DO $tenant_b_branch_scope$
BEGIN
  IF (SELECT count(*) FROM public.branches) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.branches WHERE id = '40000000-0000-4000-8000-000000000003') THEN
    RAISE EXCEPTION 'Tenant B operator must read only its own assigned-pump branch';
  END IF;
END;
$tenant_b_branch_scope$;
DO $tenant_b_schedule_scope$
BEGIN
  IF (SELECT count(*) FROM public.weekly_schedules) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.weekly_schedules WHERE id='50000000-0000-4000-8000-000000000003')
     OR (SELECT count(*) FROM public.schedule_entries) <> 1 THEN
    RAISE EXCEPTION 'Tenant B operator must read only its own pump weekly schedule and entries';
  END IF;
END;
$tenant_b_schedule_scope$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DO $tenant_a_branch_scope$
BEGIN
  IF EXISTS (SELECT 1 FROM public.branches WHERE id = '40000000-0000-4000-8000-000000000003') THEN
    RAISE EXCEPTION 'Tenant A manager read a branch from tenant B';
  END IF;
END;
$tenant_a_branch_scope$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000006', true);
DO $manager_b_active_schedule$
DECLARE v_rows bigint; v_rejected boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.weekly_schedules) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.weekly_schedules WHERE id='50000000-0000-4000-8000-000000000003' AND status='active') THEN
    RAISE EXCEPTION 'Manager B must read the active schedule in organization B';
  END IF;
  UPDATE public.weekly_schedules SET name='تغيير غير مسموح' WHERE id='50000000-0000-4000-8000-000000000003';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'Manager updated an active weekly schedule'; END IF;
  DELETE FROM public.weekly_schedules WHERE id='50000000-0000-4000-8000-000000000003';
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 0 THEN RAISE EXCEPTION 'Manager deleted an active weekly schedule'; END IF;
  BEGIN
    INSERT INTO public.schedule_entries (weekly_schedule_id,subscriber_id,weekday,sort_order,planned_minutes)
    VALUES ('50000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000004',6,20,50);
  EXCEPTION WHEN insufficient_privilege THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'Manager inserted an entry into an active schedule'; END IF;
END;
$manager_b_active_schedule$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
SELECT test_support.assert_scope('operator A', 1, 1, 1, 1, 1);
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
SELECT test_support.assert_scope('unassigned employee A', 1, 0, 0, 0, 1);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000004', true);
SELECT test_support.assert_scope('collector A', 1, 1, 1, 1, 1);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);
SELECT test_support.assert_scope('supervisor A', 1, 1, 1, 1, 1);
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

-- A collector may share a pump with other collectors; an employee still
-- cannot be duplicated for the same pump and role.
UPDATE public.profiles
SET role = 'collector'::public.app_role
WHERE id = '10000000-0000-4000-8000-000000000003';

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
VALUES (
  '20000000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000003',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'collector'
);
DO $multiple_collectors$
DECLARE v_count bigint; v_rejected boolean := false;
BEGIN
  SELECT count(*) INTO v_count FROM public.pump_assignments
  WHERE pump_id = '20000000-0000-4000-8000-000000000002'
    AND assignment_role = 'collector';
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'A pump must allow multiple distinct collectors';
  END IF;

  BEGIN
    INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
    VALUES (
      '20000000-0000-4000-8000-000000000002',
      '10000000-0000-4000-8000-000000000003',
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'collector'
    );
  EXCEPTION WHEN unique_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'The same collector was assigned twice to one pump';
  END IF;
END;
$multiple_collectors$;
SELECT test_support.assert_scope('manager A after multiple collectors', 1, 2, 3, 4, 5);
RESET ROLE;

-- The same fixture account is reused for operator coverage later in the suite.
DELETE FROM public.pump_assignments
WHERE user_id = '10000000-0000-4000-8000-000000000003'
  AND pump_id = '20000000-0000-4000-8000-000000000002'
  AND assignment_role = 'collector';
UPDATE public.profiles
SET role = 'operator'::public.app_role
WHERE id = '10000000-0000-4000-8000-000000000003';

-- Operation RPC access is scoped to the actor, organization, and pump.
DO $power_source_acl$
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.pump_power_sources'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.pump_operation_power_segments'::regclass) THEN
    RAISE EXCEPTION 'RLS must be enabled on power sources and operation segments';
  END IF;
  IF pg_catalog.has_table_privilege('anon','public.pump_power_sources','SELECT')
     OR pg_catalog.has_table_privilege('anon','public.pump_power_sources','INSERT')
     OR pg_catalog.has_table_privilege('anon','public.pump_operation_power_segments','SELECT')
     OR pg_catalog.has_table_privilege('authenticated','public.pump_operation_power_segments','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.pump_operation_power_segments','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.pump_operation_power_segments','DELETE') THEN
    RAISE EXCEPTION 'Power source or segment privileges are too broad';
  END IF;
  IF NOT pg_catalog.has_table_privilege('authenticated','public.pump_power_sources','SELECT')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.pump_power_sources','pump_id','INSERT')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.pump_power_sources','name','INSERT')
     OR NOT pg_catalog.has_column_privilege('authenticated','public.pump_power_sources','source_type','INSERT')
     OR pg_catalog.has_column_privilege('authenticated','public.pump_power_sources','organization_id','INSERT')
     OR pg_catalog.has_column_privilege('authenticated','public.pump_power_sources','pump_id','UPDATE')
     OR pg_catalog.has_column_privilege('authenticated','public.pump_power_sources','organization_id','UPDATE') THEN
    RAISE EXCEPTION 'Power source column grants do not protect tenant scope';
  END IF;
  IF (SELECT count(*) FROM public.pump_power_sources) <> 9 THEN
    RAISE EXCEPTION 'Three default electricity sources must be seeded for each test pump';
  END IF;
  IF NOT pg_catalog.has_function_privilege('authenticated','public.get_pump_power_usage(date,date,text,uuid)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','public.get_pump_power_usage(date,date,text,uuid)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','public.get_daily_work_report_allocations(uuid,date)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','public.get_daily_work_report_allocations(uuid,date)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','public.get_daily_report_operators(uuid,date,boolean)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','public.get_daily_report_operators(uuid,date,boolean)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','water_management_private.get_daily_report_operators_internal(uuid,date,boolean)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','water_management_private.get_daily_report_operators_internal(uuid,date,boolean)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','public.prepare_daily_work_report(uuid,date)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','public.prepare_daily_work_report(uuid,date)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','water_management_private.prepare_daily_work_report_internal(uuid,date)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','water_management_private.prepare_daily_work_report_internal(uuid,date)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','water_management_private.get_daily_work_report_allocations_internal(uuid,date)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','water_management_private.get_daily_work_report_allocations_internal(uuid,date)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','water_management_private.save_daily_work_report_internal(uuid,uuid,timestamptz,timestamptz,integer,jsonb,jsonb,boolean,uuid)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','water_management_private.save_daily_work_report_internal(uuid,uuid,timestamptz,timestamptz,integer,jsonb,jsonb,boolean,uuid)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','public.save_daily_work_report(uuid,uuid,timestamptz,timestamptz,integer,jsonb,jsonb,boolean,uuid)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','public.save_daily_work_report(uuid,uuid,timestamptz,timestamptz,integer,jsonb,jsonb,boolean,uuid)','EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated','public.save_daily_work_report(uuid,timestamptz,timestamptz,integer,jsonb,jsonb,boolean,uuid)','EXECUTE')
     OR pg_catalog.has_function_privilege('anon','public.save_daily_work_report(uuid,timestamptz,timestamptz,integer,jsonb,jsonb,boolean,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'Power usage and daily report RPC grants are incorrect';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_catalog.pg_proc
          WHERE oid='water_management_private.start_pump_operation_internal(uuid,uuid,text,integer,uuid)'::regprocedure)
     OR NOT (SELECT prosecdef FROM pg_catalog.pg_proc
          WHERE oid='water_management_private.resume_pump_operation_internal(uuid,uuid)'::regprocedure)
     OR (SELECT prosecdef FROM pg_catalog.pg_proc
          WHERE oid='public.start_pump_operation(uuid,uuid,text,integer,uuid)'::regprocedure)
     OR (SELECT prosecdef FROM pg_catalog.pg_proc
          WHERE oid='public.resume_pump_operation(uuid,uuid)'::regprocedure) THEN
    RAISE EXCEPTION 'Power-aware lifecycle RPC security modes are incorrect';
  END IF;
END;
$power_source_acl$;

DO $pump_operation_acl$
BEGIN
  IF NOT pg_catalog.has_table_privilege('authenticated', 'public.pump_operations', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.pump_operations', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.pump_operations', 'UPDATE')
     OR pg_catalog.has_table_privilege('authenticated', 'public.pump_operations', 'DELETE')
     OR pg_catalog.has_table_privilege('anon', 'public.pump_operations', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.pump_operations', 'INSERT') THEN
    RAISE EXCEPTION 'Pump operation table privileges are not least-privilege';
  END IF;
  IF NOT pg_catalog.has_table_privilege('authenticated', 'public.pump_operation_events', 'SELECT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.pump_operation_events', 'INSERT')
     OR pg_catalog.has_table_privilege('authenticated', 'public.pump_operation_events', 'UPDATE')
     OR pg_catalog.has_table_privilege('authenticated', 'public.pump_operation_events', 'DELETE')
     OR pg_catalog.has_table_privilege('anon', 'public.pump_operation_events', 'SELECT')
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_class c
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = 'pump_operation_events' AND c.relrowsecurity
     ) THEN
    RAISE EXCEPTION 'Operation event ledger access or RLS is not least-privilege';
  END IF;
  IF pg_catalog.has_column_privilege('authenticated', 'public.pump_operations', 'started_at', 'INSERT')
     OR pg_catalog.has_column_privilege('authenticated', 'public.pump_operations', 'operator_id', 'UPDATE')
     OR pg_catalog.has_column_privilege('authenticated', 'public.pump_operations', 'started_at', 'UPDATE')
     OR pg_catalog.has_column_privilege('authenticated', 'public.pump_operations', 'status', 'UPDATE')
     OR pg_catalog.has_column_privilege('authenticated', 'public.pump_operations', 'paused_at', 'UPDATE')
     OR pg_catalog.has_column_privilege('authenticated', 'public.pump_operations', 'organization_id', 'INSERT')
     OR pg_catalog.has_column_privilege('authenticated', 'public.pump_operations', 'pump_id', 'INSERT')
     OR pg_catalog.has_column_privilege('authenticated', 'public.pump_operations', 'operator_id', 'INSERT')
     OR pg_catalog.has_column_privilege('authenticated', 'public.pump_operations', 'planned_minutes', 'INSERT') THEN
    RAISE EXCEPTION 'Clients can directly forge operation identity, timestamps, or insert sessions';
  END IF;
  IF NOT pg_catalog.has_function_privilege('authenticated', 'public.start_pump_operation(uuid,uuid,text,integer,uuid)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'public.pause_pump_operation(uuid,text)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'public.resume_pump_operation(uuid,uuid)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'public.complete_pump_operation(uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.start_pump_operation(uuid,uuid,text,integer,uuid)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'water_management_private.start_pump_operation_internal(uuid,uuid,text,integer,uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'water_management_private.start_pump_operation_internal(uuid,uuid,text,integer,uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.pause_pump_operation(uuid,text)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.resume_pump_operation(uuid,uuid)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.complete_pump_operation(uuid)', 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege('authenticated', 'public.get_pump_operations_dashboard(date,date)', 'EXECUTE')
     OR pg_catalog.has_function_privilege('anon', 'public.get_pump_operations_dashboard(date,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Pump operation RPC grants are incorrect';
  END IF;
  IF (SELECT prosecdef FROM pg_catalog.pg_proc
      WHERE oid = 'public.start_pump_operation(uuid,uuid,text,integer,uuid)'::regprocedure) THEN
    RAISE EXCEPTION 'Exposed start operation endpoint must remain SECURITY INVOKER';
  END IF;
  IF NOT (SELECT prosecdef FROM pg_catalog.pg_proc
      WHERE oid = 'water_management_private.start_pump_operation_internal(uuid,uuid,text,integer,uuid)'::regprocedure)
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_proc p
       WHERE p.oid = 'water_management_private.start_pump_operation_internal(uuid,uuid,text,integer,uuid)'::regprocedure
         AND p.proconfig @> ARRAY['search_path=""']
     ) THEN
    RAISE EXCEPTION 'Private start operation implementation is not hardened SECURITY DEFINER';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('pause_pump_operation', 'resume_pump_operation', 'complete_pump_operation')
      AND p.prosecdef
  ) THEN
    RAISE EXCEPTION 'Exposed operation RPC endpoints must remain SECURITY INVOKER';
  END IF;
  IF (
    SELECT count(*) FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'water_management_private'
      AND p.proname IN (
        'pause_pump_operation_internal',
        'resume_pump_operation_internal',
        'complete_pump_operation_internal'
      )
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']
  ) <> 3 THEN
    RAISE EXCEPTION 'Private operation lifecycle implementations are not hardened SECURITY DEFINER functions';
  END IF;
  IF NOT pg_catalog.has_function_privilege(
       'authenticated', 'water_management_private.pause_pump_operation_internal(uuid,text)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'water_management_private.resume_pump_operation_internal(uuid,uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'water_management_private.complete_pump_operation_internal(uuid)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'water_management_private.pause_pump_operation_internal(uuid,text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Private operation lifecycle RPC execution grants are incorrect';
  END IF;
END;
$pump_operation_acl$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DO $manager_operation_lifecycle$
DECLARE
  v_operation public.pump_operations%ROWTYPE;
  v_event_types text[];
  v_dashboard jsonb;
  v_power_source_id uuid;
  v_other_source_id uuid;
  v_rejected boolean := false;
BEGIN
  SELECT id INTO v_power_source_id
  FROM public.pump_power_sources
  WHERE pump_id='20000000-0000-4000-8000-000000000001'
    AND name='طاقة شمسية – مزود 1';
  IF v_power_source_id IS NULL THEN RAISE EXCEPTION 'Default source 1 was not seeded'; END IF;

  SELECT id INTO v_other_source_id
  FROM public.pump_power_sources
  WHERE pump_id='20000000-0000-4000-8000-000000000003'
    AND name='طاقة شمسية – مزود 1';
  v_rejected := false;
  BEGIN
    PERFORM public.start_pump_operation(
      '20000000-0000-4000-8000-000000000001',
      '30000000-0000-4000-8000-000000000001',
      NULL, 10, v_other_source_id
    );
  EXCEPTION WHEN invalid_parameter_value THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'A source belonging to another pump was accepted'; END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.start_pump_operation(
      '20000000-0000-4000-8000-000000000001',
      '30000000-0000-4000-8000-000000000001',
      NULL, 10, NULL
    );
  EXCEPTION WHEN invalid_parameter_value THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'An operation started without a power source'; END IF;

  -- Managers cannot start registered subscribers until a single responsible
  -- operator is assigned; otherwise historical operation ownership is ambiguous.
  v_rejected := false;
  SELECT id INTO v_other_source_id
  FROM public.pump_power_sources
  WHERE pump_id = '20000000-0000-4000-8000-000000000002'
    AND organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    AND is_active
  ORDER BY created_at
  LIMIT 1;
  IF v_other_source_id IS NULL THEN
    RAISE EXCEPTION 'Pump 2 fixture requires an active power source';
  END IF;
  BEGIN
    PERFORM public.start_pump_operation(
      '20000000-0000-4000-8000-000000000002',
      '30000000-0000-4000-8000-000000000002',
      NULL, 5, v_other_source_id
    );
  EXCEPTION WHEN foreign_key_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Manager started a registered subscriber without a responsible operator';
  END IF;

  SELECT * INTO v_operation
  FROM public.start_pump_operation(
    '20000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000001',
    NULL,
    10,
    v_power_source_id
  );
  IF v_operation.status <> 'running' OR v_operation.operator_id <> auth.uid() THEN
    RAISE EXCEPTION 'Manager could not start a pump operation as the authenticated actor';
  END IF;

  -- A different, correctly assigned operator still cannot extend a manager-owned session.
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
  v_rejected := false;
  BEGIN
    PERFORM public.extend_pump_operation_time(v_operation.id, 1);
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  PERFORM set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An operator extended a session started by a different user';
  END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.pump_operations (
      organization_id, pump_id, subscriber_name, operator_id, planned_minutes
    ) VALUES (
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      '20000000-0000-4000-8000-000000000001',
      'محاولة إدخال مباشر',
      auth.uid(),
      5
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Authenticated manager directly inserted a pump operation outside the RPC';
  END IF;

  BEGIN
    PERFORM public.start_pump_operation(
      '20000000-0000-4000-8000-000000000001',
      '30000000-0000-4000-8000-000000000001',
      NULL,
      10,
      v_power_source_id
    );
  EXCEPTION WHEN unique_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A second active operation was allowed on one pump';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.extend_pump_operation_time(v_operation.id, 0);
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A zero-minute operation extension was accepted';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.extend_pump_operation_time(v_operation.id, 1431);
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An extension that would exceed the 24-hour operation cap was accepted';
  END IF;

  v_operation := public.extend_pump_operation_time(v_operation.id, 5);
  IF v_operation.planned_minutes <> 15 OR v_operation.status <> 'running' THEN
    RAISE EXCEPTION 'A running operation extension did not update the planned duration';
  END IF;

  v_operation := public.pause_pump_operation(v_operation.id, 'انقطاع كهرباء تجريبي');
  IF v_operation.status <> 'paused' OR v_operation.paused_at IS NULL THEN
    RAISE EXCEPTION 'Manager pause transition did not persist';
  END IF;

  v_operation := public.extend_pump_operation_time(v_operation.id, 3);
  IF v_operation.planned_minutes <> 18 OR v_operation.status <> 'paused' THEN
    RAISE EXCEPTION 'A paused operation extension did not update the target without resuming the session';
  END IF;

  v_operation := public.resume_pump_operation(v_operation.id, v_power_source_id);
  IF v_operation.status <> 'running' OR v_operation.paused_at IS NOT NULL THEN
    RAISE EXCEPTION 'Manager resume transition did not persist';
  END IF;

  v_operation := public.complete_pump_operation(v_operation.id);
  IF v_operation.status <> 'completed'
     OR v_operation.ended_at IS NULL
     OR v_operation.actual_seconds IS NULL
     OR v_operation.actual_seconds < 0
     OR v_operation.planned_minutes <> 18 THEN
    RAISE EXCEPTION 'Manager completion did not preserve the extended target and final duration';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.extend_pump_operation_time(v_operation.id, 2);
  EXCEPTION WHEN no_data_found THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A completed operation accepted additional minutes';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.pump_operations SET planned_minutes = 100 WHERE id = v_operation.id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Authenticated manager directly changed the planned duration outside the RPC';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.pump_operations SET status = 'running' WHERE id = v_operation.id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Authenticated manager directly modified an operation outside the RPC';
  END IF;

  SELECT array_agg(event_type ORDER BY event_sequence)
  INTO v_event_types
  FROM public.pump_operation_events
  WHERE operation_id = v_operation.id;
  IF v_event_types IS DISTINCT FROM ARRAY[
       'started','time_extended','paused','time_extended','resumed','completed'
     ]::text[] THEN
    RAISE EXCEPTION 'Operation event timeline is incomplete or out of order: %', v_event_types;
  END IF;
  IF (SELECT array_agg(metadata->>'planned_minutes_after' ORDER BY event_sequence)
      FROM public.pump_operation_events
      WHERE operation_id = v_operation.id AND event_type = 'time_extended')
     IS DISTINCT FROM ARRAY['15','18']::text[] THEN
    RAISE EXCEPTION 'Time extension events did not preserve the before/after targets in order';
  END IF;
  IF (SELECT count(*) FROM public.pump_operation_events
      WHERE operation_id = v_operation.id
        AND event_type = 'time_extended'
        AND actor_id = auth.uid()) <> 2 THEN
    RAISE EXCEPTION 'Time extension actor identity was not stored for every extension';
  END IF;
  IF (SELECT reason FROM public.pump_operation_events
      WHERE operation_id = v_operation.id AND event_type = 'paused')
     <> 'انقطاع كهرباء تجريبي' THEN
    RAISE EXCEPTION 'Pause reason was not preserved in the immutable event ledger';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pump_operation_events
             WHERE operation_id = v_operation.id AND actor_id <> auth.uid()) THEN
    RAISE EXCEPTION 'Operation event actor identity does not match the authenticated user';
  END IF;
  IF (SELECT count(*) FROM public.pump_operation_power_segments
      WHERE operation_id = v_operation.id) <> 2
     OR EXISTS (
       SELECT 1 FROM public.pump_operation_power_segments
       WHERE operation_id = v_operation.id AND power_source_id <> v_power_source_id
     )
     OR EXISTS (
       SELECT 1 FROM public.pump_operation_power_segments
       WHERE operation_id = v_operation.id AND ended_at IS NULL
     ) THEN
    RAISE EXCEPTION 'Power source segments were not closed and retained across pause/resume';
  END IF;

  v_dashboard := public.get_pump_operations_dashboard(
    v_operation.operation_date,
    v_operation.operation_date
  );
  IF (v_dashboard->>'today_operations')::integer <> 1
     OR (v_dashboard->>'active_operations')::integer <> 0
     OR jsonb_array_length(v_dashboard->'daily') <> 1
     OR jsonb_array_length(v_dashboard->'recent') <> 1
     OR v_dashboard->'recent'->0->>'pump_name' <> 'غطاس أ 1' THEN
    RAISE EXCEPTION 'Manager dashboard aggregate returned unexpected scoped totals';
  END IF;
END;
$manager_operation_lifecycle$;
DO $manager_power_source_management$
DECLARE v_added_source_id uuid;
BEGIN
  INSERT INTO public.pump_power_sources (pump_id, name, source_type)
  VALUES ('20000000-0000-4000-8000-000000000001', 'مولد احتياطي اختباري', 'generator')
  RETURNING id INTO v_added_source_id;
  IF NOT EXISTS (
    SELECT 1 FROM public.pump_power_sources
    WHERE id=v_added_source_id
      AND organization_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      AND created_by=auth.uid()
  ) THEN
    RAISE EXCEPTION 'Manager could not create a pump-scoped power source with derived tenant identity';
  END IF;
  UPDATE public.pump_power_sources SET is_active=false WHERE id=v_added_source_id;
  IF NOT EXISTS (
    SELECT 1 FROM public.pump_power_sources
    WHERE id=v_added_source_id AND NOT is_active AND archived_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Power source archival timestamp was not captured';
  END IF;
  UPDATE public.pump_power_sources SET is_active=true WHERE id=v_added_source_id;
  IF NOT EXISTS (
    SELECT 1 FROM public.pump_power_sources
    WHERE id=v_added_source_id AND is_active AND archived_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Power source reactivation did not clear archived_at';
  END IF;
END;
$manager_power_source_management$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $operator_operation_scope$
DECLARE
  v_operation public.pump_operations%ROWTYPE;
  v_event_types text[];
  v_dashboard jsonb;
  v_power_source_id uuid;
  v_other_pump_source_id uuid;
  v_rejected boolean := false;
BEGIN
  SELECT id INTO v_power_source_id
  FROM public.pump_power_sources
  WHERE pump_id='20000000-0000-4000-8000-000000000001'
    AND name='مولد – مزود 3';
  SELECT id INTO v_other_pump_source_id
  FROM public.pump_power_sources
  WHERE pump_id='20000000-0000-4000-8000-000000000003'
    AND name='مولد – مزود 3';
  IF (SELECT count(*) FROM public.pump_operations
      WHERE pump_id = '20000000-0000-4000-8000-000000000001') <> 1 THEN
    RAISE EXCEPTION 'Assigned operator cannot read the pump operation history';
  END IF;

  IF (SELECT count(*) FROM public.pump_operations
      WHERE pump_id = '20000000-0000-4000-8000-000000000002') <> 0 THEN
    RAISE EXCEPTION 'Operator read operations for an unassigned pump';
  END IF;

  BEGIN
    PERFORM public.start_pump_operation(
      '20000000-0000-4000-8000-000000000002', NULL, 'حالة غير مصرح بها', 5, NULL
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Operator started a pump outside their assignment';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.start_pump_operation(
      '20000000-0000-4000-8000-000000000001',
      NULL,
      'مصدر من غطاس آخر',
      5,
      v_other_pump_source_id
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Operator used a power source from another pump';
  END IF;

  SELECT * INTO v_operation
  FROM public.start_pump_operation(
    '20000000-0000-4000-8000-000000000001',
    NULL,
    'حالة طارئة للاختبار',
    5,
    v_power_source_id
  );
  IF v_operation.operator_id <> auth.uid() OR v_operation.subscriber_id IS NOT NULL THEN
    RAISE EXCEPTION 'Assigned operator could not start an emergency operation';
  END IF;

  v_operation := public.extend_pump_operation_time(v_operation.id, 2);
  IF v_operation.planned_minutes <> 7 OR v_operation.status <> 'running' THEN
    RAISE EXCEPTION 'Assigned operator could not extend their own active session';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.start_pump_operation(
      '20000000-0000-4000-8000-000000000001', NULL, 'تعبئة مكررة', 5, v_power_source_id
    );
  EXCEPTION WHEN unique_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A second active operation was allowed on one pump';
  END IF;

  v_operation := public.pause_pump_operation(v_operation.id, 'تغيير فلتر تجريبي');
  v_operation := public.resume_pump_operation(v_operation.id, v_power_source_id);
  v_operation := public.complete_pump_operation(v_operation.id);
  IF v_operation.status <> 'completed' OR v_operation.actual_seconds IS NULL THEN
    RAISE EXCEPTION 'Assigned operator could not complete their operation';
  END IF;

  SELECT array_agg(event_type ORDER BY occurred_at, id)
  INTO v_event_types
  FROM public.pump_operation_events
  WHERE operation_id = v_operation.id;
  IF v_event_types IS DISTINCT FROM ARRAY[
       'started','time_extended','paused','resumed','completed'
     ]::text[] THEN
    RAISE EXCEPTION 'Operator event timeline was not recorded completely';
  END IF;

  v_dashboard := public.get_pump_operations_dashboard(
    v_operation.operation_date,
    v_operation.operation_date
  );
  IF (v_dashboard->>'today_operations')::integer <> 2
     OR (v_dashboard->>'active_operations')::integer <> 0
     OR jsonb_array_length(v_dashboard->'recent') <> 2 THEN
    RAISE EXCEPTION 'Operator dashboard aggregate did not respect assigned-pump scope';
  END IF;
END;
$operator_operation_scope$;
RESET ROLE;

-- Collectors and supervisors can neither view nor control operation records.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000004', true);
DO $collector_power_source_read$
BEGIN
  IF (SELECT count(*) FROM public.pump_power_sources
      WHERE pump_id='20000000-0000-4000-8000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'Collector unexpectedly read operator-only power source configuration';
  END IF;
END;
$collector_power_source_read$;
DO $collector_operation_power_read$
BEGIN
  IF (SELECT count(*) FROM public.pump_operation_power_segments
      WHERE pump_id='20000000-0000-4000-8000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'Collector unexpectedly read operator-only power usage segments';
  END IF;
END;
$collector_operation_power_read$;

DO $collector_operation_read$
BEGIN
  IF (SELECT count(*) FROM public.pump_operations
      WHERE pump_id = '20000000-0000-4000-8000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'Collector unexpectedly read operation data for a different role scope';
  END IF;
  IF (SELECT count(*) FROM public.pump_operation_events
      WHERE pump_id = '20000000-0000-4000-8000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'Collector unexpectedly read the operation event ledger';
  END IF;
END;
$collector_operation_read$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);
DO $supervisor_power_source_read$
BEGIN
  -- The manager management fixture above adds and reactivates one extra source.
  IF (SELECT count(*) FROM public.pump_power_sources
      WHERE pump_id='20000000-0000-4000-8000-000000000001') <> 4 THEN
    RAISE EXCEPTION 'Supervisor source scope mismatch: visible_sources=%, profile_role=%, profile_org=%, visible_assignments=%, assigned_pump=%',
      (SELECT count(*) FROM public.pump_power_sources WHERE pump_id='20000000-0000-4000-8000-000000000001'),
      water_management_private.current_user_role(),
      water_management_private.current_user_organization_id(),
      (SELECT count(*) FROM public.pump_assignments WHERE user_id=auth.uid() AND pump_id='20000000-0000-4000-8000-000000000001'),
      (SELECT count(*) FROM public.pumps WHERE id='20000000-0000-4000-8000-000000000001');
  END IF;
  IF (SELECT count(*) FROM public.pump_operation_power_segments
      WHERE pump_id='20000000-0000-4000-8000-000000000001') <> 4 THEN
    RAISE EXCEPTION 'Assigned supervisor must read operation power segments for their pump';
  END IF;
END;
$supervisor_power_source_read$;

DO $supervisor_operation_read$
BEGIN
  IF (SELECT count(*) FROM public.pump_operations
      WHERE pump_id = '20000000-0000-4000-8000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'Supervisor unexpectedly read operator-only operation records';
  END IF;
  IF (SELECT count(*) FROM public.pump_operation_events
      WHERE pump_id = '20000000-0000-4000-8000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'Supervisor unexpectedly read the operator event ledger';
  END IF;
END;
$supervisor_operation_read$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000006', true);
SELECT test_support.assert_scope('manager B', 1, 1, 1, 1, 2);
RESET ROLE;

-- Second organization may operate its own pump but cannot view tenant A sessions.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000007', true);
DO $tenant_b_operation$
DECLARE v_operation public.pump_operations%ROWTYPE; v_power_source_id uuid;
BEGIN
  SELECT id INTO v_power_source_id
  FROM public.pump_power_sources
  WHERE pump_id='20000000-0000-4000-8000-000000000003'
    AND name='طاقة شمسية – مزود 2';
  SELECT * INTO v_operation
  FROM public.start_pump_operation(
    '20000000-0000-4000-8000-000000000003',
    '30000000-0000-4000-8000-000000000004',
    NULL,
    5,
    v_power_source_id
  );
  v_operation := public.complete_pump_operation(v_operation.id);
  IF v_operation.status <> 'completed' THEN
    RAISE EXCEPTION 'Tenant B operator could not complete its own operation';
  END IF;
  IF (SELECT count(*) FROM public.pump_operations
      WHERE pump_id = '20000000-0000-4000-8000-000000000003') <> 1
     OR (SELECT count(*) FROM public.pump_operations
         WHERE pump_id = '20000000-0000-4000-8000-000000000001') <> 0
     OR (SELECT count(*) FROM public.pump_operation_events
         WHERE pump_id = '20000000-0000-4000-8000-000000000003') <> 2
     OR (SELECT count(*) FROM public.pump_operation_events
         WHERE pump_id = '20000000-0000-4000-8000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'Tenant B operator operation/event visibility crossed organization boundaries';
  END IF;
END;
$tenant_b_operation$;
RESET ROLE;

-- The end-of-day survey is an aggregate record and must not synthesize operations.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000006', true);
DO $daily_work_report_manager_b$
DECLARE
  v_source_id uuid;
  v_allocation_id uuid;
  v_report public.daily_work_reports%ROWTYPE;
  v_total_minutes numeric;
  v_work_date date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date
    + 7
    + ((5 - extract(isodow FROM (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date)::integer + 7) % 7);
  v_rejected boolean := false;
BEGIN
  SELECT id INTO v_source_id
  FROM public.pump_power_sources
  WHERE pump_id='20000000-0000-4000-8000-000000000003'
    AND name='طاقة شمسية – مزود 2';

  PERFORM public.prepare_daily_work_report(
    '20000000-0000-4000-8000-000000000003',
    v_work_date
  );

  IF EXISTS (
    SELECT 1 FROM public.daily_queues
    WHERE pump_id = '20000000-0000-4000-8000-000000000003'
      AND queue_date = v_work_date
  ) THEN
    RAISE EXCEPTION 'Preparing a daily report must not generate a runnable daily queue';
  END IF;
  SELECT a.id INTO v_allocation_id
  FROM public.weekly_entitlement_allocations a
  WHERE a.organization_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    AND a.pump_id = '20000000-0000-4000-8000-000000000003'
    AND a.subscriber_id = '30000000-0000-4000-8000-000000000004'
    AND a.source_schedule_entry_id = '60000000-0000-4000-8000-000000000003'
    AND a.allocation_date = v_work_date;
  IF v_allocation_id IS NULL THEN
    RAISE EXCEPTION 'Tenant B daily weekly entitlement allocation fixture is missing';
  END IF;

  v_report := public.save_daily_work_report(
    '20000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000007',
    (v_work_date::timestamp + time '07:00') AT TIME ZONE 'Asia/Hebron',
    (v_work_date::timestamp + time '09:00') AT TIME ZONE 'Asia/Hebron',
    20,
    jsonb_build_array(jsonb_build_object('power_source_id',v_source_id,'minutes',100)),
    jsonb_build_array(jsonb_build_object(
      'entry_type','weekly',
      'schedule_entry_id','60000000-0000-4000-8000-000000000003',
      'weekly_entitlement_allocation_id',v_allocation_id,
      'subscriber_id','30000000-0000-4000-8000-000000000004',
      'sort_order',0,
      'manual_minutes',25,
      'extra_minutes',0,
      'note','تم توثيق التعبئة بعد العمل'
    )),
    true,
    NULL
  );

  IF v_report.status <> 'submitted'
     OR v_report.work_date <> v_work_date
     OR v_report.stoppage_minutes <> 20
     OR v_report.operator_id <> '10000000-0000-4000-8000-000000000007'::uuid
     OR v_report.created_by <> '10000000-0000-4000-8000-000000000006'::uuid
     OR v_report.submitted_by <> '10000000-0000-4000-8000-000000000006'::uuid THEN
    RAISE EXCEPTION 'Daily report did not preserve target operator, actual actor, date, stoppages, or submitted state';
  END IF;

  SELECT sum(total_minutes) INTO v_total_minutes
  FROM public.get_pump_power_usage(
    v_work_date, v_work_date, 'day',
    '20000000-0000-4000-8000-000000000003'
  )
  WHERE data_source='daily_survey'
    AND power_source_id=v_source_id;
  IF v_total_minutes <> 100 THEN
    RAISE EXCEPTION 'Daily survey power totals were not used as final daily source totals: %', v_total_minutes;
  END IF;

  IF (SELECT weekly_minutes_consumed
      FROM public.daily_work_report_items
      WHERE daily_work_report_id=v_report.id) <> 25
     OR (SELECT fulfillment_status
         FROM public.daily_work_report_items
         WHERE daily_work_report_id=v_report.id) <> 'partial' THEN
    RAISE EXCEPTION 'Partial weekly fulfillment did not consume only the delivered minutes';
  END IF;

  IF (SELECT count(*) FROM public.pump_operations
      WHERE pump_id='20000000-0000-4000-8000-000000000003'
        AND operation_date=v_work_date) <> 0 THEN
    RAISE EXCEPTION 'Daily survey created a fake pump operation';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.save_daily_work_report(
      '20000000-0000-4000-8000-000000000003',
      '10000000-0000-4000-8000-000000000007',
      ((v_work_date + 7)::timestamp + time '07:00') AT TIME ZONE 'Asia/Hebron',
      ((v_work_date + 7)::timestamp + time '09:00') AT TIME ZONE 'Asia/Hebron',
      20,
      jsonb_build_array(jsonb_build_object('power_source_id',v_source_id,'minutes',100)),
      '[]'::jsonb,
      true,
      NULL
    );
  EXCEPTION WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Daily report submission omitted a required weekly schedule entry';
  END IF;
END;
$daily_work_report_manager_b$;
RESET ROLE;

-- A pump can have more than one operator. The subscriber responsibility is
-- explicit and independent from the operator recorded on a pump operation.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
VALUES (
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000003',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'operator'
);
DO $subscriber_operator_initial_assignment$
DECLARE
  v_result jsonb;
BEGIN
  IF (SELECT count(*) FROM public.pump_assignments
      WHERE pump_id = '20000000-0000-4000-8000-000000000001'
        AND assignment_role = 'operator') <> 2 THEN
    RAISE EXCEPTION 'A pump must allow multiple assigned operators';
  END IF;

  v_result := public.assign_subscriber_operator(
    '30000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000002',
    'تعيين المشغّل المسؤول الأول'
  );

  IF (v_result->>'changed')::boolean IS DISTINCT FROM false
     OR (SELECT operator_id FROM public.subscribers
         WHERE id = '30000000-0000-4000-8000-000000000001')
        <> '10000000-0000-4000-8000-000000000002'::uuid THEN
    RAISE EXCEPTION 'Repeated assignment to the current operator must be idempotent';
  END IF;
END;
$subscriber_operator_initial_assignment$;
RESET ROLE;

-- Managers can create one independent workload report per assigned operator,
-- while pump energy is represented once per pump/date and shared read-only.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DO $multi_operator_daily_reports_manager$
DECLARE
  v_source_id uuid;
  v_first public.daily_work_reports%ROWTYPE;
  v_second public.daily_work_reports%ROWTYPE;
  v_operator_count integer;
  v_rejected boolean := false;
BEGIN
  SELECT id INTO v_source_id
  FROM public.pump_power_sources
  WHERE pump_id = '20000000-0000-4000-8000-000000000001'
    AND name = 'طاقة شمسية – مزود 1';

  v_first := public.save_daily_work_report(
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000002',
    '2026-01-20 07:00:00+02'::timestamptz,
    '2026-01-20 08:00:00+02'::timestamptz,
    0,
    jsonb_build_array(jsonb_build_object('power_source_id', v_source_id, 'minutes', 60)),
    '[]'::jsonb,
    false,
    NULL
  );

  v_second := public.save_daily_work_report(
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000003',
    '2026-01-20 07:00:00+02'::timestamptz,
    '2026-01-20 08:00:00+02'::timestamptz,
    0,
    jsonb_build_array(jsonb_build_object('power_source_id', v_source_id, 'minutes', 60)),
    '[]'::jsonb,
    true,
    NULL
  );

  SELECT count(*)::integer INTO v_operator_count
  FROM public.get_daily_report_operators(
    '20000000-0000-4000-8000-000000000001', DATE '2026-01-20', false
  );
  IF v_operator_count <> 2
     OR NOT EXISTS (
       SELECT 1 FROM public.get_daily_report_operators(
         '20000000-0000-4000-8000-000000000001', DATE '2026-01-20', false
       ) WHERE id = '10000000-0000-4000-8000-000000000002'
     )
     OR NOT EXISTS (
       SELECT 1 FROM public.get_daily_report_operators(
         '20000000-0000-4000-8000-000000000001', DATE '2026-01-20', false
       ) WHERE id = '10000000-0000-4000-8000-000000000003'
     ) THEN
    RAISE EXCEPTION 'Manager report operator selector did not return only the two assigned pump operators';
  END IF;

  IF v_first.id = v_second.id
     OR v_first.operator_id <> '10000000-0000-4000-8000-000000000002'::uuid
     OR v_second.operator_id <> '10000000-0000-4000-8000-000000000003'::uuid
     OR v_first.created_by <> auth.uid()
     OR v_second.created_by <> auth.uid() THEN
    RAISE EXCEPTION 'Manager did not create distinct operator reports with manager audit identity';
  END IF;

  IF (SELECT count(*) FROM public.daily_work_reports
      WHERE organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        AND pump_id = '20000000-0000-4000-8000-000000000001'
        AND work_date = DATE '2026-01-20') <> 2 THEN
    RAISE EXCEPTION 'Two operators could not hold independent reports for the same pump/day';
  END IF;

  IF (SELECT count(*) FROM public.daily_pump_energy_reports
      WHERE organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        AND pump_id = '20000000-0000-4000-8000-000000000001'
        AND work_date = DATE '2026-01-20') <> 1
     OR (SELECT status FROM public.daily_pump_energy_reports
         WHERE organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
           AND pump_id = '20000000-0000-4000-8000-000000000001'
           AND work_date = DATE '2026-01-20') <> 'submitted'
     OR (SELECT count(*) FROM public.daily_pump_energy_source_totals totals
         JOIN public.daily_pump_energy_reports energy
           ON energy.id = totals.daily_pump_energy_report_id
         WHERE energy.organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
           AND energy.pump_id = '20000000-0000-4000-8000-000000000001'
           AND energy.work_date = DATE '2026-01-20') <> 1 THEN
    RAISE EXCEPTION 'Pump energy totals were duplicated across independent operator reports';
  END IF;
  v_rejected := false;
  BEGIN
    PERFORM public.save_daily_work_report(
      '20000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000002',
      '2026-01-20 07:00:00+02'::timestamptz,
      '2026-01-20 08:00:00+02'::timestamptz,
      0,
      jsonb_build_array(jsonb_build_object('power_source_id', v_source_id, 'minutes', 59)),
      '[]'::jsonb,
      false,
      v_first.id
    );
    RAISE EXCEPTION 'A later operator report changed already submitted pump energy totals';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Submitted pump energy totals were not immutable across operator reports';
  END IF;
END;
$multi_operator_daily_reports_manager$;
RESET ROLE;

-- A shared pump-energy draft belongs to the pump/day, not to a single
-- operator report. Another operator may reuse or submit it unchanged, but
-- cannot silently overwrite the first operator's physical energy totals.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $shared_pump_energy_draft_creator$
DECLARE
  v_source_id uuid;
  v_report public.daily_work_reports%ROWTYPE;
BEGIN
  SELECT id INTO v_source_id
  FROM public.pump_power_sources
  WHERE pump_id = '20000000-0000-4000-8000-000000000001'
    AND name = 'طاقة شمسية – مزود 1';

  v_report := public.save_daily_work_report(
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000002',
    '2026-01-21 07:00:00+02'::timestamptz,
    '2026-01-21 08:00:00+02'::timestamptz,
    0,
    jsonb_build_array(jsonb_build_object('power_source_id', v_source_id, 'minutes', 60)),
    '[]'::jsonb,
    false,
    NULL
  );

  IF v_report.created_by <> auth.uid()
     OR v_report.operator_id <> auth.uid()
     OR v_report.status <> 'draft' THEN
    RAISE EXCEPTION 'First operator did not create their own report and shared pump-energy draft';
  END IF;
END;
$shared_pump_energy_draft_creator$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);
DO $shared_pump_energy_draft_second_operator$
DECLARE
  v_source_id uuid;
  v_report public.daily_work_reports%ROWTYPE;
  v_rejected boolean := false;
BEGIN
  SELECT id INTO v_source_id
  FROM public.pump_power_sources
  WHERE pump_id = '20000000-0000-4000-8000-000000000001'
    AND name = 'طاقة شمسية – مزود 1';

  BEGIN
    PERFORM public.save_daily_work_report(
      '20000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000003',
      '2026-01-21 07:00:00+02'::timestamptz,
      '2026-01-21 08:00:00+02'::timestamptz,
      0,
      jsonb_build_array(jsonb_build_object('power_source_id', v_source_id, 'minutes', 59)),
      '[]'::jsonb,
      false,
      NULL
    );
    RAISE EXCEPTION 'A second operator replaced another operator shared energy draft';
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    v_rejected := true;
  END;

  IF NOT v_rejected OR EXISTS (
    SELECT 1 FROM public.daily_work_reports
    WHERE pump_id = '20000000-0000-4000-8000-000000000001'
      AND work_date = DATE '2026-01-21'
      AND operator_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Mismatched shared energy values were not rejected atomically';
  END IF;

  v_report := public.save_daily_work_report(
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000003',
    '2026-01-21 07:00:00+02'::timestamptz,
    '2026-01-21 08:00:00+02'::timestamptz,
    0,
    jsonb_build_array(jsonb_build_object('power_source_id', v_source_id, 'minutes', 60)),
    '[]'::jsonb,
    false,
    NULL
  );

  IF v_report.operator_id <> auth.uid()
     OR v_report.created_by <> auth.uid()
     OR (SELECT count(*) FROM public.daily_pump_energy_reports
         WHERE pump_id = '20000000-0000-4000-8000-000000000001'
           AND work_date = DATE '2026-01-21') <> 1
     OR (SELECT count(*) FROM public.daily_pump_energy_source_totals totals
         JOIN public.daily_pump_energy_reports energy
           ON energy.id = totals.daily_pump_energy_report_id
         WHERE energy.pump_id = '20000000-0000-4000-8000-000000000001'
           AND energy.work_date = DATE '2026-01-21') <> 1 THEN
    RAISE EXCEPTION 'Second operator could not reuse the exact shared draft without duplicating pump-energy totals';
  END IF;
END;
$shared_pump_energy_draft_second_operator$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $multi_operator_daily_reports_operator_one$
BEGIN
  IF (SELECT count(*) FROM public.daily_work_reports
      WHERE pump_id = '20000000-0000-4000-8000-000000000001'
        AND work_date = DATE '2026-01-20') <> 1
     OR NOT EXISTS (
       SELECT 1 FROM public.daily_work_reports
       WHERE pump_id = '20000000-0000-4000-8000-000000000001'
         AND work_date = DATE '2026-01-20'
         AND operator_id = auth.uid()
     ) THEN
    RAISE EXCEPTION 'Operator one can see another operator daily report';
  END IF;

  IF (SELECT count(*) FROM public.daily_pump_energy_reports
      WHERE pump_id = '20000000-0000-4000-8000-000000000001'
        AND work_date = DATE '2026-01-20') <> 1
     OR (SELECT count(*) FROM public.daily_pump_energy_source_totals totals
         JOIN public.daily_pump_energy_reports energy
           ON energy.id = totals.daily_pump_energy_report_id
         WHERE energy.pump_id = '20000000-0000-4000-8000-000000000001'
           AND energy.work_date = DATE '2026-01-20') <> 1 THEN
    RAISE EXCEPTION 'Assigned operators must share the single pump energy report';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.daily_pump_energy_reports
    WHERE organization_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
       OR pump_id = '20000000-0000-4000-8000-000000000003'
  ) OR EXISTS (
    SELECT 1
    FROM public.daily_pump_energy_source_totals totals
    JOIN public.daily_pump_energy_reports energy
      ON energy.id = totals.daily_pump_energy_report_id
     AND energy.organization_id = totals.organization_id
     AND energy.pump_id = totals.pump_id
    WHERE energy.organization_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
       OR energy.pump_id = '20000000-0000-4000-8000-000000000003'
  ) THEN
    RAISE EXCEPTION 'Tenant A operator can read tenant B shared energy rows';
  END IF;

  BEGIN
    PERFORM 1
    FROM public.get_daily_work_report_allocations(
      '20000000-0000-4000-8000-000000000003',
      DATE '2026-01-20'
    );
    RAISE EXCEPTION 'Tenant A operator read tenant B daily allocations';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM public.save_daily_work_report(
      '20000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000003',
      '2026-01-20 07:00:00+02'::timestamptz,
      '2026-01-20 08:00:00+02'::timestamptz,
      0,
      '[]'::jsonb,
      '[]'::jsonb,
      false,
      NULL
    );
    RAISE EXCEPTION 'Operator one created a report for operator two';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$multi_operator_daily_reports_operator_one$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);
DO $multi_operator_daily_reports_operator_two$
BEGIN
  IF (SELECT count(*) FROM public.daily_work_reports
      WHERE pump_id = '20000000-0000-4000-8000-000000000001'
        AND work_date = DATE '2026-01-20') <> 1
     OR NOT EXISTS (
       SELECT 1 FROM public.daily_work_reports
       WHERE pump_id = '20000000-0000-4000-8000-000000000001'
         AND work_date = DATE '2026-01-20'
         AND operator_id = auth.uid()
     ) THEN
    RAISE EXCEPTION 'Operator two cannot see only their own daily report';
  END IF;
END;
$multi_operator_daily_reports_operator_two$;
RESET ROLE;

-- Supervisors can select only operators who already have a report on
-- the assigned pump/date; the profile table remains self-readable only.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);
DO $supervisor_daily_report_operator_selector$
DECLARE
  v_count integer;
  v_rejected boolean := false;
BEGIN
  SELECT count(*)::integer INTO v_count
  FROM public.get_daily_report_operators(
    '20000000-0000-4000-8000-000000000001', DATE '2026-01-20', true
  );

  IF v_count <> 2
     OR EXISTS (
       SELECT 1 FROM public.get_daily_report_operators(
         '20000000-0000-4000-8000-000000000001', DATE '2026-01-20', true
       ) WHERE id NOT IN (
         '10000000-0000-4000-8000-000000000002',
         '10000000-0000-4000-8000-000000000003'
       )
     ) THEN
    RAISE EXCEPTION 'Supervisor report selector returned operators outside the assigned pump/date reports';
  END IF;

  BEGIN
    PERFORM 1 FROM public.get_daily_report_operators(
      '20000000-0000-4000-8000-000000000001', DATE '2026-01-20', false
    );
    RAISE EXCEPTION 'Supervisor listed operators without filtering to existing reports';
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Supervisor unfiltered operator selector was not rejected';
  END IF;

  IF pg_catalog.has_table_privilege('authenticated','public.profiles','SELECT')
     AND NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_policies
       WHERE schemaname = 'public'
         AND tablename = 'profiles'
         AND policyname = 'users_select_own_profile'
     ) THEN
    RAISE EXCEPTION 'Profiles RLS self-read boundary changed unexpectedly';
  END IF;
END;
$supervisor_daily_report_operator_selector$;
RESET ROLE;



\ir daily_queue.sql

-- Collectors retain their prior pump-level schedule/subscriber visibility, but
-- they must not inherit the operator/supervisor-only weekly entitlement ledger.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
INSERT INTO public.pump_assignments (pump_id, user_id, organization_id, assignment_role)
VALUES (
  '20000000-0000-4000-8000-000000000001',
  '10000000-0000-4000-8000-000000000004',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'collector'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000004', true);
DO $collector_weekly_entitlement_boundary$
BEGIN
  IF (SELECT count(*) FROM public.weekly_schedule_subscribers
      WHERE subscriber_id = '30000000-0000-4000-8000-000000000001') <> 1
     -- daily_queue.sql adds a second same-subscriber entry to split the weekly
     -- quota across today and the following day. Both remain pump-visible.
     OR (SELECT count(*) FROM public.schedule_entries
         WHERE subscriber_id = '30000000-0000-4000-8000-000000000001') <> 2 THEN
    RAISE EXCEPTION 'Collector lost its existing pump-level weekly schedule visibility';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.weekly_entitlement_cycles
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) OR EXISTS (
    SELECT 1 FROM public.weekly_entitlement_allocations
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) OR EXISTS (
    SELECT 1 FROM public.weekly_entitlement_events
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) THEN
    RAISE EXCEPTION 'Collector read the weekly entitlement ledger outside its former role scope';
  END IF;
END;
$collector_weekly_entitlement_boundary$;
RESET ROLE;

-- Materialize a future queue while the first operator owns the subscriber;
-- reassignment must move only waiting items and leave completed history intact.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $create_future_assignment_queue$
DECLARE
  v_queue_id uuid;
  v_future_date date := (clock_timestamp() AT TIME ZONE 'Asia/Hebron')::date + 1;
BEGIN
  v_queue_id := public.generate_daily_queue(
    '20000000-0000-4000-8000-000000000001',
    v_future_date
  );
  PERFORM set_config('test.assignment_future_queue_id', v_queue_id::text, true);
END;
$create_future_assignment_queue$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DO $subscriber_operator_reassignment$
DECLARE
  v_queue_id uuid := current_setting('test.assignment_future_queue_id')::uuid;
  v_result jsonb;
  v_expected integer;
  v_completed_count integer;
  v_transfer_source_id uuid;
BEGIN
  SELECT count(*)::integer INTO v_expected
  FROM public.queue_items
  WHERE daily_queue_id = v_queue_id
    AND subscriber_id = '30000000-0000-4000-8000-000000000001'
    AND status = 'queued';

  IF v_expected < 1 THEN
    RAISE EXCEPTION 'Future queue fixture must contain a waiting item for reassignment';
  END IF;

  SELECT a.id INTO v_transfer_source_id
  FROM public.weekly_entitlement_allocations a
  WHERE a.subscriber_id = '30000000-0000-4000-8000-000000000001'
    AND a.available_minutes > 0
  ORDER BY a.allocation_date DESC, a.id
  LIMIT 1;

  IF v_transfer_source_id IS NULL THEN
    RAISE EXCEPTION 'Reassignment test requires one unconsumed weekly entitlement allocation';
  END IF;
  PERFORM set_config('test.assignment_source_allocation_id', v_transfer_source_id::text, true);

  SELECT count(*)::integer INTO v_completed_count
  FROM public.queue_items
  WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
    AND status = 'completed'
    AND assigned_operator_id = '10000000-0000-4000-8000-000000000002';

  v_result := public.assign_subscriber_operator(
    '30000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000003',
    'إعادة توزيع مسؤولية المشترك إلى المشغّل الثاني'
  );

  IF (v_result->>'changed')::boolean IS DISTINCT FROM true
     OR (v_result->>'updated_queue_items')::integer <> v_expected
     OR (SELECT operator_id FROM public.subscribers
         WHERE id = '30000000-0000-4000-8000-000000000001')
        <> '10000000-0000-4000-8000-000000000003'::uuid
     OR EXISTS (
       SELECT 1 FROM public.queue_items
       WHERE daily_queue_id = v_queue_id
         AND subscriber_id = '30000000-0000-4000-8000-000000000001'
         AND status = 'queued'
         AND assigned_operator_id IS DISTINCT FROM '10000000-0000-4000-8000-000000000003'::uuid
     ) THEN
    RAISE EXCEPTION 'Reassignment did not atomically move waiting queue items to the new operator';
  END IF;

  IF (SELECT count(*) FROM public.queue_item_events
      WHERE daily_queue_id = v_queue_id
        AND event_type = 'item_operator_reassigned') <> v_expected THEN
    RAISE EXCEPTION 'Queue reassignment did not append an event for each waiting item';
  END IF;

  IF (SELECT count(*) FROM public.subscriber_operator_assignment_events
      WHERE subscriber_id = '30000000-0000-4000-8000-000000000001') <> 2 THEN
    RAISE EXCEPTION 'Subscriber operator assignment history must record both assignment changes';
  END IF;

  -- A manager cannot assign a subscriber to an operator from another tenant
  -- or to a collector account, even when the target user ID is known.
  BEGIN
    PERFORM public.assign_subscriber_operator(
      '30000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000007',
      'يجب رفض مشغّل من مؤسسة أخرى'
    );
    RAISE EXCEPTION 'Cross-tenant subscriber operator assignment was accepted';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  BEGIN
    PERFORM public.assign_subscriber_operator(
      '30000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000004',
      'يجب رفض حساب محصّل بدل المشغّل'
    );
    RAISE EXCEPTION 'A collector account was accepted as a subscriber operator';
  EXCEPTION WHEN foreign_key_violation THEN
    NULL;
  END;

  IF (SELECT count(*) FROM public.queue_items
      WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
        AND status = 'completed'
        AND assigned_operator_id = '10000000-0000-4000-8000-000000000002') <> v_completed_count THEN
    RAISE EXCEPTION 'Reassignment rewrote completed queue ownership history';
  END IF;
END;
$subscriber_operator_reassignment$;

DO $subscriber_operator_direct_update_denied$
DECLARE
  v_rejected boolean := false;
BEGIN
  -- Custom GUC values are settable by API sessions and must not be accepted
  -- as an authorization capability for bypassing the assignment RPC.
  PERFORM set_config('water_management.allow_subscriber_operator_change', 'on', true);
  BEGIN
    UPDATE public.subscribers
    SET operator_id = '10000000-0000-4000-8000-000000000002'
    WHERE id = '30000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Direct subscriber operator updates bypassed the guarded assignment RPC';
  END IF;
END;
$subscriber_operator_direct_update_denied$;
RESET ROLE;

-- Subscriber-level read isolation is evaluated against the current assignment.
-- The old owner (operator A1) must lose subscriber/schedule/entitlement access;
-- the new owner (operator A2) receives that current working scope.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $operator_a1_subscriber_scope_after_reassignment$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.subscribers
    WHERE id = '30000000-0000-4000-8000-000000000001'
  ) OR EXISTS (
    SELECT 1 FROM public.schedule_entries
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) OR EXISTS (
    SELECT 1 FROM public.weekly_schedule_subscribers
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) OR EXISTS (
    SELECT 1 FROM public.weekly_entitlement_cycles
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) OR EXISTS (
    SELECT 1 FROM public.weekly_entitlement_allocations
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) OR EXISTS (
    SELECT 1 FROM public.weekly_entitlement_events
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) THEN
    RAISE EXCEPTION 'Former operator can still read the reassigned subscriber or weekly entitlement data';
  END IF;
END;
$operator_a1_subscriber_scope_after_reassignment$;

DO $operator_a1_transfer_forbidden$
DECLARE
  v_queue_date date;
  v_rejected boolean := false;
BEGIN
  SELECT queue_date INTO v_queue_date
  FROM public.daily_queues
  WHERE id = current_setting('test.daily_queue_id')::uuid;

  BEGIN
    PERFORM public.transfer_weekly_entitlement_minutes(
      current_setting('test.assignment_source_allocation_id')::uuid,
      v_queue_date + 3,
      1,
      'محاولة نقل دقائق تخص مشترك مشغّل آخر'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Former operator transferred another operator weekly entitlement minutes';
  END IF;
END;
$operator_a1_transfer_forbidden$;

-- The global queue still exposes the turn position, but not another operator's
-- subscriber identity, branch, minutes, operation, or event metadata.
DO $operator_a1_redacted_queue_view$
DECLARE
  v_queue_id uuid := current_setting('test.assignment_future_queue_id')::uuid;
  v_view jsonb;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.queue_items
    WHERE daily_queue_id = v_queue_id
  ) THEN
    RAISE EXCEPTION 'Former operator can read another operator queue item rows directly';
  END IF;

  v_view := public.get_daily_queue_operator_view(v_queue_id);
  IF jsonb_array_length(COALESCE(v_view->'items', '[]'::jsonb)) < 1
     OR EXISTS (
       SELECT 1
       FROM jsonb_array_elements(COALESCE(v_view->'items', '[]'::jsonb)) AS item
       WHERE item->>'is_owned' <> 'false'
          OR item->>'source_type' <> 'other'
          OR item->>'subscriber_id' IS NOT NULL
          OR item->>'planned_minutes' <> '0'
          OR item->>'subscriber_name_snapshot' <> 'دور لمشغّل آخر'
     )
     OR jsonb_array_length(COALESCE(v_view->'events', '[]'::jsonb)) <> 0 THEN
    RAISE EXCEPTION 'Queue view exposed details or events for a different operator';
  END IF;
END;
$operator_a1_redacted_queue_view$;

-- Historical operation/report rows preserve their recorded owner after the
-- subscriber changes manager. The former owner keeps their own history only.
DO $operator_a1_historical_operation_report_scope$
DECLARE
  v_operations integer;
  v_events integer;
  v_segments integer;
  v_reports integer;
  v_report_items integer;
  v_source_totals integer;
  v_power_usage_rows integer;
  v_transfer_option_rows integer;
  v_report_date date;
  v_queue_date date;
  v_reassignment_event jsonb;
BEGIN
  SELECT count(*)::integer INTO v_operations
  FROM public.pump_operations
  WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
    AND subscriber_operator_id = '10000000-0000-4000-8000-000000000002';

  SELECT count(*)::integer INTO v_events
  FROM public.pump_operation_events e
  JOIN public.pump_operations op
    ON op.id = e.operation_id
   AND op.organization_id = e.organization_id
   AND op.pump_id = e.pump_id
  WHERE op.subscriber_id = '30000000-0000-4000-8000-000000000001';

  SELECT count(*)::integer INTO v_segments
  FROM public.pump_operation_power_segments seg
  JOIN public.pump_operations op
    ON op.id = seg.operation_id
   AND op.organization_id = seg.organization_id
   AND op.pump_id = seg.pump_id
  WHERE op.subscriber_id = '30000000-0000-4000-8000-000000000001';

  -- Reports are per operator's submission and date. Count only this former
  -- owner's historical reports; the pump may legitimately have reports for
  -- multiple dates and must not be treated as a single-report aggregate.
  SELECT count(*)::integer INTO v_reports
  FROM public.daily_work_reports
  WHERE pump_id = '20000000-0000-4000-8000-000000000001'
    AND operator_id = auth.uid();

  SELECT count(*)::integer INTO v_report_items
  FROM public.daily_work_report_items ri
  JOIN public.daily_work_reports r
    ON r.id = ri.daily_work_report_id
   AND r.organization_id = ri.organization_id
   AND r.pump_id = ri.pump_id
  WHERE ri.subscriber_id = '30000000-0000-4000-8000-000000000001'
    AND ri.assigned_operator_id = auth.uid()
    AND r.operator_id = auth.uid();

  SELECT count(*)::integer INTO v_source_totals
  FROM public.daily_pump_energy_source_totals totals
  JOIN public.daily_pump_energy_reports energy
    ON energy.id = totals.daily_pump_energy_report_id
   AND energy.organization_id = totals.organization_id
   AND energy.pump_id = totals.pump_id
  WHERE energy.pump_id = '20000000-0000-4000-8000-000000000001'
    AND EXISTS (
      SELECT 1 FROM public.daily_work_reports r
      WHERE r.organization_id = energy.organization_id
        AND r.pump_id = energy.pump_id
        AND r.work_date = energy.work_date
        AND r.operator_id = auth.uid()
    );

  SELECT work_date INTO v_report_date
  FROM public.daily_work_reports
  WHERE pump_id = '20000000-0000-4000-8000-000000000001'
    AND operator_id = auth.uid()
  ORDER BY work_date DESC
  LIMIT 1;

  SELECT count(*)::integer INTO v_power_usage_rows
  FROM public.get_pump_power_usage(
    v_report_date, v_report_date, 'day', '20000000-0000-4000-8000-000000000001'
  );

  SELECT queue_date INTO v_queue_date
  FROM public.daily_queues
  WHERE id = current_setting('test.daily_queue_id')::uuid;

  IF (SELECT count(*) FROM public.get_daily_work_report_allocations(
        '20000000-0000-4000-8000-000000000001',
        (SELECT queue_date FROM public.daily_queues
         WHERE id = current_setting('test.assignment_future_queue_id')::uuid)
      ) WHERE operator_id = auth.uid()) <> 0 THEN
    RAISE EXCEPTION 'Former operator can view a future allocation after subscriber reassignment';
  END IF;

  SELECT count(*)::integer INTO v_transfer_option_rows
  FROM public.get_weekly_entitlement_transfer_options(
    '20000000-0000-4000-8000-000000000001', v_queue_date + 3
  );

  IF v_operations < 1 OR v_events < 1 OR v_segments < 1
     OR v_reports < 1 OR v_report_items < 1 OR v_source_totals < 1
     OR v_power_usage_rows < 1 OR v_transfer_option_rows <> 0 THEN
    RAISE EXCEPTION 'Former operator historical scope mismatch: ops %, events %, segments %, reports %, items %, sources %, power rows %, transfer options %',
      v_operations, v_events, v_segments, v_reports, v_report_items, v_source_totals,
      v_power_usage_rows, v_transfer_option_rows;
  END IF;
END;
$operator_a1_historical_operation_report_scope$;

DO $operator_a1_cannot_write_new_owner_report_item$
DECLARE
  v_queue_date date;
  v_target_date date;
  v_rejected boolean := false;
  v_started_at timestamptz;
  v_ended_at timestamptz;
BEGIN
  SELECT queue_date INTO v_queue_date
  FROM public.daily_queues
  WHERE id = current_setting('test.daily_queue_id')::uuid;
  v_target_date := v_queue_date + 1;
  v_started_at := (v_target_date + time '07:00') AT TIME ZONE 'Asia/Hebron';
  v_ended_at := (v_target_date + time '08:00') AT TIME ZONE 'Asia/Hebron';

  BEGIN
    PERFORM public.save_daily_work_report(
      '20000000-0000-4000-8000-000000000001',
      v_started_at,
      v_ended_at,
      0,
      '[]'::jsonb,
      jsonb_build_array(jsonb_build_object(
        'entry_type', 'additional_registered',
        'subscriber_id', '30000000-0000-4000-8000-000000000001',
        'sort_order', 0,
        'manual_minutes', 0,
        'extra_minutes', 0,
        'note', 'اختبار منع كتابة سجل لمشترك مشغّل آخر'
      )),
      false,
      NULL
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;

  IF NOT v_rejected OR EXISTS (
    SELECT 1 FROM public.daily_work_reports
    WHERE pump_id = '20000000-0000-4000-8000-000000000001'
      AND work_date = v_target_date
      AND operator_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Former operator created a report item for a subscriber assigned to another operator';
  END IF;
END;
$operator_a1_cannot_write_new_owner_report_item$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);
DO $operator_a2_current_subscriber_scope$
DECLARE
  v_queue_id uuid := current_setting('test.assignment_future_queue_id')::uuid;
  v_view jsonb;
  v_items integer;
  v_cycles integer;
  v_allocations integer;
  v_power_usage_rows integer;
  v_transfer_option_rows integer;
  v_report_date date;
  v_queue_date date;
  v_reassignment_event jsonb;
BEGIN
  IF (SELECT count(*) FROM public.subscribers
      WHERE id = '30000000-0000-4000-8000-000000000001') <> 1
     -- daily_queue.sql splits this subscriber's weekly quota across two dates.
     OR (SELECT count(*) FROM public.schedule_entries
         WHERE subscriber_id = '30000000-0000-4000-8000-000000000001') <> 2
     OR (SELECT count(*) FROM public.weekly_schedule_subscribers
         WHERE subscriber_id = '30000000-0000-4000-8000-000000000001') <> 1 THEN
    RAISE EXCEPTION 'New operator cannot read the reassigned subscriber and active schedule membership';
  END IF;

  SELECT count(*)::integer INTO v_cycles
  FROM public.weekly_entitlement_cycles
  WHERE subscriber_id = '30000000-0000-4000-8000-000000000001';
  SELECT count(*)::integer INTO v_allocations
  FROM public.weekly_entitlement_allocations
  WHERE subscriber_id = '30000000-0000-4000-8000-000000000001';
  IF v_cycles < 1 OR v_allocations < 1 THEN
    RAISE EXCEPTION 'New operator cannot read current weekly entitlement balance';
  END IF;

  IF (SELECT count(*) FROM public.get_daily_work_report_allocations(
        '20000000-0000-4000-8000-000000000001',
        (SELECT queue_date FROM public.daily_queues
         WHERE id = v_queue_id)
      ) WHERE operator_id = auth.uid()) < 1 THEN
    RAISE EXCEPTION 'New operator cannot load work-date entitlement ownership after reassignment';
  END IF;

  SELECT count(*)::integer INTO v_items
  FROM public.queue_items
  WHERE daily_queue_id = v_queue_id
    AND subscriber_id = '30000000-0000-4000-8000-000000000001'
    AND assigned_operator_id = auth.uid();
  IF v_items < 1 THEN
    RAISE EXCEPTION 'New operator cannot read their reassigned waiting queue items';
  END IF;

  v_view := public.get_daily_queue_operator_view(v_queue_id);
  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_view->'items', '[]'::jsonb)) AS item
    WHERE item->>'is_owned' = 'true'
      AND item->>'subscriber_id' = '30000000-0000-4000-8000-000000000001'
      AND item->>'subscriber_name_snapshot' = 'مشترك أ 1'
  ) OR NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_view->'events', '[]'::jsonb)) AS event
    WHERE event->>'event_type' = 'item_operator_reassigned'
  ) THEN
    RAISE EXCEPTION 'New operator queue view did not return owned item details and reassignment event';
  END IF;

  SELECT event_row.value INTO v_reassignment_event
  FROM jsonb_array_elements(COALESCE(v_view->'events', '[]'::jsonb)) AS event_row(value)
  WHERE event_row.value->>'event_type' = 'item_operator_reassigned'
  LIMIT 1;

  IF v_reassignment_event IS NULL
     OR v_reassignment_event->>'actor_id' IS NOT NULL
     OR v_reassignment_event->>'reason' IS NOT NULL
     OR COALESCE(v_reassignment_event->'metadata', '{}'::jsonb) <> '{}'::jsonb THEN
    RAISE EXCEPTION 'Reassignment event leaked the manager identity, internal reason, or metadata to the new operator';
  END IF;

  IF (SELECT count(*) FROM public.queue_item_events
      WHERE daily_queue_id = v_queue_id
        AND queue_item_id IN (
          SELECT id FROM public.queue_items
          WHERE daily_queue_id = v_queue_id
            AND subscriber_id = '30000000-0000-4000-8000-000000000001'
        )
        AND event_type = 'item_operator_reassigned') <> 0 THEN
    RAISE EXCEPTION 'New operator directly selected an event created by the manager';
  END IF;

  -- The new operator must not query an old owner's report date through RLS.
  -- Use the daily queue's known date to verify their power view independently.
  SELECT queue_date INTO v_queue_date
  FROM public.daily_queues
  WHERE id = current_setting('test.daily_queue_id')::uuid;
  v_report_date := v_queue_date;

  SELECT count(*)::integer INTO v_power_usage_rows
  FROM public.get_pump_power_usage(
    v_report_date, v_report_date, 'day', '20000000-0000-4000-8000-000000000001'
  );

  SELECT count(*)::integer INTO v_transfer_option_rows
  FROM public.get_weekly_entitlement_transfer_options(
    '20000000-0000-4000-8000-000000000001', v_queue_date + 3
  );

  IF v_power_usage_rows < 1 OR v_transfer_option_rows < 1 THEN
    RAISE EXCEPTION 'New operator must read shared pump energy and their own weekly transfer options: power rows %, transfer options %',
      v_power_usage_rows, v_transfer_option_rows;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.pump_operations
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
      AND subscriber_operator_id = '10000000-0000-4000-8000-000000000002'
  ) OR EXISTS (
    SELECT 1
    FROM public.pump_operation_events e
    JOIN public.pump_operations op
      ON op.id = e.operation_id
     AND op.organization_id = e.organization_id
     AND op.pump_id = e.pump_id
    WHERE op.subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) OR (
    SELECT count(*) FROM public.daily_work_reports
    WHERE pump_id = '20000000-0000-4000-8000-000000000001'
      AND work_date = DATE '2026-01-20'
  ) <> 1 OR NOT EXISTS (
    SELECT 1 FROM public.daily_work_reports
    WHERE pump_id = '20000000-0000-4000-8000-000000000001'
      AND work_date = DATE '2026-01-20'
      AND operator_id = auth.uid()
  ) OR EXISTS (
    SELECT 1
    FROM public.daily_work_report_items ri
    JOIN public.daily_work_reports r
      ON r.id = ri.daily_work_report_id
     AND r.organization_id = ri.organization_id
     AND r.pump_id = ri.pump_id
    WHERE ri.subscriber_id = '30000000-0000-4000-8000-000000000001'
      AND r.operator_id <> auth.uid()
  ) THEN
    RAISE EXCEPTION 'New operator must see only their own report and must not inherit another operator report items';
  END IF;
END;
$operator_a2_current_subscriber_scope$;
RESET ROLE;

-- Supervisors keep pump-wide read access but do not receive operator controls.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000005', true);
DO $supervisor_queue_is_read_only$
DECLARE
  v_queue_id uuid := current_setting('test.assignment_future_queue_id')::uuid;
  v_view jsonb;
BEGIN
  v_view := public.get_daily_queue_operator_view(v_queue_id);

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(v_view->'items', '[]'::jsonb)) AS item
    WHERE item->>'subscriber_id' = '30000000-0000-4000-8000-000000000001'
      AND item->>'subscriber_name_snapshot' = 'مشترك أ 1'
      AND item->>'is_owned' = 'false'
  ) THEN
    RAISE EXCEPTION 'Supervisor lost pump-wide read access or was incorrectly granted operator ownership controls';
  END IF;
END;
$supervisor_queue_is_read_only$;
RESET ROLE;

-- Assignment history is append-only and visible only to the organization manager.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000003', true);
DO $subscriber_operator_history_not_visible_to_operator$
BEGIN
  IF (SELECT count(*) FROM public.subscriber_operator_assignment_events
      WHERE subscriber_id = '30000000-0000-4000-8000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'Operator can read manager-only subscriber assignment history';
  END IF;
END;
$subscriber_operator_history_not_visible_to_operator$;
RESET ROLE;

-- The initial assignment reason for a newly created subscriber is server-authored;
-- a client-settable custom GUC must not forge the audit reason.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DO $subscriber_assignment_insert_reason_not_forged$
DECLARE
  v_subscriber_id uuid;
BEGIN
  PERFORM set_config('water_management.subscriber_operator_reason', 'سبب مزور من العميل', true);

  INSERT INTO public.subscribers (
    organization_id, pump_id, operator_id, full_name, phone
  ) VALUES (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '20000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000003',
    'مشترك اختبار سجل الإسناد',
    '+970599888801'
  )
  RETURNING id INTO v_subscriber_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.subscriber_operator_assignment_events
    WHERE subscriber_id = v_subscriber_id
      AND actor_id = auth.uid()
      AND new_operator_id = '10000000-0000-4000-8000-000000000003'
      AND reason = 'إسناد عند إنشاء المشترك'
  ) OR EXISTS (
    SELECT 1 FROM public.subscriber_operator_assignment_events
    WHERE subscriber_id = v_subscriber_id
      AND reason = 'سبب مزور من العميل'
  ) THEN
    RAISE EXCEPTION 'Client-set reason GUC forged the initial subscriber assignment audit event';
  END IF;

  DELETE FROM public.subscribers WHERE id = v_subscriber_id;
END;
$subscriber_assignment_insert_reason_not_forged$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DO $subscriber_operator_history_append_only$
DECLARE
  v_update_rejected boolean := false;
  v_delete_rejected boolean := false;
BEGIN
  IF (SELECT count(*) FROM public.subscriber_operator_assignment_events
      WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
        AND organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        AND actor_id = '10000000-0000-4000-8000-000000000001'
        AND reason IN (
          'تهيئة مسؤول المشترك في اختبار المؤسسة أ',
          'إعادة توزيع مسؤولية المشترك إلى المشغّل الثاني'
        )) <> 2
     OR NOT EXISTS (
       SELECT 1 FROM public.subscriber_operator_assignment_events
       WHERE subscriber_id = '30000000-0000-4000-8000-000000000001'
         AND previous_operator_id = '10000000-0000-4000-8000-000000000002'
         AND new_operator_id = '10000000-0000-4000-8000-000000000003'
         AND actor_id = '10000000-0000-4000-8000-000000000001'
         AND reason = 'إعادة توزيع مسؤولية المشترك إلى المشغّل الثاني'
     ) THEN
    RAISE EXCEPTION 'Assignment history did not preserve the exact actor, previous/new owner, and reason';
  END IF;

  BEGIN
    UPDATE public.subscriber_operator_assignment_events
    SET reason = 'عبث بالسجل'
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN
    v_update_rejected := true;
  END;
  BEGIN
    DELETE FROM public.subscriber_operator_assignment_events
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN
    v_delete_rejected := true;
  END;
  IF NOT v_update_rejected OR NOT v_delete_rejected THEN
    RAISE EXCEPTION 'Subscriber assignment history accepted update or delete';
  END IF;
END;
$subscriber_operator_history_append_only$;
RESET ROLE;

-- A manager from another tenant must not read organization A assignment history.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000006', true);
DO $subscriber_operator_history_cross_tenant$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.subscriber_operator_assignment_events
    WHERE organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
       OR subscriber_id = '30000000-0000-4000-8000-000000000001'
  ) THEN
    RAISE EXCEPTION 'Tenant B manager read tenant A subscriber assignment history';
  END IF;
END;
$subscriber_operator_history_cross_tenant$;
RESET ROLE;

-- A former owner cannot start a registered subscriber after reassignment.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000002', true);
DO $subscriber_operator_wrong_executor$
DECLARE
  v_rejected boolean := false;
  v_source_id uuid;
BEGIN
  SELECT id INTO v_source_id
  FROM public.pump_power_sources
  WHERE pump_id = '20000000-0000-4000-8000-000000000001'
    AND organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    AND is_active
  ORDER BY created_at
  LIMIT 1;

  BEGIN
    PERFORM public.start_pump_operation(
      '20000000-0000-4000-8000-000000000001',
      '30000000-0000-4000-8000-000000000001',
      NULL,
      5,
      v_source_id
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A former subscriber operator started an operation after reassignment';
  END IF;
END;
$subscriber_operator_wrong_executor$;
RESET ROLE;

DO $subscriber_operator_active_operation_fixture$
DECLARE
  v_operation_id uuid;
BEGIN
  INSERT INTO public.pump_operations (
    organization_id, pump_id, subscriber_id, subscriber_name,
    operator_id, planned_minutes
  ) VALUES (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '20000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000001',
    'مشترك أ 1',
    '10000000-0000-4000-8000-000000000003',
    5
  )
  RETURNING id INTO v_operation_id;
  PERFORM set_config('test.assignment_active_operation_id', v_operation_id::text, true);
END;
$subscriber_operator_active_operation_fixture$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DO $subscriber_operator_active_operation_guard$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM public.assign_subscriber_operator(
      '30000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000002',
      'محاولة تغيير المسؤولية أثناء التشغيل'
    );
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Subscriber reassignment was allowed during a running operation';
  END IF;
END;
$subscriber_operator_active_operation_guard$;
RESET ROLE;

UPDATE public.pump_operations
SET status = 'completed',
    ended_at = clock_timestamp(),
    actual_seconds = 0
WHERE id = current_setting('test.assignment_active_operation_id')::uuid;

DO $daily_work_report_acl$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgname='delete_pump_daily_work_reports'
      AND tgrelid='public.pumps'::regclass
      AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='water_management_private'
      AND p.proname='delete_pump_daily_work_reports'
      AND p.prosecdef
      AND p.proconfig @> ARRAY['search_path=""']
  ) OR pg_catalog.has_function_privilege(
    'authenticated','water_management_private.delete_pump_daily_work_reports()','EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon','water_management_private.delete_pump_daily_work_reports()','EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Daily report teardown must be trigger-only private SECURITY DEFINER';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_work_reports'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_work_source_totals'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_work_report_items'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_work_report_events'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_pump_energy_reports'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_pump_energy_source_totals'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_pump_energy_report_events'::regclass) THEN
    RAISE EXCEPTION 'RLS must be enabled on all daily work and shared pump energy report tables';
  END IF;
  IF pg_catalog.has_table_privilege('anon','public.daily_work_reports','SELECT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_reports','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_reports','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_source_totals','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_report_items','DELETE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_report_events','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_report_events','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_report_events','DELETE')
     OR pg_catalog.has_table_privilege('anon','public.daily_pump_energy_reports','SELECT')
     OR pg_catalog.has_table_privilege('anon','public.daily_pump_energy_source_totals','SELECT')
     OR pg_catalog.has_table_privilege('anon','public.daily_pump_energy_report_events','SELECT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_pump_energy_reports','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_pump_energy_reports','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_pump_energy_reports','DELETE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_pump_energy_source_totals','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_pump_energy_source_totals','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_pump_energy_source_totals','DELETE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_pump_energy_report_events','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_pump_energy_report_events','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_pump_energy_report_events','DELETE') THEN
    RAISE EXCEPTION 'Daily work or shared energy report write privileges are too broad';
  END IF;
END;
$daily_work_report_acl$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DO $tenant_a_cannot_see_tenant_b_operation$
BEGIN
  IF (SELECT count(*) FROM public.pump_operations
      WHERE pump_id = '20000000-0000-4000-8000-000000000003') <> 0
     OR (SELECT count(*) FROM public.pump_operation_events
         WHERE pump_id = '20000000-0000-4000-8000-000000000003') <> 0 THEN
    RAISE EXCEPTION 'Tenant A manager read an operation/event from tenant B';
  END IF;
END;
$tenant_a_cannot_see_tenant_b_operation$;
RESET ROLE;

-- Operation event and session rows are removed before the test deletes pumps with RESTRICT FKs.
DELETE FROM public.daily_work_report_events
WHERE pump_id <> '20000000-0000-4000-8000-000000000003';
DELETE FROM public.daily_work_report_items
WHERE pump_id <> '20000000-0000-4000-8000-000000000003';
DELETE FROM public.daily_work_source_totals
WHERE pump_id <> '20000000-0000-4000-8000-000000000003';
DELETE FROM public.daily_work_reports
WHERE pump_id <> '20000000-0000-4000-8000-000000000003';
-- Queue items retain operation_id with ON DELETE RESTRICT; clear the queue
-- event/item/snapshot graph before removing operation sessions.
DELETE FROM public.queue_item_events;
DELETE FROM public.queue_items;
DELETE FROM public.daily_queues;
DELETE FROM public.pump_operation_power_segments;
DELETE FROM public.pump_operation_events;
DELETE FROM public.pump_operations;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000008', true);
SELECT test_support.assert_scope('unassigned user', 0, 0, 0, 0, 1);
RESET ROLE;

-- Anonymous API access has no table grants.
SET LOCAL ROLE anon;
DO $anonymous_access$
DECLARE v_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM count(id) FROM public.pumps;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Anonymous role unexpectedly read tenant data';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM water_management_private.current_user_role();
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Anonymous role unexpectedly executed a private authorization helper';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.create_organization('مؤسسة غير مصرح بها');
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Anonymous role unexpectedly executed organization onboarding';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM water_management_private.create_organization('مؤسسة داخلية غير مصرح بها');
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Anonymous role unexpectedly executed the private onboarding implementation';
  END IF;
END;
$anonymous_access$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000009', true);
DO $onboarding$
DECLARE v_organization_id uuid;
BEGIN
  v_organization_id := public.create_organization('مؤسسة التهيئة');
  IF v_organization_id IS NULL
     OR (SELECT water_management_private.current_user_role()) <> 'manager'::public.app_role
     OR (SELECT water_management_private.current_user_organization_id()) <> v_organization_id THEN
    RAISE EXCEPTION 'Secure onboarding did not establish the manager profile correctly';
  END IF;
END;
$onboarding$;
SELECT test_support.assert_scope('onboarded manager', 1, 0, 0, 0, 1);

DO $onboarding_replay$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM public.create_organization('مؤسسة ثانية');
  EXCEPTION WHEN raise_exception THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An already-onboarded user created a second organization';
  END IF;
END;
$onboarding_replay$;

RESET ROLE;


-- Platform administrator is a web-console role and organization provisioning is server-only.
INSERT INTO auth.users (id,email,raw_user_meta_data)
VALUES ('10000000-0000-4000-8000-000000000012','platform-admin@example.test','{"display_name":"مدير المنصة"}');
UPDATE public.profiles
SET role='platform_admin'::public.app_role,
    organization_id=NULL
WHERE id='10000000-0000-4000-8000-000000000012';

-- Managed account quotas, forced password change, and old-token fencing.
INSERT INTO auth.users (id,email,raw_user_meta_data) VALUES
('10000000-0000-4000-8000-000000000010','managed-10@example.test','{"display_name":"موظف مؤقت"}'),
('10000000-0000-4000-8000-000000000011','managed-11@example.test','{"display_name":"موظف إضافي"}');
UPDATE public.organizations SET account_limit=6 WHERE id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
SET LOCAL ROLE service_role;
SELECT public.assign_managed_user('10000000-0000-4000-8000-000000000010','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','operator'::public.app_role,'worker10','موظف مؤقت');
DO $managed_account_quota$
DECLARE v_rejected boolean:=false;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id='10000000-0000-4000-8000-000000000010' AND username='worker10' AND must_change_password AND role='operator'::public.app_role) THEN RAISE EXCEPTION 'Managed account was not provisioned with mandatory password change';END IF;
 BEGIN
  PERFORM public.assign_managed_user('10000000-0000-4000-8000-000000000011','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','operator'::public.app_role,'worker11','موظف إضافي');
 EXCEPTION WHEN raise_exception THEN v_rejected:=true;END;
 IF NOT v_rejected THEN RAISE EXCEPTION 'Organization account quota was exceeded';END IF;
 v_rejected:=false;
 BEGIN
  PERFORM public.set_organization_account_limit('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',5);
 EXCEPTION WHEN raise_exception THEN v_rejected:=true;END;
 IF NOT v_rejected THEN RAISE EXCEPTION 'Account limit was reduced below current account count';END IF;
END;$managed_account_quota$;
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000010',true);
SELECT set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000010","role":"authenticated","iat":1000}',true);
SELECT test_support.assert_scope('temporary-password account',0,0,0,0,1);
RESET ROLE;
UPDATE public.profiles SET must_change_password=false,session_invalid_before=to_timestamp(2000000000) WHERE id='10000000-0000-4000-8000-000000000010';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000010',true);
SELECT set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000010","role":"authenticated","iat":1000}',true);
SELECT test_support.assert_scope('pre-reset token fenced',0,0,0,0,1);
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000010',true);
SELECT set_config('request.jwt.claims','{"sub":"10000000-0000-4000-8000-000000000010","role":"authenticated","iat":2100000000}',true);
SELECT test_support.assert_scope('post-reset token accepted',1,0,0,0,1);
RESET ROLE;
DO $account_management_acl$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_catalog.pg_enum e JOIN pg_catalog.pg_type t ON t.oid=e.enumtypid WHERE t.typname='app_role' AND e.enumlabel='platform_admin') THEN RAISE EXCEPTION 'Platform administrator role was not added';END IF;
 IF pg_catalog.has_function_privilege('authenticated','public.assign_managed_user(uuid, uuid, public.app_role, text, text)','EXECUTE')
 OR NOT pg_catalog.has_function_privilege('service_role','public.assign_managed_user(uuid, uuid, public.app_role, text, text)','EXECUTE') THEN RAISE EXCEPTION 'Managed account assignment RPC grants are incorrect';END IF;
 IF pg_catalog.has_table_privilege('authenticated','public.account_audit_log','SELECT') OR pg_catalog.has_table_privilege('anon','public.account_audit_log','SELECT') THEN RAISE EXCEPTION 'Account audit log is exposed to API clients';END IF;
 IF pg_catalog.has_function_privilege('anon','public.create_platform_organization(uuid,text)','EXECUTE')
 OR pg_catalog.has_function_privilege('authenticated','public.create_platform_organization(uuid,text)','EXECUTE')
 OR NOT pg_catalog.has_function_privilege('service_role','public.create_platform_organization(uuid,text)','EXECUTE') THEN
  RAISE EXCEPTION 'Platform organization provisioning RPC grants are incorrect';
 END IF;
 IF EXISTS (
  SELECT 1 FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='create_platform_organization' AND p.prosecdef
 ) THEN RAISE EXCEPTION 'Platform organization provisioning must use SECURITY INVOKER';END IF;
END;$account_management_acl$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000012',true);
DO $platform_admin_direct_rpc$
DECLARE v_rejected boolean:=false;
BEGIN
 BEGIN
  PERFORM public.create_platform_organization('10000000-0000-4000-8000-000000000012','مؤسسة ممنوعة');
 EXCEPTION WHEN insufficient_privilege THEN v_rejected:=true;END;
 IF NOT v_rejected THEN RAISE EXCEPTION 'Authenticated platform admin directly executed privileged organization RPC';END IF;
END;$platform_admin_direct_rpc$;
RESET ROLE;

SET LOCAL ROLE service_role;
SELECT * FROM public.create_platform_organization(
 '10000000-0000-4000-8000-000000000012',
 'مؤسسة أنشأها مدير المنصة'
);
RESET ROLE;

DO $platform_organization_audit$
DECLARE v_org public.organizations%ROWTYPE;
BEGIN
 SELECT * INTO v_org FROM public.organizations
 WHERE name='مؤسسة أنشأها مدير المنصة';
 IF v_org.id IS NULL
 OR v_org.created_by<>'10000000-0000-4000-8000-000000000012'::uuid
 OR v_org.account_limit<>5 THEN
  RAISE EXCEPTION 'Platform organization was not provisioned with the expected owner and default quota';
 END IF;
 IF NOT EXISTS (
  SELECT 1 FROM public.account_audit_log
  WHERE actor_id='10000000-0000-4000-8000-000000000012'::uuid
    AND organization_id=v_org.id
    AND action='organization_created'
    AND metadata->>'organization_name'='مؤسسة أنشأها مدير المنصة'
 ) THEN
  RAISE EXCEPTION 'Platform organization creation was not atomically audited';
 END IF;
END;$platform_organization_audit$;
-- Retrospective report rows hold RESTRICT references to pump power sources.
-- Remove the tenant B report ledger explicitly before the pump/source cascade.
DELETE FROM public.queue_item_events;
DELETE FROM public.queue_items;
DELETE FROM public.daily_queues;
DELETE FROM public.daily_work_report_events
WHERE organization_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  AND pump_id='20000000-0000-4000-8000-000000000003';
DELETE FROM public.daily_work_report_items
WHERE organization_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  AND pump_id='20000000-0000-4000-8000-000000000003';
DELETE FROM public.daily_work_source_totals
WHERE organization_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  AND pump_id='20000000-0000-4000-8000-000000000003';
DO $delete_tenant_b_pump_as_system$
DECLARE
  v_previous_claim text := current_setting('request.jwt.claim.sub', true);
BEGIN
  -- This fixture models a system/database lifecycle delete, not an action
  -- performed by the last JWT identity used by preceding tests.
  PERFORM set_config('request.jwt.claim.sub', '', true);
  DELETE FROM public.pumps
  WHERE id = '20000000-0000-4000-8000-000000000003';
  PERFORM set_config('request.jwt.claim.sub', COALESCE(v_previous_claim, ''), true);
END;
$delete_tenant_b_pump_as_system$;
DO $daily_report_pump_teardown$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.daily_work_reports
    WHERE organization_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      AND pump_id='20000000-0000-4000-8000-000000000003'
  ) OR EXISTS (
    SELECT 1 FROM public.daily_work_source_totals
    WHERE pump_id='20000000-0000-4000-8000-000000000003'
  ) OR EXISTS (
    SELECT 1 FROM public.daily_pump_energy_reports
    WHERE pump_id='20000000-0000-4000-8000-000000000003'
  ) OR EXISTS (
    SELECT 1 FROM public.daily_pump_energy_source_totals
    WHERE pump_id='20000000-0000-4000-8000-000000000003'
  ) OR EXISTS (
    SELECT 1 FROM public.daily_pump_energy_report_events
    WHERE pump_id='20000000-0000-4000-8000-000000000003'
  ) OR EXISTS (
    SELECT 1 FROM public.pump_power_sources
    WHERE pump_id='20000000-0000-4000-8000-000000000003'
  ) THEN
    RAISE EXCEPTION 'Pump teardown must remove daily work and shared energy report children before its power sources';
  END IF;
END;
$daily_report_pump_teardown$;
DO $delete_behavior$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.subscribers
    WHERE id = '30000000-0000-4000-8000-000000000004'
      AND pump_id IS NULL
      AND operator_id IS NULL
      AND branch_id IS NULL
      AND organization_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  ) THEN
    RAISE EXCEPTION 'Pump deletion did not preserve the subscriber while clearing its pump, branch, and operator assignment';
  END IF;
END;
$delete_behavior$;

DO $pump_delete_assignment_audit$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.subscriber_operator_assignment_events
    WHERE subscriber_id = '30000000-0000-4000-8000-000000000004'
      AND organization_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      AND previous_operator_id = '10000000-0000-4000-8000-000000000007'
      AND new_operator_id IS NULL
      AND new_operator_name IS NULL
      AND actor_id IS NULL
      AND actor_type = 'system'
      AND reason = 'إلغاء إسناد المشترك تلقائيًا بسبب حذف الغطاس'
  ) THEN
    RAISE EXCEPTION 'Pump deletion did not append a system audit event for subscriber operator unassignment';
  END IF;
END;
$pump_delete_assignment_audit$;

-- Public portal lookup is service-only and requires exact number + phone matching.
SET LOCAL ROLE service_role;
DO $subscriber_portal_lookup$
DECLARE
  v_number integer;
  v_result record;
  v_attempt integer;
BEGIN
  SELECT subscriber_number INTO v_number
  FROM public.subscribers
  WHERE id='30000000-0000-4000-8000-000000000001';

  IF NOT pg_catalog.has_schema_privilege('service_role', 'extensions', 'USAGE') THEN
    RAISE EXCEPTION 'Trusted portal RPC role cannot use the pgcrypto extensions schema';
  END IF;

  IF v_number NOT BETWEEN 100000 AND 999999
     OR (SELECT pg_catalog.count(*) FROM public.subscribers WHERE subscriber_number IS NULL) > 0
     OR (SELECT pg_catalog.count(*) FROM public.subscribers)
        <> (SELECT pg_catalog.count(DISTINCT subscriber_number) FROM public.subscribers) THEN
    RAISE EXCEPTION 'Subscriber numbers are not six-digit, assigned, and globally unique';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_indexes
    WHERE schemaname='public'
      AND indexname='subscribers_subscriber_number_global_uidx'
      AND indexdef ILIKE 'CREATE UNIQUE INDEX%'
  ) THEN
    RAISE EXCEPTION 'Global unique subscriber-number index is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_indexes
    WHERE schemaname='public'
      AND indexname='subscribers_org_phone_normalized_idx'
      AND indexdef ILIKE 'CREATE INDEX%'
      AND indexdef NOT ILIKE 'CREATE UNIQUE INDEX%'
  ) THEN
    RAISE EXCEPTION 'Organization phone index must be non-unique so household members may share a phone';
  END IF;

  IF pg_catalog.has_table_privilege('anon','water_management_private.subscriber_number_registry','SELECT')
     OR pg_catalog.has_table_privilege('authenticated','water_management_private.subscriber_number_registry','SELECT')
     OR pg_catalog.has_table_privilege('service_role','water_management_private.subscriber_number_registry','SELECT') THEN
    RAISE EXCEPTION 'Subscriber number registry is exposed to an API role';
  END IF;


  SELECT * INTO v_result
  FROM public.lookup_subscriber_portal(v_number, '+970599111111', '203.0.113.10');
  IF NOT v_result.found
     OR v_result.subscriber_number <> v_number
     OR v_result.full_name <> 'مشترك أ 1'
     OR v_result.phone_last4 <> '1111' THEN
    RAISE EXCEPTION 'Correct six-digit subscriber number and phone did not resolve';
  END IF;

  SELECT * INTO v_result
  FROM public.lookup_subscriber_portal(v_number, '+970599999999', '203.0.113.11');
  IF v_result.found THEN
    RAISE EXCEPTION 'A wrong phone number exposed a subscriber record';
  END IF;

  -- Arabic-Indic digits must normalize to the same registered phone number.
  SELECT * INTO v_result
  FROM public.lookup_subscriber_portal(v_number, '٠٥٩٩١١١١١١', '203.0.113.12');
  IF NOT v_result.found THEN
    RAISE EXCEPTION 'Arabic-Indic phone digits did not match the subscriber';
  END IF;

  -- Six requests against one subscriber number trigger its hourly HMAC bucket.
  FOR v_attempt IN 1..3 LOOP
    SELECT * INTO v_result
    FROM public.lookup_subscriber_portal(
      v_number,
      '+97059922222' || v_attempt::text,
      '203.0.113.' || (20 + v_attempt)::text
    );
  END LOOP;

  SELECT * INTO v_result
  FROM public.lookup_subscriber_portal(v_number, '+970599222229', '203.0.113.29');
  IF NOT v_result.rate_limited THEN
    RAISE EXCEPTION 'Per-subscriber lookup rate limit did not activate after six attempts';
  END IF;
END;
$subscriber_portal_lookup$;
RESET ROLE;

-- The table owner verifies the immutable-number trigger; API roles cannot update this field.
DO $immutable_subscriber_number$
BEGIN
  BEGIN
    UPDATE public.subscribers
    SET subscriber_number = CASE WHEN subscriber_number = 999999 THEN 100000 ELSE subscriber_number + 1 END
    WHERE id='30000000-0000-4000-8000-000000000001';
    RAISE EXCEPTION 'Subscriber number mutation was not rejected';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'Subscriber number mutation was not rejected' THEN RAISE; END IF;
  END;
END;
$immutable_subscriber_number$;

-- Multiple subscribers in one household may share the same contact phone.
INSERT INTO public.subscribers (organization_id, full_name, phone)
VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'مشترك من الأسرة', '0599111111');
DO $shared_phone$
BEGIN
  IF (SELECT count(*) FROM public.subscribers
      WHERE organization_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        AND phone_normalized='0599111111') < 2 THEN
    RAISE EXCEPTION 'Household subscribers could not share one normalized phone';
  END IF;
END;
$shared_phone$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DELETE FROM public.branches WHERE id = '40000000-0000-4000-8000-000000000002';
RESET ROLE;
DO $branch_delete_behavior$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.subscribers
    WHERE id = '30000000-0000-4000-8000-000000000002'
      AND (branch_id IS NOT NULL OR pump_id <> '20000000-0000-4000-8000-000000000002')
  ) THEN
    RAISE EXCEPTION 'Deleting a branch must clear only branch_id and preserve subscriber pump_id';
  END IF;
END;
$branch_delete_behavior$;

-- Deleting a pump clears branch_id before the existing pump FK clears pump_id.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
DELETE FROM public.pumps WHERE id = '20000000-0000-4000-8000-000000000001';
RESET ROLE;
DO $pump_delete_branch_behavior$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.subscribers
    WHERE id = '30000000-0000-4000-8000-000000000001'
      AND (branch_id IS NOT NULL OR pump_id IS NOT NULL)
  ) THEN
    RAISE EXCEPTION 'Deleting a pump must clear both the subscriber branch and pump assignments';
  END IF;
END;
$pump_delete_branch_behavior$;

-- Organization deletion must cascade organization-owned rows while retaining auth profiles.
SET CONSTRAINTS pump_assignments_user_tenant_role_fkey DEFERRED;
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
  ) OR EXISTS (
    SELECT 1 FROM public.branches
    WHERE organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  ) OR EXISTS (
    SELECT 1 FROM public.weekly_schedules
    WHERE organization_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  ) OR EXISTS (
    SELECT 1 FROM public.schedule_entries
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


-- Every child-side foreign key must have a matching index in the same
-- column order as the constraint, including composite tenant constraints.
DO $tenant_fk_indexes$
DECLARE
  v_index regclass;
BEGIN
  v_index := to_regclass('public.organizations_created_by_idx');
  IF v_index IS NULL THEN
    RAISE EXCEPTION 'Missing index for organizations.created_by';
  END IF;
  IF pg_get_indexdef(v_index) NOT LIKE '%(created_by)' THEN
    RAISE EXCEPTION 'Invalid index definition for organizations.created_by';
  END IF;

  v_index := to_regclass('public.profiles_organization_id_idx');
  IF v_index IS NULL THEN
    RAISE EXCEPTION 'Missing index for profiles.organization_id';
  END IF;
  IF pg_get_indexdef(v_index) NOT LIKE '%(organization_id)' THEN
    RAISE EXCEPTION 'Invalid index definition for profiles.organization_id';
  END IF;

  v_index := to_regclass('public.pump_assignments_pump_tenant_idx');
  IF v_index IS NULL THEN
    RAISE EXCEPTION 'Missing index for pump_assignments (pump_id, organization_id)';
  END IF;
  IF pg_get_indexdef(v_index) NOT LIKE '%(pump_id, organization_id)' THEN
    RAISE EXCEPTION 'Invalid index definition for pump_assignments (pump_id, organization_id)';
  END IF;

  v_index := to_regclass('public.pump_assignments_user_tenant_role_idx');
  IF v_index IS NULL THEN
    RAISE EXCEPTION 'Missing index for pump_assignments (user_id, organization_id, assignment_role)';
  END IF;
  IF pg_get_indexdef(v_index) NOT LIKE '%(user_id, organization_id, assignment_role)' THEN
    RAISE EXCEPTION 'Invalid index definition for pump_assignments (user_id, organization_id, assignment_role)';
  END IF;

  v_index := to_regclass('public.subscribers_pump_tenant_idx');
  IF v_index IS NULL THEN
    RAISE EXCEPTION 'Missing index for subscribers (pump_id, organization_id)';
  END IF;
  IF pg_get_indexdef(v_index) NOT LIKE '%(pump_id, organization_id)' THEN
    RAISE EXCEPTION 'Invalid index definition for subscribers (pump_id, organization_id)';
  END IF;

  v_index := to_regclass('public.branches_pump_tenant_idx');
  IF v_index IS NULL OR pg_get_indexdef(v_index) NOT LIKE '%(pump_id, organization_id)' THEN
    RAISE EXCEPTION 'Missing covering index for branches pump tenant foreign key';
  END IF;

  v_index := to_regclass('public.subscribers_branch_tenant_idx');
  IF v_index IS NULL OR pg_get_indexdef(v_index) NOT LIKE '%(branch_id, organization_id, pump_id)%' THEN
    RAISE EXCEPTION 'Missing covering index for subscribers branch tenant foreign key';
  END IF;

  v_index := to_regclass('public.weekly_schedules_pump_tenant_idx');
  IF v_index IS NULL OR pg_get_indexdef(v_index) NOT LIKE '%(pump_id, organization_id)' THEN
    RAISE EXCEPTION 'Missing covering index for weekly_schedules pump tenant foreign key';
  END IF;

  v_index := to_regclass('public.weekly_schedules_created_by_idx');
  IF v_index IS NULL OR pg_get_indexdef(v_index) NOT LIKE '%(created_by)' THEN
    RAISE EXCEPTION 'Missing covering index for weekly_schedules.created_by foreign key';
  END IF;

  v_index := to_regclass('public.schedule_entries_schedule_scope_idx');
  IF v_index IS NULL OR pg_get_indexdef(v_index) NOT LIKE '%(weekly_schedule_id, organization_id, pump_id)' THEN
    RAISE EXCEPTION 'Missing covering index for schedule_entries weekly schedule foreign key';
  END IF;

  v_index := to_regclass('public.schedule_entries_subscriber_scope_idx');
  IF v_index IS NULL OR pg_get_indexdef(v_index) NOT LIKE '%(subscriber_id, organization_id, pump_id)' THEN
    RAISE EXCEPTION 'Missing covering index for schedule_entries subscriber foreign key';
  END IF;

  v_index := to_regclass('public.pump_operation_events_actor_id_idx');
  IF v_index IS NULL OR pg_get_indexdef(v_index) NOT LIKE '%(actor_id)' THEN
    RAISE EXCEPTION 'Missing covering index for pump_operation_events.actor_id';
  END IF;

  v_index := to_regclass('public.pump_operation_events_operation_scope_fk_idx');
  IF v_index IS NULL
     OR pg_get_indexdef(v_index) NOT LIKE '%(operation_id, organization_id, pump_id)' THEN
    RAISE EXCEPTION 'Missing covering index for pump_operation_events operation scope foreign key';
  END IF;
END;
$tenant_fk_indexes$;

SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
