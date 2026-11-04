import { Redirect } from "expo-router";
import { ActivityIndicator, StyleSheet, View } from "react-native";
import { ErrorState } from "@/components/ui";
import { useAuth } from "@/lib/auth";
import { colors } from "@/constants/theme";
import { getAuthenticatedDestination } from "@/lib/auth-routing";

export default function EntryScreen() {
  const { session, profile, loading, profileError, refreshProfile } = useAuth();

  if (loading) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator color={colors.brand.teal} />
      </View>
    );
  }

  if (!session) return <Redirect href="/sign-in" />;

  if (!profile) {
    return (
      <View style={styles.loading}>
        <ErrorState
          title="تعذر تحميل بيانات الحساب"
          message={profileError ?? "أعد تحميل الحساب للتحقق من صلاحياتك."}
          onRetry={() => void refreshProfile()}
        />
      </View>
    );
  }

  return <Redirect href={getAuthenticatedDestination(profile.organization_id)} />;
}

const styles = StyleSheet.create({
  loading: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.background.main,
  },
});
