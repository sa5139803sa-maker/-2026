type PublicSupabaseConfig = {
  url: string;
  publishableKey: string;
};

export function getPublicSupabaseConfig(): PublicSupabaseConfig {
  const rawUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const publishableKey =
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

  if (!rawUrl || !publishableKey) {
    throw new Error("Supabase web configuration is missing.");
  }

  let parsedUrl: URL;
  try {
    parsedUrl = new URL(rawUrl);
  } catch {
    throw new Error("NEXT_PUBLIC_SUPABASE_URL must be a valid URL.");
  }

  const isLocalDevelopment =
    process.env.NODE_ENV !== "production" &&
    (parsedUrl.hostname === "localhost" || parsedUrl.hostname === "127.0.0.1");

  if (parsedUrl.protocol !== "https:" && !isLocalDevelopment) {
    throw new Error("Supabase must use HTTPS outside local development.");
  }

  if (!publishableKey.trim()) {
    throw new Error("Supabase publishable key is empty.");
  }

  return { url: parsedUrl.origin, publishableKey };
}

export function hasPublicSupabaseConfig(): boolean {
  return Boolean(
    process.env.NEXT_PUBLIC_SUPABASE_URL &&
      (process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ||
        process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY),
  );
}