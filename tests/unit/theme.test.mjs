import assert from "node:assert/strict";
import test from "node:test";
import { colors } from "../../constants/theme/colors.ts";
import { spacing } from "../../constants/theme/spacing.ts";

test("brand and surface colors match the approved visual identity", () => {
  assert.equal(colors.brand.primary, "#145B7A");
  assert.equal(colors.brand.navy, "#0B3449");
  assert.equal(colors.brand.teal, "#1B9AAA");
  assert.equal(colors.brand.aqua, "#53C6C8");
  assert.equal(colors.background.main, "#F5F8FA");
  assert.equal(colors.background.surface, "#FFFFFF");
  assert.equal(colors.background.subtle, "#EAF1F5");
  assert.equal(colors.border, "#DCE5EB");
});

test("all spacing tokens follow the 4-pixel grid", () => {
  for (const [token, value] of Object.entries(spacing)) {
    assert.equal(value % 4, 0, `${token} must be a multiple of 4`);
  }
});
