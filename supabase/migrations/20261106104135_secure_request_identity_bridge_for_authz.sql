-- The managed auth schema is owned by Supabase's internal auth-admin role.
-- Keep the isolated RLS helper owner independent from direct auth schema ACLs.
GRANT USAGE ON SCHEMA water_management_private TO water_management_authz;

CREATE OR REPLACE FUNCTION water_management_private.request_user_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT auth.uid()
$$;
REVOKE ALL ON FUNCTION water_management_private.request_user_id()
  FROM PUBLIC, anon, authenticated, service_role, water_management_authz;
GRANT EXECUTE ON FUNCTION water_management_private.request_user_id()
  TO water_management_authz;

-- Replace the authorization helpers as their dedicated owner.
SET LOCAL ROLE water_management_authz;

CREATE OR REPLACE FUNCTION water_management_private.current_user_organization_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.organization_id
  FROM public.profiles p
  WHERE p.id = (SELECT water_management_private.request_user_id())
$$;
REVOKE ALL ON FUNCTION water_management_private.current_user_organization_id()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.current_user_organization_id()
  TO authenticated;

CREATE OR REPLACE FUNCTION water_management_private.current_user_role()
RETURNS public.app_role
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.role
  FROM public.profiles p
  WHERE p.id = (SELECT water_management_private.request_user_id())
$$;
REVOKE ALL ON FUNCTION water_management_private.current_user_role()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION water_management_private.current_user_role()
  TO authenticated;

RESET ROLE;

DO $verify$
BEGIN
  IF NOT has_schema_privilege('water_management_authz', 'water_management_private', 'USAGE') THEN
    RAISE EXCEPTION 'water_management_authz lacks private schema USAGE';
  END IF;
  IF has_schema_privilege('water_management_authz', 'auth', 'USAGE') THEN
    RAISE EXCEPTION 'water_management_authz must not have direct auth schema access';
  END IF;
  IF pg_get_userbyid((SELECT proowner FROM pg_proc WHERE oid='water_management_private.request_user_id()'::regprocedure)) <> 'postgres' THEN
    RAISE EXCEPTION 'request_user_id must be owned by postgres';
  END IF;
  IF NOT has_function_privilege('water_management_authz', 'water_management_private.request_user_id()', 'EXECUTE') THEN
    RAISE EXCEPTION 'water_management_authz cannot execute request_user_id';
  END IF;
  IF has_function_privilege('anon', 'water_management_private.request_user_id()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'water_management_private.request_user_id()', 'EXECUTE')
     OR has_function_privilege('service_role', 'water_management_private.request_user_id()', 'EXECUTE') THEN
    RAISE EXCEPTION 'API roles must not execute request_user_id';
  END IF;
END;
$verify$;
