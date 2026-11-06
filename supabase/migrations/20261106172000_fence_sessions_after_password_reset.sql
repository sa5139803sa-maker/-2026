ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS session_invalid_before timestamptz;
CREATE OR REPLACE FUNCTION water_management_private.request_token_issued_at()
RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $function$
 SELECT CASE WHEN(auth.jwt()->>'iat')~'^[0-9]+$' THEN pg_catalog.to_timestamp(((auth.jwt()->>'iat')::double precision)) ELSE NULL END
$function$;
REVOKE ALL ON FUNCTION water_management_private.request_token_issued_at() FROM PUBLIC,anon,authenticated,service_role,water_management_authz;
GRANT EXECUTE ON FUNCTION water_management_private.request_token_issued_at() TO water_management_authz;
SET LOCAL ROLE water_management_authz;
CREATE OR REPLACE FUNCTION water_management_private.current_user_organization_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $function$ SELECT p.organization_id FROM public.profiles p WHERE p.id=(SELECT water_management_private.request_user_id()) AND p.must_change_password=false AND(p.session_invalid_before IS NULL OR(SELECT water_management_private.request_token_issued_at())>=p.session_invalid_before) $function$;
CREATE OR REPLACE FUNCTION water_management_private.current_user_role()
RETURNS public.app_role LANGUAGE sql STABLE SECURITY DEFINER SET search_path=''
AS $function$ SELECT p.role FROM public.profiles p WHERE p.id=(SELECT water_management_private.request_user_id()) AND p.must_change_password=false AND(p.session_invalid_before IS NULL OR(SELECT water_management_private.request_token_issued_at())>=p.session_invalid_before) $function$;
RESET ROLE;
REVOKE ALL ON FUNCTION water_management_private.current_user_organization_id() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION water_management_private.current_user_role() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION water_management_private.current_user_organization_id() TO authenticated;
GRANT EXECUTE ON FUNCTION water_management_private.current_user_role() TO authenticated;
