/*
  Defense in depth for private portal tables.

  No client policies are created. API roles retain no direct table privileges.
  service_role keeps its existing narrow grants and BYPASSRLS behavior; the
  subscriber-number trigger continues to execute as its postgres-owned
  SECURITY DEFINER function.
*/

ALTER TABLE water_management_private.subscriber_number_registry
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE water_management_private.portal_rate_limit_secret
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE water_management_private.portal_rate_limits
  ENABLE ROW LEVEL SECURITY;

-- Reassert that these internal tables are not directly available to clients.
-- Existing service_role grants are intentionally preserved.
REVOKE ALL ON TABLE
  water_management_private.subscriber_number_registry,
  water_management_private.portal_rate_limit_secret,
  water_management_private.portal_rate_limits
FROM PUBLIC, anon, authenticated;
