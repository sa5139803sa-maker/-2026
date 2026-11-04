/*
# Tighten Water Management grants

1. Purpose
- Removes broad table privileges that are not needed by the mobile client.
- Keeps organization creation available only through the protected onboarding function.

2. Modified tables
- `organizations`: authenticated users can only SELECT organizations they belong to.
- `profiles`: authenticated users can SELECT profile fields and update only their display name.
- `pumps`: authenticated users can read rows allowed by RLS and use manager-only CRUD policies.
- `pump_assignments`: authenticated users can read rows allowed by RLS and use manager-only CRUD policies.
- `subscribers`: authenticated users can read rows allowed by RLS and use manager-only CRUD policies.

3. Security changes
- Revokes all table privileges from anon and authenticated before restoring the minimum required grants.
- Prevents clients from directly inserting profiles or organizations.
- Prevents clients from updating profile roles or organization membership.
- The SECURITY DEFINER onboarding function remains intentionally callable by authenticated users because it is the only safe path for first-organization setup; it checks auth.uid(), profile membership, and the organization name server-side.
*/

REVOKE ALL ON public.organizations FROM anon, authenticated;
REVOKE ALL ON public.profiles FROM anon, authenticated;
REVOKE ALL ON public.pumps FROM anon, authenticated;
REVOKE ALL ON public.pump_assignments FROM anon, authenticated;
REVOKE ALL ON public.subscribers FROM anon, authenticated;

GRANT SELECT ON public.organizations TO authenticated;
GRANT SELECT (id, organization_id, display_name, role, created_at) ON public.profiles TO authenticated;
GRANT UPDATE (display_name) ON public.profiles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pumps TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pump_assignments TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.subscribers TO authenticated;

REVOKE ALL ON public.organizations FROM anon;
REVOKE ALL ON public.profiles FROM anon;
REVOKE ALL ON public.pumps FROM anon;
REVOKE ALL ON public.pump_assignments FROM anon;
REVOKE ALL ON public.subscribers FROM anon;
