export type AuthenticatedDestination = "/(tabs)" | "/onboarding";

export function getAuthenticatedDestination(
  organizationId: string | null | undefined,
): AuthenticatedDestination {
  return organizationId ? "/(tabs)" : "/onboarding";
}
