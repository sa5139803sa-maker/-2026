"use client";

import { createBrowserClient } from "@supabase/ssr";
import { getPublicSupabaseConfig } from "./env";

type BrowserSupabaseClient = ReturnType<typeof createBrowserClient>;

let browserClient: BrowserSupabaseClient | undefined;

export function createSupabaseBrowserClient(): BrowserSupabaseClient {
  if (browserClient) return browserClient;

  const { url, publishableKey } = getPublicSupabaseConfig();
  browserClient = createBrowserClient(url, publishableKey, {
    auth: {
      flowType: "pkce",
      autoRefreshToken: true,
      detectSessionInUrl: true,
      persistSession: true,
    },
    cookieOptions: {
      name: "wm-web-auth",
      path: "/",
      sameSite: "lax",
      secure: process.env.NODE_ENV === "production",
    },
  });

  return browserClient;
}