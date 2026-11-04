import type { ReactNode } from "react";
import { Button } from "./Button";

type SecondaryButtonProps = {
  label: string;
  onPress: () => void;
  icon?: ReactNode;
  disabled?: boolean;
  fullWidth?: boolean;
  size?: "small" | "medium" | "large";
};

export function SecondaryButton({
  label,
  onPress,
  icon,
  disabled = false,
  fullWidth = false,
  size = "medium",
}: SecondaryButtonProps) {
  return (
    <Button
      label={label}
      onPress={onPress}
      icon={icon}
      variant="secondary"
      size={size}
      disabled={disabled}
      fullWidth={fullWidth}
    />
  );
}
