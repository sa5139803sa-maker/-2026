import type { ReactNode } from "react";
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { colors, radius, spacing, typography } from "@/constants/theme";

export type ButtonVariant = "primary" | "secondary" | "ghost" | "danger";
export type ButtonSize = "small" | "medium" | "large";

type ButtonProps = {
  label: string;
  onPress?: () => void;
  icon?: ReactNode;
  variant?: ButtonVariant;
  size?: ButtonSize;
  disabled?: boolean;
  loading?: boolean;
  fullWidth?: boolean;
  accessibilityLabel?: string;
};

const variantStyles = {
  primary: {
    backgroundColor: colors.brand.primary,
    borderColor: colors.brand.primary,
    textColor: colors.text.inverse,
  },
  secondary: {
    backgroundColor: colors.background.surface,
    borderColor: colors.border,
    textColor: colors.brand.primary,
  },
  ghost: {
    backgroundColor: "transparent",
    borderColor: "transparent",
    textColor: colors.brand.primary,
  },
  danger: {
    backgroundColor: colors.status.danger.background,
    borderColor: colors.status.danger.background,
    textColor: colors.status.danger.text,
  },
} as const;

const sizeStyles = {
  small: { minHeight: 40, paddingHorizontal: spacing.md, fontSize: typography.fontSize.sm },
  medium: { minHeight: 48, paddingHorizontal: spacing.lg, fontSize: typography.fontSize.md },
  large: { minHeight: 60, paddingHorizontal: spacing.xl, fontSize: typography.fontSize.lg },
} as const;

export function Button({
  label,
  onPress,
  icon,
  variant = "primary",
  size = "medium",
  disabled = false,
  loading = false,
  fullWidth = false,
  accessibilityLabel,
}: ButtonProps) {
  const palette = variantStyles[variant];
  const dimensions = sizeStyles[size];
  const isDisabled = disabled || loading || !onPress;

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityState={{ disabled: isDisabled, busy: loading }}
      disabled={isDisabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        {
          minHeight: dimensions.minHeight,
          paddingHorizontal: dimensions.paddingHorizontal,
          backgroundColor: palette.backgroundColor,
          borderColor: palette.borderColor,
        },
        fullWidth && styles.fullWidth,
        isDisabled && styles.disabled,
        pressed && !isDisabled && styles.pressed,
      ]}
    >
      {loading ? (
        <ActivityIndicator
          size="small"
          color={palette.textColor}
          accessibilityLabel="جاري التنفيذ"
        />
      ) : (
        <>
          <Text style={[styles.label, { color: palette.textColor, fontSize: dimensions.fontSize }]}>
            {label}
          </Text>
          {icon ? <View style={styles.icon}>{icon}</View> : null}
        </>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    borderWidth: 1,
    borderRadius: radius.md,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: spacing.sm,
  },
  fullWidth: { alignSelf: "stretch", width: "100%" },
  label: {
    fontFamily: typography.fontFamily.semiBold,
    textAlign: "center",
  },
  icon: { alignItems: "center", justifyContent: "center" },
  disabled: { opacity: 0.45 },
  pressed: { opacity: 0.82, transform: [{ scale: 0.99 }] },
});
