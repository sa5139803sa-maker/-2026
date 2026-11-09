import assert from "node:assert/strict";
import test from "node:test";
import { getAssignableEmployees } from "../../lib/pump-assignment-rules.ts";

const employees = [
  { id: "operator-1", display_name: "مشغل أول", role: "operator" },
  { id: "operator-2", display_name: "مشغل ثان", role: "operator" },
  { id: "collector-1", display_name: "محصل أول", role: "collector" },
  { id: "collector-2", display_name: "محصل ثان", role: "collector" },
  { id: "supervisor-1", display_name: "مشرف أول", role: "supervisor" },
  { id: "supervisor-2", display_name: "مشرف ثان", role: "supervisor" },
];

const assignments = [
  { pump_id: "pump-1", user_id: "operator-1", assignment_role: "operator" },
  { pump_id: "pump-1", user_id: "supervisor-1", assignment_role: "supervisor" },
];

test("only employees with the selected role are eligible", () => {
  assert.deepEqual(
    getAssignableEmployees("collector", "pump-1", employees, assignments).map((employee) => employee.id),
    ["collector-1", "collector-2"],
  );
});

test("multiple operators can be assigned to the same pump", () => {
  assert.deepEqual(
    getAssignableEmployees("operator", "pump-1", employees, assignments).map((employee) => employee.id),
    ["operator-2"],
  );
});

test("the same operator cannot be assigned twice to the same pump", () => {
  const withOperator = [...assignments, { pump_id: "pump-1", user_id: "operator-2", assignment_role: "operator" }];
  assert.ok(!getAssignableEmployees("operator", "pump-1", employees, withOperator)
    .some((employee) => employee.id === "operator-2"));
});

test("multiple collectors can be assigned to the same pump", () => {
  const withCollector = [...assignments, { pump_id: "pump-1", user_id: "collector-1", assignment_role: "collector" }];
  assert.deepEqual(
    getAssignableEmployees("collector", "pump-1", employees, withCollector).map((employee) => employee.id),
    ["collector-2"],
  );
});

test("the same collector cannot be assigned twice to the same pump", () => {
  const withCollector = [...assignments, { pump_id: "pump-1", user_id: "collector-1", assignment_role: "collector" }];
  assert.ok(!getAssignableEmployees("collector", "pump-1", employees, withCollector)
    .some((employee) => employee.id === "collector-1"));
});

test("multiple supervisors can be assigned to the same pump", () => {
  assert.deepEqual(
    getAssignableEmployees("supervisor", "pump-1", employees, assignments).map((employee) => employee.id),
    ["supervisor-2"],
  );
});

test("an assignment on another pump does not occupy this pump's slot", () => {
  assert.deepEqual(
    getAssignableEmployees("operator", "pump-2", employees, assignments).map((employee) => employee.id),
    ["operator-1", "operator-2"],
  );
});

test("assignments of the same employee to another pump remain independent", () => {
  const otherPump = [...assignments, { pump_id: "pump-2", user_id: "collector-1", assignment_role: "collector" }];
  assert.ok(getAssignableEmployees("collector", "pump-1", employees, otherPump)
    .some((employee) => employee.id === "collector-1"));
});
