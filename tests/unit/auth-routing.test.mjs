import assert from "node:assert/strict";
import test from "node:test";
import { getAuthenticatedDestination } from "../../lib/auth-routing.ts";

test("authenticated users with an organization enter the app", () => {
  assert.equal(
    getAuthenticatedDestination("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
    "/(tabs)",
  );
});

test("authenticated users without an organization must complete onboarding", () => {
  assert.equal(getAuthenticatedDestination(null), "/onboarding");
  assert.equal(getAuthenticatedDestination(undefined), "/onboarding");
  assert.equal(getAuthenticatedDestination(""), "/onboarding");
});
