
-- Make event ordering explicit and independent from transaction-stable now().
ALTER TABLE public.pump_operation_events
  ADD COLUMN IF NOT EXISTS event_sequence bigint;

WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY operation_id
           ORDER BY occurred_at, id
         ) AS sequence_number
  FROM public.pump_operation_events
)
UPDATE public.pump_operation_events e
SET event_sequence = ranked.sequence_number
FROM ranked
WHERE ranked.id = e.id
  AND e.event_sequence IS NULL;

ALTER TABLE public.pump_operation_events
  ALTER COLUMN event_sequence SET NOT NULL;

ALTER TABLE public.pump_operation_events
  ADD CONSTRAINT pump_operation_events_sequence_positive_check
  CHECK (event_sequence > 0);

CREATE UNIQUE INDEX IF NOT EXISTS pump_operation_events_operation_sequence_uidx
  ON public.pump_operation_events (operation_id, event_sequence);

CREATE OR REPLACE FUNCTION water_management_private.capture_pump_operation_event()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_event_type text;
  v_reason text;
  v_actor_id uuid := auth.uid();
  v_sequence bigint;
  v_occurred_at timestamptz := clock_timestamp();
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Operation events require an authenticated actor' USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_event_type := 'started';
    v_reason := NULL;
  ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
    v_event_type := CASE
      WHEN OLD.status = 'running' AND NEW.status = 'paused' THEN 'paused'
      WHEN OLD.status = 'paused' AND NEW.status = 'running' THEN 'resumed'
      WHEN OLD.status IN ('running', 'paused') AND NEW.status = 'completed' THEN 'completed'
      ELSE NULL
    END;
    v_reason := CASE
      WHEN v_event_type = 'paused' THEN NEW.pause_reason
      WHEN v_event_type IN ('resumed', 'completed') THEN OLD.pause_reason
      ELSE NULL
    END;
  ELSE
    RETURN NEW;
  END IF;

  IF v_event_type IS NULL THEN
    RAISE EXCEPTION 'Unsupported pump operation state transition' USING ERRCODE = '23514';
  END IF;

  -- The parent operation row is already locked by the INSERT/UPDATE that fired
  -- this trigger. Taking max(sequence)+1 therefore serializes event numbering.
  SELECT COALESCE(max(event_sequence), 0) + 1
  INTO v_sequence
  FROM public.pump_operation_events
  WHERE operation_id = NEW.id;

  INSERT INTO public.pump_operation_events (
    organization_id, pump_id, operation_id, actor_id,
    event_type, occurred_at, event_sequence, reason, metadata
  ) VALUES (
    NEW.organization_id, NEW.pump_id, NEW.id, v_actor_id,
    v_event_type, v_occurred_at, v_sequence, v_reason,
    jsonb_build_object(
      'from_status', CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END,
      'to_status', NEW.status
    )
  );

  RETURN NEW;
END;
$$;
