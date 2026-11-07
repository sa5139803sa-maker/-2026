CREATE POLICY "service_role_manage_account_audit_log"
ON public.account_audit_log
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);
