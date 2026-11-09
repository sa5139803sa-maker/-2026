import test from "node:test";
import assert from "node:assert/strict";
import {
  END_REMINDER_GRACE_MS,
  getHandoverAlertWindow,
  getOperationNotificationSchedule,
  shouldTriggerMinuteWarning,
} from "../../lib/alerts/timing-rules.ts";

test("minute warning starts at one minute and does not repeat", () => {
  assert.equal(shouldTriggerMinuteWarning(61, false), false);
  assert.equal(shouldTriggerMinuteWarning(60, false), true);
  assert.equal(shouldTriggerMinuteWarning(56, false), true);
  assert.equal(shouldTriggerMinuteWarning(55, false), false);
  assert.equal(shouldTriggerMinuteWarning(0, false), false);
  assert.equal(shouldTriggerMinuteWarning(59, true), false);
});

test("native notification timestamps include elapsed pause time", () => {
  const start = "2026-11-09T20:00:00.000Z";
  const schedule = getOperationNotificationSchedule(start, 5, 30, Date.parse(start));
  assert.deepEqual(schedule, {
    endAt: Date.parse(start) + 330_000,
    minuteWarningAt: Date.parse(start) + 270_000,
    endReminderAt: Date.parse(start) + 330_000 + END_REMINDER_GRACE_MS,
  });
});

test("expired minute warning is not replayed when app returns", () => {
  const start = "2026-11-09T20:00:00.000Z";
  const schedule = getOperationNotificationSchedule(start, 5, 0, Date.parse(start) + 240_000);
  assert.equal(schedule?.minuteWarningAt, null);
  assert.notEqual(schedule?.endReminderAt, null);
});

test("invalid timer values do not schedule notifications", () => {
  assert.equal(getOperationNotificationSchedule("not-a-date", 5, 0, 0), null);
  assert.equal(getOperationNotificationSchedule("2026-11-09T20:00:00Z", 0, 0, 0), null);
  assert.equal(getOperationNotificationSchedule("2026-11-09T20:00:00Z", 5, -1, 0), null);
});

test("queue transition notification uses the final two seconds of three", () => {
  assert.deepEqual(getHandoverAlertWindow(3000, 0), { delayMs: 1000, durationMs: 2000 });
  assert.deepEqual(getHandoverAlertWindow(2000, 0), { delayMs: 0, durationMs: 2000 });
  assert.deepEqual(getHandoverAlertWindow(1500, 0), { delayMs: 0, durationMs: 1500 });
});

test("cancelled and expired queue deadlines never replay", () => {
  assert.equal(getHandoverAlertWindow(0, 0), null);
  assert.equal(getHandoverAlertWindow(999, 1000), null);
  assert.equal(getHandoverAlertWindow(Number.NaN, 0), null);
});
