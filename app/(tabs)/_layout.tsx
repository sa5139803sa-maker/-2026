import { useEffect } from "react";
import { ActivityIndicator, StyleSheet, View } from "react-native";
import { router, Tabs } from "expo-router";
import {
  Activity,
  Banknote,
  LayoutDashboard,
  MoreHorizontal,
} from "lucide-react-native";
import { ErrorState } from "@/components/ui";
import { colors } from "@/constants/theme";
import { useAuth } from "@/lib/auth";
import { canAccessFeature } from "@/lib/permissions";

export default function TabLayout() {
  const { session, profile, loading, profileError, refreshProfile } = useAuth();

  useEffect(() => {
    if (!loading && !session) router.replace("/sign-in");
    if (!loading && session && profile && !profile.organization_id) {
      router.replace("/onboarding");
    }
  }, [loading, session, profile]);

  if (loading) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator color={colors.brand.teal} />
      </View>
    );
  }

  if (!session) return null;

  if (!profile) {
    return (
      <View style={styles.profileError}>
        <ErrorState
          title="تعذر تحميل صلاحيات الحساب"
          message={profileError ?? "لا يوجد ملف شخصي مرتبط بحساب الدخول. لا يمكن فتح شاشات المؤسسة قبل التحقق من الدور."}
          retryLabel="إعادة المحاولة"
          onRetry={() => void refreshProfile()}
        />
      </View>
    );
  }

  // Prevent accounts that have not completed organization onboarding from
  // reaching staff tabs, even when navigating to a tab URL directly.
  if (!profile.organization_id) return null;

  // Navigation visibility improves UX; RLS is still the real security boundary.
  const canOperate = canAccessFeature(profile.role, "operations");
  const canCollect = canAccessFeature(profile.role, "collections");

  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: colors.brand.primary,
        tabBarInactiveTintColor: colors.text.secondary,
        tabBarLabelStyle: {
          fontFamily: "IBMPlexSansArabic_600SemiBold",
          fontSize: 11,
        },
        tabBarStyle: {
          height: 72,
          paddingTop: 8,
          paddingBottom: 10,
          borderTopColor: colors.border,
          backgroundColor: colors.background.surface,
        },
        tabBarHideOnKeyboard: true,
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          title: "الرئيسية",
          tabBarIcon: ({ color, size }) => (
            <LayoutDashboard color={color} size={size} />
          ),
        }}
      />
      <Tabs.Screen
        name="operations"
        options={{
          href: canOperate ? undefined : null,
          title: "التشغيل",
          tabBarIcon: ({ color, size }) => (
            <Activity color={color} size={size} />
          ),
        }}
      />
      <Tabs.Screen
        name="collections"
        options={{
          href: canCollect ? undefined : null,
          title: "التحصيل",
          tabBarIcon: ({ color, size }) => (
            <Banknote color={color} size={size} />
          ),
        }}
      />
      <Tabs.Screen name="portal" options={{ href: null }} />
      <Tabs.Screen name="management" options={{ href: null }} />
      <Tabs.Screen
        name="more"
        options={{
          title: "المزيد",
          tabBarIcon: ({ color, size }) => (
            <MoreHorizontal color={color} size={size} />
          ),
        }}
      />
    </Tabs>
  );
}

const styles = StyleSheet.create({
  loading: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.background.main,
  },
  profileError: {
    flex: 1,
    justifyContent: "center",
    backgroundColor: colors.background.main,
  },
});
