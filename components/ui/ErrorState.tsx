import { AlertCircle } from "lucide-react-native";
import { StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@/constants/theme";
import { Button } from "./Button";

type ErrorStateProps = {
  title?: string;
  message: string;
  retryLabel?: string;
  onRetry?: () => void;
};

export function ErrorState({
  title = "تعذر إكمال العملية",
  message,
  retryLabel = "إعادة المحاولة",
  onRetry,
}: ErrorStateProps) {
  return (
    <View style={styles.container}>
      <View style={styles.icon}>
        <AlertCircle size={28} color={colors.status.danger.main} />
      </View>
      <Text style={styles.title}>{title}</Text>
      <Text style={styles.message}>{message}</Text>
      {onRetry ? <Button label={retryLabel} variant="secondary" size="small" onPress={onRetry} /> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    minHeight: 144,
    alignItems: "center",
    justifyContent: "center",
    gap: spacing.sm,
    padding: spacing.xl,
  },
  icon: {
    width: 48,
    height: 48,
    borderRadius: 24,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.status.danger.background,
  },
  title: {
    color: colors.text.primary,
    fontSize: typography.fontSize.lg,
    fontFamily: typography.fontFamily.bold,
  },
  message: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.sm,
    lineHeight: 22,
    fontFamily: typography.fontFamily.regular,
    textAlign: "center",
    maxWidth: 360,
  },
});
