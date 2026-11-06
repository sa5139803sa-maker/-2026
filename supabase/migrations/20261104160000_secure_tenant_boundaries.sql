/*
# Secure tenant and pump boundaries
- Enforce same-organization relationships with composite foreign keys.
- Use pump_assignments as the only canonical user-to-pump assignment table.
- Require assignment_role to match profiles.role.
- Add supervisor read-only pump scope and constrain staff reads to assignments.
- Keep authorization helpers in a non-exposed private schema.
*/
DO $preflight$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.pump_assignments pa
    JOIN public.pumps p ON p.id = pa.pump_id
    JOIN public.profiles pr ON pr.id = pa.user_id
    WHERE pr.organization_id IS DISTINCT FROM p.organization_id
       OR pr.role::text IS DISTINCT FROM pa.assignment_role::text
  ) THEN
    RAISE EXCEPTION 'Tenant isolation stopped: existing assignments cross organizations or do not match the assigned profile role';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.pump_assignments
    WHERE assignment_role::text IN ('operator', 'collector')
    GROUP BY pump_id, assignment_role HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Tenant isolation stopped: a pump has duplicate assigned operators or collectors';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.subscribers s
    JOIN public.pumps p ON p.id = s.pump_id
    WHERE s.organization_id IS DISTINCT FROM p.organization_id
  ) THEN
    RAISE EXCEPTION 'Tenant isolation stopped: subscribers reference pumps from another organization';
  END IF;
END;
$preflight$;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_id_organization_role_key UNIQUE (id, organization_id, role);
ALTER TABLE public.pumps
  ADD CONSTRAINT pumps_id_organization_key UNIQUE (id, organization_id);

ALTER TABLE public.pump_assignments ADD COLUMN organization_id uuid;
UPDATE public.pump_assignments pa
SET organization_id = p.organization_id
FROM public.pumps p
WHERE p.id = pa.pump_id;
ALTER TABLE public.pump_assignments ALTER COLUMN organization_id SET NOT NULL;

ALTER TABLE public.pump_assignments
  DROP CONSTRAINT IF EXISTS pump_assignments_pump_id_fkey,
  DROP CONSTRAINT IF EXISTS pump_assignments_user_id_fkey;

ALTER TABLE public.pump_assignments
  ALTER COLUMN assignment_role TYPE public.app_role
  USING assignment_role::text::public.app_role;

ALTER TABLE public.pump_assignments
  ADD CONSTRAINT pump_assignments_role_is_employee_check
  CHECK (assignment_role IN (
    'operator'::public.app_role,
    'collector'::public.app_role,
    'supervisor'::public.app_role
  ));

DROP TYPE public.assignment_role;

ALTER TABLE public.pump_assignments
  ADD CONSTRAINT pump_assignments_pump_tenant_fkey
  FOREIGN KEY (pump_id, organization_id)
  REFERENCES public.pumps (id, organization_id)
  ON DELETE CASCADE,
  ADD CONSTRAINT pump_assignments_user_tenant_role_fkey
  FOREIGN KEY (user_id, organization_id, assignment_role)
  REFERENCES public.profiles (id, organization_id, role)
  ON DELETE CASCADE
  DEFERRABLE INITIALLY DEFERRED;

CREATE UNIQUE INDEX pump_assignments_one_operator_per_pump_idx
  ON public.pump_assignments (pump_id)
  WHERE assignment_role = 'operator'::public.app_role;
CREATE UNIQUE INDEX pump_assignments_one_collector_per_pump_idx
  ON public.pump_assignments (pump_id)
  WHERE assignment_role = 'collector'::public.app_role;
CREATE INDEX pump_assignments_user_scope_idx
  ON public.pump_assignments (organization_id, user_id, assignment_role, pump_id);

ALTER TABLE public.subscribers
  DROP CONSTRAINT IF EXISTS subscribers_pump_id_fkey;
ALTER TABLE public.subscribers
  ADD CONSTRAINT subscribers_pump_tenant_fkey
  FOREIGN KEY (pump_id, organization_id)
  REFERENCES public.pumps (id, organization_id)
  ON DELETE SET NULL (pump_id);
CREATE INDEX subscribers_organization_pump_idx
  ON public.subscribers (organization_id, pump_id);

COMMENT ON TABLE public.pump_assignments IS
  'Canonical user-to-pump assignment relation. Assignment role must match profiles.role and tenant.';
COMMENT ON COLUMN public.pump_assignments.organization_id IS
  'Tenant key used by composite foreign keys to prevent cross-organization assignments.';
COMMENT ON CONSTRAINT subscribers_pump_tenant_fkey ON public.subscribers IS
  'Prevents cross-organization pump references while preserving subscriber.organization_id when a pump is deleted.';

CREATE SCHEMA IF NOT EXISTS water_management_private;
REVOKE ALL ON SCHEMA water_management_private FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA water_management_private TO authenticated, water_management_authz;

-- Own authorization helpers with a dedicated NOLOGIN role, not postgres.
-- It can bypass RLS only to read profiles, which is required to avoid policy recursion.
DO $authz_role$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'water_management_authz'
  ) THEN
    CREATE ROLE water_management_authz NOLOGIN BYPASSRLS;
  END IF;
END;
$authz_role$;
ALTER ROLE water_management_authz NOLOGIN BYPASSRLS;

-- Supabase's hosted postgres role is CREATEROLE but not SUPERUSER. PostgreSQL
-- creates the admin membership with SET FALSE by default, so explicitly allow
-- this migration role to SET ROLE before changing its own default privileges.
GRANT water_management_authz TO CURRENT_USER WITH SET TRUE, INHERIT FALSE;

GRANT USAGE ON SCHEMA public TO water_management_authz;
GRANT SELECT ON TABLE public.profiles TO water_management_authz;
GRANT USAGE ON TYPE public.app_role TO water_management_authz;
GRANT CREATE ON SCHEMA water_management_private TO water_management_authz;

-- This owner is dedicated to this application's helper functions, so its global
-- function defaults can be closed without changing postgres defaults for other apps.
SET ROLE water_management_authz;
ALTER DEFAULT PRIVILEGES
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;
RESET ROLE;

-- Supabase owns the auth schema with its managed auth-admin role. The project-level
-- postgres role cannot grant auth schema USAGE to our isolated helper owner.
-- This narrow bridge is postgres-owned, accepts no user-supplied identity, and
-- exposes only the current request's authenticated user id to the private owner.
CREATE OR REPLACE FUNCTION water_management_private.request_user_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $
  SELECT auth.uid()
$;
REVOKE ALL ON FUNCTION water_management_private.request_user_id()
  FROM PUBLIC, anon, authenticated, service_role, water_management_authz;
GRANT EXECUTE ON FUNCTION water_management_private.request_user_id()
  TO water_management_authz;

CREATE OR REPLACE FUNCTION water_management_private.current_user_organization_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.organization_id
  FROM public.profiles p
  WHERE p.id = (SELECT water_management_private.request_user_id())
$$;

CREATE OR REPLACE FUNCTION water_management_private.current_user_role()
RETURNS public.app_role
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.role
  FROM public.profiles p
  WHERE p.id = (SELECT water_management_private.request_user_id())
$$;

ALTER FUNCTION water_management_private.current_user_organization_id() OWNER TO water_management_authz;
ALTER FUNCTION water_management_private.current_user_role() OWNER TO water_management_authz;
REVOKE ALL ON FUNCTION water_management_private.current_user_organization_id() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION water_management_private.current_user_role() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.current_user_organization_id() TO authenticated;
GRANT EXECUTE ON FUNCTION water_management_private.current_user_role() TO authenticated;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_display_name text;
BEGIN
  v_display_name := pg_catalog.btrim(NEW.raw_user_meta_data ->> 'display_name');
  IF v_display_name IS NULL
     OR pg_catalog.char_length(v_display_name) NOT BETWEEN 2 AND 120 THEN
    v_display_name := pg_catalog.left(
      pg_catalog.split_part(COALESCE(NEW.email, 'مستخدم جديد'), '@', 1),
      120
    );
  END IF;
  IF pg_catalog.char_length(COALESCE(v_display_name, '')) < 2 THEN
    v_display_name := 'مستخدم جديد';
  END IF;

  INSERT INTO public.profiles (id, display_name)
  VALUES (NEW.id, v_display_name)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_organization(p_name text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_profile public.profiles%ROWTYPE;
  v_organization_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_name IS NULL
     OR pg_catalog.char_length(pg_catalog.btrim(p_name)) NOT BETWEEN 2 AND 120 THEN
    RAISE EXCEPTION 'Invalid organization name';
  END IF;

  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = v_user_id
  FOR UPDATE;

  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Profile not found';
  END IF;
  IF v_profile.organization_id IS NOT NULL THEN
    RAISE EXCEPTION 'Organization already assigned';
  END IF;

  INSERT INTO public.organizations (name, created_by)
  VALUES (pg_catalog.btrim(p_name), v_user_id)
  RETURNING id INTO v_organization_id;

  UPDATE public.profiles
  SET organization_id = v_organization_id, role = 'manager'::public.app_role
  WHERE id = v_user_id;
  RETURN v_organization_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_organization(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_organization(text) TO authenticated;

DROP POLICY IF EXISTS "members_select_organizations" ON public.organizations;
CREATE POLICY "members_select_organizations" ON public.organizations
  FOR SELECT TO authenticated
  USING (id = (SELECT water_management_private.current_user_organization_id()));

DROP POLICY IF EXISTS "users_select_own_profile" ON public.profiles;
CREATE POLICY "users_select_own_profile" ON public.profiles
  FOR SELECT TO authenticated
  USING (
    id = (SELECT auth.uid())
    OR (
      organization_id = (SELECT water_management_private.current_user_organization_id())
      AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    )
  );

DROP POLICY IF EXISTS "users_update_own_display_name" ON public.profiles;
CREATE POLICY "users_update_own_display_name" ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = (SELECT auth.uid()))
  WITH CHECK (id = (SELECT auth.uid()));

DROP POLICY IF EXISTS "members_select_pumps" ON public.pumps;
CREATE POLICY "members_select_pumps" ON public.pumps
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1 FROM public.pump_assignments pa
        WHERE pa.pump_id = pumps.id
          AND pa.organization_id = pumps.organization_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
      )
    )
  );

DROP POLICY IF EXISTS "managers_insert_pumps" ON public.pumps;
CREATE POLICY "managers_insert_pumps" ON public.pumps
  FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS "managers_update_pumps" ON public.pumps;
CREATE POLICY "managers_update_pumps" ON public.pumps
  FOR UPDATE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  )
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS "managers_delete_pumps" ON public.pumps;
CREATE POLICY "managers_delete_pumps" ON public.pumps
  FOR DELETE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS "members_select_assignments" ON public.pump_assignments;
CREATE POLICY "members_select_assignments" ON public.pump_assignments
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR user_id = (SELECT auth.uid())
    )
  );

DROP POLICY IF EXISTS "managers_insert_assignments" ON public.pump_assignments;
-- The composite FK pump_assignments_pump_tenant_fkey validates pump_id/organization_id.
-- Do not query pumps here: its SELECT policy consults pump_assignments and would recurse.
CREATE POLICY "managers_insert_assignments" ON public.pump_assignments
  FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS "managers_update_assignments" ON public.pump_assignments;
CREATE POLICY "managers_update_assignments" ON public.pump_assignments
  FOR UPDATE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  )
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS "managers_delete_assignments" ON public.pump_assignments;
CREATE POLICY "managers_delete_assignments" ON public.pump_assignments
  FOR DELETE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS "members_select_subscribers" ON public.subscribers;
CREATE POLICY "members_select_subscribers" ON public.subscribers
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR (
        pump_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM public.pump_assignments pa
          WHERE pa.pump_id = subscribers.pump_id
            AND pa.organization_id = subscribers.organization_id
            AND pa.user_id = (SELECT auth.uid())
            AND pa.assignment_role = (SELECT water_management_private.current_user_role())
        )
      )
    )
  );

DROP POLICY IF EXISTS "managers_insert_subscribers" ON public.subscribers;
CREATE POLICY "managers_insert_subscribers" ON public.subscribers
  FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS "managers_update_subscribers" ON public.subscribers;
CREATE POLICY "managers_update_subscribers" ON public.subscribers
  FOR UPDATE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  )
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS "managers_delete_subscribers" ON public.subscribers;
CREATE POLICY "managers_delete_subscribers" ON public.subscribers
  FOR DELETE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );
