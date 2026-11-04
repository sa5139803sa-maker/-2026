import type { ReactNode } from "react";
import { StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@/constants/theme";

type AppHeaderProps = {
  title: string;
  subtitle?: string;
  leading?: ReactNode;
  trailing?: ReactNode;
};

export function AppHeader({
  title,
  subtitle,
  leading,
  trailing,
}: AppHeaderProps) {
  return (
    <View style={styles.container}>
      {leading ? <View style={styles.side}>{leading}</View> : null}
      <View style={styles.content}>
        <Text accessibilityRole="header" style={styles.title}>{title}</Text>
        {subtitle ? <Text style={styles.subtitle}>{subtitle}</Text> : null}
      </View>
      {trailing ? <View style={styles.side}>{trailing}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    minHeight: 52,
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
  },
  content: { flex: 1, alignItems: "flex-end", gap: 2 },
  side: { alignItems: "center", justifyContent: "center" },
  title: {
    color: colors.text.primary,
    fontSize: typography.fontSize.xl,
    fontFamily: typography.fontFamily.bold,
    textAlign: "right",
  },
  subtitle: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    textAlign: "right",
  },
});
