import { AlertTriangle } from "lucide-react-native";
import { StyleSheet, Text, View } from "react-native";
import { colors, radius, spacing, typography } from "@/constants/theme";

type PreviewBannerProps = {
  title?: string;
  description: string;
};

export function PreviewBanner({
  title = "واجهة توضيحية",
  description,
}: PreviewBannerProps) {
  return (
    <View accessibilityRole="summary" style={styles.container}>
      <View style={styles.icon}>
        <AlertTriangle size={17} color={colors.status.warning.text} />
      </View>
      <View style={styles.content}>
        <Text style={styles.title}>{title}</Text>
        <Text style={styles.description}>{description}</Text>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: "row-reverse",
    alignItems: "flex-start",
    gap: spacing.sm,
    padding: spacing.md,
    borderRadius: radius.md,
    backgroundColor: colors.status.warning.background,
    borderWidth: 1,
    borderColor: "#F1D9A8",
  },
  icon: { paddingTop: 2 },
  content: { flex: 1, alignItems: "flex-end", gap: 2 },
  title: {
    color: colors.status.warning.text,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.bold,
    textAlign: "right",
  },
  description: {
    color: colors.status.warning.text,
    fontSize: typography.fontSize.xs,
    lineHeight: 19,
    fontFamily: typography.fontFamily.regular,
    textAlign: "right",
  },
});
