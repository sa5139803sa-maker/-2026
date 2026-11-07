declare global {
  namespace NodeJS {
    interface ProcessEnv {
      SUPABASE_URL?: string;
      SUPABASE_PUBLISHABLE_KEY?: string;
      SUPABASE_ANON_KEY?: string;
      EXPO_PUBLIC_SUPABASE_URL?: string;
      EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY?: string;
      EXPO_PUBLIC_SUPABASE_ANON_KEY?: string;
    }
  }
}

export {};
