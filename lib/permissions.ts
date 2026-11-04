import type { AppRole } from "./auth";

/**
 * UI navigation policy for the four application roles.
 * This is not a security boundary; matching RLS policies must enforce every
 * data-access rule on the Supabase side.
 */
export const roleAccess = {
  dashboardStats: ["manager"],
  management: ["manager"],
  operations: ["manager", "operator"],
  collections: ["manager", "collector"],
  reports: ["manager", "supervisor"],
  userManagement: ["manager"],
} as const satisfies Record<string, readonly AppRole[]>;

export type ProtectedFeature = keyof typeof roleAccess;

export function canAccessFeature(
  role: AppRole | null | undefined,
  feature: ProtectedFeature,
): boolean {
  if (!role) return false;
  const allowedRoles: readonly AppRole[] = roleAccess[feature];
  return allowedRoles.includes(role);
}
