
CREATE OR REPLACE FUNCTION public.get_pump_operations_dashboard(
  p_from date,
  p_today date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_org_id uuid := water_management_private.current_user_organization_id();
  v_role public.app_role := water_management_private.current_user_role();
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR v_org_id IS NULL
     OR v_role NOT IN ('manager', 'operator') THEN
    RAISE EXCEPTION 'Not authorized to read operation dashboard' USING ERRCODE = '42501';
  END IF;

  IF p_from IS NULL
     OR p_today IS NULL
     OR p_from > p_today
     OR p_today - p_from > 13 THEN
    RAISE EXCEPTION 'Dashboard date range must be between 1 and 14 days' USING ERRCODE = '22023';
  END IF;

  SELECT jsonb_build_object(
    'today_operations',
      (SELECT count(*)
       FROM public.pump_operations op
       WHERE op.organization_id = v_org_id
         AND op.operation_date = p_today),
    'active_operations',
      (SELECT count(*)
       FROM public.pump_operations op
       WHERE op.organization_id = v_org_id
         AND op.status IN ('running', 'paused')),
    'daily',
      COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'date', dates.day::date,
            'count', COALESCE(daily.operation_count, 0)
          )
          ORDER BY dates.day
        )
        FROM generate_series(p_from::timestamp, p_today::timestamp, interval '1 day') AS dates(day)
        LEFT JOIN LATERAL (
          SELECT count(*) AS operation_count
          FROM public.pump_operations op
          WHERE op.organization_id = v_org_id
            AND op.operation_date = dates.day::date
        ) daily ON true
      ), '[]'::jsonb),
    'recent',
      COALESCE((
        SELECT jsonb_agg(to_jsonb(recent) ORDER BY recent.started_at DESC)
        FROM (
          SELECT
            op.id,
            op.pump_id,
            op.subscriber_name,
            op.status,
            op.started_at,
            op.ended_at,
            op.actual_seconds,
            op.operation_date,
            p.name AS pump_name
          FROM public.pump_operations op
          JOIN public.pumps p
            ON p.id = op.pump_id
           AND p.organization_id = op.organization_id
          WHERE op.organization_id = v_org_id
          ORDER BY op.started_at DESC
          LIMIT 6
        ) recent
      ), '[]'::jsonb)
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_pump_operations_dashboard(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_pump_operations_dashboard(date, date) TO authenticated;
