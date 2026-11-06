CREATE OR REPLACE FUNCTION public.set_organization_account_limit(p_organization_id uuid,p_account_limit integer)
RETURNS void LANGUAGE plpgsql SECURITY INVOKER SET search_path=''
AS $function$
DECLARE v_current_limit integer;v_account_count bigint;
BEGIN
 IF p_account_limit IS NULL OR p_account_limit NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'Invalid account limit';END IF;
 SELECT o.account_limit INTO v_current_limit FROM public.organizations o WHERE o.id=p_organization_id FOR UPDATE;
 IF v_current_limit IS NULL THEN RAISE EXCEPTION 'Organization not found';END IF;
 SELECT pg_catalog.count(*) INTO v_account_count FROM public.profiles p WHERE p.organization_id=p_organization_id;
 IF v_account_count>p_account_limit THEN RAISE EXCEPTION 'Account limit cannot be lower than current account count';END IF;
 UPDATE public.organizations SET account_limit=p_account_limit WHERE id=p_organization_id;
END;$function$;
REVOKE ALL ON FUNCTION public.set_organization_account_limit(uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.set_organization_account_limit(uuid,integer) TO service_role;
