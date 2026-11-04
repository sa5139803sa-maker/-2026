import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import {
  ChevronLeft,
  FileText,
  Settings,
  ShieldCheck,
  UsersRound,
} from "lucide-react-native";
import { BrandMark } from "@/components/BrandMark";
import { StatusBadge } from "@/components/UI";
import { Button, Card, PreviewBanner } from "@/components/ui";
import { colors, spacing, typography } from "@/constants/theme";
import { useAuth, type AppRole } from "@/lib/auth";

const roleLabels: Record<AppRole, string> = {
  manager: "مدير المؤسسة",
  operator: "مشغّل",
  collector: "محصّل",
  supervisor: "مشرف",
};

const items = [
  {
    label: "المشتركون والغواطس",
    detail: "إدارة بيانات المشتركين والغواطس",
    icon: UsersRound,
    enabled: true,
  },
  {
    label: "التقارير",
    detail: "قيد التطوير",
    icon: FileText,
    enabled: false,
  },
  {
    label: "المستخدمون والصلاحيات",
    detail: "قيد التطوير",
    icon: ShieldCheck,
    enabled: false,
  },
  {
    label: "الإعدادات",
    detail: "قيد التطوير",
    icon: Settings,
    enabled: false,
  },
];

export default function MoreScreen() {
  const { profile, signOut } = useAuth();
  const displayName = profile?.display_name?.trim() || "المستخدم";
  const roleLabel = profile ? roleLabels[profile.role] : "دور غير محدد";
  const visibleItems = items.filter((item) => item.label !== "المشتركون والغواطس" || profile?.role === "manager");
  const initial = displayName.charAt(0) || "؟";

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={styles.content}
      showsVerticalScrollIndicator={false}
    >
      <BrandMark />

      <Card style={styles.profileCard}>
        <View style={styles.avatar}>
          <Text style={styles.avatarText}>{initial}</Text>
        </View>
        <View style={styles.profileBody}>
          <Text style={styles.profileName}>{displayName}</Text>
          <Text style={styles.profileMeta}>{roleLabel}</Text>
        </View>
        <StatusBadge label="جلسة دخول" status="info" />
      </Card>

      <PreviewBanner description="الأقسام غير المفعّلة معروضة للتعريف ببنية التطبيق فقط. لا يوجد ادعاء بأن التقارير أو المستخدمين أو إعدادات المزامنة تعمل حاليًا." />

      <Text style={styles.heading}>الإدارة والإعدادات</Text>

      <Card style={styles.menu}>
        {visibleItems.map(({ label, detail, icon: Icon, enabled }, index) => (
          <Pressable
            key={label}
            accessibilityRole="button"
            accessibilityState={{ disabled: !enabled }}
            disabled={!enabled}
            onPress={() => router.push("/management")}
            style={({ pressed }) => [
              styles.menuItem,
              index === items.length - 1 && styles.lastMenuItem,
              !enabled && styles.disabledItem,
              pressed && enabled && styles.pressed,
            ]}
          >
            <View style={styles.menuIcon}>
              <Icon
                size={19}
                color={enabled ? colors.brand.primary : colors.text.secondary}
              />
            </View>
            <View style={styles.menuBody}>
              <Text style={styles.menuLabel}>{label}</Text>
              <Text style={styles.menuDetail}>{detail}</Text>
            </View>
            {enabled ? (
              <ChevronLeft size={18} color={colors.text.secondary} />
            ) : (
              <StatusBadge label="لاحقاً" status="warning" />
            )}
          </Pressable>
        ))}
      </Card>

      <Card style={styles.statusCard}>
        <View style={styles.statusIcon}>
          <ShieldCheck size={20} color={colors.status.warning.text} />
        </View>
        <View style={styles.statusBody}>
          <Text style={styles.statusTitle}>المزامنة غير مفعّلة بعد</Text>
          <Text style={styles.statusMeta}>
            ستظهر حالة الاتصال والمزامنة الفعلية بعد تنفيذ وحدة Offline First.
          </Text>
        </View>
        <StatusBadge label="غير متاحة" status="warning" />
      </Card>

      <Button
        label="تسجيل الخروج"
        variant="danger"
        fullWidth
        onPress={() => void signOut()}
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: "rtl" },
  content: {
    padding: spacing.md,
    paddingTop: spacing.lg,
    gap: spacing.md,
    maxWidth: 760,
    width: "100%",
    alignSelf: "center",
  },
  profileCard: {
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
  },
  avatar: {
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: colors.brand.primary,
    alignItems: "center",
    justifyContent: "center",
  },
  avatarText: {
    color: colors.text.inverse,
    fontSize: typography.fontSize.lg,
    fontFamily: typography.fontFamily.bold,
  },
  profileBody: { flex: 1, alignItems: "flex-end" },
  profileName: {
    color: colors.text.primary,
    fontSize: typography.fontSize.md,
    fontFamily: typography.fontFamily.bold,
  },
  profileMeta: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    marginTop: 3,
  },
  heading: {
    color: colors.text.primary,
    fontSize: typography.fontSize.lg,
    fontFamily: typography.fontFamily.bold,
    textAlign: "right",
  },
  menu: { paddingHorizontal: spacing.md, paddingVertical: 0 },
  menuItem: {
    minHeight: 70,
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
    borderBottomWidth: 1,
    borderBottomColor: colors.background.subtle,
  },
  lastMenuItem: { borderBottomWidth: 0 },
  disabledItem: { opacity: 0.65 },
  pressed: { opacity: 0.75 },
  menuIcon: {
    width: 38,
    height: 38,
    borderRadius: 11,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.background.subtle,
  },
  menuBody: { flex: 1, alignItems: "flex-end" },
  menuLabel: {
    color: colors.text.primary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.bold,
  },
  menuDetail: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    marginTop: 2,
    textAlign: "right",
  },
  statusCard: {
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
  },
  statusIcon: {
    width: 36,
    height: 36,
    borderRadius: 10,
    backgroundColor: colors.status.warning.background,
    alignItems: "center",
    justifyContent: "center",
  },
  statusBody: { flex: 1, alignItems: "flex-end" },
  statusTitle: {
    color: colors.text.primary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.bold,
  },
  statusMeta: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    textAlign: "right",
  },
});
