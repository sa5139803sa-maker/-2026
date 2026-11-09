
CREATE INDEX IF NOT EXISTS pump_operation_events_actor_id_idx
  ON public.pump_operation_events (actor_id);

CREATE INDEX IF NOT EXISTS pump_operation_events_operation_scope_fk_idx
  ON public.pump_operation_events (operation_id, organization_id, pump_id);
