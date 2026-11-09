export type AssignmentRole = "operator" | "collector" | "supervisor";

export type AssignmentEmployee = {
  id: string;
  display_name: string;
  role: AssignmentRole;
};

export type ExistingPumpAssignment = {
  pump_id: string;
  user_id: string;
  assignment_role: AssignmentRole;
};

/**
 * Enforces the assignment-slot rules already represented by the database:
 * one operator and one collector per pump, with multiple supervisors allowed.
 * Tenant membership and role/profile matching remain enforced by RLS and FKs.
 */
export function getAssignableEmployees(
  role: AssignmentRole,
  pumpId: string,
  employees: readonly AssignmentEmployee[],
  assignments: readonly ExistingPumpAssignment[],
): AssignmentEmployee[] {
  const slotOccupied = role !== "supervisor" && assignments.some(
    (assignment) =>
      assignment.pump_id === pumpId &&
      assignment.assignment_role === role,
  );

  if (slotOccupied) return [];

  const assignedUserIds = new Set(
    assignments
      .filter(
        (assignment) =>
          assignment.pump_id === pumpId &&
          assignment.assignment_role === role,
      )
      .map((assignment) => assignment.user_id),
  );

  // Keep the server-provided alphabetical ordering; never mutate the input.
  return employees.filter(
    (employee) =>
      employee.role === role && !assignedUserIds.has(employee.id),
  );
}
