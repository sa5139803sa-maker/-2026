import test from "node:test";
import assert from "node:assert/strict";
import {
  END_REMINDER_GRACE_MS,
  getHandoverAlertWindow,
  getOperationNotificationSchedule,
  getPersistentTimerSnapshot,
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


test("persistent notification derives an absolute end timestamp for a running operation", () => {
  const start = "2026-11-09T20:00:00.000Z";
  assert.deepEqual(getPersistentTimerSnapshot({
    id: "operation-1",
    status: "running",
    started_at: start,
    paused_at: null,
    planned_minutes: 5,
    paused_seconds: 30,
  }, Date.parse(start) + 1000), {
    mode: "running",
    operationId: "operation-1",
    endAtEpochMs: Date.parse(start) + 330_000,
  });
});

test("persistent notification freezes correct remaining time while paused", () => {
  const start = "2026-11-09T20:00:00.000Z";
  assert.deepEqual(getPersistentTimerSnapshot({
    id: "operation-2",
    status: "paused",
    started_at: start,
    paused_at: "2026-11-09T20:02:00.000Z",
    planned_minutes: 5,
    paused_seconds: 0,
  }, Date.parse("2026-11-09T20:03:00.000Z")), {
    mode: "paused",
    operationId: "operation-2",
    remainingMs: 180_000,
  });
});

test("persistent paused time subtracts only previously accumulated pauses", () => {
  const start = "2026-11-09T20:00:00.000Z";
  const snapshot = getPersistentTimerSnapshot({
    id: "operation-3",
    status: "paused",
    started_at: start,
    paused_at: "2026-11-09T20:02:00.000Z",
    planned_minutes: 5,
    paused_seconds: 15,
  }, Date.parse(start));
  assert.equal(snapshot?.mode, "paused");
  assert.equal(snapshot?.remainingMs, 165_000);
});

test("completed or invalid operations do not leave a persistent countdown", () => {
  const start = "2026-11-09T20:00:00.000Z";
  assert.equal(getPersistentTimerSnapshot({
    id: "operation-4",
    status: "completed",
    started_at: start,
    paused_at: null,
    planned_minutes: 5,
    paused_seconds: 0,
  }, Date.parse(start)), null);
  assert.equal(getPersistentTimerSnapshot({
    id: "operation-5",
    status: "paused",
    started_at: start,
    paused_at: null,
    planned_minutes: 5,
    paused_seconds: 0,
  }, Date.parse(start)), null);
});
