import type { ReactNode } from "react";
import {
  StyleSheet,
  Text,
  TextInput,
  View,
  type TextInputProps,
} from "react-native";
import { colors, radius, spacing, typography } from "@/constants/theme";

type TextFieldProps = {
  label?: string;
  value: string;
  onChangeText: (value: string) => void;
  placeholder?: string;
  helperText?: string;
  error?: string;
  leading?: ReactNode;
  trailing?: ReactNode;
  disabled?: boolean;
  secureTextEntry?: boolean;
  keyboardType?: TextInputProps["keyboardType"];
  autoCapitalize?: TextInputProps["autoCapitalize"];
  multiline?: boolean;
  numberOfLines?: number;
  returnKeyType?: TextInputProps["returnKeyType"];
  onSubmitEditing?: TextInputProps["onSubmitEditing"];
  accessibilityLabel?: string;
};

export function TextField({
  label,
  value,
  onChangeText,
  placeholder,
  helperText,
  error,
  leading,
  trailing,
  disabled = false,
  secureTextEntry = false,
  keyboardType = "default",
  autoCapitalize = "sentences",
  multiline = false,
  numberOfLines = 4,
  returnKeyType,
  onSubmitEditing,
  accessibilityLabel,
}: TextFieldProps) {
  const hasError = Boolean(error);

  return (
    <View style={styles.container}>
      {label ? <Text style={styles.label}>{label}</Text> : null}
      <View
        style={[
          styles.inputShell,
          multiline && styles.multilineShell,
          hasError && styles.errorShell,
          disabled && styles.disabledShell,
        ]}
      >
        {leading ? <View style={styles.adornment}>{leading}</View> : null}
        <TextInput
          accessibilityLabel={accessibilityLabel ?? label ?? placeholder}
          editable={!disabled}
          value={value}
          onChangeText={onChangeText}
          placeholder={placeholder}
          placeholderTextColor={colors.text.secondary}
          secureTextEntry={secureTextEntry}
          keyboardType={keyboardType}
          autoCapitalize={autoCapitalize}
          multiline={multiline}
          numberOfLines={multiline ? numberOfLines : 1}
          returnKeyType={returnKeyType}
          onSubmitEditing={onSubmitEditing}
          textAlign="right"
          style={[styles.input, multiline && styles.multilineInput]}
        />
        {trailing ? <View style={styles.adornment}>{trailing}</View> : null}
      </View>
      {error ? (
        <Text accessibilityRole="alert" style={styles.errorText}>{error}</Text>
      ) : helperText ? (
        <Text style={styles.helperText}>{helperText}</Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { gap: spacing.xs },
  label: {
    color: colors.text.primary,
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.semiBold,
    textAlign: "right",
  },
  inputShell: {
    minHeight: 48,
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
    paddingHorizontal: spacing.md,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    backgroundColor: colors.background.surface,
  },
  multilineShell: { minHeight: 112, alignItems: "flex-start", paddingVertical: spacing.sm },
  errorShell: { borderColor: colors.status.danger.main },
  disabledShell: { backgroundColor: colors.background.subtle, opacity: 0.7 },
  adornment: { alignItems: "center", justifyContent: "center" },
  input: {
    flex: 1,
    minHeight: 46,
    padding: 0,
    color: colors.text.primary,
    fontSize: typography.fontSize.md,
    fontFamily: typography.fontFamily.regular,
    writingDirection: "rtl",
  },
  multilineInput: { minHeight: 88, textAlignVertical: "top" },
  helperText: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.regular,
    textAlign: "right",
  },
  errorText: {
    color: colors.status.danger.text,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.medium,
    textAlign: "right",
  },
});
