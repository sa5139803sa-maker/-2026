import type { ReactNode } from "react";
import { StyleSheet, Text, View } from "react-native";
import {
  Button,
  LoadingState,
  SectionHeader,
  StatusBadge,
  type StatusTone,
} from "@/components/ui";
import { colors, radius, shadows, spacing, typography } from "@/constants/theme";

export { LoadingState, StatusBadge };

export function SectionTitle({ title, action }: { title: string; action?: string }) {
  return <SectionHeader title={title} actionLabel={action} />;
}

export function StatCard({
  label,
  value,
  caption,
  icon,
  tone = "info",
}: {
  label: string;
  value: string;
  caption: string;
  icon: ReactNode;
  tone?: StatusTone;
}) {
  const palette = colors.status[tone];

  return (
    <View style={[styles.statCard, shadows.card]}>
      <View style={[styles.statIcon, { backgroundColor: palette.background }]}>
        {icon}
      </View>
      <Text style={styles.statLabel}>{label}</Text>
      <Text style={styles.statValue}>{value}</Text>
      <Text style={[styles.statCaption, { color: palette.text }]}>{caption}</Text>
    </View>
  );
}

export function PrimaryButton({
  label,
  icon,
  onPress,
}: {
  label: string;
  icon?: ReactNode;
  onPress?: () => void;
}) {
  return (
    <Button
      label={label}
      icon={icon}
      onPress={onPress}
      disabled={!onPress}
      fullWidth
      variant="primary"
      size="medium"
    />
  );
}

const styles = StyleSheet.create({
  statCard: {
    flex: 1,
    minWidth: 145,
    backgroundColor: colors.background.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
  },
  statIcon: {
    width: 36,
    height: 36,
    borderRadius: 10,
    alignItems: "center",
    justifyContent: "center",
    marginBottom: spacing.sm,
  },
  statLabel: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.medium,
  },
  statValue: {
    color: colors.text.primary,
    fontSize: typography.fontSize["2xl"],
    lineHeight: 31,
    fontFamily: typography.fontFamily.bold,
    marginTop: 2,
  },
  statCaption: {
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.semiBold,
    marginTop: 2,
  },
});
