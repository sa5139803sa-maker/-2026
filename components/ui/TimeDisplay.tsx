import { StyleSheet, Text, View } from "react-native";
import { colors, typography } from "@/constants/theme";
import { formatDuration } from "./formatters";

type TimeDisplayProps = {
  totalSeconds: number;
  compact?: boolean;
};

export { formatDuration };

export function TimeDisplay({ totalSeconds, compact = false }: TimeDisplayProps) {
  return (
    <View accessibilityRole="text" accessibilityLabel={formatDuration(totalSeconds)}>
      <Text style={[styles.value, compact && styles.compact]}>
        {formatDuration(totalSeconds)}
      </Text>
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
