import { getJwtIssuedAtSeconds } from "./session-token.ts";

function tokenWithPayload(payload: Record<string, unknown>): string {
  const encoded = btoa(JSON.stringify(payload))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
  return `header.${encoded}.signature`;
}

Deno.test("reads the Auth-issued iat from a Bearer JWT", () => {
  const token = tokenWithPayload({ sub: "test-user", iat: 1_800_000_000 });
  const actual = getJwtIssuedAtSeconds(`Bearer ${token}`);
  if (actual !== 1_800_000_000) throw new Error(`Expected iat, got ${actual}`);
});

Deno.test("rejects a missing Bearer prefix", () => {
  const token = tokenWithPayload({ iat: 1_800_000_000 });
  if (getJwtIssuedAtSeconds(token) !== null) throw new Error("A non-Bearer token was accepted");
});

Deno.test("rejects a JWT without an integer iat", () => {
  const token = tokenWithPayload({ sub: "test-user", iat: "later" });
  if (getJwtIssuedAtSeconds(`Bearer ${token}`) !== null) throw new Error("A string iat was accepted");
});

Deno.test("rejects malformed tokens", () => {
  if (getJwtIssuedAtSeconds("Bearer not-a-jwt") !== null) {
    throw new Error("A malformed token was accepted");
  }
});
