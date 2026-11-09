import assert from "node:assert/strict";
import test from "node:test";
import { allocateWholeMinutesByLargestRemainder } from "../../lib/power-usage-rules.ts";

test("preserves the sum of whole minutes when source segments contain seconds", () => {
  const result = allocateWholeMinutesByLargestRemainder([
    { sourceId: "solar-1", totalSeconds: 1830 },
    { sourceId: "generator", totalSeconds: 1830 },
  ]);

  assert.deepEqual(result, { generator: "31", "solar-1": "30" });
  assert.equal(Object.values(result).reduce((sum, minutes) => sum + Number(minutes || 0), 0), 61);
});

test("aggregates duplicate rows for the same source before allocating minutes", () => {
  const result = allocateWholeMinutesByLargestRemainder([
    { sourceId: "solar", totalSeconds: 40 },
    { sourceId: "solar", totalSeconds: 40 },
    { sourceId: "generator", totalSeconds: 40 },
  ]);

  assert.deepEqual(result, { generator: "1", solar: "1" });
});

test("uses the largest fractional remainder first", () => {
  const result = allocateWholeMinutesByLargestRemainder([
    { sourceId: "a", totalSeconds: 95 },
    { sourceId: "b", totalSeconds: 80 },
    { sourceId: "c", totalSeconds: 65 },
  ]);

  assert.deepEqual(result, { a: "2", b: "1", c: "1" });
});

test("uses a stable source ID tie-break when fractional remainders are equal", () => {
  const result = allocateWholeMinutesByLargestRemainder([
    { sourceId: "source-b", totalSeconds: 30 },
    { sourceId: "source-a", totalSeconds: 30 },
  ]);

  assert.deepEqual(result, { "source-a": "1", "source-b": "" });
});

test("returns an empty result for no source usage", () => {
  assert.deepEqual(allocateWholeMinutesByLargestRemainder([]), {});
});

test("rejects negative, fractional, or unsafe seconds", () => {
  assert.throws(
    () => allocateWholeMinutesByLargestRemainder([{ sourceId: "solar", totalSeconds: -1 }]),
    /non-negative safe integer/,
  );
  assert.throws(
    () => allocateWholeMinutesByLargestRemainder([{ sourceId: "solar", totalSeconds: 1.5 }]),
    /non-negative safe integer/,
  );
  assert.throws(
    () => allocateWholeMinutesByLargestRemainder([{ sourceId: "solar", totalSeconds: Number.MAX_SAFE_INTEGER + 1 }]),
    /non-negative safe integer/,
  );
});
