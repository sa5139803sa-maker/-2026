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
 * A pump may have multiple operators, collectors, and supervisors.
 * The same person cannot be assigned twice to the same pump/role.
 * Tenant membership and role matching remain enforced by database RLS/FKs.
 */
export function getAssignableEmployees(
  role: AssignmentRole,
  pumpId: string,
  employees: readonly AssignmentEmployee[],
  assignments: readonly ExistingPumpAssignment[],
): AssignmentEmployee[] {
  const assignedUserIds = new Set(
    assignments
      .filter(
        (assignment) =>
          assignment.pump_id === pumpId &&
          assignment.assignment_role === role,
      )
      .map((assignment) => assignment.user_id),
  );

  return employees.filter(
    (employee) =>
      employee.role === role && !assignedUserIds.has(employee.id),
  );
}
