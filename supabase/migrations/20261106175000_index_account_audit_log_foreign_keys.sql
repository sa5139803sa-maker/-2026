CREATE INDEX IF NOT EXISTS account_audit_log_actor_id_idx ON public.account_audit_log(actor_id);
CREATE INDEX IF NOT EXISTS account_audit_log_target_user_id_idx ON public.account_audit_log(target_user_id);
CREATE INDEX IF NOT EXISTS account_audit_log_organization_id_idx ON public.account_audit_log(organization_id);
CREATE INDEX IF NOT EXISTS account_audit_log_created_at_idx ON public.account_audit_log(created_at DESC);
