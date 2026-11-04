import type { Session } from "@supabase/supabase-js";
import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { supabase } from "@/lib/supabase";

export type AppRole = "manager" | "operator" | "collector" | "supervisor";
export type Profile = {
  id: string;
  organization_id: string | null;
  display_name: string;
  role: AppRole;
};

type AuthContextValue = {
  session: Session | null;
  profile: Profile | null;
  loading: boolean;
  profileError: string | null;
  signIn: (email: string, password: string) => Promise<string | null>;
  signUp: (
    displayName: string,
    organizationName: string,
    email: string,
    password: string,
  ) => Promise<string | null>;
  signOut: () => Promise<void>;
  refreshProfile: () => Promise<void>;
};

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

async function loadProfile(userId: string): Promise<Profile | null> {
  const { data, error } = await supabase
    .from("profiles")
    .select("id, organization_id, display_name, role")
    .eq("id", userId)
    .maybeSingle();

  if (error) throw error;
  return data as Profile | null;
}

function friendlyAuthError(): string {
  return "تعذر إكمال العملية. تحقق من البيانات واتصال الإنترنت ثم حاول مرة أخرى.";
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  const [profileError, setProfileError] = useState<string | null>(null);
  const observedUserId = useRef<string | null>(null);

  const userId = session?.user.id ?? null;

  // Keep the auth event callback synchronous. Supabase Auth can hold an
  // internal lock while notifying subscribers; profile queries belong in
  // the effect below, after the callback has returned.
  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      const nextUserId = nextSession?.user.id ?? null;
      const identityChanged = observedUserId.current !== nextUserId;

      observedUserId.current = nextUserId;
      setSession(nextSession);

      if (!nextUserId) {
        setProfile(null);
        setProfileError(null);
        setLoading(false);
        return;
      }

      if (identityChanged) {
        setProfile(null);
        setProfileError(null);
        setLoading(true);
      }
    });

    return () => {
      data.subscription.unsubscribe();
    };
  }, []);

  // Profile I/O is deliberately separated from onAuthStateChange.
  useEffect(() => {
    if (!userId) {
      setProfile(null);
      setProfileError(null);
      setLoading(false);
      return;
    }

    let active = true;
    setLoading(true);
    setProfileError(null);

    void loadProfile(userId)
      .then((nextProfile) => {
        if (active) setProfile(nextProfile);
      })
      .catch((error: unknown) => {
        console.error("profile load failed", error);
        if (active) {
          setProfile(null);
          setProfileError("تعذر تحميل بيانات الحساب. حاول تحديث الصفحة.");
        }
      })
      .finally(() => {
        if (active) setLoading(false);
      });

    return () => {
      active = false;
    };
  }, [userId]);

  const refreshProfile = useCallback(async () => {
    if (!userId) {
      setProfile(null);
      setProfileError(null);
      return;
    }

    try {
      setProfileError(null);
      setProfile(await loadProfile(userId));
    } catch (error) {
      console.error("profile refresh failed", error);
      setProfileError("تعذر تحديث بيانات الحساب. حاول مرة أخرى.");
    }
  }, [userId]);

  const value = useMemo<AuthContextValue>(
    () => ({
      session,
      profile,
      loading,
      profileError,
      refreshProfile,
      signIn: async (email, password) => {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        });
        return error ? friendlyAuthError() : null;
      },
      signUp: async (displayName, organizationName, email, password) => {
        const { data, error } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: { data: { display_name: displayName.trim() } },
        });

        if (error) return friendlyAuthError();
        if (!data.session) {
          return "تم إنشاء الحساب. تحقق من بريدك الإلكتروني ثم سجّل الدخول.";
        }

        const { error: organizationError } = await supabase.rpc(
          "create_organization",
          { p_name: organizationName.trim() },
        );

        if (organizationError) {
          console.error("organization creation failed", organizationError);
          await supabase.auth.signOut();
          return "تم إنشاء الحساب لكن تعذر إنشاء المؤسسة. حاول التسجيل مرة أخرى.";
        }

        // The auth event may have loaded the profile before the organization
        // RPC completed. Refresh it now so organization_id is not left stale.
        try {
          const createdProfile = await loadProfile(data.session.user.id);
          setProfile(createdProfile);
          setProfileError(null);
        } catch (profileLoadError) {
          console.error("profile reload after organization creation failed", profileLoadError);
          setProfileError("تم إنشاء المؤسسة، لكن تعذر تحديث الملف الشخصي. سجّل الدخول مجددًا.");
        }

        return null;
      },
      signOut: async () => {
        const { error } = await supabase.auth.signOut();
        if (error) console.error("sign out failed", error);
      },
    }),
    [session, profile, loading, profileError, refreshProfile],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext);
  if (!context) throw new Error("useAuth must be used within AuthProvider");
  return context;
}
