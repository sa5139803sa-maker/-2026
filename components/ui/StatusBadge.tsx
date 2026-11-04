import { AlertTriangle, CheckCircle2, Info, XCircle } from "lucide-react-native";
import { StyleSheet, Text, View } from "react-native";
import { colors, radius, spacing, typography } from "@/constants/theme";

export type StatusTone = "success" | "warning" | "danger" | "info";

type StatusBadgeProps = {
  label: string;
  status: StatusTone;
};

const statusIcon = {
  success: CheckCircle2,
  warning: AlertTriangle,
  danger: XCircle,
  info: Info,
} as const;

export function StatusBadge({ label, status }: StatusBadgeProps) {
  const palette = colors.status[status];
  const Icon = statusIcon[status];

  return (
    <View
      accessibilityRole="text"
      accessibilityLabel={`الحالة: ${label}`}
      style={[styles.badge, { backgroundColor: palette.background }]}
    >
      <Icon size={14} color={palette.main} strokeWidth={2.3} />
      <Text style={[styles.label, { color: palette.text }]}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  badge: {
    minHeight: 28,
    flexDirection: "row-reverse",
    alignItems: "center",
    alignSelf: "flex-start",
    gap: spacing.xs,
    borderRadius: radius.pill,
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
  },
  label: {
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.semiBold,
  },
});
