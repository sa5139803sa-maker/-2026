ALTER TABLE public.account_audit_log
  DROP CONSTRAINT account_audit_log_action_check;

ALTER TABLE public.account_audit_log
  ADD CONSTRAINT account_audit_log_action_check
  CHECK (
    action = ANY (
      ARRAY[
        'account_created',
        'password_reset',
        'password_changed',
        'account_limit_changed',
        'organization_created'
      ]::text[]
    )
  );

GRANT INSERT ON public.organizations TO service_role;

CREATE OR REPLACE FUNCTION public.create_platform_organization(
  p_actor_id uuid,
  p_name text
)
RETURNS TABLE(id uuid, name text, account_limit integer)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_organization public.organizations%ROWTYPE;
BEGIN
  IF p_actor_id IS NULL THEN
    RAISE EXCEPTION 'Platform actor is required';
  END IF;

  IF p_name IS NULL
     OR pg_catalog.char_length(pg_catalog.btrim(p_name)) NOT BETWEEN 2 AND 120 THEN
    RAISE EXCEPTION 'Organization name must contain 2 to 120 characters';
  END IF;

  INSERT INTO public.organizations(name, created_by)
  VALUES (pg_catalog.btrim(p_name), p_actor_id)
  RETURNING * INTO v_organization;

  INSERT INTO public.account_audit_log(
    actor_id,
    target_user_id,
    organization_id,
    action,
    metadata
  )
  VALUES (
    p_actor_id,
    NULL,
    v_organization.id,
    'organization_created',
    pg_catalog.jsonb_build_object('organization_name', v_organization.name)
  );

  RETURN QUERY
  SELECT v_organization.id, v_organization.name, v_organization.account_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_platform_organization(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_platform_organization(uuid, text)
  TO service_role;

COMMENT ON FUNCTION public.create_platform_organization(uuid, text)
  IS 'Atomically provisions a platform-owned organization and records its audit event. Executable only by service_role through the authenticated platform Edge Function.';
