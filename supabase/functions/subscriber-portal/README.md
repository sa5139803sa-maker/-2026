# Subscriber portal Edge Function

Public unauthenticated lookup. Deploy with `verify_jwt=false`. The browser calls this single Edge Function directly using the publishable key; no intermediate Next.js Route Handler is used.

## Request

POST JSON:

```json
{
  "subscriber_number": "123456",
  "phone": "0591234567"
}
```

Both values are mandatory. The subscriber number is six digits and globally unique. There is no OTP, SMS verification, or subscriber Auth account.

## Trust boundary

- The Edge Function trusts only Cloudflare's `cf-connecting-ip` header as supplied by Supabase's managed edge gateway. It deliberately ignores `x-forwarded-for`, `x-real-ip`, `x-vercel-forwarded-for`, and any IP supplied in JSON because those can be forged when the public function URL is called directly. It fails closed with 503 if the trusted header is absent.
- Phone numbers are not unique: household members may share the same registered contact phone. The subscriber number remains globally unique.
- The RPC HMACs the IP, subscriber number, and normalized phone with a private random pepper stored in `water_management_private`; raw IP and phone values are not written to rate-limit storage.
- Supabase service-role key exists only in the Edge Function environment. It is never returned to the browser.
- The Edge Function is the only public entry point. The database lookup RPC has EXECUTE granted only to `service_role`.
- All unknown, inactive, or phone-mismatched records return the same `{ found: false }` response.
- On success, return only the subscriber's number, name, assigned pump label/code, and last four phone digits. No organization ID, UUID, full phone, financial history, or internal fields are exposed.
- Requests are limited to 10 per IP per 15 minutes, 5 per subscriber number per hour, and 5 per normalized phone per hour; the database performs atomic locking and increments.

## CORS

CORS is wildcard because this is intentionally a public, non-cookie, read-only lookup. CORS is not treated as authentication or abuse prevention; the database rate limiter is enforced for every origin.

## Operational requirements

- Supabase's managed gateway must provide `cf-connecting-ip`; the function fails closed with 503 if it is absent. Never put this function behind a proxy that does not sanitize/overwrite this header.
- Monitor 429 and 503 rates. The SQL rate-limit buckets are HMAC-keyed and are opportunistically pruned after two days.
- Do not add OTP or subscriber Auth accounts. Phone + six-digit global number is the agreed verification mechanism.

## Development deployment status

- Migration `20261106190000_add_global_subscriber_number_and_public_lookup.sql` applied to the primary project `kxdncnswbwktbiphptbr`.
- Function `subscriber-portal` deployed as version 1, ACTIVE, with `verify_jwt=false`; version 2 updates IP trust to accept only `cf-connecting-ip`.
- PostgreSQL RLS, web console, and quality CI passed on commit `86dad24be7aa8895bcda34ed6884ed20db527af3`.
- Live SQL verification confirmed service-role-only RPC execution and a non-matching lookup result. The primary database has no subscriber rows yet, so a successful match has been tested using transaction-scoped synthetic data with ROLLBACK. A live browser HTTP test is still required.
