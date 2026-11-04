/*
# Create Water Management foundation

1. Purpose
- Creates the first protected Supabase data model for the Water Management application.
- Supports Arabic field operations with one organization per user during onboarding and organization-scoped records afterwards.

2. New enum types
- `app_role`: manager, operator, collector, supervisor.
- `pump_status`: active, paused, maintenance, inactive.
- `assignment_role`: operator, collector.

3. New tables and columns
- `organizations`: organization name, creator, and creation time.
- `profiles`: one profile per authenticated user, display name, protected role, and organization membership.
- `pumps`: organization-owned water pumps with a human-readable code and operational status.
- `pump_assignments`: links users to pumps as operators or collectors.
- `subscribers`: organization-owned subscribers, their assigned pump, contact details, and active state.

4. Security changes
- Enables RLS on every new table.
- Grants only the minimum Data API privileges to authenticated users.
- Adds separate SELECT, INSERT, UPDATE, and DELETE policies.
- Restricts all organization data to members of that organization.
- Restricts pump, assignment, and subscriber writes to managers.
- Protects profile roles and organization membership from client updates.
- Adds a secure onboarding function that creates the first organization and promotes only the caller's unassigned profile to manager.

5. Important notes
- Sign-up automatically creates a profile with the least-privileged `operator` role and no organization.
- The app must call `create_organization` during onboarding to establish the first organization safely.
- No financial, operational event, or synchronization tables are created in this foundation migration.
*/

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'app_role') THEN
    CREATE TYPE public.app_role AS ENUM ('manager', 'operator', 'collector', 'supervisor');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pump_status') THEN
    CREATE TYPE public.pump_status AS ENUM ('active', 'paused', 'maintenance', 'inactive');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'assignment_role') THEN
    CREATE TYPE public.assignment_role AS ENUM ('operator', 'collector');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.organizations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(trim(name)) BETWEEN 2 AND 120),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  organization_id uuid REFERENCES public.organizations(id) ON DELETE SET NULL,
  display_name text NOT NULL CHECK (char_length(trim(display_name)) BETWEEN 2 AND 120),
  role public.app_role NOT NULL DEFAULT 'operator',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.pumps (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(trim(name)) BETWEEN 1 AND 80),
  code text NOT NULL CHECK (char_length(trim(code)) BETWEEN 1 AND 30),
  status public.pump_status NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, code)
);

CREATE TABLE IF NOT EXISTS public.pump_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pump_id uuid NOT NULL REFERENCES public.pumps(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  assignment_role public.assignment_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pump_id, user_id, assignment_role)
);

CREATE TABLE IF NOT EXISTS public.subscribers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  pump_id uuid REFERENCES public.pumps(id) ON DELETE SET NULL,
  full_name text NOT NULL CHECK (char_length(trim(full_name)) BETWEEN 2 AND 120),
  phone text,
  phone_normalized text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pumps_organization_id_idx ON public.pumps (organization_id);
CREATE INDEX IF NOT EXISTS pump_assignments_user_id_idx ON public.pump_assignments (user_id);
CREATE INDEX IF NOT EXISTS subscribers_organization_id_idx ON public.subscribers (organization_id);
CREATE INDEX IF NOT EXISTS subscribers_pump_id_idx ON public.subscribers (pump_id);
CREATE UNIQUE INDEX IF NOT EXISTS subscribers_org_phone_normalized_idx
  ON public.subscribers (organization_id, phone_normalized)
  WHERE phone_normalized IS NOT NULL;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, display_name)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(trim(NEW.raw_user_meta_data ->> 'display_name'), ''), split_part(COALESCE(NEW.email, 'مستخدم جديد'), '@', 1))
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE OR REPLACE FUNCTION public.create_organization(p_name text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_profile public.profiles%ROWTYPE;
  v_organization_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_name IS NULL OR char_length(trim(p_name)) NOT BETWEEN 2 AND 120 THEN
    RAISE EXCEPTION 'Invalid organization name';
  END IF;

  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = v_user_id
  FOR UPDATE;

  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Profile not found';
  END IF;
  IF v_profile.organization_id IS NOT NULL THEN
    RAISE EXCEPTION 'Organization already assigned';
  END IF;

  INSERT INTO public.organizations (name, created_by)
  VALUES (trim(p_name), v_user_id)
  RETURNING id INTO v_organization_id;

  UPDATE public.profiles
  SET organization_id = v_organization_id, role = 'manager'
  WHERE id = v_user_id;

  RETURN v_organization_id;
END;
$$;

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pumps ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pump_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscribers ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.organizations TO authenticated;
GRANT SELECT ON public.profiles TO authenticated;
GRANT UPDATE (display_name) ON public.profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pumps TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pump_assignments TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.subscribers TO authenticated;
REVOKE ALL ON public.organizations FROM anon;
REVOKE ALL ON public.profiles FROM anon;
REVOKE ALL ON public.pumps FROM anon;
REVOKE ALL ON public.pump_assignments FROM anon;
REVOKE ALL ON public.subscribers FROM anon;
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.create_organization(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_organization(text) TO authenticated;

DROP POLICY IF EXISTS "members_select_organizations" ON public.organizations;
CREATE POLICY "members_select_organizations" ON public.organizations FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = organizations.id));

DROP POLICY IF EXISTS "users_select_own_profile" ON public.profiles;
CREATE POLICY "users_select_own_profile" ON public.profiles FOR SELECT TO authenticated
USING (id = auth.uid());
DROP POLICY IF EXISTS "users_update_own_display_name" ON public.profiles;
CREATE POLICY "users_update_own_display_name" ON public.profiles FOR UPDATE TO authenticated
USING (id = auth.uid()) WITH CHECK (id = auth.uid());

DROP POLICY IF EXISTS "members_select_pumps" ON public.pumps;
CREATE POLICY "members_select_pumps" ON public.pumps FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = pumps.organization_id));
DROP POLICY IF EXISTS "managers_insert_pumps" ON public.pumps;
CREATE POLICY "managers_insert_pumps" ON public.pumps FOR INSERT TO authenticated
WITH CHECK (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = pumps.organization_id AND profiles.role = 'manager'));
DROP POLICY IF EXISTS "managers_update_pumps" ON public.pumps;
CREATE POLICY "managers_update_pumps" ON public.pumps FOR UPDATE TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = pumps.organization_id AND profiles.role = 'manager'))
WITH CHECK (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = pumps.organization_id AND profiles.role = 'manager'));
DROP POLICY IF EXISTS "managers_delete_pumps" ON public.pumps;
CREATE POLICY "managers_delete_pumps" ON public.pumps FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = pumps.organization_id AND profiles.role = 'manager'));

DROP POLICY IF EXISTS "members_select_assignments" ON public.pump_assignments;
CREATE POLICY "members_select_assignments" ON public.pump_assignments FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles member JOIN public.pumps ON pumps.organization_id = member.organization_id WHERE member.id = auth.uid() AND pumps.id = pump_assignments.pump_id));
DROP POLICY IF EXISTS "managers_insert_assignments" ON public.pump_assignments;
CREATE POLICY "managers_insert_assignments" ON public.pump_assignments FOR INSERT TO authenticated
WITH CHECK (EXISTS (SELECT 1 FROM public.profiles member JOIN public.pumps ON pumps.organization_id = member.organization_id WHERE member.id = auth.uid() AND member.role = 'manager' AND pumps.id = pump_assignments.pump_id));
DROP POLICY IF EXISTS "managers_update_assignments" ON public.pump_assignments;
CREATE POLICY "managers_update_assignments" ON public.pump_assignments FOR UPDATE TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles member JOIN public.pumps ON pumps.organization_id = member.organization_id WHERE member.id = auth.uid() AND member.role = 'manager' AND pumps.id = pump_assignments.pump_id))
WITH CHECK (EXISTS (SELECT 1 FROM public.profiles member JOIN public.pumps ON pumps.organization_id = member.organization_id WHERE member.id = auth.uid() AND member.role = 'manager' AND pumps.id = pump_assignments.pump_id));
DROP POLICY IF EXISTS "managers_delete_assignments" ON public.pump_assignments;
CREATE POLICY "managers_delete_assignments" ON public.pump_assignments FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles member JOIN public.pumps ON pumps.organization_id = member.organization_id WHERE member.id = auth.uid() AND member.role = 'manager' AND pumps.id = pump_assignments.pump_id));

DROP POLICY IF EXISTS "members_select_subscribers" ON public.subscribers;
CREATE POLICY "members_select_subscribers" ON public.subscribers FOR SELECT TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = subscribers.organization_id));
DROP POLICY IF EXISTS "managers_insert_subscribers" ON public.subscribers;
CREATE POLICY "managers_insert_subscribers" ON public.subscribers FOR INSERT TO authenticated
WITH CHECK (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = subscribers.organization_id AND profiles.role = 'manager'));
DROP POLICY IF EXISTS "managers_update_subscribers" ON public.subscribers;
CREATE POLICY "managers_update_subscribers" ON public.subscribers FOR UPDATE TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = subscribers.organization_id AND profiles.role = 'manager'))
WITH CHECK (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = subscribers.organization_id AND profiles.role = 'manager'));
DROP POLICY IF EXISTS "managers_delete_subscribers" ON public.subscribers;
CREATE POLICY "managers_delete_subscribers" ON public.subscribers FOR DELETE TO authenticated
USING (EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.organization_id = subscribers.organization_id AND profiles.role = 'manager'));
