/**
 * Return the client address asserted by Supabase's managed Cloudflare edge.
 *
 * The public Edge Function URL can be called directly, so caller-controlled
 * forwarding headers must never be treated as the source of the rate-limit IP.
 * Cloudflare overwrites CF-Connecting-IP with the connecting client address.
 */
export function trustedGatewayIp(headers: Headers): string | null {
  const candidate = headers.get("cf-connecting-ip")?.trim();
  if (!candidate || candidate.length > 64 || candidate.includes(",") || /\s/.test(candidate)) {
    return null;
  }
  return candidate;
}
