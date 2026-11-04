import { Session } from '@supabase/supabase-js';
import { createContext, ReactNode, useContext, useEffect, useMemo, useState } from 'react';
import { supabase } from '@/lib/supabase';

export type AppRole = 'manager' | 'operator' | 'collector' | 'supervisor';
export type Profile = { id: string; organization_id: string | null; display_name: string; role: AppRole };

type AuthContextValue = {
  session: Session | null;
  profile: Profile | null;
  loading: boolean;
  profileError: string | null;
  signIn: (email: string, password: string) => Promise<string | null>;
  signUp: (displayName: string, organizationName: string, email: string, password: string) => Promise<string | null>;
  signOut: () => Promise<void>;
  refreshProfile: () => Promise<void>;
};

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

async function loadProfile(userId: string): Promise<Profile | null> {
  const { data, error } = await supabase.from('profiles').select('id, organization_id, display_name, role').eq('id', userId).maybeSingle();
  if (error) throw error;
  return data as Profile | null;
}

function friendlyAuthError(): string {
  return 'تعذر إكمال العملية. تحقق من البيانات واتصال الإنترنت ثم حاول مرة أخرى.';
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  const [profileError, setProfileError] = useState<string | null>(null);

  const refreshProfile = async () => {
    if (!session?.user.id) {
      setProfile(null);
      return;
    }
    try {
      setProfileError(null);
      setProfile(await loadProfile(session.user.id));
    } catch (error) {
      console.error('profile load failed', error);
      setProfileError('تعذر تحميل بيانات الحساب. حاول تحديث الصفحة.');
    }
  };

  useEffect(() => {
    let mounted = true;
    supabase.auth.getSession().then(async ({ data }) => {
      if (!mounted) return;
      setSession(data.session);
      if (data.session) {
        try {
          setProfile(await loadProfile(data.session.user.id));
        } catch (error) {
          console.error('initial profile load failed', error);
          setProfileError('تعذر تحميل بيانات الحساب. حاول تحديث الصفحة.');
        }
      }
      setLoading(false);
    });

    const { data: subscription } = supabase.auth.onAuthStateChange((_, nextSession) => {
      setSession(nextSession);
      if (!nextSession) {
        setProfile(null);
        setLoading(false);
        return;
      }
      void (async () => {
        try {
          setProfile(await loadProfile(nextSession.user.id));
        } catch (error) {
          console.error('auth profile load failed', error);
          setProfileError('تعذر تحميل بيانات الحساب. حاول تحديث الصفحة.');
        } finally {
          setLoading(false);
        }
      })();
    });

    return () => {
      mounted = false;
      subscription.subscription.unsubscribe();
    };
  }, []);

  const value = useMemo<AuthContextValue>(() => ({
    session,
    profile,
    loading,
    profileError,
    refreshProfile,
    signIn: async (email, password) => {
      const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
      return error ? friendlyAuthError() : null;
    },
    signUp: async (displayName, organizationName, email, password) => {
      const { data, error } = await supabase.auth.signUp({ email: email.trim(), password, options: { data: { display_name: displayName.trim() } } });
      if (error) return friendlyAuthError();
      if (!data.session) return 'تم إنشاء الحساب. تحقق من بريدك الإلكتروني ثم سجّل الدخول.';
      const { error: organizationError } = await supabase.rpc('create_organization', { p_name: organizationName.trim() });
      if (organizationError) {
        console.error('organization creation failed', organizationError);
        await supabase.auth.signOut();
        return 'تم إنشاء الحساب لكن تعذر إنشاء المؤسسة. حاول التسجيل مرة أخرى.';
      }
      return null;
    },
    signOut: async () => {
      const { error } = await supabase.auth.signOut();
      if (error) console.error('sign out failed', error);
    },
  }), [session, profile, loading, profileError]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext);
  if (!context) throw new Error('useAuth must be used within AuthProvider');
  return context;
}
