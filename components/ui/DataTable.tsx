import type { ReactNode } from "react";
import { ScrollView, StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@/constants/theme";
import { EmptyState } from "./EmptyState";

export type DataTableColumn<T> = {
  key: string;
  title: string;
  width?: number;
  align?: "left" | "center" | "right";
  render: (row: T) => ReactNode;
};

type DataTableProps<T> = {
  columns: DataTableColumn<T>[];
  rows: T[];
  rowKey: (row: T, index: number) => string;
  emptyTitle?: string;
  emptyMessage?: string;
};

export function DataTable<T>({
  columns,
  rows,
  rowKey,
  emptyTitle = "لا توجد بيانات",
  emptyMessage = "ستظهر السجلات هنا عند توفرها.",
}: DataTableProps<T>) {
  if (rows.length === 0) {
    return <EmptyState title={emptyTitle} message={emptyMessage} />;
  }

  return (
    <ScrollView horizontal showsHorizontalScrollIndicator>
      <View style={styles.table}>
        <View style={[styles.row, styles.headerRow]}>
          {columns.map((column) => (
            <View
              key={column.key}
              style={[styles.cell, { width: column.width ?? 144 }]}
            >
              <Text style={[styles.headerText, alignment[column.align ?? "right"]]}>
                {column.title}
              </Text>
            </View>
          ))}
        </View>
        {rows.map((row, index) => (
          <View key={rowKey(row, index)} style={styles.row}>
            {columns.map((column) => (
              <View
                key={column.key}
                style={[styles.cell, { width: column.width ?? 144 }]}
              >
                <View style={alignment[column.align ?? "right"]}>
                  {column.render(row)}
                </View>
              </View>
            ))}
          </View>
        ))}
      </View>
    </ScrollView>
  );
}

const alignment = {
  left: { alignItems: "flex-start" as const, textAlign: "left" as const },
  center: { alignItems: "center" as const, textAlign: "center" as const },
  right: { alignItems: "flex-end" as const, textAlign: "right" as const },
};

const styles = StyleSheet.create({
  table: { minWidth: "100%" },
  row: {
    minHeight: 52,
    flexDirection: "row-reverse",
    borderBottomWidth: 1,
    borderBottomColor: colors.background.subtle,
  },
  headerRow: {
    minHeight: 44,
    backgroundColor: colors.background.subtle,
    borderBottomColor: colors.border,
  },
  cell: {
    justifyContent: "center",
    paddingHorizontal: spacing.sm,
    paddingVertical: spacing.sm,
  },
  headerText: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    fontFamily: typography.fontFamily.bold,
  },
});
