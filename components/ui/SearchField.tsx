import { Search, X } from "lucide-react-native";
import { Pressable } from "react-native";
import { colors } from "@/constants/theme";
import { TextField } from "./TextField";

type SearchFieldProps = {
  value: string;
  onChangeText: (value: string) => void;
  placeholder?: string;
  accessibilityLabel?: string;
};

export function SearchField({
  value,
  onChangeText,
  placeholder = "ابحث...",
  accessibilityLabel = "بحث",
}: SearchFieldProps) {
  return (
    <TextField
      value={value}
      onChangeText={onChangeText}
      placeholder={placeholder}
      accessibilityLabel={accessibilityLabel}
      autoCapitalize="none"
      leading={<Search size={18} color={colors.text.secondary} />}
      trailing={
        value.length > 0 ? (
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="مسح البحث"
            hitSlop={8}
            onPress={() => onChangeText("")}
          >
            <X size={17} color={colors.text.secondary} />
          </Pressable>
        ) : null
      }
    />
  );
}
