import type { ReactNode } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@/constants/theme";

export type NavigationItem = {
  key: string;
  label: string;
  icon: ReactNode;
  accessibilityLabel?: string;
};

type BottomNavigationProps = {
  items: NavigationItem[];
  activeKey: string;
  onChange: (key: string) => void;
};

export function BottomNavigation({
  items,
  activeKey,
  onChange,
}: BottomNavigationProps) {
  return (
    <View accessibilityRole="tablist" style={styles.container}>
      {items.map((item) => {
        const active = item.key === activeKey;
        return (
          <Pressable
            key={item.key}
            accessibilityRole="tab"
            accessibilityLabel={item.accessibilityLabel ?? item.label}
            accessibilityState={{ selected: active }}
            onPress={() => onChange(item.key)}
            style={({ pressed }) => [
              styles.item,
              pressed && styles.pressed,
            ]}
          >
            <View style={[styles.icon, active && styles.activeIcon]}>
              {item.icon}
            </View>
            <Text
              numberOfLines={1}
              style={[styles.label, active && styles.activeLabel]}
            >
              {item.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    minHeight: 68,
    flexDirection: "row-reverse",
    alignItems: "stretch",
    justifyContent: "space-around",
    backgroundColor: colors.background.surface,
    borderTopWidth: 1,
    borderTopColor: colors.border,
    paddingHorizontal: spacing.xs,
    paddingTop: spacing.xs,
    paddingBottom: spacing.sm,
  },
  item: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: 3,
    minWidth: 0,
    paddingHorizontal: spacing.xxs,
    borderRadius: 10,
  },
  icon: {
    width: 30,
    height: 28,
    alignItems: "center",
    justifyContent: "center",
  },
  activeIcon: { transform: [{ translateY: -1 }] },
  label: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.medium,
  },
  activeLabel: {
    color: colors.brand.primary,
    fontFamily: typography.fontFamily.bold,
  },
  pressed: { opacity: 0.7 },
});
