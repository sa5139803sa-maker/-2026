import { StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@/constants/theme";

type TimeDisplayProps = {
  totalSeconds: number;
  compact?: boolean;
};

export function formatDuration(totalSeconds: number): string {
  const safeSeconds = Number.isFinite(totalSeconds) ? Math.max(0, Math.floor(totalSeconds)) : 0;
  const hours = Math.floor(safeSeconds / 3600);
  const minutes = Math.floor((safeSeconds % 3600) / 60);
  const seconds = safeSeconds % 60;

  if (hours > 0) {
    return [hours, minutes, seconds].map((part) => String(part).padStart(2, "0")).join(":");
  }
  return [minutes, seconds].map((part) => String(part).padStart(2, "0")).join(":");
}

export function TimeDisplay({ totalSeconds, compact = false }: TimeDisplayProps) {
  return (
    <View accessibilityRole="text" accessibilityLabel={formatDuration(totalSeconds)}>
      <Text style={[styles.value, compact && styles.compact]}>{formatDuration(totalSeconds)}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  value: {
    color: colors.brand.navy,
    fontSize: typography.fontSize["3xl"],
    fontFamily: typography.fontFamily.bold,
    fontVariant: ["tabular-nums"],
    letterSpacing: 1,
  },
  compact: { fontSize: typography.fontSize.xl },
});
