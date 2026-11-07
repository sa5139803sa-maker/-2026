/**
 * Mirrors the account-provisioning mapping used by the Expo application and
 * Supabase manage-accounts function. The synthetic domain is never emailed.
 */
export function usernameToAuthEmail(identifier: string): string {
  const value = identifier.trim();
  if (value.includes("@")) return value;

  const normalized = value.normalize("NFKC").toLocaleLowerCase("en-US");
  const bytes = new TextEncoder().encode(normalized);
  const encoded = Array.from(bytes, (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");

  return `u-${encoded}@login.water-management.invalid`;
}

export function validateLoginIdentifier(identifier: string): boolean {
  const value = identifier.trim();
  if (!value) return false;
  if (value.includes("@")) return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
  const normalized = value.normalize("NFKC").toLocaleLowerCase("en-US");
  return (
    normalized.length >= 3 &&
    normalized.length <= 40 &&
    /^[\p{L}\p{N}._-]+$/u.test(normalized)
  );
}