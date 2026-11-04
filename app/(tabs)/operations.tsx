import { ScrollView, StyleSheet, Text, View } from "react-native";
import { ChevronLeft, Pause, Waves } from "lucide-react-native";
import { SectionTitle, StatusBadge } from "@/components/UI";
import { Button, Card, PreviewBanner, TimeDisplay } from "@/components/ui";
import { colors, radius, spacing, typography } from "@/constants/theme";

const previewQueue = [
  { name: "أحمد محمد", note: "قيد التشغيل", active: true },
  { name: "خالد علي", note: "40 دقيقة · التفرع الغربي", active: false },
  { name: "سارة محمود", note: "30 دقيقة · التفرع الشمالي", active: false },
  { name: "محمود يوسف", note: "40 دقيقة · التفرع الغربي", active: false },
];

export default function OperationsScreen() {
  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={styles.content}
      showsVerticalScrollIndicator={false}
    >
      <View style={styles.top}>
        <View style={styles.heading}>
          <Text style={styles.eyebrow}>غرفة التشغيل</Text>
          <Text style={styles.title}>الغطاس #1</Text>
        </View>
        <StatusBadge label="عرض توضيحي" status="warning" />
      </View>

      <PreviewBanner description="الأسماء والمؤقت والطابور المعروض بيانات تجريبية. لا يتم تشغيل المضخة أو حفظ أي حدث من هذه الشاشة." />

      <View style={styles.pumpCard}>
        <View style={styles.pumpIcon}>
          <Waves size={26} color={colors.text.inverse} />
        </View>
        <Text style={styles.pumpLabel}>مثال على التعبئة الحالية</Text>
        <Text style={styles.subscriber}>أحمد محمد</Text>
        <Text style={styles.branch}>التفرع: الشمال · التعبئة رقم 24</Text>

        <View style={styles.timer}>
          <Text style={styles.timerLabel}>الوقت المتبقي — مثال</Text>
          <TimeDisplay totalSeconds={45 * 60} inverse />
          <View style={styles.progressTrack}>
            <View style={styles.progressFill} />
          </View>
          <Text style={styles.progressText}>45 دقيقة متبقية من أصل 60 دقيقة</Text>
        </View>

        <View style={styles.disabledAction}>
          <Pause size={19} color="#D8E7EB" />
          <Text style={styles.disabledActionText}>التحكم بالتعبئة غير متاح في النموذج</Text>
        </View>
      </View>

      <View style={styles.infoRow}>
        <Card style={styles.infoBox}>
          <Text style={styles.infoLabel}>وقت البداية</Text>
          <Text style={styles.infoValue}>10:00 ص</Text>
        </Card>
        <Card style={styles.infoBox}>
          <Text style={styles.infoLabel}>المنفذ</Text>
          <Text style={styles.infoValue}>15 دقيقة</Text>
        </Card>
        <Card style={styles.infoBox}>
          <Text style={styles.infoLabel}>التالي</Text>
          <Text style={styles.infoValue}>خالد علي</Text>
        </Card>
      </View>

      <Card style={styles.queueCard}>
        <View style={styles.sectionHeading}>
          <SectionTitle title="طابور اليوم" />
          <StatusBadge label="بيانات تجريبية" status="warning" />
        </View>
        {previewQueue.map((item, index) => (
          <View key={item.name} style={styles.queueItem}>
            <View style={styles.number}>
              <Text style={styles.numberText}>{index + 1}</Text>
            </View>
            <View style={styles.queueBody}>
              <Text style={styles.queueName}>{item.name}</Text>
              <Text style={styles.queueMeta}>{item.note}</Text>
            </View>
            {item.active ? (
              <StatusBadge label="مثال نشط" status="info" />
            ) : (
              <ChevronLeft size={17} color={colors.text.secondary} />
            )}
          </View>
        ))}
      </Card>

      <Button
        label="التأجيل غير متاح في النموذج"
        variant="secondary"
        disabled
        fullWidth
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: "rtl" },
  content: {
    padding: spacing.md,
    gap: spacing.md,
    maxWidth: 760,
    width: "100%",
    alignSelf: "center",
  },
  top: {
    flexDirection: "row-reverse",
    justifyContent: "space-between",
    alignItems: "center",
  },
  heading: { alignItems: "flex-end" },
  eyebrow: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.medium,
  },
  title: {
    color: colors.text.primary,
    fontSize: typography.fontSize["2xl"],
    fontFamily: typography.fontFamily.bold,
    marginTop: 3,
  },
  pumpCard: {
    backgroundColor: colors.brand.navy,
    borderRadius: radius.lg,
    padding: spacing.xl,
    alignItems: "center",
    overflow: "hidden",
  },
  pumpIcon: {
    width: 54,
    height: 54,
    borderRadius: 27,
    backgroundColor: colors.brand.teal,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: spacing.sm,
  },
  pumpLabel: {
    color: "#B7DDE4",
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.medium,
  },
  subscriber: {
    color: colors.text.inverse,
    fontSize: typography.fontSize["2xl"],
    fontFamily: typography.fontFamily.bold,
    marginTop: spacing.xs,
  },
  branch: {
    color: "#C3D4DC",
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
  },
  timer: {
    width: "100%",
    alignItems: "center",
    marginVertical: spacing.lg,
    gap: spacing.sm,
  },
  timerLabel: {
    color: "#B7DDE4",
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.medium,
  },
  progressTrack: {
    width: "100%",
    height: 8,
    backgroundColor: "#31586B",
    borderRadius: 4,
    overflow: "hidden",
  },
  progressFill: {
    height: "100%",
    width: "75%",
    backgroundColor: colors.brand.aqua,
    borderRadius: 4,
  },
  progressText: {
    color: "#B7DDE4",
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
  },
  disabledAction: {
    minHeight: 52,
    width: "100%",
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: "#527487",
    backgroundColor: "#244B60",
    alignItems: "center",
    justifyContent: "center",
    flexDirection: "row-reverse",
    gap: spacing.sm,
    paddingHorizontal: spacing.md,
  },
  disabledActionText: {
    color: "#D8E7EB",
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.semiBold,
  },
  infoRow: { flexDirection: "row", gap: spacing.sm },
  infoBox: { flex: 1, alignItems: "center", padding: spacing.sm },
  infoLabel: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
  },
  infoValue: {
    color: colors.text.primary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.bold,
    marginTop: 4,
  },
  queueCard: { padding: spacing.md },
  sectionHeading: {
    flexDirection: "row-reverse",
    alignItems: "center",
    justifyContent: "space-between",
    gap: spacing.sm,
  },
  queueItem: {
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
    minHeight: 60,
    borderTopWidth: 1,
    borderTopColor: colors.background.subtle,
  },
  number: {
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: colors.background.subtle,
    alignItems: "center",
    justifyContent: "center",
  },
  numberText: {
    color: colors.brand.primary,
    fontFamily: typography.fontFamily.bold,
  },
  queueBody: { flex: 1, alignItems: "flex-end" },
  queueName: {
    color: colors.text.primary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.bold,
  },
  queueMeta: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    marginTop: 2,
  },
});
