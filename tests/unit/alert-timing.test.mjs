import test from "node:test";
import assert from "node:assert/strict";
import {
  getHandoverAlertWindow,
  shouldTriggerMinuteWarning,
} from "../../lib/alerts/timing-rules.ts";

test("minute warning fires only in the final five-second window beginning at 60s", () => {
  assert.equal(shouldTriggerMinuteWarning(61, false), false);
  assert.equal(shouldTriggerMinuteWarning(60, false), true);
  assert.equal(shouldTriggerMinuteWarning(56, false), true);
  assert.equal(shouldTriggerMinuteWarning(55, false), false);
  assert.equal(shouldTriggerMinuteWarning(0, false), false);
  assert.equal(shouldTriggerMinuteWarning(59, true), false);
});

test("combined handover alert begins after one second and lasts the final two seconds", () => {
  assert.deepEqual(getHandoverAlertWindow(3000, 0), { delayMs: 1000, durationMs: 2000 });
});

test("combined handover alert starts immediately when only two seconds remain", () => {
  assert.deepEqual(getHandoverAlertWindow(2000, 0), { delayMs: 0, durationMs: 2000 });
});

test("when less than two seconds remain, handover alert lasts only to the deadline", () => {
  assert.deepEqual(getHandoverAlertWindow(1500, 0), { delayMs: 0, durationMs: 1500 });
});

test("cancelled or overdue handover deadlines never replay a stale alert", () => {
  assert.equal(getHandoverAlertWindow(0, 0), null);
  assert.equal(getHandoverAlertWindow(999, 1000), null);
});

test("invalid timing values are ignored", () => {
  assert.equal(getHandoverAlertWindow(Number.NaN, 0), null);
  assert.equal(getHandoverAlertWindow(1000, Number.NaN), null);
  assert.equal(shouldTriggerMinuteWarning(Number.NaN, false), false);
});
