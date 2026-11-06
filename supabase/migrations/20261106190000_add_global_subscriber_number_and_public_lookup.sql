/*
  Global six-digit subscriber identity and public lookup (number + phone only).
  Numbers are random, global, immutable, and never reused.
  Public lookup is rate-limited and executable only by service_role.
*/

-- Supabase installs pgcrypto in the extensions schema. CI PostgreSQL starts
-- with a clean cluster, so create the same schema/extension explicitly here.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Normalize Palestinian and international phone formats into one canonical
-- representation. Arabic-Indic and Persian digits are accepted.
CREATE OR REPLACE FUNCTION water_management_private.normalize_subscriber_phone(p_phone text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $function$
DECLARE
  v_digits text;
BEGIN
  IF p_phone IS NULL THEN
    RETURN NULL;
  END IF;

  v_digits := pg_catalog.translate(
    pg_catalog.btrim(p_phone),
    '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹',
    '01234567890123456789'
  );
  v_digits := pg_catalog.regexp_replace(v_digits, '[^0-9]', '', 'g');

  IF v_digits LIKE '00970%' OR v_digits LIKE '00972%' THEN
    v_digits := '0' || pg_catalog.substr(v_digits, 6);
  ELSIF v_digits LIKE '970%' OR v_digits LIKE '972%' THEN
    v_digits := '0' || pg_catalog.substr(v_digits, 4);
  ELSIF pg_catalog.length(v_digits) = 9 AND v_digits LIKE '5%' THEN
    v_digits := '0' || v_digits;
  END IF;

  RETURN NULLIF(v_digits, '');
END;
$function$;

REVOKE ALL ON FUNCTION water_management_private.normalize_subscriber_phone(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION water_management_private.normalize_subscriber_phone(text)
  TO service_role;

-- Existing subscribers must have a valid phone before portal lookups are enabled.
DO $preflight$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.subscribers
    WHERE phone IS NULL
       OR water_management_private.normalize_subscriber_phone(phone) IS NULL
       OR pg_catalog.length(water_management_private.normalize_subscriber_phone(phone)) NOT BETWEEN 8 AND 15
  ) THEN
    RAISE EXCEPTION
      'Subscriber portal migration stopped: every subscriber must have a valid phone number (8 to 15 digits)';
  END IF;
END;
$preflight$;

UPDATE public.subscribers
SET phone_normalized = water_management_private.normalize_subscriber_phone(phone);

ALTER TABLE public.subscribers
  ALTER COLUMN phone SET NOT NULL,
  ALTER COLUMN phone_normalized SET NOT NULL;

ALTER TABLE public.subscribers
  ADD CONSTRAINT subscribers_phone_normalized_format_check
  CHECK (phone_normalized ~ '^[0-9]{8,15}$');

-- A phone may be shared by multiple household subscribers in one organization.
-- Keep a lookup index, but do not impose uniqueness on the contact phone.
DROP INDEX IF EXISTS public.subscribers_org_phone_normalized_idx;
CREATE INDEX subscribers_org_phone_normalized_idx
  ON public.subscribers (organization_id, phone_normalized)
  WHERE phone_normalized IS NOT NULL;
-- Reserve numbers independently of subscriber rows. Allocations are never
-- deleted/reused, even if a subscriber is archived or deleted.
ALTER TABLE public.subscribers
  ADD COLUMN subscriber_number integer;

CREATE TABLE water_management_private.subscriber_number_registry (
  subscriber_number integer PRIMARY KEY
    CHECK (subscriber_number BETWEEN 100000 AND 999999),
  reserved_at timestamptz NOT NULL DEFAULT now()
);

REVOKE ALL ON TABLE water_management_private.subscriber_number_registry
  FROM PUBLIC, anon, authenticated, service_role;

-- Allocate a cryptographically random six-digit number and reserve it
-- atomically. The registry primary key resolves collisions under concurrency.
CREATE OR REPLACE FUNCTION water_management_private.enforce_subscriber_portal_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_random bigint;
  v_candidate integer;
  v_attempt integer;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.subscriber_number IS NOT NULL THEN
    IF NEW.subscriber_number IS DISTINCT FROM OLD.subscriber_number THEN
      RAISE EXCEPTION 'Subscriber number is immutable';
    END IF;
  ELSE
    FOR v_attempt IN 1..100 LOOP
      v_random := (
        'x' || pg_catalog.encode(extensions.gen_random_bytes(4), 'hex')
      )::bit(32)::bigint;

      -- Reject the small modulo tail to keep the 900,000 values unbiased.
      IF v_random >= 4294800000 THEN
        CONTINUE;
      END IF;

      v_candidate := 100000 + (v_random % 900000)::integer;

      INSERT INTO water_management_private.subscriber_number_registry(subscriber_number)
      VALUES (v_candidate)
      ON CONFLICT (subscriber_number) DO NOTHING;

      IF FOUND THEN
        NEW.subscriber_number := v_candidate;
        EXIT;
      END IF;
    END LOOP;

    IF NEW.subscriber_number IS NULL THEN
      RAISE EXCEPTION 'Unable to allocate a unique subscriber number; retry the operation';
    END IF;
  END IF;

  NEW.phone_normalized :=
    water_management_private.normalize_subscriber_phone(NEW.phone);

  IF NEW.phone_normalized IS NULL
     OR pg_catalog.length(NEW.phone_normalized) NOT BETWEEN 8 AND 15 THEN
    RAISE EXCEPTION 'A valid subscriber phone number (8 to 15 digits) is required';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION water_management_private.enforce_subscriber_portal_fields()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS subscribers_enforce_portal_fields
  ON public.subscribers;

CREATE TRIGGER subscribers_enforce_portal_fields
  BEFORE INSERT OR UPDATE ON public.subscribers
  FOR EACH ROW
  EXECUTE FUNCTION water_management_private.enforce_subscriber_portal_fields();

-- Backfill any existing subscriber rows using the same collision-safe allocator.
UPDATE public.subscribers
SET subscriber_number = NULL
WHERE subscriber_number IS NULL;

ALTER TABLE public.subscribers
  ALTER COLUMN subscriber_number SET NOT NULL,
  ADD CONSTRAINT subscribers_subscriber_number_range_check
    CHECK (subscriber_number BETWEEN 100000 AND 999999);

CREATE UNIQUE INDEX subscribers_subscriber_number_global_uidx
  ON public.subscribers (subscriber_number);

COMMENT ON COLUMN public.subscribers.subscriber_number IS
  'Random six-digit, globally unique platform subscriber number. Immutable and never reused.';

-- Private HMAC pepper and atomic attempt buckets. Raw IPs and phone numbers
-- are never stored in these rate-limit tables.
CREATE TABLE water_management_private.portal_rate_limit_secret (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  pepper bytea NOT NULL CHECK (pg_catalog.octet_length(pepper) >= 32),
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO water_management_private.portal_rate_limit_secret(singleton, pepper)
VALUES (true, extensions.gen_random_bytes(32));

CREATE TABLE water_management_private.portal_rate_limits (
  bucket_kind text NOT NULL CHECK (bucket_kind IN ('ip', 'subscriber', 'phone')),
  bucket_hash bytea NOT NULL,
  window_started_at timestamptz NOT NULL,
  attempt_count integer NOT NULL CHECK (attempt_count >= 0),
  blocked_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (bucket_kind, bucket_hash)
);

REVOKE ALL ON TABLE
  water_management_private.portal_rate_limit_secret,
  water_management_private.portal_rate_limits
  FROM PUBLIC, anon, authenticated, service_role;

GRANT USAGE ON SCHEMA water_management_private TO service_role;
GRANT SELECT ON water_management_private.portal_rate_limit_secret TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON water_management_private.portal_rate_limits
  TO service_role;

GRANT SELECT ON public.subscribers, public.pumps TO service_role;

COMMENT ON TABLE water_management_private.portal_rate_limits IS
  'HMAC-keyed IP and subscriber-number attempt buckets. No raw IP or phone values are persisted.';

-- This SECURITY INVOKER RPC is callable only by service_role. The public Edge
-- Function validates input and invokes it using the server-side service key.
CREATE OR REPLACE FUNCTION public.lookup_subscriber_portal(
  p_subscriber_number integer,
  p_phone text,
  p_client_ip text
)
RETURNS TABLE (
  rate_limited boolean,
  retry_after_seconds integer,
  found boolean,
  subscriber_number integer,
  full_name text,
  pump_name text,
  pump_code text,
  phone_last4 text
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_pepper bytea;
  v_ip inet;
  v_ip_hash bytea;
  v_subscriber_hash bytea;
  v_phone_hash bytea;
  v_phone_normalized text;
  v_bucket record;
  v_started timestamptz;
  v_attempts integer;
  v_blocked_until timestamptz;
  v_blocked boolean := false;
  v_retry_after integer := 0;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF p_subscriber_number IS NULL
     OR p_subscriber_number NOT BETWEEN 100000 AND 999999 THEN
    RETURN QUERY SELECT false, 0, false, NULL::integer, NULL::text, NULL::text, NULL::text, NULL::text;
    RETURN;
  END IF;

  BEGIN
    v_ip := p_client_ip::inet;
  EXCEPTION WHEN OTHERS THEN
    v_ip := '0.0.0.0'::inet;
  END;

  v_phone_normalized := water_management_private.normalize_subscriber_phone(p_phone);

  SELECT pepper
    INTO v_pepper
  FROM water_management_private.portal_rate_limit_secret
  WHERE singleton = true;

  IF v_pepper IS NULL THEN
    RAISE EXCEPTION 'Subscriber portal rate limiter is not configured';
  END IF;

  v_ip_hash := extensions.hmac(
    pg_catalog.convert_to('ip:' || pg_catalog.host(v_ip), 'UTF8'),
    v_pepper,
    'sha256'
  );

  v_subscriber_hash := extensions.hmac(
    pg_catalog.convert_to('subscriber:' || p_subscriber_number::text, 'UTF8'),
    v_pepper,
    'sha256'
  );

  IF v_phone_normalized IS NOT NULL THEN
    v_phone_hash := extensions.hmac(
      pg_catalog.convert_to('phone:' || v_phone_normalized, 'UTF8'),
      v_pepper,
      'sha256'
    );
  END IF;

  -- 10 attempts/IP per 15 minutes, 5/subscriber per hour, and
  -- 5/phone per hour. Phone is HMACed: no clear phone is persisted.
  FOR v_bucket IN
    SELECT *
    FROM (
      VALUES
        ('ip'::text, v_ip_hash, 10, interval '15 minutes'),
        ('subscriber'::text, v_subscriber_hash, 5, interval '1 hour'),
        ('phone'::text, v_phone_hash, 5, interval '1 hour')
    ) AS limits(bucket_kind, bucket_hash, max_attempts, bucket_window)
    WHERE bucket_hash IS NOT NULL
  LOOP
    INSERT INTO water_management_private.portal_rate_limits (
      bucket_kind, bucket_hash, window_started_at, attempt_count
    )
    VALUES (v_bucket.bucket_kind, v_bucket.bucket_hash, v_now, 0)
    ON CONFLICT (bucket_kind, bucket_hash) DO NOTHING;

    SELECT window_started_at, attempt_count, blocked_until
      INTO v_started, v_attempts, v_blocked_until
    FROM water_management_private.portal_rate_limits
    WHERE bucket_kind = v_bucket.bucket_kind
      AND bucket_hash = v_bucket.bucket_hash
    FOR UPDATE;

    IF v_blocked_until IS NOT NULL AND v_blocked_until > v_now THEN
      v_blocked := true;
      v_retry_after := GREATEST(
        v_retry_after,
        pg_catalog.ceil(EXTRACT(epoch FROM (v_blocked_until - v_now)))::integer
      );
      CONTINUE;
    END IF;

    IF v_started + v_bucket.bucket_window <= v_now THEN
      v_started := v_now;
      v_attempts := 1;
      v_blocked_until := NULL;
    ELSE
      v_attempts := v_attempts + 1;
      IF v_attempts > v_bucket.max_attempts THEN
        v_blocked_until := v_started + v_bucket.bucket_window;
        v_blocked := true;
        v_retry_after := GREATEST(
          v_retry_after,
          pg_catalog.ceil(EXTRACT(epoch FROM (v_blocked_until - v_now)))::integer
        );
      ELSE
        v_blocked_until := NULL;
      END IF;
    END IF;

    UPDATE water_management_private.portal_rate_limits
    SET window_started_at = v_started,
        attempt_count = v_attempts,
        blocked_until = v_blocked_until,
        updated_at = v_now
    WHERE bucket_kind = v_bucket.bucket_kind
      AND bucket_hash = v_bucket.bucket_hash;
  END LOOP;

  DELETE FROM water_management_private.portal_rate_limits
  WHERE updated_at < v_now - interval '2 days';

  IF v_blocked THEN
    RETURN QUERY SELECT true, GREATEST(v_retry_after, 1), false,
      NULL::integer, NULL::text, NULL::text, NULL::text, NULL::text;
    RETURN;
  END IF;

  IF v_phone_normalized IS NULL
     OR pg_catalog.length(v_phone_normalized) NOT BETWEEN 8 AND 15 THEN
    RETURN QUERY SELECT false, 0, false, NULL::integer, NULL::text, NULL::text, NULL::text, NULL::text;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    false,
    0,
    true,
    s.subscriber_number,
    s.full_name,
    p.name,
    p.code,
    pg_catalog.right(s.phone_normalized, 4)
  FROM public.subscribers AS s
  LEFT JOIN public.pumps AS p
    ON p.id = s.pump_id
   AND p.organization_id = s.organization_id
  WHERE s.subscriber_number = p_subscriber_number
    AND s.phone_normalized = v_phone_normalized
    AND s.is_active = true
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 0, false, NULL::integer, NULL::text, NULL::text, NULL::text, NULL::text;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.lookup_subscriber_portal(integer, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lookup_subscriber_portal(integer, text, text)
  TO service_role;

COMMENT ON FUNCTION public.lookup_subscriber_portal(integer, text, text) IS
  'Rate-limited exact match on a random global six-digit subscriber number and normalized phone. Returns a minimal portal projection; service_role only.';
