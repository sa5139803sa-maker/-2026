import assert from "node:assert/strict";
import test from "node:test";
import { getAssignableEmployees } from "../../lib/pump-assignment-rules.ts";

const employees = [
  { id: "operator-1", display_name: "مشغل أول", role: "operator" },
  { id: "operator-2", display_name: "مشغل ثان", role: "operator" },
  { id: "collector-1", display_name: "محصل أول", role: "collector" },
  { id: "supervisor-1", display_name: "مشرف أول", role: "supervisor" },
  { id: "supervisor-2", display_name: "مشرف ثان", role: "supervisor" },
];

const assignments = [
  { pump_id: "pump-1", user_id: "operator-1", assignment_role: "operator" },
  { pump_id: "pump-1", user_id: "supervisor-1", assignment_role: "supervisor" },
];

test("only employees with the selected role are eligible", () => {
  assert.deepEqual(
    getAssignableEmployees("collector", "pump-1", employees, assignments)
      .map((employee) => employee.id),
    ["collector-1"],
  );
});

test("a pump cannot receive a second operator while its operator slot is occupied", () => {
  assert.deepEqual(
    getAssignableEmployees("operator", "pump-1", employees, assignments),
    [],
  );
});

test("a pump cannot receive a second collector while its collector slot is occupied", () => {
  const withCollector = [
    ...assignments,
    { pump_id: "pump-1", user_id: "collector-1", assignment_role: "collector" },
  ];
  assert.deepEqual(
    getAssignableEmployees("collector", "pump-1", employees, withCollector),
    [],
  );
});

test("multiple supervisors can be assigned to the same pump", () => {
  assert.deepEqual(
    getAssignableEmployees("supervisor", "pump-1", employees, assignments)
      .map((employee) => employee.id),
    ["supervisor-2"],
  );
});

test("an assignment on another pump does not occupy this pump's slot", () => {
  assert.deepEqual(
    getAssignableEmployees("operator", "pump-2", employees, assignments)
      .map((employee) => employee.id),
    ["operator-1", "operator-2"],
  );
});

test("the same supervisor cannot be added twice to the same pump", () => {
  const withTwoSupervisors = [
    ...assignments,
    { pump_id: "pump-1", user_id: "supervisor-2", assignment_role: "supervisor" },
  ];
  assert.deepEqual(
    getAssignableEmployees("supervisor", "pump-1", employees, withTwoSupervisors),
    [],
  );
});
