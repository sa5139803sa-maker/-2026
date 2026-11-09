\set ON_ERROR_STOP on

-- The tenant isolation suite has already exercised and removed its original
-- tenant-A fixture. Reuse the surviving auth profiles in a dedicated tenant
-- so the concurrency test runs after the fixture transaction is committed.
DO $concurrency_fixture_preconditions$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id IN (
      '10000000-0000-4000-8000-000000000001',
      '10000000-0000-4000-8000-000000000002',
      '10000000-0000-4000-8000-000000000003'
    )
      AND organization_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Concurrency test profiles must be detached from the prior tenant';
  END IF;

  IF (SELECT count(*) FROM auth.users
      WHERE id IN (
        '10000000-0000-4000-8000-000000000001',
        '10000000-0000-4000-8000-000000000002',
        '10000000-0000-4000-8000-000000000003'
      )) <> 3 THEN
    RAISE EXCEPTION 'Concurrency test auth fixtures are missing';
  END IF;
END;
$concurrency_fixture_preconditions$;

INSERT INTO public.organizations (id, name, created_by)
VALUES (
  '26000000-0000-4000-8000-000000000001',
  'مؤسسة اختبار التزامن',
  '10000000-0000-4000-8000-000000000001'
);

UPDATE public.profiles
SET organization_id = '26000000-0000-4000-8000-000000000001',
    role = 'manager'::public.app_role
WHERE id = '10000000-0000-4000-8000-000000000001';

UPDATE public.profiles
SET organization_id = '26000000-0000-4000-8000-000000000001',
    role = 'operator'::public.app_role
WHERE id IN (
  '10000000-0000-4000-8000-000000000002',
  '10000000-0000-4000-8000-000000000003'
);

INSERT INTO public.pumps (id, organization_id, name, code, status)
VALUES (
  '26000000-0000-4000-8000-000000000002',
  '26000000-0000-4000-8000-000000000001',
  'غطاس اختبار التزامن',
  'CONCURRENCY-1',
  'active'
);

INSERT INTO public.pump_assignments (
  pump_id, user_id, organization_id, assignment_role
) VALUES
  (
    '26000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    '26000000-0000-4000-8000-000000000001',
    'operator'
  ),
  (
    '26000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000003',
    '26000000-0000-4000-8000-000000000001',
    'operator'
  );

INSERT INTO public.pump_power_sources (
  id, organization_id, pump_id, name, source_type, created_by
) VALUES (
  '26000000-0000-4000-8000-000000000003',
  '26000000-0000-4000-8000-000000000001',
  '26000000-0000-4000-8000-000000000002',
  'مصدر اختبار التزامن',
  'solar',
  '10000000-0000-4000-8000-000000000001'
);
