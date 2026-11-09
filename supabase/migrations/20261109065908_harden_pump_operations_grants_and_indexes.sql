REVOKE ALL ON TABLE public.pump_operations FROM anon, authenticated;
GRANT SELECT ON TABLE public.pump_operations TO authenticated;
GRANT INSERT (
  organization_id, pump_id, subscriber_id, subscriber_name, operator_id, planned_minutes
) ON TABLE public.pump_operations TO authenticated;
GRANT UPDATE (
  status, paused_at, paused_seconds, ended_at, actual_seconds
) ON TABLE public.pump_operations TO authenticated;

CREATE INDEX IF NOT EXISTS pump_operations_operator_id_idx
  ON public.pump_operations (operator_id);
CREATE INDEX IF NOT EXISTS pump_operations_pump_tenant_idx
  ON public.pump_operations (pump_id, organization_id);
CREATE INDEX IF NOT EXISTS pump_operations_subscriber_scope_idx
  ON public.pump_operations (subscriber_id, organization_id, pump_id)
  WHERE subscriber_id IS NOT NULL;
