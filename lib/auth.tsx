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

export type AppRole = "platform_admin" | "manager" | "operator" | "collector" | "supervisor";
export type Profile = {
  id: string;
  organization_id: string | null;
  display_name: string;
  role: AppRole;
  username: string | null;
  must_change_password: boolean;
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
    .select("id, organization_id, display_name, role, username, must_change_password")
    .eq("id", userId)
    .maybeSingle();

  if (error) throw error;
  return data as Profile | null;
}

export function usernameToAuthEmail(identifier: string): string {
  const value=identifier.trim(); if(value.includes("@")) return value;
  const normalized=value.normalize("NFKC").toLocaleLowerCase();
  const bytes=new TextEncoder().encode(normalized);
  const encoded=Array.from(bytes,b=>b.toString(16).padStart(2,"0")).join("");
  return `u-${encoded}@login.water-management.invalid`;
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
  const profileRequestSequence = useRef(0);

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

      if (identityChanged) {
        // Invalidate any in-flight profile response from the previous identity.
        profileRequestSequence.current += 1;
      }

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
      profileRequestSequence.current += 1;
      setProfile(null);
      setProfileError(null);
      setLoading(false);
      return;
    }

    let active = true;
    const requestId = ++profileRequestSequence.current;
    setLoading(true);
    setProfileError(null);

    void loadProfile(userId)
      .then((nextProfile) => {
        if (active && requestId === profileRequestSequence.current) {
          setProfile(nextProfile);
        }
      })
      .catch((error: unknown) => {
        console.error("profile load failed", error);
        if (active && requestId === profileRequestSequence.current) {
          setProfile(null);
          setProfileError("تعذر تحميل بيانات الحساب. حاول تحديث الصفحة.");
        }
      })
      .finally(() => {
        if (active && requestId === profileRequestSequence.current) {
          setLoading(false);
        }
      });

    return () => {
      active = false;
    };
  }, [userId]);

  const refreshProfile = useCallback(async () => {
    if (!userId) {
      profileRequestSequence.current += 1;
      setProfile(null);
      setProfileError(null);
      return;
    }

    const requestId = ++profileRequestSequence.current;
    try {
      setProfileError(null);
      const refreshedProfile = await loadProfile(userId);
      if (requestId === profileRequestSequence.current) {
        setProfile(refreshedProfile);
      }
    } catch (error) {
      console.error("profile refresh failed", error);
      if (requestId === profileRequestSequence.current) {
        setProfileError("تعذر تحديث بيانات الحساب. حاول مرة أخرى.");
      }
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
          email: usernameToAuthEmail(email),
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
        const signedUpUserId = data.session.user.id;
        const requestId = ++profileRequestSequence.current;
        try {
          const createdProfile = await loadProfile(signedUpUserId);
          if (
            requestId === profileRequestSequence.current &&
            observedUserId.current === signedUpUserId
          ) {
            setProfile(createdProfile);
            setProfileError(null);
          }
        } catch (profileLoadError) {
          console.error("profile reload after organization creation failed", profileLoadError);
          if (
            requestId === profileRequestSequence.current &&
            observedUserId.current === signedUpUserId
          ) {
            setProfileError("تم إنشاء المؤسسة، لكن تعذر تحديث الملف الشخصي. سجّل الدخول مجددًا.");
          }
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
