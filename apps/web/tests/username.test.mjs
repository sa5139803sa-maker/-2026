import assert from "node:assert/strict";
import { test } from "node:test";
import {
  usernameToAuthEmail,
  validateLoginIdentifier,
} from "../lib/auth/username.ts";

test("username mapping is case-insensitive and stable", () => {
  assert.equal(
    usernameToAuthEmail("Worker01"),
    "u-776f726b65723031@login.water-management.invalid",
  );
  assert.equal(usernameToAuthEmail(" worker01 "), usernameToAuthEmail("WORKER01"));
});

test("Arabic usernames are encoded as UTF-8 bytes", () => {
  const username = "مستخدم";
  const expected = Array.from(new TextEncoder().encode(username), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  assert.equal(
    usernameToAuthEmail(username),
    `u-${expected}@login.water-management.invalid`,
  );
});

test("emails remain unchanged", () => {
  assert.equal(
    usernameToAuthEmail("Admin@example.com"),
    "Admin@example.com",
  );
});

test("login identifiers reject empty, whitespace, and invalid characters", () => {
  assert.equal(validateLoginIdentifier("operator_1"), true);
  assert.equal(validateLoginIdentifier("مشغل-١"), true);
  assert.equal(validateLoginIdentifier("name@example.com"), true);
  assert.equal(validateLoginIdentifier(""), false);
  assert.equal(validateLoginIdentifier("bad user"), false);
  assert.equal(validateLoginIdentifier("bad@"), false);
  assert.equal(validateLoginIdentifier("a".repeat(41)), false);
});