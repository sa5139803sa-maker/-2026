import { AlertCircle, CloudCheck, CloudUpload, RefreshCw, WifiOff } from "lucide-react-native";
import { StyleSheet, Text, View } from "react-native";
import { colors, radius, spacing, typography } from "@/constants/theme";

export type SyncState = "offline" | "pending" | "syncing" | "synced" | "error";

type SyncIndicatorProps = {
  state: SyncState;
  label?: string;
};

const statePresentation = {
  offline: { label: "غير متصل", color: colors.status.warning.text, background: colors.status.warning.background, Icon: WifiOff },
  pending: { label: "بانتظار المزامنة", color: colors.status.warning.text, background: colors.status.warning.background, Icon: CloudUpload },
  syncing: { label: "جاري المزامنة", color: colors.status.info.text, background: colors.status.info.background, Icon: RefreshCw },
  synced: { label: "متزامن", color: colors.status.success.text, background: colors.status.success.background, Icon: CloudCheck },
  error: { label: "تعذر المزامنة", color: colors.status.danger.text, background: colors.status.danger.background, Icon: AlertCircle },
} as const;

export function SyncIndicator({ state, label }: SyncIndicatorProps) {
  const item = statePresentation[state];
  const Icon = item.Icon;

  return (
    <View
      accessibilityRole="text"
      accessibilityLabel={label ?? item.label}
      style={[styles.container, { backgroundColor: item.background }]}
    >
      <Icon size={14} color={item.color} />
      <Text style={[styles.label, { color: item.color }]}>{label ?? item.label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    minHeight: 28,
    flexDirection: "row-reverse",
    alignItems: "center",
    justifyContent: "center",
    gap: spacing.xs,
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.xs,
    borderRadius: radius.pill,
  },
  label: {
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.semiBold,
  },
});
