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

export type SignUpResult = {
  error: string | null;
  notice: string | null;
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
  ) => Promise<SignUpResult>;
  completeOnboarding: (organizationName: string) => Promise<string | null>;
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

function friendlyOrganizationError(): string {
  return "تعذر إنشاء المؤسسة الآن. تحقق من الاتصال ثم أعد المحاولة؛ لن تحتاج إلى إنشاء حساب جديد.";
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [loading, setLoading] = useState(true);
  const [profileError, setProfileError] = useState<string | null>(null);
  const observedUserId = useRef<string | null>(null);
  const profileRequestSequence = useRef(0);
  const userId = session?.user.id ?? null;

  // Keep the auth event callback synchronous. Profile I/O belongs in the
  // effect below, after Supabase's auth notification callback has returned.
  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      const nextUserId = nextSession?.user.id ?? null;
      const identityChanged = observedUserId.current !== nextUserId;
      observedUserId.current = nextUserId;
      setSession(nextSession);

      if (identityChanged) profileRequestSequence.current += 1;

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

    return () => data.subscription.unsubscribe();
  }, []);

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

  const createOrganizationForUser = useCallback(
    async (targetUserId: string, organizationName: string): Promise<string | null> => {
      const normalizedName = organizationName.trim();
      if (normalizedName.length < 2 || normalizedName.length > 120) {
        return "يجب أن يتراوح اسم المؤسسة بين حرفين و120 حرفًا.";
      }

      // Do not complete setup for a previous account if the session changed.
      const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
      if (sessionError || sessionData.session?.user.id !== targetUserId) {
        return "انتهت جلسة الدخول. سجّل الدخول مجددًا لإكمال إعداد المؤسسة.";
      }

      const { error: organizationError } = await supabase.rpc(
        "create_organization",
        { p_name: normalizedName },
      );

      // The RPC may have committed even if the client lost its response.
      // Read the server-owned profile before deciding that a retry is needed.
      const requestId = ++profileRequestSequence.current;
      try {
        const latestProfile = await loadProfile(targetUserId);
        if (
          requestId === profileRequestSequence.current &&
          observedUserId.current === targetUserId
        ) {
          setProfile(latestProfile);
          setProfileError(null);
        }
        if (latestProfile?.organization_id) return null;
      } catch (profileLoadError) {
        console.error("profile reload after organization setup failed", profileLoadError);
        if (
          requestId === profileRequestSequence.current &&
          observedUserId.current === targetUserId
        ) {
          setProfileError("تعذر التحقق من إعداد المؤسسة. أعد تحميل بيانات الحساب.");
        }
      }

      if (organizationError) {
        console.error("organization creation failed", organizationError);
        return friendlyOrganizationError();
      }

      return "تمت العملية لكن لم يظهر ارتباط المؤسسة في الحساب بعد. حدّث بيانات الحساب ثم حاول مرة أخرى.";
    },
    [],
  );

  const completeOnboarding = useCallback(
    async (organizationName: string) => {
      if (!userId) return "يجب تسجيل الدخول قبل إنشاء المؤسسة.";
      return createOrganizationForUser(userId, organizationName);
    },
    [userId, createOrganizationForUser],
  );

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
      completeOnboarding,
      signIn: async (email, password) => {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        });
        return error ? friendlyAuthError() : null;
      },
      signUp: async (displayName, organizationName, email, password) => {
        const normalizedDisplayName = displayName.trim();
        const normalizedOrganizationName = organizationName.trim();
        const { data, error } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: {
            // This is only a form hint after email confirmation, never an
            // authorization source. The server RPC creates the organization.
            data: {
              display_name: normalizedDisplayName,
              organization_name: normalizedOrganizationName,
            },
          },
        });

        if (error) return { error: friendlyAuthError(), notice: null };

        if (!data.session) {
          return {
            error: null,
            notice:
              "تم إنشاء الحساب. افتح رسالة التأكيد المرسلة إلى بريدك الإلكتروني، ثم عُد إلى التطبيق وسجّل الدخول لإكمال إعداد المؤسسة. احتفظنا باسم المؤسسة لتعبئته لك.",
          };
        }

        const organizationError = await createOrganizationForUser(
          data.session.user.id,
          normalizedOrganizationName,
        );

        if (organizationError) {
          await supabase.auth.signOut();
          return { error: organizationError, notice: null };
        }

        return { error: null, notice: null };
      },
      signOut: async () => {
        const { error } = await supabase.auth.signOut();
        if (error) console.error("sign out failed", error);
      },
    }),
    [
      session,
      profile,
      loading,
      profileError,
      refreshProfile,
      completeOnboarding,
      createOrganizationForUser,
    ],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const context = useContext(AuthContext);
  if (!context) throw new Error("useAuth must be used within AuthProvider");
  return context;
}
