import { ScrollView, StyleSheet, Text, View } from "react-native";
import {
  CalendarDays,
  ChevronLeft,
  CircleDollarSign,
  Droplets,
  FileCheck2,
  MessageCircle,
} from "lucide-react-native";
import { BrandMark } from "@/components/BrandMark";
import { SectionTitle, StatusBadge } from "@/components/UI";
import {
  Button,
  Card,
  MoneyDisplay,
  PreviewBanner,
} from "@/components/ui";
import { colors, radius, spacing, typography } from "@/constants/theme";

const previewFills = [
  { date: "24 مايو", duration: "60 دقيقة" },
  { date: "17 مايو", duration: "60 دقيقة" },
  { date: "10 مايو", duration: "45 دقيقة" },
];

export default function SubscriberPortalScreen() {
  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={styles.content}
      showsVerticalScrollIndicator={false}
    >
      <BrandMark />

      <View style={styles.greeting}>
        <Text style={styles.eyebrow}>بوابة المشترك</Text>
        <Text style={styles.title}>مرحباً بك</Text>
        <Text style={styles.subtitle}>
          معاينة طريقة عرض التعبئات والمستحقات وإشعارات الدفع.
        </Text>
      </View>

      <PreviewBanner description="هذه بوابة تجريبية وليست مرتبطة بحساب مشترك. الأسماء والمبالغ والسجلات أدناه أمثلة شكلية ولا تمثل مستحقات أو دفعات فعلية." />

      <View style={styles.balanceCard}>
        <View style={styles.balanceTop}>
          <View style={styles.waterIcon}>
            <Droplets size={22} color={colors.text.inverse} />
          </View>
          <StatusBadge label="حساب تجريبي" status="warning" />
        </View>
        <Text style={styles.balanceLabel}>مثال للمبلغ المستحق</Text>
        <MoneyDisplay amount={450} currencyLabel="ر.س" emphasis="strong" inverse />
        <Text style={styles.balanceMeta}>قيمة توضيحية — لا يوجد تحديث حساب فعلي</Text>
        <Button
          label="إشعار التحويل غير متاح في النموذج"
          disabled
          fullWidth
          variant="secondary"
        />
      </View>

      <View style={styles.quickRow}>
        <Card style={styles.quickCard}>
          <CalendarDays size={21} color={colors.brand.teal} />
          <Text style={styles.quickValue}>4</Text>
          <Text style={styles.quickLabel}>تعبئات هذا الشهر — مثال</Text>
        </Card>
        <Card style={styles.quickCard}>
          <CircleDollarSign size={21} color={colors.status.success.main} />
          <MoneyDisplay amount={1200} currencyLabel="ر.س" emphasis="strong" />
          <Text style={styles.quickLabel}>إجمالي مدفوع توضيحي</Text>
        </Card>
      </View>

      <Card style={styles.listCard}>
        <View style={styles.sectionHeading}>
          <SectionTitle title="آخر التعبئات" />
          <StatusBadge label="أمثلة فقط" status="warning" />
        </View>
        {previewFills.map((item) => (
          <View style={styles.row} key={item.date}>
            <View style={styles.rowIcon}>
              <Droplets size={17} color={colors.brand.teal} />
            </View>
            <View style={styles.rowBody}>
              <Text style={styles.rowTitle}>{item.date}</Text>
              <Text style={styles.rowMeta}>الغطاس #1 · {item.duration}</Text>
            </View>
            <StatusBadge label="مثال مكتمل" status="info" />
            <ChevronLeft size={17} color={colors.text.secondary} />
          </View>
        ))}
      </Card>

      <Card style={styles.listCard}>
        <SectionTitle title="إشعارات الدفع" />
        <View style={styles.notice}>
          <View style={styles.noticeIcon}>
            <FileCheck2 size={18} color={colors.status.warning.main} />
          </View>
          <View style={styles.rowBody}>
            <Text style={styles.rowTitle}>حالة توضيحية</Text>
            <Text style={styles.rowMeta}>
              ستظهر الإشعارات الحقيقية بعد تنفيذ بوابة المشترك.
            </Text>
          </View>
          <MessageCircle size={18} color={colors.text.secondary} />
        </View>
      </Card>
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
  greeting: { marginTop: spacing.sm, alignItems: "flex-end" },
  eyebrow: {
    color: colors.brand.teal,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.semiBold,
  },
  title: {
    color: colors.text.primary,
    fontSize: typography.fontSize["2xl"],
    fontFamily: typography.fontFamily.bold,
    marginTop: 3,
  },
  subtitle: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    lineHeight: 21,
    fontFamily: typography.fontFamily.regular,
    textAlign: "right",
    marginTop: 4,
  },
  balanceCard: {
    backgroundColor: colors.brand.navy,
    borderRadius: radius.lg,
    padding: spacing.lg,
    gap: spacing.sm,
  },
  balanceTop: {
    flexDirection: "row-reverse",
    justifyContent: "space-between",
    alignItems: "center",
  },
  waterIcon: {
    width: 42,
    height: 42,
    borderRadius: 13,
    backgroundColor: colors.brand.teal,
    alignItems: "center",
    justifyContent: "center",
  },
  balanceLabel: {
    color: "#B7DDE4",
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.medium,
    marginTop: spacing.sm,
  },
  balanceMeta: {
    color: "#C3D4DC",
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    marginBottom: spacing.sm,
  },
  quickRow: { flexDirection: "row", gap: spacing.sm },
  quickCard: { flex: 1, alignItems: "center", gap: 4 },
  quickValue: {
    color: colors.text.primary,
    fontSize: typography.fontSize.xl,
    fontFamily: typography.fontFamily.bold,
    marginTop: 3,
  },
  quickLabel: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    textAlign: "center",
  },
  listCard: { padding: spacing.md },
  sectionHeading: {
    flexDirection: "row-reverse",
    alignItems: "center",
    justifyContent: "space-between",
    gap: spacing.sm,
  },
  row: {
    minHeight: 62,
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
    borderTopWidth: 1,
    borderTopColor: colors.background.subtle,
  },
  rowIcon: {
    width: 36,
    height: 36,
    borderRadius: 10,
    backgroundColor: colors.background.subtle,
    alignItems: "center",
    justifyContent: "center",
  },
  rowBody: { flex: 1, alignItems: "flex-end" },
  rowTitle: {
    color: colors.text.primary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.bold,
  },
  rowMeta: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    marginTop: 2,
    textAlign: "right",
  },
  notice: {
    minHeight: 64,
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
    borderTopWidth: 1,
    borderTopColor: colors.background.subtle,
  },
  noticeIcon: {
    width: 36,
    height: 36,
    borderRadius: 10,
    backgroundColor: colors.status.warning.background,
    alignItems: "center",
    justifyContent: "center",
  },
});
