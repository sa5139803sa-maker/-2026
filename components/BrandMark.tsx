import { StyleSheet, Text, View } from "react-native";
import { BrandSymbol } from "@/components/BrandSymbol";
import { colors, spacing, typography } from "@/constants/theme";

type BrandMarkProps = { compact?: boolean };

export function BrandMark({ compact = false }: BrandMarkProps) {
  return (
    <View style={[styles.wrap, compact && styles.compactWrap]}>
      <BrandSymbol size={compact ? 40 : 56} />
      {!compact && (
        <View style={styles.wordmark}>
          <Text style={styles.arabic}>إدارة المياه</Text>
          <Text style={styles.english}>Water Management</Text>
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing.sm,
  },
  compactWrap: { gap: 0 },
  wordmark: { alignItems: "flex-end" },
  arabic: {
    color: colors.brand.navy,
    fontSize: 21,
    fontFamily: typography.fontFamily.bold,
    textAlign: "right",
  },
  english: {
    color: colors.brand.primary,
    fontSize: 11,
    fontFamily: typography.fontFamily.medium,
    letterSpacing: 0.4,
  },
});
