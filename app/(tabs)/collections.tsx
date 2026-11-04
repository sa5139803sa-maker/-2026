import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { Banknote, Check, Smartphone } from "lucide-react-native";
import { SectionTitle, StatusBadge } from "@/components/UI";
import {
  Button,
  Card,
  MoneyDisplay,
  PreviewBanner,
  SearchField,
  TextField,
} from "@/components/ui";
import { colors, radius, spacing, typography } from "@/constants/theme";

const previewCollections = [
  { time: "10:24 ص", name: "أحمد محمد", amount: 450 },
  { time: "09:42 ص", name: "سارة محمود", amount: 300 },
  { time: "أمس", name: "خالد علي", amount: 500 },
];

const paymentMethods = ["نقداً", "جوال باي", "تحويل بنكي"] as const;

export default function CollectionsScreen() {
  const [method, setMethod] = useState<(typeof paymentMethods)[number]>("نقداً");
  const [subscriberSearch, setSubscriberSearch] = useState("");
  const [amount, setAmount] = useState("");

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={styles.content}
      keyboardShouldPersistTaps="handled"
      showsVerticalScrollIndicator={false}
    >
      <View style={styles.heading}>
        <Text style={styles.eyebrow}>المعاملات المالية</Text>
        <Text style={styles.title}>تسجيل قبض</Text>
        <Text style={styles.subtitle}>معاينة نموذج تسجيل عملية تحصيل</Text>
      </View>

      <PreviewBanner description="هذا نموذج عرض فقط. اختيار المشترك وحفظ القبض وإصدار الإيصال غير متصل بقاعدة البيانات، ولا تُنشأ أي حركة مالية فعلية." />

      <Card style={styles.formCard}>
        <SectionTitle title="بيانات التحصيل" />

        <SearchField
          value={subscriberSearch}
          onChangeText={setSubscriberSearch}
          placeholder="ابحث باسم المشترك أو رقمه"
          accessibilityLabel="البحث عن مشترك — نموذج توضيحي"
        />

        <View style={styles.previewSubscriber}>
          <View style={styles.selectedAvatar}>
            <Text style={styles.selectedAvatarText}>م</Text>
          </View>
          <View style={styles.selectedBody}>
            <Text style={styles.selectedName}>مشترك تجريبي</Text>
            <Text style={styles.selectedMeta}>بيانات اختيارية للمعاينة — غير مرتبطة بسجل حقيقي</Text>
          </View>
          <StatusBadge label="مثال" status="warning" />
        </View>

        <TextField
          label="المبلغ"
          value={amount}
          onChangeText={setAmount}
          placeholder="0.00"
          keyboardType="decimal-pad"
          autoCapitalize="none"
          trailing={<Text style={styles.currency}>ر.س</Text>}
          helperText="أدخل مبلغًا لمعاينة شكل الحقل فقط؛ لن يتم حفظه."
        />

        <View style={styles.fieldGroup}>
          <Text style={styles.label}>طريقة الدفع — اختيار محلي</Text>
          <View style={styles.methods}>
            {paymentMethods.map((item) => {
              const selected = method === item;
              return (
                <Pressable
                  key={item}
                  accessibilityRole="radio"
                  accessibilityState={{ selected }}
                  onPress={() => setMethod(item)}
                  style={[styles.method, selected && styles.methodActive]}
                >
                  {item === "نقداً" ? (
                    <Banknote size={17} color={selected ? colors.brand.primary : colors.text.secondary} />
                  ) : (
                    <Smartphone size={17} color={selected ? colors.brand.primary : colors.text.secondary} />
                  )}
                  <Text style={[styles.methodText, selected && styles.methodTextActive]}>
                    {item}
                  </Text>
                </Pressable>
              );
            })}
          </View>
        </View>

        <Button
          label="تسجيل القبض غير متاح في النموذج"
          icon={<Check size={18} color={colors.text.secondary} />}
          disabled
          fullWidth
          variant="secondary"
        />
      </Card>

      <Card style={styles.historyCard}>
        <View style={styles.sectionHeading}>
          <SectionTitle title="آخر التحصيلات" />
          <StatusBadge label="أمثلة فقط" status="warning" />
        </View>
        {previewCollections.map((item) => (
          <View style={styles.historyRow} key={`${item.time}-${item.name}`}>
            <View style={styles.receipt}>
              <Banknote size={17} color={colors.text.secondary} />
            </View>
            <View style={styles.historyBody}>
              <Text style={styles.historyName}>{item.name}</Text>
              <Text style={styles.historyMeta}>{item.time} · سجل تجريبي</Text>
            </View>
            <View style={styles.historyEnd}>
              <MoneyDisplay amount={item.amount} currencyLabel="ر.س" />
              <StatusBadge label="غير معتمد" status="warning" />
            </View>
          </View>
        ))}
      </Card>
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
  heading: { alignItems: "flex-end" },
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
    fontFamily: typography.fontFamily.regular,
    marginTop: 4,
  },
  formCard: { gap: spacing.md },
  previewSubscriber: {
    minHeight: 58,
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
    backgroundColor: colors.background.subtle,
    borderRadius: radius.md,
    padding: spacing.sm,
  },
  selectedAvatar: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: colors.brand.aqua,
    alignItems: "center",
    justifyContent: "center",
  },
  selectedAvatarText: {
    color: colors.brand.navy,
    fontFamily: typography.fontFamily.bold,
  },
  selectedBody: { flex: 1, alignItems: "flex-end", gap: 2 },
  selectedName: {
    color: colors.text.primary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.bold,
  },
  selectedMeta: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    textAlign: "right",
  },
  currency: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.semiBold,
  },
  fieldGroup: { gap: spacing.sm },
  label: {
    color: colors.text.primary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.bold,
    textAlign: "right",
  },
  methods: { flexDirection: "row-reverse", gap: spacing.sm },
  method: {
    flex: 1,
    minHeight: 48,
    flexDirection: "row-reverse",
    alignItems: "center",
    justifyContent: "center",
    gap: 5,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    backgroundColor: colors.background.surface,
  },
  methodActive: {
    backgroundColor: colors.status.info.background,
    borderColor: colors.brand.teal,
  },
  methodText: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.medium,
  },
  methodTextActive: {
    color: colors.brand.primary,
    fontFamily: typography.fontFamily.bold,
  },
  historyCard: { padding: spacing.md },
  sectionHeading: {
    flexDirection: "row-reverse",
    alignItems: "center",
    justifyContent: "space-between",
    gap: spacing.sm,
  },
  historyRow: {
    minHeight: 70,
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
    borderTopWidth: 1,
    borderTopColor: colors.background.subtle,
  },
  receipt: {
    width: 36,
    height: 36,
    borderRadius: 10,
    backgroundColor: colors.background.subtle,
    alignItems: "center",
    justifyContent: "center",
  },
  historyBody: { flex: 1, alignItems: "flex-end" },
  historyName: {
    color: colors.text.primary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.bold,
  },
  historyMeta: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
  },
  historyEnd: { alignItems: "flex-end", gap: 4 },
});
