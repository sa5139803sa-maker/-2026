-- Column-level UPDATE grants survive a table-level REVOKE.
-- Remove those as well so lifecycle changes can only run through guarded RPCs.
REVOKE UPDATE (status, paused_at, paused_seconds, ended_at, actual_seconds)
ON TABLE public.pump_operations FROM authenticated;
