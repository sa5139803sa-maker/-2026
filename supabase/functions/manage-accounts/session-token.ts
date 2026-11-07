/** Extract the trusted Auth-issued JWT iat (Unix seconds) from a Bearer header. */
export function getJwtIssuedAtSeconds(authorization: string): number | null {
  if (!authorization.startsWith("Bearer ")) return null;
  const token = authorization.slice(7).trim();
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[1]) return null;

  try {
    const normalized = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    const payload: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (!payload || typeof payload !== "object" || !("iat" in payload)) return null;
    const issuedAt = payload.iat;
    return typeof issuedAt === "number" && Number.isSafeInteger(issuedAt) && issuedAt > 0
      ? issuedAt
      : null;
  } catch {
    return null;
  }
}
