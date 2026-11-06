import assert from "node:assert/strict";

const supabaseUrl = process.env.SUPABASE_URL;
const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;
const previewOrigin = process.env.PREVIEW_ORIGIN;

if (!supabaseUrl || !publishableKey || !previewOrigin) {
  throw new Error("SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, and PREVIEW_ORIGIN are required.");
}

const endpoint = new URL("/functions/v1/subscriber-portal", supabaseUrl).toString();
const manageEndpoint = new URL("/functions/v1/manage-accounts", supabaseUrl).toString();
const commonHeaders = { apikey: publishableKey };

async function request(url, init = {}) {
  return fetch(url, {
    ...init,
    headers: { ...commonHeaders, ...(init.headers ?? {}) },
    redirect: "manual",
  });
}

const preflight = await request(endpoint, {
  method: "OPTIONS",
  headers: {
    origin: previewOrigin,
    "access-control-request-method": "POST",
    "access-control-request-headers": "apikey, content-type",
  },
});
assert.equal(preflight.status, 200, "subscriber portal preflight should succeed");
assert.equal(preflight.headers.get("access-control-allow-origin"), "*");
assert.match(preflight.headers.get("access-control-allow-methods") ?? "", /POST/);

const portalGet = await request(endpoint, { method: "GET" });
assert.equal(portalGet.status, 405, "subscriber portal must reject GET");
assert.match(portalGet.headers.get("allow") ?? "", /POST/);

const portalWrongContentType = await request(endpoint, {
  method: "POST",
  headers: { "content-type": "text/plain", origin: previewOrigin },
  body: "not-json",
});
assert.equal(portalWrongContentType.status, 415, "subscriber portal must reject non-JSON");

const portalMalformedJson = await request(endpoint, {
  method: "POST",
  headers: { "content-type": "application/json", origin: previewOrigin },
  body: "{",
});
assert.equal(portalMalformedJson.status, 400, "subscriber portal must reject malformed JSON");

const portalMalformedIdentity = await request(endpoint, {
  method: "POST",
  headers: { "content-type": "application/json", origin: previewOrigin },
  body: JSON.stringify({ subscriber_number: "12", phone: "0591234567" }),
});
assert.equal(portalMalformedIdentity.status, 200);
assert.deepEqual(await portalMalformedIdentity.json(), { found: false });

const manageNoJwt = await request(manageEndpoint, {
  method: "POST",
  headers: { "content-type": "application/json", origin: previewOrigin },
  body: JSON.stringify({ action: "list_users" }),
});
assert.equal(manageNoJwt.status, 401, "manage-accounts must reject requests without a JWT");

const manageInvalidJwt = await request(manageEndpoint, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    origin: previewOrigin,
    authorization: "Bearer not-a-valid-jwt",
  },
  body: JSON.stringify({ action: "list_users" }),
});
assert.equal(manageInvalidJwt.status, 401, "manage-accounts must reject an invalid JWT");

// A valid-format lookup would write three rate-limit buckets. Keep recurring CI
// non-mutating; the live RPC and rate limiter are separately exercised in an
// operator-run transaction whose cleanup is verified before completion.
const portalRejectedBeforeRateLimit = await request(endpoint, {
  method: "POST",
  headers: { "content-type": "application/json", origin: previewOrigin },
  body: JSON.stringify({
    subscriber_number: "999999",
    phone: "123",
  }),
});
assert.equal(portalRejectedBeforeRateLimit.status, 200);
assert.deepEqual(await portalRejectedBeforeRateLimit.json(), { found: false });


console.log(JSON.stringify({
  result: "PASS",
  testStartedAt,
  checks: {
    subscriberPreflight: preflight.status,
    preflightOrigin: preflight.headers.get("access-control-allow-origin"),
    subscriberGetRejected: portalGet.status,
    subscriberContentTypeRejected: portalWrongContentType.status,
    subscriberMalformedJsonRejected: portalMalformedJson.status,
    subscriberMalformedIdentityRejected: portalMalformedIdentity.status,
    manageAccountsNoJwtRejected: manageNoJwt.status,
    manageAccountsInvalidJwtRejected: manageInvalidJwt.status,
    subscriberMalformedIdentityWithoutRateLimitMutation: portalRejectedBeforeRateLimit.status,
  },
  cleanupNote: "CI uses malformed identity input that exits before the rate limiter; it does not create subscriber, account, or rate-limit rows.",
}));
