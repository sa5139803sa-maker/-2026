import 'react-native-url-polyfill/auto';
import 'expo-sqlite/localStorage/install';
import { AppState, Platform } from 'react-native';
import { createClient } from '@supabase/supabase-js';

const supabaseUrl = process.env.EXPO_PUBLIC_SUPABASE_URL ?? process.env.SUPABASE_URL;
const supabasePublishableKey =
  process.env.EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
  process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY ??
  process.env.SUPABASE_PUBLISHABLE_KEY ??
  process.env.SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabasePublishableKey) {
  throw new Error('Supabase configuration is missing');
}

// Expo installs an SQLite-backed localStorage implementation on native.
// Web uses the browser's native localStorage; static rendering gets a no-op
// adapter so importing the client never touches an undefined browser global.
const fallbackStorage = {
  getItem: (_key: string) => null,
  setItem: (_key: string, _value: string) => undefined,
  removeItem: (_key: string) => undefined,
};
const authStorage = typeof localStorage !== 'undefined' ? localStorage : fallbackStorage;

export const supabase = createClient(supabaseUrl, supabasePublishableKey, {
  auth: {
    storage: authStorage,
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
});

// Native platforms do not have browser visibility events. Pause token refresh
// while the app is backgrounded and resume it when the user returns.
if (Platform.OS !== 'web') {
  const syncAutoRefreshWithAppState = (state: string | null) => {
    if (state === 'active') {
      supabase.auth.startAutoRefresh();
    } else {
      supabase.auth.stopAutoRefresh();
    }
  };

  syncAutoRefreshWithAppState(AppState.currentState);
  AppState.addEventListener('change', syncAutoRefreshWithAppState);
}
