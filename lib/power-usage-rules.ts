export type SourceDurationSeconds = {
  sourceId: string;
  totalSeconds: number;
};

/**
 * Converts fractional source intervals into whole minutes without losing
 * fractional minutes between sources. The sum is rounded down once, then
 * remaining minutes are assigned by largest remainder with a stable ID tie-break.
 */
export function allocateWholeMinutesByLargestRemainder(
  sourceDurations: readonly SourceDurationSeconds[],
): Record<string, string> {
  const secondsBySource = new Map<string, number>();

  for (const row of sourceDurations) {
    if (!row.sourceId.trim()) {
      throw new Error("Power source ID is required.");
    }
    if (!Number.isSafeInteger(row.totalSeconds) || row.totalSeconds < 0) {
      throw new RangeError("Source duration must be a non-negative safe integer.");
    }
    secondsBySource.set(
      row.sourceId,
      (secondsBySource.get(row.sourceId) ?? 0) + row.totalSeconds,
    );
  }

  const entries = [...secondsBySource.entries()]
    .map(([sourceId, seconds]) => ({
      sourceId,
      minutes: Math.floor(seconds / 60),
      remainderSeconds: seconds % 60,
    }))
    .sort((a, b) => a.sourceId.localeCompare(b.sourceId));

  const totalSeconds = entries.reduce((sum, entry) => sum + entry.minutes * 60 + entry.remainderSeconds, 0);
  const targetMinutes = Math.floor(totalSeconds / 60);
  const allocatedMinutes = entries.reduce((sum, entry) => sum + entry.minutes, 0);
  let remainingMinutes = targetMinutes - allocatedMinutes;

  const byLargestRemainder = [...entries].sort(
    (a, b) => b.remainderSeconds - a.remainderSeconds || a.sourceId.localeCompare(b.sourceId),
  );

  for (const entry of byLargestRemainder) {
    if (remainingMinutes <= 0) break;
    entry.minutes += 1;
    remainingMinutes -= 1;
  }

  const result: Record<string, string> = {};
  for (const entry of entries) {
    result[entry.sourceId] = entry.minutes > 0 ? String(entry.minutes) : "";
  }
  return result;
}
