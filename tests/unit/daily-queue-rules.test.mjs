import assert from "node:assert/strict";
import test from "node:test";
import {
  findConsecutiveBranchConflicts,
  orderDailyQueueByBranch,
} from "../../lib/daily-queue-rules.ts";

const item = (id, branchId, sortOrder) => ({ id, branchId, sortOrder });

test("interleaves branches whenever another assigned branch is available", () => {
  const input = [
    item("a-1", "branch-a", 0),
    item("a-2", "branch-a", 1),
    item("b-1", "branch-b", 2),
    item("b-2", "branch-b", 3),
    item("c-1", "branch-c", 4),
  ];

  assert.deepEqual(
    orderDailyQueueByBranch(input).map(({ id }) => id),
    ["a-1", "b-1", "a-2", "b-2", "c-1"],
  );
});

test("preserves relative order within each branch", () => {
  const input = [
    item("a-1", "branch-a", 0),
    item("b-1", "branch-b", 1),
    item("a-2", "branch-a", 2),
    item("b-2", "branch-b", 3),
    item("a-3", "branch-a", 4),
  ];

  const ordered = orderDailyQueueByBranch(input);
  const positionsFor = (branchId) => ordered
    .filter((candidate) => candidate.branchId === branchId)
    .map((candidate) => candidate.id);

  assert.deepEqual(positionsFor("branch-a"), ["a-1", "a-2", "a-3"]);
  assert.deepEqual(positionsFor("branch-b"), ["b-1", "b-2"]);
});

test("repeats a branch only after all alternative branches are exhausted", () => {
  const ordered = orderDailyQueueByBranch([
    item("a-1", "branch-a", 0),
    item("a-2", "branch-a", 1),
    item("a-3", "branch-a", 2),
    item("a-4", "branch-a", 3),
    item("b-1", "branch-b", 4),
  ]);

  assert.deepEqual(ordered.map(({ id }) => id), ["a-1", "b-1", "a-2", "a-3", "a-4"]);
  assert.deepEqual(
    findConsecutiveBranchConflicts(ordered).map(({ previousItemId, itemId }) => [
      previousItemId,
      itemId,
    ]),
    [["a-2", "a-3"], ["a-3", "a-4"]],
  );
});

test("unassigned items do not count as one shared branch", () => {
  const ordered = orderDailyQueueByBranch([
    item("a-1", "branch-a", 0),
    item("unassigned-1", null, 1),
    item("unassigned-2", null, 2),
    item("a-2", "branch-a", 3),
  ]);

  assert.deepEqual(
    ordered.map(({ id }) => id),
    ["a-1", "unassigned-1", "unassigned-2", "a-2"],
  );
  assert.deepEqual(findConsecutiveBranchConflicts(ordered), []);
});

test("uses input order as a deterministic tie-breaker", () => {
  const ordered = orderDailyQueueByBranch([
    item("a-1", "branch-a", 0),
    item("b-1", "branch-b", 0),
    item("c-1", "branch-c", 0),
  ]);

  assert.deepEqual(ordered.map(({ id }) => id), ["a-1", "b-1", "c-1"]);
});

test("does not mutate the input array or item objects", () => {
  const input = [
    item("a-1", "branch-a", 0),
    item("a-2", "branch-a", 1),
    item("b-1", "branch-b", 2),
  ];
  const before = structuredClone(input);

  orderDailyQueueByBranch(input);

  assert.deepEqual(input, before);
});

test("rejects duplicate item ids and invalid sort orders", () => {
  assert.throws(
    () => orderDailyQueueByBranch([
      item("same", "branch-a", 0),
      item("same", "branch-b", 1),
    ]),
    /Duplicate daily queue item id/,
  );
  assert.throws(
    () => orderDailyQueueByBranch([item("invalid", "branch-a", -1)]),
    /non-negative safe integer/,
  );
});
