import type { ReactNode } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@/constants/theme";

export type SidebarItem = {
  key: string;
  label: string;
  icon: ReactNode;
  accessibilityLabel?: string;
  disabled?: boolean;
};

type WebSidebarProps = {
  items: SidebarItem[];
  activeKey: string;
  onNavigate: (key: string) => void;
  brand?: ReactNode;
  footer?: ReactNode;
  width?: number;
};

export function WebSidebar({
  items,
  activeKey,
  onNavigate,
  brand,
  footer,
  width = 248,
}: WebSidebarProps) {
  return (
    <View style={[styles.sidebar, { width }]}>
      {brand ? <View style={styles.brand}>{brand}</View> : null}
      <ScrollView
        style={styles.scroll}
        contentContainerStyle={styles.navigation}
        showsVerticalScrollIndicator={false}
      >
        {items.map((item) => {
          const active = item.key === activeKey;
          return (
            <Pressable
              key={item.key}
              accessibilityRole="button"
              accessibilityLabel={item.accessibilityLabel ?? item.label}
              accessibilityState={{ selected: active, disabled: Boolean(item.disabled) }}
              disabled={item.disabled}
              onPress={() => onNavigate(item.key)}
              style={({ pressed }) => [
                styles.item,
                active && styles.activeItem,
                item.disabled && styles.disabledItem,
                pressed && !item.disabled && styles.pressed,
              ]}
            >
              <View style={styles.icon}>{item.icon}</View>
              <Text style={[styles.label, active && styles.activeLabel]}>
                {item.label}
              </Text>
            </Pressable>
          );
        })}
      </ScrollView>
      {footer ? <View style={styles.footer}>{footer}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  sidebar: {
    flex: 1,
    minHeight: 0,
    backgroundColor: colors.brand.navy,
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.md,
  },
  brand: {
    minHeight: 72,
    justifyContent: "center",
    alignItems: "flex-end",
    paddingHorizontal: spacing.sm,
    marginBottom: spacing.sm,
  },
  scroll: { flex: 1 },
  navigation: { gap: spacing.xs, paddingBottom: spacing.md },
  item: {
    minHeight: 46,
    flexDirection: "row-reverse",
    alignItems: "center",
    gap: spacing.sm,
    borderRadius: 10,
    paddingHorizontal: spacing.md,
  },
  activeItem: { backgroundColor: colors.brand.primary },
  disabledItem: { opacity: 0.4 },
  pressed: { opacity: 0.75 },
  icon: { width: 22, alignItems: "center", justifyContent: "center" },
  label: {
    flex: 1,
    color: "#D6E4EA",
    fontSize: typography.fontSize.sm,
    fontFamily: typography.fontFamily.medium,
    textAlign: "right",
  },
  activeLabel: {
    color: colors.text.inverse,
    fontFamily: typography.fontFamily.bold,
  },
  footer: {
    borderTopWidth: 1,
    borderTopColor: "rgba(255,255,255,0.14)",
    paddingTop: spacing.md,
    marginTop: spacing.sm,
  },
});
