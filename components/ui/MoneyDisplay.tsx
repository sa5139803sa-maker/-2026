import { StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@/constants/theme";

type MoneyDisplayProps = {
  amount: number;
  currencyLabel: string;
  locale?: string;
  emphasis?: "normal" | "strong";
};

export function MoneyDisplay({
  amount,
  currencyLabel,
  locale = "ar",
  emphasis = "normal",
}: MoneyDisplayProps) {
  const formattedAmount = Number.isFinite(amount)
    ? new Intl.NumberFormat(locale, {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      }).format(amount)
    : "—";

  return (
    <View
      accessibilityRole="text"
      accessibilityLabel={`${formattedAmount} ${currencyLabel}`}
      style={styles.container}
    >
      <Text style={[styles.amount, emphasis === "strong" && styles.strong]}>
        {formattedAmount}
      </Text>
      <Text style={styles.currency}>{currencyLabel}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flexDirection: "row-reverse", alignItems: "baseline", gap: spacing.xs },
  amount: {
    color: colors.text.primary,
    fontSize: typography.fontSize.lg,
    fontFamily: typography.fontFamily.medium,
    fontVariant: ["tabular-nums"],
  },
  strong: {
    color: colors.brand.navy,
    fontSize: typography.fontSize["2xl"],
    fontFamily: typography.fontFamily.bold,
  },
  currency: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.medium,
  },
});
