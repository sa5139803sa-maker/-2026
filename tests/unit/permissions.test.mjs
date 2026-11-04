import assert from "node:assert/strict";
import test from "node:test";
import { canAccessFeature, roleAccess } from "../../lib/permissions.ts";

test("manager can access all organization management features", () => {
  for (const feature of Object.keys(roleAccess)) {
    assert.equal(canAccessFeature("manager", feature), true, feature);
  }
});

test("operator is limited to operations", () => {
  assert.equal(canAccessFeature("operator", "operations"), true);
  assert.equal(canAccessFeature("operator", "management"), false);
  assert.equal(canAccessFeature("operator", "collections"), false);
  assert.equal(canAccessFeature("operator", "dashboardStats"), false);
  assert.equal(canAccessFeature("operator", "userManagement"), false);
});

test("collector is limited to collections", () => {
  assert.equal(canAccessFeature("collector", "collections"), true);
  assert.equal(canAccessFeature("collector", "operations"), false);
  assert.equal(canAccessFeature("collector", "management"), false);
  assert.equal(canAccessFeature("collector", "dashboardStats"), false);
});

test("supervisor has read-only reports scope only", () => {
  assert.equal(canAccessFeature("supervisor", "reports"), true);
  assert.equal(canAccessFeature("supervisor", "management"), false);
  assert.equal(canAccessFeature("supervisor", "operations"), false);
  assert.equal(canAccessFeature("supervisor", "collections"), false);
  assert.equal(canAccessFeature("supervisor", "userManagement"), false);
});

test("missing roles have no protected feature access", () => {
  assert.equal(canAccessFeature(null, "management"), false);
  assert.equal(canAccessFeature(undefined, "operations"), false);
});
