import { useEffect, useState } from "react";
import {
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { ArrowLeft, Building2, LockKeyhole, Mail, UserRound } from "lucide-react-native";
import { router } from "expo-router";
import { BrandMark } from "@/components/BrandMark";
import { PrimaryButton } from "@/components/UI";
import { ErrorState, LoadingState, TextField } from "@/components/ui";
import { colors, radius, spacing } from "@/constants/theme";
import { useAuth } from "@/lib/auth";
import { getAuthenticatedDestination } from "@/lib/auth-routing";

export default function SignInScreen() {
  const {
    session,
    profile,
    loading,
    profileError,
    refreshProfile,
    signIn,
    signUp,
  } = useAuth();
  const [mode, setMode] = useState<"signIn" | "signUp">("signIn");
  const [displayName, setDisplayName] = useState("");
  const [organizationName, setOrganizationName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!loading && session && profile) {
      router.replace(getAuthenticatedDestination(profile.organization_id));
    }
  }, [loading, session, profile]);

  if (session) {
    if (loading) {
      return <View style={styles.sessionState}><LoadingState message="جاري تحميل بيانات الحساب..." /></View>;
    }
    if (!profile) {
      return (
        <View style={styles.sessionState}>
          <ErrorState
            title="تعذر التحقق من الحساب"
            message={profileError ?? "لم يتم العثور على ملف الحساب. أعد المحاولة قبل المتابعة."}
            retryLabel="إعادة تحميل الحساب"
            onRetry={() => void refreshProfile()}
          />
        </View>
      );
    }
    return null;
  }

  const submit = async () => {
    const validEmail = email.trim().length > 3 && email.includes("@");
    const validPassword = password.length >= 6;
    const validSignUpDetails =
      displayName.trim().length >= 2 &&
      organizationName.trim().length >= 2 &&
      organizationName.trim().length <= 120;

    if (!validEmail || !validPassword || (mode === "signUp" && !validSignUpDetails)) {
      setError(
        mode === "signUp"
          ? "أدخل الاسم واسم المؤسسة والبريد الإلكتروني، واستخدم كلمة مرور من 6 أحرف على الأقل."
          : "أدخل بريدًا إلكترونيًا صحيحًا وكلمة مرور من 6 أحرف على الأقل.",
      );
      setNotice(null);
      return;
    }

    setSubmitting(true);
    setError(null);
    setNotice(null);

    try {
      if (mode === "signIn") {
        const signInError = await signIn(email, password);
        if (signInError) setError(signInError);
      } else {
        const result = await signUp(displayName, organizationName, email, password);
        setError(result.error);
        setNotice(result.notice);
      }
    } catch (submitError) {
      console.error("authentication form submission failed", submitError);
      setError("تعذر الاتصال بخدمة الحسابات. تحقق من الإنترنت ثم حاول مرة أخرى.");
    } finally {
      setSubmitting(false);
    }
  };

  const switchMode = () => {
    setMode(mode === "signIn" ? "signUp" : "signIn");
    setError(null);
    setNotice(null);
  };

  return (
    <KeyboardAvoidingView
      style={styles.screen}
      behavior={Platform.OS === "ios" ? "padding" : undefined}
    >
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        <View style={styles.brand}><BrandMark /></View>
        <View style={styles.hero}>
          <Text style={styles.eyebrow}>منصة إدارة المياه</Text>
          <Text style={styles.title}>
            {mode === "signIn" ? "مرحباً بعودتك" : "أنشئ مؤسستك الآن"}
          </Text>
          <Text style={styles.subtitle}>
            {mode === "signIn"
              ? "سجّل الدخول لمتابعة التشغيل والتحصيل والمشتركين."
              : "أنشئ حسابك، أكّد بريدك الإلكتروني، ثم أكمل إعداد المؤسسة."}
          </Text>
        </View>

        <View style={styles.form}>
          {mode === "signUp" ? (
            <>
              <Field
                icon={<UserRound size={18} color={colors.text.secondary} />}
                placeholder="الاسم الكامل"
                value={displayName}
                onChangeText={setDisplayName}
              />
              <Field
                icon={<Building2 size={18} color={colors.text.secondary} />}
                placeholder="اسم المؤسسة"
                value={organizationName}
                onChangeText={setOrganizationName}
              />
            </>
          ) : null}
          <Field
            icon={<Mail size={18} color={colors.text.secondary} />}
            placeholder="البريد الإلكتروني"
            value={email}
            onChangeText={setEmail}
            keyboardType="email-address"
            autoCapitalize="none"
          />
          <Field
            icon={<LockKeyhole size={18} color={colors.text.secondary} />}
            placeholder="كلمة المرور"
            value={password}
            onChangeText={setPassword}
            secureTextEntry
          />
          <View style={styles.notice}>
            <Text style={styles.noticeText}>بياناتك محمية بصلاحيات منفصلة لكل مؤسسة.</Text>
          </View>
          {error ? <Text accessibilityRole="alert" style={styles.error}>{error}</Text> : null}
          {notice ? <Text accessibilityRole="alert" style={styles.success}>{notice}</Text> : null}
          <PrimaryButton
            label={
              submitting
                ? "جاري المعالجة..."
                : mode === "signIn"
                  ? "تسجيل الدخول"
                  : "إنشاء الحساب"
            }
            icon={<ArrowLeft size={18} color={colors.text.inverse} />}
            onPress={submitting ? undefined : submit}
          />
        </View>

        <Pressable onPress={switchMode} style={styles.switch}>
          <Text style={styles.switchText}>
            {mode === "signIn"
              ? "ليس لديك حساب؟ إنشاء مؤسسة جديدة"
              : "لديك حساب؟ تسجيل الدخول"}
          </Text>
        </Pressable>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

function Field({
  icon,
  placeholder,
  value,
  onChangeText,
  secureTextEntry = false,
  keyboardType = "default",
  autoCapitalize = "sentences",
}: {
  icon: React.ReactNode;
  placeholder: string;
  value: string;
  onChangeText: (value: string) => void;
  secureTextEntry?: boolean;
  keyboardType?: "default" | "email-address";
  autoCapitalize?: "none" | "sentences";
}) {
  return (
    <TextField
      leading={icon}
      placeholder={placeholder}
      value={value}
      onChangeText={onChangeText}
      secureTextEntry={secureTextEntry}
      keyboardType={keyboardType}
      autoCapitalize={autoCapitalize}
    />
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: "rtl" },
  sessionState: {
    flex: 1,
    justifyContent: "center",
    backgroundColor: colors.background.main,
  },
  content: {
    flexGrow: 1,
    justifyContent: "center",
    padding: spacing.lg,
    maxWidth: 560,
    width: "100%",
    alignSelf: "center",
  },
  brand: { alignItems: "flex-end", marginBottom: spacing.xxl },
  hero: { alignItems: "flex-end", marginBottom: spacing.lg },
  eyebrow: {
    color: colors.brand.teal,
    fontSize: 13,
    fontFamily: "IBMPlexSansArabic_600SemiBold",
  },
  title: {
    color: colors.text.primary,
    fontSize: 29,
    fontFamily: "IBMPlexSansArabic_700Bold",
    marginTop: spacing.sm,
  },
  subtitle: {
    color: colors.text.secondary,
    fontSize: 13,
    lineHeight: 23,
    fontFamily: "IBMPlexSansArabic_400Regular",
    textAlign: "right",
    marginTop: spacing.sm,
  },
  form: {
    backgroundColor: colors.background.surface,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
    gap: spacing.sm,
  },
  notice: {
    backgroundColor: colors.background.subtle,
    borderRadius: radius.sm,
    padding: spacing.sm,
    marginVertical: spacing.xs,
  },
  noticeText: {
    color: colors.text.secondary,
    fontSize: 11,
    fontFamily: "IBMPlexSansArabic_400Regular",
    textAlign: "right",
  },
  error: {
    color: colors.status.danger.text,
    backgroundColor: colors.status.danger.background,
    borderRadius: radius.sm,
    padding: spacing.sm,
    fontSize: 12,
    lineHeight: 19,
    fontFamily: "IBMPlexSansArabic_500Medium",
    textAlign: "right",
  },
  success: {
    color: colors.status.info.text,
    backgroundColor: colors.status.info.background,
    borderRadius: radius.sm,
    padding: spacing.sm,
    fontSize: 12,
    lineHeight: 22,
    fontFamily: "IBMPlexSansArabic_500Medium",
    textAlign: "right",
  },
  switch: { alignItems: "center", padding: spacing.lg },
  switchText: {
    color: colors.brand.primary,
    fontSize: 13,
    fontFamily: "IBMPlexSansArabic_600SemiBold",
  },
});
