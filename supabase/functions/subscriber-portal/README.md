# Subscriber portal Edge Function

Public unauthenticated lookup. Deploy with `verify_jwt=false`.

## Request

POST JSON:

```json
{
  "subscriber_number": "123456",
  "phone": "0591234567"
}
```

Both values are mandatory. There is no OTP and no subscriber Auth account.

## Trust boundary

- The Edge Function obtains the caller IP from the Supabase gateway's `x-forwarded-for` header (gateway-appended final entry), not from request JSON.
- The RPC HMACs the IP and subscriber number with a private random pepper stored in `water_management_private`; raw IP and phone values are not written to rate-limit storage.
- Supabase service-role key exists only in the Edge Function environment. It is never returned to the browser.
- The Edge Function is the only public entry point. The database lookup RPC has EXECUTE granted only to `service_role`.
- All unknown, inactive, or phone-mismatched records return the same `{ found: false }` response.
- On success, return only the subscriber's number, name, assigned pump label/code, and last four phone digits. No organization ID, UUID, full phone, financial history, or internal fields are exposed.
- Requests are limited to 20 per IP per 15 minutes and 8 per subscriber number per hour; the database performs atomic locking and increments.

## CORS

CORS is wildcard because this is intentionally a public, non-cookie, read-only lookup. CORS is not treated as authentication or abuse prevention; the database rate limiter is enforced for every origin.

## Operational requirements

- Configure Supabase's Edge Function gateway to provide `x-forwarded-for`. The function fails closed with 503 if no trusted gateway address is available.
- Monitor 429 and 503 rates. The SQL rate-limit buckets are HMAC-keyed and are opportunistically pruned after two days.
- Do not add OTP or subscriber Auth accounts. Phone + six-digit global number is the agreed verification mechanism.