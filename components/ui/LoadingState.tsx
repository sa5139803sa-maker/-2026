import { ActivityIndicator, StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@/constants/theme";

type LoadingStateProps = {
  message?: string;
  inline?: boolean;
};

export function LoadingState({
  message = "جاري التحميل...",
  inline = false,
}: LoadingStateProps) {
  return (
    <View style={[styles.container, inline && styles.inline]}>
      <ActivityIndicator size="small" color={colors.brand.teal} />
      <Text accessibilityLiveRegion="polite" style={styles.message}>{message}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    minHeight: 112,
    alignItems: "center",
    justifyContent: "center",
    gap: spacing.sm,
    padding: spacing.lg,
  },
  inline: { minHeight: 48, padding: spacing.sm, flexDirection: "row" },
  message: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.medium,
  },
});
