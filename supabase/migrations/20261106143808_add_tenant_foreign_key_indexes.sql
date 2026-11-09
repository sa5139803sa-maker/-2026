-- Child-side indexes for the foreign keys in the tenant-isolation schema.
-- Keep the column order identical to each FK, including composite keys.
CREATE INDEX IF NOT EXISTS organizations_created_by_idx
  ON public.organizations (created_by);

CREATE INDEX IF NOT EXISTS profiles_organization_id_idx
  ON public.profiles (organization_id);

CREATE INDEX IF NOT EXISTS pump_assignments_pump_tenant_idx
  ON public.pump_assignments (pump_id, organization_id);

CREATE INDEX IF NOT EXISTS pump_assignments_user_tenant_role_idx
  ON public.pump_assignments (user_id, organization_id, assignment_role);

CREATE INDEX IF NOT EXISTS subscribers_pump_tenant_idx
  ON public.subscribers (pump_id, organization_id);
