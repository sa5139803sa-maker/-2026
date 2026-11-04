import { Modal, StyleSheet, Text, View } from "react-native";
import { Button } from "./Button";
import { colors, radius, spacing, typography } from "@/constants/theme";

type ConfirmDialogProps = {
  visible: boolean;
  title: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  destructive?: boolean;
  loading?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
};

export function ConfirmDialog({
  visible,
  title,
  message,
  confirmLabel = "تأكيد",
  cancelLabel = "إلغاء",
  destructive = false,
  loading = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  return (
    <Modal
      visible={visible}
      transparent
      animationType="fade"
      onRequestClose={onCancel}
      statusBarTranslucent
    >
      <View style={styles.overlay}>
        <View
          accessibilityViewIsModal
          style={styles.dialog}
        >
          <Text accessibilityRole="header" style={styles.title}>{title}</Text>
          <Text style={styles.message}>{message}</Text>
          <View style={styles.actions}>
            <View style={styles.action}>
              <Button
                label={cancelLabel}
                variant="secondary"
                fullWidth
                onPress={onCancel}
                disabled={loading}
              />
            </View>
            <View style={styles.action}>
              <Button
                label={confirmLabel}
                variant={destructive ? "danger" : "primary"}
                fullWidth
                loading={loading}
                onPress={onConfirm}
              />
            </View>
          </View>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  overlay: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    padding: spacing.lg,
    backgroundColor: "rgba(11, 52, 73, 0.42)",
  },
  dialog: {
    width: "100%",
    maxWidth: 440,
    padding: spacing.lg,
    gap: spacing.md,
    backgroundColor: colors.background.surface,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
  },
  title: {
    color: colors.text.primary,
    fontSize: typography.fontSize.xl,
    fontFamily: typography.fontFamily.bold,
    textAlign: "right",
  },
  message: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.md,
    fontFamily: typography.fontFamily.regular,
    lineHeight: 24,
    textAlign: "right",
  },
  actions: { flexDirection: "row-reverse", gap: spacing.sm, marginTop: spacing.xs },
  action: { flex: 1 },
});
