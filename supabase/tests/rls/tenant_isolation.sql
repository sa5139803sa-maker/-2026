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
    RAISE EXCEPTION 'Private pump cleanup trigger function must not be executable from the Data API';
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
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_trigger
       WHERE tgname='delete_organization_weekly_schedules'
         AND tgrelid='public.organizations'::regclass
         AND NOT tgisinternal
     ) THEN
    RAISE EXCEPTION 'Organization teardown must remove weekly schedules through its private trigger only';
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
DECLARE v_schedule_id uuid; v_entry_id uuid; v_rows bigint;
BEGIN
  INSERT INTO public.weekly_schedules (pump_id, name, effective_from, effective_to, week_starts_on)
  VALUES ('20000000-0000-4000-8000-000000000001', 'مسودة اختبار مدير', '2026-11-02', '2026-12-31', 1)
  RETURNING id INTO v_schedule_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.weekly_schedules
    WHERE id=v_schedule_id
      AND organization_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      AND pump_id='20000000-0000-4000-8000-000000000001'
      AND created_by='10000000-0000-4000-8000-000000000001'
      AND status='draft'
  ) THEN RAISE EXCEPTION 'Weekly schedule tenant, creator, or draft status was not derived safely'; END IF;

  INSERT INTO public.schedule_entries (weekly_schedule_id, subscriber_id, weekday, sort_order, planned_minutes)
  VALUES (v_schedule_id, '30000000-0000-4000-8000-000000000001', 2, 5, 35)
  RETURNING id INTO v_entry_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.schedule_entries
    WHERE id=v_entry_id
      AND organization_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      AND pump_id='20000000-0000-4000-8000-000000000001'
      AND weekly_schedule_id=v_schedule_id
  ) THEN RAISE EXCEPTION 'Schedule entry tenant scope was not derived from its parent schedule'; END IF;

  UPDATE public.schedule_entries SET planned_minutes=40 WHERE id=v_entry_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'Manager could not update an entry in a draft schedule'; END IF;

  UPDATE public.weekly_schedules SET name='مسودة اختبار مدير معدلة', effective_to='2027-01-31'
  WHERE id=v_schedule_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'Manager could not update a draft schedule'; END IF;

  DELETE FROM public.weekly_schedules WHERE id=v_schedule_id;
  IF EXISTS (SELECT 1 FROM public.schedule_entries WHERE id=v_entry_id) THEN
    RAISE EXCEPTION 'Deleting a draft schedule did not cascade its draft entries';
  END IF;
END;
$manager_weekly_schedule_write$;

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
  IF (SELECT count(*) FROM public.weekly_schedules) <> 1
     OR NOT EXISTS (SELECT 1 FROM public.weekly_schedules WHERE id='50000000-0000-4000-8000-000000000002')
     OR (SELECT count(*) FROM public.schedule_entries) <> 1 THEN
    RAISE EXCEPTION 'Collector A must read only the schedule and entries for the assigned pump';
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

  v_operation := public.pause_pump_operation(v_operation.id, 'انقطاع كهرباء تجريبي');
  IF v_operation.status <> 'paused' OR v_operation.paused_at IS NULL THEN
    RAISE EXCEPTION 'Manager pause transition did not persist';
  END IF;

  v_operation := public.resume_pump_operation(v_operation.id, v_power_source_id);
  IF v_operation.status <> 'running' OR v_operation.paused_at IS NOT NULL THEN
    RAISE EXCEPTION 'Manager resume transition did not persist';
  END IF;

  v_operation := public.complete_pump_operation(v_operation.id);
  IF v_operation.status <> 'completed'
     OR v_operation.ended_at IS NULL
     OR v_operation.actual_seconds IS NULL
     OR v_operation.actual_seconds < 0 THEN
    RAISE EXCEPTION 'Manager completion did not persist the final duration';
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
  IF v_event_types IS DISTINCT FROM ARRAY['started','paused','resumed','completed']::text[] THEN
    RAISE EXCEPTION 'Operation event timeline is incomplete or out of order: %', v_event_types;
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
  IF v_event_types IS DISTINCT FROM ARRAY['started','paused','resumed','completed']::text[] THEN
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
  IF (SELECT count(*) FROM public.pump_power_sources
      WHERE pump_id='20000000-0000-4000-8000-000000000001') <> 3 THEN
    RAISE EXCEPTION 'Assigned supervisor must read the power sources for their pump';
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
  v_report public.daily_work_reports%ROWTYPE;
  v_total_minutes numeric;
  v_rejected boolean := false;
BEGIN
  SELECT id INTO v_source_id
  FROM public.pump_power_sources
  WHERE pump_id='20000000-0000-4000-8000-000000000003'
    AND name='طاقة شمسية – مزود 2';

  v_report := public.save_daily_work_report(
    '20000000-0000-4000-8000-000000000003',
    '2026-01-09 07:00:00+02'::timestamptz,
    '2026-01-09 09:00:00+02'::timestamptz,
    20,
    jsonb_build_array(jsonb_build_object('power_source_id',v_source_id,'minutes',100)),
    jsonb_build_array(jsonb_build_object(
      'entry_type','weekly',
      'schedule_entry_id','60000000-0000-4000-8000-000000000003',
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
     OR v_report.work_date <> DATE '2026-01-09'
     OR v_report.stoppage_minutes <> 20 THEN
    RAISE EXCEPTION 'Daily work survey did not preserve its date, stoppages, or submitted state';
  END IF;

  SELECT sum(total_minutes) INTO v_total_minutes
  FROM public.get_pump_power_usage(
    DATE '2026-01-09', DATE '2026-01-09', 'day',
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
        AND operation_date=DATE '2026-01-09') <> 0 THEN
    RAISE EXCEPTION 'Daily survey created a fake pump operation';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.save_daily_work_report(
      '20000000-0000-4000-8000-000000000003',
      '2026-01-16 07:00:00+02'::timestamptz,
      '2026-01-16 09:00:00+02'::timestamptz,
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

DO $daily_work_report_acl$
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_work_reports'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_work_source_totals'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_work_report_items'::regclass)
     OR NOT (SELECT relrowsecurity FROM pg_catalog.pg_class WHERE oid='public.daily_work_report_events'::regclass) THEN
    RAISE EXCEPTION 'RLS must be enabled on all daily work report tables';
  END IF;
  IF pg_catalog.has_table_privilege('anon','public.daily_work_reports','SELECT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_reports','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_reports','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_source_totals','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_report_items','DELETE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_report_events','INSERT')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_report_events','UPDATE')
     OR pg_catalog.has_table_privilege('authenticated','public.daily_work_report_events','DELETE') THEN
    RAISE EXCEPTION 'Daily work report write privileges are too broad';
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
