-- A subscriber is retained when its pump is deleted, but it cannot keep
-- an operator assignment that is scoped to the deleted pump. Clear that
-- assignment before the existing pump_id ON DELETE SET NULL action runs.
-- The assignment history records this system-driven unassignment.

ALTER TABLE public.subscriber_operator_assignment_events
  ALTER COLUMN new_operator_id DROP NOT NULL,
  ALTER COLUMN new_operator_name DROP NOT NULL,
  ALTER COLUMN actor_id DROP NOT NULL;

ALTER TABLE public.subscriber_operator_assignment_events
  ADD COLUMN actor_type text NOT NULL DEFAULT 'user';

ALTER TABLE public.subscriber_operator_assignment_events
  ADD CONSTRAINT subscriber_operator_assignment_events_actor_type_check
    CHECK (
      (actor_type = 'user' AND actor_id IS NOT NULL)
      OR (actor_type = 'system' AND actor_id IS NULL)
    ),
  ADD CONSTRAINT subscriber_operator_assignment_events_new_owner_check
    CHECK (
      (new_operator_id IS NULL AND new_operator_name IS NULL)
      OR (new_operator_id IS NOT NULL AND new_operator_name IS NOT NULL)
    );

COMMENT ON COLUMN public.subscriber_operator_assignment_events.actor_type IS
  'Identifies whether the assignment change was performed by an authenticated user or by a system lifecycle action.';

CREATE OR REPLACE FUNCTION water_management_private.record_subscriber_operator_assignment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $record_subscriber_operator_assignment$
DECLARE
  v_previous_name text;
  v_new_name text;
  v_reason text;
  v_actor_id uuid := auth.uid();
  v_actor_type text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.operator_id IS NOT DISTINCT FROM OLD.operator_id THEN
    RETURN NEW;
  END IF;

  -- A new subscriber may legitimately be created before it is assigned.
  -- An UPDATE from an assigned operator to NULL is an audited unassignment.
  IF TG_OP = 'INSERT' AND NEW.operator_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.operator_id IS NOT NULL THEN
    SELECT p.display_name INTO v_previous_name
    FROM public.profiles p
    WHERE p.id = OLD.operator_id;
  END IF;

  IF NEW.operator_id IS NOT NULL THEN
    SELECT p.display_name INTO v_new_name
    FROM public.profiles p
    WHERE p.id = NEW.operator_id;
  END IF;

  v_reason := NULLIF(btrim(COALESCE(
    current_setting('water_management.subscriber_operator_reason', true), ''
  )), '');

  IF v_reason IS NULL THEN
    v_reason := CASE
      WHEN TG_OP = 'INSERT' THEN 'إسناد عند إنشاء المشترك'
      WHEN NEW.operator_id IS NULL THEN 'إلغاء إسناد المشترك بسبب حذف الغطاس'
      ELSE 'تحديث إسناد المشترك'
    END;
  END IF;

  v_actor_type := CASE WHEN v_actor_id IS NULL THEN 'system' ELSE 'user' END;

  INSERT INTO public.subscriber_operator_assignment_events (
    subscriber_id, organization_id, pump_id,
    previous_operator_id, previous_operator_name,
    new_operator_id, new_operator_name, actor_id, actor_type, reason
  ) VALUES (
    NEW.id, NEW.organization_id, NEW.pump_id,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.operator_id ELSE NULL END,
    v_previous_name,
    NEW.operator_id,
    CASE WHEN NEW.operator_id IS NULL THEN NULL ELSE COALESCE(v_new_name, 'مشغّل غير معروف') END,
    v_actor_id,
    v_actor_type,
    v_reason
  );

  RETURN NEW;
END;
$record_subscriber_operator_assignment$;

ALTER FUNCTION water_management_private.record_subscriber_operator_assignment()
  OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.record_subscriber_operator_assignment()
  FROM PUBLIC, anon, authenticated, service_role;

-- Keep the existing branch cleanup trigger SECURITY INVOKER. A separate,
-- narrowly scoped SECURITY DEFINER trigger clears only the pump-scoped operator
-- assignment after the branch trigger has cleared branch_id. Trigger names sort
-- alphabetically, so clear_subscriber_branches... runs first.

CREATE FUNCTION water_management_private.clear_subscriber_operator_assignments_before_pump_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $clear_subscriber_operator_assignments_before_pump_delete$
BEGIN
  PERFORM set_config(
    'water_management.subscriber_operator_reason',
    'إلغاء إسناد المشترك تلقائيًا بسبب حذف الغطاس',
    true
  );

  UPDATE public.subscribers
  SET operator_id = NULL
  WHERE organization_id = OLD.organization_id
    AND pump_id = OLD.id
    AND operator_id IS NOT NULL;

  RETURN OLD;
END;
$clear_subscriber_operator_assignments_before_pump_delete$;

ALTER FUNCTION water_management_private.clear_subscriber_operator_assignments_before_pump_delete()
  OWNER TO postgres;
REVOKE ALL ON FUNCTION water_management_private.clear_subscriber_operator_assignments_before_pump_delete()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER clear_subscriber_operator_assignments_before_pump_delete
  BEFORE DELETE ON public.pumps
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.clear_subscriber_operator_assignments_before_pump_delete();
