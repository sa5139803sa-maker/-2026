-- Keep the public onboarding RPC invoker-only. Its implementation runs
-- in an unexposed schema under a dedicated, non-login, non-BYPASSRLS owner.
DO $onboarding_role$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = 'water_management_onboarding'
  ) THEN
    CREATE ROLE water_management_onboarding
      NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOINHERIT;
  END IF;
END;
$onboarding_role$;

DO $onboarding_role_guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles
    WHERE rolname = 'water_management_onboarding'
      AND rolcanlogin = false
      AND rolsuper = false
      AND rolcreatedb = false
      AND rolcreaterole = false
      AND rolreplication = false
      AND rolbypassrls = false
      AND rolinherit = false
  ) THEN
    RAISE EXCEPTION 'Existing onboarding role has unsafe attributes';
  END IF;
END;
$onboarding_role_guard$;

-- Only the migration owner can assume this role. No API role is made a member.
GRANT water_management_onboarding TO CURRENT_USER WITH SET TRUE, INHERIT FALSE;

GRANT USAGE ON SCHEMA public, water_management_private
  TO water_management_onboarding;
GRANT USAGE ON TYPE public.app_role TO water_management_onboarding;
GRANT EXECUTE ON FUNCTION water_management_private.request_user_id()
  TO water_management_onboarding;

-- Column-level grants are the hard permission boundary for this function owner.
GRANT SELECT (id, organization_id, role), UPDATE (organization_id, role)
  ON public.profiles TO water_management_onboarding;
GRANT INSERT (id, name, created_by)
  ON public.organizations TO water_management_onboarding;

-- This role cannot log in and is not granted to API roles. These narrowly scoped
-- policies allow only the dedicated onboarding function to perform its fixed flow.
DROP POLICY IF EXISTS "onboarding_select_profiles" ON public.profiles;
CREATE POLICY "onboarding_select_profiles" ON public.profiles
  FOR SELECT TO water_management_onboarding
  USING (true);

DROP POLICY IF EXISTS "onboarding_update_profiles" ON public.profiles;
CREATE POLICY "onboarding_update_profiles" ON public.profiles
  FOR UPDATE TO water_management_onboarding
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "onboarding_insert_organizations" ON public.organizations;
CREATE POLICY "onboarding_insert_organizations" ON public.organizations
  FOR INSERT TO water_management_onboarding
  WITH CHECK (
    created_by = (SELECT water_management_private.request_user_id())
  );

CREATE OR REPLACE FUNCTION water_management_private.create_organization(p_name text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user_id uuid := water_management_private.request_user_id();
  v_profile_id uuid;
  v_organization_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_name IS NULL
     OR pg_catalog.char_length(pg_catalog.btrim(p_name)) NOT BETWEEN 2 AND 120 THEN
    RAISE EXCEPTION 'Invalid organization name';
  END IF;

  SELECT p.id INTO v_profile_id
  FROM public.profiles p
  WHERE p.id = v_user_id
    AND p.organization_id IS NULL
    AND p.role = 'operator'::public.app_role
  FOR UPDATE;

  IF v_profile_id IS NULL THEN
    RAISE EXCEPTION 'Profile not found or already onboarded';
  END IF;

  v_organization_id := pg_catalog.gen_random_uuid();

  INSERT INTO public.organizations (id, name, created_by)
  VALUES (v_organization_id, pg_catalog.btrim(p_name), v_user_id);

  UPDATE public.profiles
  SET organization_id = v_organization_id,
      role = 'manager'::public.app_role
  WHERE id = v_user_id
    AND organization_id IS NULL
    AND role = 'operator'::public.app_role;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile onboarding update failed';
  END IF;

  RETURN v_organization_id;
END;
$function$;

-- ALTER FUNCTION OWNER requires CREATE on the target schema. Grant it only
-- for the ownership transfer, then remove it immediately.
GRANT CREATE ON SCHEMA water_management_private TO water_management_onboarding;
ALTER FUNCTION water_management_private.create_organization(text)
  OWNER TO water_management_onboarding;
REVOKE CREATE ON SCHEMA water_management_private FROM water_management_onboarding;

-- Helpers created by this owner must not inherit API EXECUTE privileges.
SET LOCAL ROLE water_management_onboarding;
ALTER DEFAULT PRIVILEGES
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;
RESET ROLE;

REVOKE ALL ON FUNCTION water_management_private.create_organization(text)
  FROM PUBLIC, anon, service_role, water_management_authz;
GRANT EXECUTE ON FUNCTION water_management_private.create_organization(text)
  TO authenticated;

-- Exposed RPC is invoker-only. It delegates to the unexposed, least-privilege helper.
CREATE OR REPLACE FUNCTION public.create_organization(p_name text)
RETURNS uuid
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $wrapper$
  SELECT water_management_private.create_organization(p_name);
$wrapper$;

REVOKE ALL ON FUNCTION public.create_organization(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_organization(text)
  TO authenticated;

COMMENT ON ROLE water_management_onboarding IS
  'NOLOGIN, NOBYPASSRLS owner for the single-purpose first-organization onboarding function. Not granted to API roles.';
COMMENT ON FUNCTION water_management_private.create_organization(text) IS
  'Internal onboarding implementation. Callable through the public SECURITY INVOKER wrapper; owner has column-scoped profile/organization privileges only.';
COMMENT ON FUNCTION public.create_organization(text) IS
  'Authenticated onboarding RPC. SECURITY INVOKER wrapper around the unexposed private implementation.';
