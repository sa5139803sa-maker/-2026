import { useEffect, useState } from "react";
import { router } from "expo-router";
import { Building2, LogOut } from "lucide-react-native";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { BrandMark } from "@/components/BrandMark";
import { Button, Card, ErrorState, LoadingState, TextField } from "@/components/ui";
import { colors, radius, spacing, typography } from "@/constants/theme";
import { useAuth } from "@/lib/auth";

export default function OnboardingScreen() {
  const {
    session,
    profile,
    loading,
    profileError,
    refreshProfile,
    completeOnboarding,
    signOut,
  } = useAuth();
  const [organizationName, setOrganizationName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const suggestedName =
    typeof session?.user.user_metadata?.organization_name === "string"
      ? session.user.user_metadata.organization_name
      : "";

  useEffect(() => {
    // Reset the suggestion when a different account enters this route so
    // another user's draft organization name is never reused.
    setOrganizationName(suggestedName);
    setError(null);
  }, [session?.user.id, suggestedName]);

  useEffect(() => {
    if (!loading && !session) router.replace("/sign-in");
    if (!loading && profile?.organization_id) router.replace("/(tabs)");
  }, [loading, session, profile]);

  if (loading) {
    return <View style={styles.state}><LoadingState message="جاري التحقق من حسابك..." /></View>;
  }

  if (!session) return null;

  if (!profile) {
    return (
      <View style={styles.state}>
        <ErrorState
          title="تعذر تحميل ملف الحساب"
          message={profileError ?? "لا يمكن إكمال إعداد المؤسسة قبل تحميل ملف الحساب."}
          retryLabel="إعادة المحاولة"
          onRetry={() => void refreshProfile()}
        />
        <Button label="تسجيل الخروج" variant="ghost" onPress={() => void signOut()} />
      </View>
    );
  }

  if (profile.organization_id) return null;

  const submit = async () => {
    const name = organizationName.trim();
    if (name.length < 2 || name.length > 120) {
      setError("يجب أن يتراوح اسم المؤسسة بين حرفين و120 حرفًا.");
      return;
    }

    setSubmitting(true);
    setError(null);
    try {
      const result = await completeOnboarding(name);
      if (result) setError(result);
      else router.replace("/(tabs)");
    } catch (submitError) {
      console.error("organization onboarding failed", submitError);
      setError("تعذر إكمال إعداد المؤسسة. تحقق من الاتصال ثم حاول مرة أخرى.");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={styles.content}
      keyboardShouldPersistTaps="handled"
    >
      <BrandMark />
      <View style={styles.heading}>
        <View style={styles.icon}>
          <Building2 size={24} color={colors.brand.primary} />
        </View>
        <Text style={styles.title}>أكمل إعداد مؤسستك</Text>
        <Text style={styles.description}>
          تم تأكيد حسابك. أدخل اسم المؤسسة لإنشاء مساحة العمل وربط حسابك بها كمدير.
        </Text>
      </View>

      <Card style={styles.card}>
        <Text style={styles.greeting}>مرحبًا {profile.display_name || "بك"}</Text>
        <TextField
          label="اسم المؤسسة"
          value={organizationName}
          onChangeText={(value) => {
            setOrganizationName(value);
            setError(null);
          }}
          placeholder="مثال: إدارة مياه الحي"
          helperText="يمكنك تعديل الاسم لاحقًا من إعدادات المؤسسة."
          error={error ?? undefined}
          autoCapitalize="sentences"
          returnKeyType="done"
          onSubmitEditing={() => void submit()}
        />
        <Button
          label="إنشاء المؤسسة والمتابعة"
          fullWidth
          loading={submitting}
          disabled={submitting}
          onPress={() => void submit()}
        />
      </Card>

      <Button
        label="تسجيل الخروج"
        variant="ghost"
        icon={<LogOut size={17} color={colors.brand.primary} />}
        onPress={() => void signOut()}
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main },
  state: {
    flex: 1,
    justifyContent: "center",
    backgroundColor: colors.background.main,
  },
  content: {
    flexGrow: 1,
    justifyContent: "center",
    padding: spacing.lg,
    gap: spacing.lg,
    maxWidth: 580,
    width: "100%",
    alignSelf: "center",
  },
  heading: { alignItems: "center", gap: spacing.sm },
  icon: {
    width: 52,
    height: 52,
    borderRadius: radius.lg,
    backgroundColor: colors.background.subtle,
    alignItems: "center",
    justifyContent: "center",
  },
  title: {
    color: colors.text.primary,
    fontSize: typography.fontSize.xl,
    fontFamily: typography.fontFamily.bold,
    textAlign: "center",
  },
  description: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.regular,
    lineHeight: 23,
    textAlign: "center",
  },
  card: { gap: spacing.md },
  greeting: {
    color: colors.text.primary,
    fontSize: typography.fontSize.md,
    fontFamily: typography.fontFamily.semiBold,
    textAlign: "right",
  },
});
