export const MINUTE_WARNING_THRESHOLD_SECONDS = 60;
export const MINUTE_WARNING_WINDOW_SECONDS = 5;
export const HANDOVER_WARNING_WINDOW_MS = 2000;
export const END_REMINDER_GRACE_MS = 3000;

export type HandoverAlertWindow = { delayMs: number; durationMs: number };
export type OperationNotificationSchedule = {
  endAt: number;
  minuteWarningAt: number | null;
  endReminderAt: number | null;
};

export function shouldTriggerMinuteWarning(remainingSeconds: number, alreadyTriggered: boolean): boolean {
  return (
    !alreadyTriggered
    && Number.isFinite(remainingSeconds)
    && remainingSeconds <= MINUTE_WARNING_THRESHOLD_SECONDS
    && remainingSeconds > MINUTE_WARNING_THRESHOLD_SECONDS - MINUTE_WARNING_WINDOW_SECONDS
  );
}

export function getOperationNotificationSchedule(
  startedAt: string,
  plannedMinutes: number,
  pausedSeconds: number,
  nowEpochMs: number,
): OperationNotificationSchedule | null {
  const startedAtMs = Date.parse(startedAt);
  if (!Number.isFinite(startedAtMs) || !Number.isInteger(plannedMinutes) || plannedMinutes < 1
      || !Number.isFinite(pausedSeconds) || pausedSeconds < 0 || !Number.isFinite(nowEpochMs)) {
    return null;
  }
  const endAt = startedAtMs + plannedMinutes * 60_000 + pausedSeconds * 1000;
  if (!Number.isFinite(endAt)) return null;
  const minuteWarningAt = endAt - MINUTE_WARNING_THRESHOLD_SECONDS * 1000;
  const endReminderAt = endAt + END_REMINDER_GRACE_MS;
  return {
    endAt,
    minuteWarningAt: minuteWarningAt > nowEpochMs ? minuteWarningAt : null,
    endReminderAt: endReminderAt > nowEpochMs ? endReminderAt : null,
  };
}

export function getHandoverAlertWindow(deadlineEpochMs: number, nowEpochMs: number): HandoverAlertWindow | null {
  if (!Number.isFinite(deadlineEpochMs) || !Number.isFinite(nowEpochMs)) return null;
  const remainingMs = deadlineEpochMs - nowEpochMs;
  if (remainingMs <= 0) return null;
  const durationMs = Math.min(HANDOVER_WARNING_WINDOW_MS, remainingMs);
  return { delayMs: Math.max(0, remainingMs - HANDOVER_WARNING_WINDOW_MS), durationMs };
}
