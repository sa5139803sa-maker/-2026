-- Add pump-scoped branches and bind subscribers to a branch without
-- weakening the existing organization/pump composite tenant boundary.

CREATE TABLE public.branches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL
    DEFAULT water_management_private.current_user_organization_id(),
  pump_id uuid NOT NULL,
  name text NOT NULL
    CHECK (char_length(btrim(name)) BETWEEN 2 AND 80),
  code text
    CHECK (code IS NULL OR char_length(btrim(code)) BETWEEN 1 AND 30),
  sort_order integer NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT branches_id_organization_pump_key
    UNIQUE (id, organization_id, pump_id),
  CONSTRAINT branches_pump_tenant_fkey
    FOREIGN KEY (pump_id, organization_id)
    REFERENCES public.pumps (id, organization_id)
    ON DELETE CASCADE
);

CREATE UNIQUE INDEX branches_name_per_pump_uidx
  ON public.branches (organization_id, pump_id, lower(btrim(name)));
CREATE UNIQUE INDEX branches_code_per_pump_uidx
  ON public.branches (organization_id, pump_id, lower(btrim(code)))
  WHERE code IS NOT NULL;
CREATE INDEX branches_pump_tenant_idx
  ON public.branches (pump_id, organization_id);
CREATE INDEX branches_pump_order_idx
  ON public.branches (pump_id, organization_id, is_active, sort_order, id);

ALTER TABLE public.subscribers
  ADD COLUMN branch_id uuid,
  ADD CONSTRAINT subscribers_branch_requires_pump_check
    CHECK (branch_id IS NULL OR pump_id IS NOT NULL),
  ADD CONSTRAINT subscribers_branch_tenant_fkey
    FOREIGN KEY (branch_id, organization_id, pump_id)
    REFERENCES public.branches (id, organization_id, pump_id)
    ON DELETE SET NULL (branch_id);

CREATE INDEX subscribers_branch_tenant_idx
  ON public.subscribers (branch_id, organization_id, pump_id)
  WHERE branch_id IS NOT NULL;

-- A pump deletion already clears subscribers.pump_id through the existing
-- composite FK. Clear branch_id first so the branch-required-pump check remains
-- valid regardless of the order in which PostgreSQL processes FK actions.
-- Keep this trigger function SECURITY INVOKER: the user deleting a pump
-- must also be authorized to update the affected subscriber rows. The
-- migration owner retains implicit EXECUTE for CREATE TRIGGER; client roles do not.
CREATE FUNCTION water_management_private.clear_subscriber_branches_before_pump_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $clear_subscriber_branches$
BEGIN
  UPDATE public.subscribers
  SET branch_id = NULL
  WHERE organization_id = OLD.organization_id
    AND pump_id = OLD.id
    AND branch_id IS NOT NULL;
  RETURN OLD;
END;
$clear_subscriber_branches$;

REVOKE ALL ON FUNCTION water_management_private.clear_subscriber_branches_before_pump_delete()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER clear_subscriber_branches_before_pump_delete
  BEFORE DELETE ON public.pumps
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.clear_subscriber_branches_before_pump_delete();

ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;

-- Explicit grants are required for the authenticated Data API role; RLS
-- remains the row-level boundary. No anonymous table access is permitted.
REVOKE ALL ON TABLE public.branches FROM PUBLIC, anon, authenticated;
GRANT SELECT, DELETE ON TABLE public.branches TO authenticated;
GRANT INSERT (pump_id, name, code, sort_order, is_active)
  ON TABLE public.branches TO authenticated;
GRANT UPDATE (name, code, sort_order, is_active)
  ON TABLE public.branches TO authenticated;

DROP POLICY IF EXISTS branches_select_assigned_pumps ON public.branches;
CREATE POLICY branches_select_assigned_pumps ON public.branches
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1
        FROM public.pump_assignments pa
        WHERE pa.organization_id = branches.organization_id
          AND pa.pump_id = branches.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
      )
    )
  );

DROP POLICY IF EXISTS managers_insert_branches ON public.branches;
CREATE POLICY managers_insert_branches ON public.branches
  FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS managers_update_branches ON public.branches;
CREATE POLICY managers_update_branches ON public.branches
  FOR UPDATE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  )
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

DROP POLICY IF EXISTS managers_delete_branches ON public.branches;
CREATE POLICY managers_delete_branches ON public.branches
  FOR DELETE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
  );

COMMENT ON TABLE public.branches IS
  'Pump-scoped subscriber branches; all reads and writes are tenant and assignment scoped by RLS.';
COMMENT ON COLUMN public.subscribers.branch_id IS
  'Optional branch within the same organization and pump. The composite FK prevents cross-pump or cross-tenant assignments.';
