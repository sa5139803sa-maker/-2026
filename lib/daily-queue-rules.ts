export type DailyQueueOrderingItem = {
  id: string;
  branchId: string | null;
  sortOrder: number;
};

export type ConsecutiveBranchConflict = {
  /** One-based position of the later item in the queue. */
  position: number;
  previousItemId: string;
  itemId: string;
  branchId: string;
};

type PendingItem<T> = {
  item: T;
  inputIndex: number;
};

type BranchBucket<T> = {
  branchId: string | null;
  items: PendingItem<T>[];
  nextIndex: number;
};

function comparePending<T extends DailyQueueOrderingItem>(
  left: PendingItem<T>,
  right: PendingItem<T>,
): number {
  return left.item.sortOrder - right.item.sortOrder || left.inputIndex - right.inputIndex;
}

function assertValidItems<T extends DailyQueueOrderingItem>(items: readonly T[]): void {
  const seenIds = new Set<string>();

  for (const item of items) {
    if (typeof item.id !== "string" || item.id.trim().length === 0) {
      throw new TypeError("Every daily queue item must have a non-empty id.");
    }
    if (seenIds.has(item.id)) {
      throw new TypeError(`Duplicate daily queue item id: ${item.id}`);
    }
    seenIds.add(item.id);

    if (!Number.isSafeInteger(item.sortOrder) || item.sortOrder < 0) {
      throw new TypeError("Queue sortOrder must be a non-negative safe integer.");
    }
    if (item.branchId !== null &&
      (typeof item.branchId !== "string" || item.branchId.trim().length === 0)) {
      throw new TypeError("branchId must be a non-empty string or null.");
    }
  }
}

/**
 * Produces a deterministic queue order that avoids adjacent items from the
 * same assigned branch whenever another branch is still available.
 *
 * The relative order of items within each branch is preserved. Items without
 * a branch are not treated as belonging to one shared branch. The input array
 * and its items are never mutated.
 *
 * This is a domain rule only; persistence, authorization, and manual override
 * reasons must be enforced by the server/database layer.
 */
export function orderDailyQueueByBranch<T extends DailyQueueOrderingItem>(
  items: readonly T[],
): T[] {
  assertValidItems(items);

  const buckets = new Map<string | null, BranchBucket<T>>();

  items.forEach((item, inputIndex) => {
    let bucket = buckets.get(item.branchId);
    if (!bucket) {
      bucket = { branchId: item.branchId, items: [], nextIndex: 0 };
      buckets.set(item.branchId, bucket);
    }
    bucket.items.push({ item, inputIndex });
  });

  for (const bucket of buckets.values()) {
    bucket.items.sort(comparePending);
  }

  const result: T[] = [];
  let lastBranchId: string | null | undefined;

  while (result.length < items.length) {
    const available = [...buckets.values()].filter(
      (bucket) => bucket.nextIndex < bucket.items.length,
    );
    const alternatives = available.filter((bucket) => {
      const nextBranchId = bucket.items[bucket.nextIndex].item.branchId;
      return nextBranchId === null ||
        lastBranchId === undefined ||
        nextBranchId !== lastBranchId;
    });

    // Repeating a branch is permitted only when no other assigned branch has
    // a remaining item. This is unavoidable when one branch has excess items.
    const candidates = alternatives.length > 0 ? alternatives : available;
    candidates.sort((left, right) =>
      comparePending(
        left.items[left.nextIndex],
        right.items[right.nextIndex],
      ),
    );

    const selected = candidates[0];
    const next = selected.items[selected.nextIndex];
    selected.nextIndex += 1;
    result.push(next.item);
    lastBranchId = next.item.branchId;
  }

  return result;
}

/**
 * Finds adjacent queue items from the same assigned branch.
 * Unassigned items (branchId = null) are intentionally ignored.
 */
export function findConsecutiveBranchConflicts<T extends DailyQueueOrderingItem>(
  items: readonly T[],
): ConsecutiveBranchConflict[] {
  const conflicts: ConsecutiveBranchConflict[] = [];

  for (let index = 1; index < items.length; index += 1) {
    const previous = items[index - 1];
    const current = items[index];

    if (current.branchId !== null && current.branchId === previous.branchId) {
      conflicts.push({
        position: index + 1,
        previousItemId: previous.id,
        itemId: current.id,
        branchId: current.branchId,
      });
    }
  }

  return conflicts;
}
