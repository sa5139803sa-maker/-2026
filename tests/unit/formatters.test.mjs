import assert from "node:assert/strict";
import test from "node:test";
import { formatDuration } from "../../components/ui/formatters.ts";

test("formats zero and minute/second durations", () => {
  assert.equal(formatDuration(0), "00:00");
  assert.equal(formatDuration(7), "00:07");
  assert.equal(formatDuration(65), "01:05");
  assert.equal(formatDuration(3599), "59:59");
});

test("formats durations that include hours", () => {
  assert.equal(formatDuration(3600), "01:00:00");
  assert.equal(formatDuration(3661), "01:01:01");
  assert.equal(formatDuration(360000), "100:00:00");
});

test("normalizes negative, fractional, and non-finite inputs", () => {
  assert.equal(formatDuration(-1), "00:00");
  assert.equal(formatDuration(60.9), "01:00");
  assert.equal(formatDuration(Number.NaN), "00:00");
  assert.equal(formatDuration(Number.POSITIVE_INFINITY), "00:00");
});
