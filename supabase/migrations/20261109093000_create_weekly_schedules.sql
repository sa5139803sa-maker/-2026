-- Versioned weekly schedule templates scoped to one organization and pump.
-- Only draft schedules are editable through the client Data API. Publishing is
-- intentionally reserved for a guarded server RPC added after conflict rules.

CREATE TABLE public.weekly_schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL
    DEFAULT water_management_private.current_user_organization_id(),
  pump_id uuid NOT NULL,
  name text NOT NULL
    CHECK (char_length(btrim(name)) BETWEEN 2 AND 100),
  effective_from date NOT NULL,
  effective_to date,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'active', 'archived')),
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT weekly_schedules_id_tenant_pump_key
    UNIQUE (id, organization_id, pump_id),
  CONSTRAINT weekly_schedules_pump_tenant_fkey
    FOREIGN KEY (pump_id, organization_id)
    REFERENCES public.pumps (id, organization_id)
    ON DELETE CASCADE,
  CONSTRAINT weekly_schedules_created_by_fkey
    FOREIGN KEY (created_by)
    REFERENCES public.profiles (id)
    ON DELETE RESTRICT,
  CONSTRAINT weekly_schedules_effective_dates_check
    CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

-- A pump may have multiple drafts and archived versions, but at most one
-- active version. Publishing/rotation is intentionally handled server-side.
CREATE UNIQUE INDEX weekly_schedules_one_active_per_pump_uidx
  ON public.weekly_schedules (organization_id, pump_id)
  WHERE status = 'active';
CREATE INDEX weekly_schedules_pump_tenant_idx
  ON public.weekly_schedules (pump_id, organization_id);
CREATE INDEX weekly_schedules_created_by_idx
  ON public.weekly_schedules (created_by);
CREATE INDEX weekly_schedules_pump_status_effective_idx
  ON public.weekly_schedules (organization_id, pump_id, status, effective_from, effective_to);

CREATE TABLE public.schedule_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  weekly_schedule_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  pump_id uuid NOT NULL,
  subscriber_id uuid NOT NULL,
  weekday smallint NOT NULL CHECK (weekday BETWEEN 1 AND 7),
  sort_order integer NOT NULL DEFAULT 0 CHECK (sort_order >= 0),
  planned_minutes integer NOT NULL
    CHECK (planned_minutes BETWEEN 1 AND 1440),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT schedule_entries_id_tenant_pump_key
    UNIQUE (id, organization_id, pump_id),
  CONSTRAINT schedule_entries_day_order_uidx
    UNIQUE (weekly_schedule_id, organization_id, pump_id, weekday, sort_order),
  CONSTRAINT schedule_entries_schedule_scope_fkey
    FOREIGN KEY (weekly_schedule_id, organization_id, pump_id)
    REFERENCES public.weekly_schedules (id, organization_id, pump_id)
    ON DELETE CASCADE,
  CONSTRAINT schedule_entries_subscriber_scope_fkey
    FOREIGN KEY (subscriber_id, organization_id, pump_id)
    REFERENCES public.subscribers (id, organization_id, pump_id)
    ON DELETE CASCADE
);

CREATE INDEX schedule_entries_schedule_scope_idx
  ON public.schedule_entries (weekly_schedule_id, organization_id, pump_id);
CREATE INDEX schedule_entries_subscriber_scope_idx
  ON public.schedule_entries (subscriber_id, organization_id, pump_id);
CREATE INDEX schedule_entries_weekday_order_idx
  ON public.schedule_entries (weekly_schedule_id, weekday, sort_order, id);

-- The client supplies only the schedule and subscriber IDs. Tenant and pump
-- scope are derived from the visible draft schedule and cannot be forged.
CREATE FUNCTION water_management_private.prepare_schedule_entry_scope()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $prepare_schedule_entry_scope$
DECLARE
  v_organization_id uuid;
  v_pump_id uuid;
  v_schedule_status text;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.weekly_schedule_id IS DISTINCT FROM OLD.weekly_schedule_id THEN
    RAISE EXCEPTION 'A schedule entry cannot be moved to another weekly schedule'
      USING ERRCODE = '42501';
  END IF;

  SELECT ws.organization_id, ws.pump_id, ws.status
    INTO v_organization_id, v_pump_id, v_schedule_status
  FROM public.weekly_schedules ws
  WHERE ws.id = NEW.weekly_schedule_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Weekly schedule not found or not visible'
      USING ERRCODE = '23503';
  END IF;

  IF v_organization_id IS DISTINCT FROM
       (SELECT water_management_private.current_user_organization_id())
     OR (SELECT water_management_private.current_user_role()) IS DISTINCT FROM 'manager'::public.app_role THEN
    RAISE EXCEPTION 'Only the organization manager may edit weekly schedule entries'
      USING ERRCODE = '42501';
  END IF;

  IF v_schedule_status <> 'draft' THEN
    RAISE EXCEPTION 'Only draft weekly schedules may be edited'
      USING ERRCODE = '23514';
  END IF;

  NEW.organization_id := v_organization_id;
  NEW.pump_id := v_pump_id;
  RETURN NEW;
END;
$prepare_schedule_entry_scope$;

REVOKE ALL ON FUNCTION water_management_private.prepare_schedule_entry_scope()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER prepare_schedule_entry_scope
  BEFORE INSERT OR UPDATE ON public.schedule_entries
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.prepare_schedule_entry_scope();

ALTER TABLE public.weekly_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.schedule_entries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.weekly_schedules FROM PUBLIC, anon, authenticated;
GRANT SELECT, DELETE ON TABLE public.weekly_schedules TO authenticated;
GRANT INSERT (pump_id, name, effective_from, effective_to)
  ON TABLE public.weekly_schedules TO authenticated;
GRANT UPDATE (name, effective_from, effective_to)
  ON TABLE public.weekly_schedules TO authenticated;

REVOKE ALL ON TABLE public.schedule_entries FROM PUBLIC, anon, authenticated;
GRANT SELECT, DELETE ON TABLE public.schedule_entries TO authenticated;
GRANT INSERT (weekly_schedule_id, subscriber_id, weekday, sort_order, planned_minutes)
  ON TABLE public.schedule_entries TO authenticated;
GRANT UPDATE (subscriber_id, weekday, sort_order, planned_minutes)
  ON TABLE public.schedule_entries TO authenticated;

-- Managers manage schedules inside their organization. Assigned staff can read
-- the schedules of pumps assigned to their matching application role.
CREATE POLICY weekly_schedules_select_assigned_pumps
  ON public.weekly_schedules
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (
      (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
      OR EXISTS (
        SELECT 1
        FROM public.pump_assignments pa
        WHERE pa.organization_id = weekly_schedules.organization_id
          AND pa.pump_id = weekly_schedules.pump_id
          AND pa.user_id = (SELECT auth.uid())
          AND pa.assignment_role = (SELECT water_management_private.current_user_role())
      )
    )
  );

CREATE POLICY managers_insert_weekly_schedules
  ON public.weekly_schedules
  FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    AND status = 'draft'
    AND created_by = (SELECT auth.uid())
  );

CREATE POLICY managers_update_draft_weekly_schedules
  ON public.weekly_schedules
  FOR UPDATE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    AND status = 'draft'
  )
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    AND status = 'draft'
    AND created_by = (SELECT auth.uid())
  );

CREATE POLICY managers_delete_draft_weekly_schedules
  ON public.weekly_schedules
  FOR DELETE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    AND status = 'draft'
  );

CREATE POLICY schedule_entries_select_assigned_pumps
  ON public.schedule_entries
  FOR SELECT TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND EXISTS (
      SELECT 1
      FROM public.weekly_schedules ws
      WHERE ws.id = schedule_entries.weekly_schedule_id
        AND ws.organization_id = schedule_entries.organization_id
        AND ws.pump_id = schedule_entries.pump_id
        AND (
          (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
          OR EXISTS (
            SELECT 1
            FROM public.pump_assignments pa
            WHERE pa.organization_id = ws.organization_id
              AND pa.pump_id = ws.pump_id
              AND pa.user_id = (SELECT auth.uid())
              AND pa.assignment_role = (SELECT water_management_private.current_user_role())
          )
        )
    )
  );

CREATE POLICY managers_insert_draft_schedule_entries
  ON public.schedule_entries
  FOR INSERT TO authenticated
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    AND EXISTS (
      SELECT 1
      FROM public.weekly_schedules ws
      WHERE ws.id = schedule_entries.weekly_schedule_id
        AND ws.organization_id = schedule_entries.organization_id
        AND ws.pump_id = schedule_entries.pump_id
        AND ws.status = 'draft'
    )
  );

CREATE POLICY managers_update_draft_schedule_entries
  ON public.schedule_entries
  FOR UPDATE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    AND EXISTS (
      SELECT 1
      FROM public.weekly_schedules ws
      WHERE ws.id = schedule_entries.weekly_schedule_id
        AND ws.organization_id = schedule_entries.organization_id
        AND ws.pump_id = schedule_entries.pump_id
        AND ws.status = 'draft'
    )
  )
  WITH CHECK (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    AND EXISTS (
      SELECT 1
      FROM public.weekly_schedules ws
      WHERE ws.id = schedule_entries.weekly_schedule_id
        AND ws.organization_id = schedule_entries.organization_id
        AND ws.pump_id = schedule_entries.pump_id
        AND ws.status = 'draft'
    )
  );

CREATE POLICY managers_delete_draft_schedule_entries
  ON public.schedule_entries
  FOR DELETE TO authenticated
  USING (
    organization_id = (SELECT water_management_private.current_user_organization_id())
    AND (SELECT water_management_private.current_user_role()) = 'manager'::public.app_role
    AND EXISTS (
      SELECT 1
      FROM public.weekly_schedules ws
      WHERE ws.id = schedule_entries.weekly_schedule_id
        AND ws.organization_id = schedule_entries.organization_id
        AND ws.pump_id = schedule_entries.pump_id
        AND ws.status = 'draft'
    )
  );

COMMENT ON TABLE public.weekly_schedules IS
  'Versioned weekly schedule templates scoped to one organization and pump; client edits are restricted to draft rows.';
COMMENT ON COLUMN public.weekly_schedules.effective_from IS
  'First local calendar date on which this schedule version may apply; activation is performed by a guarded server procedure.';
COMMENT ON TABLE public.schedule_entries IS
  'Recurring weekly subscriber appointments; ISO weekday 1=Monday through 7=Sunday and one planned duration per appointment.';
COMMENT ON COLUMN public.schedule_entries.weekday IS
  'ISO weekday number: 1 Monday through 7 Sunday.';
COMMENT ON COLUMN public.schedule_entries.planned_minutes IS
  'Planned duration for this single weekly appointment, not a weekly subscriber quota.';
