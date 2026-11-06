ALTER TYPE public.app_role ADD VALUE IF NOT EXISTS 'platform_admin';
ALTER TABLE public.organizations ADD COLUMN IF NOT EXISTS account_limit integer NOT NULL DEFAULT 5;
ALTER TABLE public.organizations ADD CONSTRAINT organizations_account_limit_range_check CHECK(account_limit BETWEEN 1 AND 1000);
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS username text, ADD COLUMN IF NOT EXISTS must_change_password boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS profiles_username_lower_uidx ON public.profiles(lower(username)) WHERE username IS NOT NULL;
COMMENT ON COLUMN public.organizations.account_limit IS 'Maximum login accounts in this organization, including its manager.';
COMMENT ON COLUMN public.profiles.username IS 'Unique login identifier for accounts provisioned by administrators.';
COMMENT ON COLUMN public.profiles.must_change_password IS 'When true, account is restricted to mandatory password change.';
CREATE TABLE IF NOT EXISTS public.account_audit_log(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), actor_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
 target_user_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
 organization_id uuid REFERENCES public.organizations(id) ON DELETE SET NULL,
 action text NOT NULL CHECK(action IN('account_created','password_reset','password_changed','account_limit_changed')),
 created_at timestamptz NOT NULL DEFAULT now(), metadata jsonb NOT NULL DEFAULT '{}'::jsonb);
ALTER TABLE public.account_audit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_audit_log FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT ON public.account_audit_log TO service_role;
CREATE OR REPLACE FUNCTION public.assign_managed_user(p_user_id uuid,p_organization_id uuid,p_role public.app_role,p_username text,p_display_name text)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path=''
AS $function$
DECLARE v_limit integer;v_count bigint;v_updated integer;
BEGIN
 IF p_user_id IS NULL OR p_organization_id IS NULL THEN RAISE EXCEPTION 'Missing account or organization';END IF;
 IF p_role::text NOT IN('manager','operator','collector','supervisor') THEN RAISE EXCEPTION 'Invalid managed account role';END IF;
 IF p_username IS NULL OR pg_catalog.char_length(pg_catalog.btrim(p_username)) NOT BETWEEN 3 AND 40 OR p_username~'[[:space:]@]' THEN RAISE EXCEPTION 'Invalid username';END IF;
 IF p_display_name IS NULL OR pg_catalog.char_length(pg_catalog.btrim(p_display_name)) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'Invalid display name';END IF;
 SELECT o.account_limit INTO v_limit FROM public.organizations o WHERE o.id=p_organization_id FOR UPDATE;
 IF v_limit IS NULL THEN RAISE EXCEPTION 'Organization not found';END IF;
 SELECT pg_catalog.count(*) INTO v_count FROM public.profiles p WHERE p.organization_id=p_organization_id;
 IF v_count>=v_limit THEN RAISE EXCEPTION 'Organization account limit reached';END IF;
 IF EXISTS(SELECT 1 FROM public.profiles p WHERE pg_catalog.lower(p.username)=pg_catalog.lower(pg_catalog.btrim(p_username))) THEN RAISE EXCEPTION 'Username already exists';END IF;
 UPDATE public.profiles SET organization_id=p_organization_id,role=p_role,username=pg_catalog.lower(pg_catalog.btrim(p_username)),display_name=pg_catalog.btrim(p_display_name),must_change_password=true
 WHERE id=p_user_id AND organization_id IS NULL AND role='operator'::public.app_role;
 GET DIAGNOSTICS v_updated=ROW_COUNT;
 IF v_updated<>1 THEN RAISE EXCEPTION 'New auth user profile was not available for assignment';END IF;
END;$function$;
REVOKE ALL ON FUNCTION public.assign_managed_user(uuid,uuid,public.app_role,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.assign_managed_user(uuid,uuid,public.app_role,text,text) TO service_role;
