export const MINUTE_WARNING_THRESHOLD_SECONDS = 60;
export const MINUTE_WARNING_WINDOW_SECONDS = 5;
export const HANDOVER_WARNING_WINDOW_MS = 2000;

export type HandoverAlertWindow = {
  delayMs: number;
  durationMs: number;
};

export function shouldTriggerMinuteWarning(
  remainingSeconds: number,
  alreadyTriggered: boolean,
): boolean {
  return (
    !alreadyTriggered
    && Number.isFinite(remainingSeconds)
    && remainingSeconds <= MINUTE_WARNING_THRESHOLD_SECONDS
    && remainingSeconds > MINUTE_WARNING_THRESHOLD_SECONDS - MINUTE_WARNING_WINDOW_SECONDS
  );
}

/**
 * Return the exact local scheduling window for the one combined
 * end-of-fill / handover alert. At a fresh 3s deadline this returns
 * delay=1s and duration=2s. A stale deadline never replays a missed alert.
 */
export function getHandoverAlertWindow(
  deadlineEpochMs: number,
  nowEpochMs: number,
): HandoverAlertWindow | null {
  if (!Number.isFinite(deadlineEpochMs) || !Number.isFinite(nowEpochMs)) return null;
  const remainingMs = deadlineEpochMs - nowEpochMs;
  if (remainingMs <= 0) return null;

  const durationMs = Math.min(HANDOVER_WARNING_WINDOW_MS, remainingMs);
  return {
    delayMs: Math.max(0, remainingMs - HANDOVER_WARNING_WINDOW_MS),
    durationMs,
  };
}
