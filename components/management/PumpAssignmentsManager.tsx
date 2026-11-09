import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { Check, Plus, Trash2, UserRound, X } from "lucide-react-native";
import { Button, Card } from "@/components/ui";
import { colors, radius, spacing, typography } from "@/constants/theme";
import { getAssignableEmployees, type AssignmentEmployee, type AssignmentRole } from "@/lib/pump-assignment-rules";
import { supabase } from "@/lib/supabase";

type PumpOption = { id: string; name: string; code: string };
type PumpAssignment = {
  id: string;
  organization_id: string;
  pump_id: string;
  user_id: string;
  assignment_role: AssignmentRole;
};

type Props = {
  organizationId: string | null;
  pumps: PumpOption[];
};

const roleLabels: Record<AssignmentRole, string> = {
  operator: "المشغّل",
  collector: "المحصّل",
  supervisor: "المشرف",
};
const roleOrder: AssignmentRole[] = ["operator", "collector", "supervisor"];

function friendlyError(error: { code?: string }): string {
  if (error.code === "23505") {
    return "هذا الموظف مسند بالفعل، أو أن خانة هذا الدور مشغولة على الغطاس.";
  }
  if (error.code === "23503" || error.code === "23514") {
    return "تعذر الإسناد لأن دور الموظف أو المؤسسة لا يطابق بيانات الغطاس.";
  }
  if (error.code === "42501") {
    return "ليس لديك صلاحية تنفيذ هذا الإجراء.";
  }
  return "تعذر تنفيذ العملية. حدّث القائمة ثم حاول مرة أخرى.";
}

export function PumpAssignmentsManager({ organizationId, pumps }: Props) {
  const [employees, setEmployees] = useState<AssignmentEmployee[]>([]);
  const [assignments, setAssignments] = useState<PumpAssignment[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [activeSlot, setActiveSlot] = useState<{
    pump: PumpOption;
    role: AssignmentRole;
  } | null>(null);
  const [selectedEmployeeId, setSelectedEmployeeId] = useState("");
  const requestSequence = useRef(0);

  const employeeNames = useMemo(
    () => new Map<string, string>(employees.map((employee) => [employee.id, employee.display_name] as const)),
    [employees],
  );

  const load = useCallback(async () => {
    if (!organizationId) {
      requestSequence.current += 1;
      setEmployees([]);
      setAssignments([]);
      setLoading(false);
      return;
    }

    const requestId = ++requestSequence.current;
    setLoading(true);
    setError(null);

    try {
      const [employeeResult, assignmentResult] = await Promise.all([
        supabase
          .from("profiles")
          .select("id,display_name,role")
          .eq("organization_id", organizationId)
          .in("role", ["operator", "collector", "supervisor"])
          .order("display_name", { ascending: true }),
        supabase
          .from("pump_assignments")
          .select("id,organization_id,pump_id,user_id,assignment_role")
          .eq("organization_id", organizationId)
          .order("created_at", { ascending: true }),
      ]);

      if (requestId !== requestSequence.current) return;

      if (employeeResult.error || assignmentResult.error) {
        console.error(
          "pump assignment list failed",
          employeeResult.error ?? assignmentResult.error,
        );
        setEmployees([]);
        setAssignments([]);
        setError("تعذر تحميل توزيع الموظفين. تحقق من الاتصال ثم أعد المحاولة.");
      } else {
        setEmployees((employeeResult.data ?? []) as AssignmentEmployee[]);
        setAssignments((assignmentResult.data ?? []) as PumpAssignment[]);
      }
    } catch (cause) {
      console.error("pump assignment request failed", cause);
      if (requestId === requestSequence.current) {
        setEmployees([]);
        setAssignments([]);
        setError("تعذر تحميل توزيع الموظفين. تحقق من الاتصال ثم أعد المحاولة.");
      }
    } finally {
      if (requestId === requestSequence.current) setLoading(false);
    }
  }, [organizationId]);

  useEffect(() => {
    void load();
    return () => {
      requestSequence.current += 1;
    };
  }, [load]);

  const closeModal = () => {
    setActiveSlot(null);
    setSelectedEmployeeId("");
  };

  const openAssignment = (pump: PumpOption, role: AssignmentRole) => {
    setError(null);
    setNotice(null);
    setSelectedEmployeeId("");
    setActiveSlot({ pump, role });
  };

  const eligibleEmployees = activeSlot
    ? getAssignableEmployees(activeSlot.role, activeSlot.pump.id, employees, assignments)
    : [];

  const saveAssignment = async () => {
    if (!organizationId || !activeSlot || !selectedEmployeeId) {
      setError("اختر موظفًا قبل حفظ الإسناد.");
      return;
    }

    setSaving(true);
    setError(null);
    setNotice(null);

    const { error: insertError } = await supabase
      .from("pump_assignments")
      .insert({
        organization_id: organizationId,
        pump_id: activeSlot.pump.id,
        user_id: selectedEmployeeId,
        assignment_role: activeSlot.role,
      });

    if (insertError) {
      console.error("pump assignment insert failed", insertError);
      setError(friendlyError(insertError));
      setSaving(false);
      return;
    }

    const assignedRole = activeSlot.role;
    const pumpName = activeSlot.pump.name;
    closeModal();
    await load();
    setNotice(`تم إسناد ${roleLabels[assignedRole]} إلى ${pumpName} بنجاح.`);
    setSaving(false);
  };

  const removeAssignment = async (assignment: PumpAssignment, pumpName: string) => {
    setSaving(true);
    setError(null);
    setNotice(null);

    const { data, error: deleteError } = await supabase
      .from("pump_assignments")
      .delete()
      .eq("id", assignment.id)
      .eq("organization_id", organizationId ?? "")
      .select("id")
      .maybeSingle();

    if (deleteError || !data) {
      console.error("pump assignment delete failed", deleteError);
      setError(
        deleteError
          ? friendlyError(deleteError)
          : "لم يتم العثور على الإسناد المطلوب أو لا تملك صلاحية إزالته.",
      );
      setSaving(false);
      return;
    }

    await load();
    setNotice(`تم إلغاء إسناد ${roleLabels[assignment.assignment_role]} من ${pumpName}.`);
    setSaving(false);
  };

  if (!organizationId) return null;

  return (
    <>
      <Card style={styles.card}>
        <View style={styles.heading}>
          <View style={styles.headingText}>
            <Text style={styles.title}>توزيع الموظفين على الغواطس</Text>
            <Text style={styles.subtitle}>
              عيّن مشغّلًا ومحصّلًا، ويمكن إسناد أكثر من مشرف إلى الغطاس.
            </Text>
          </View>
          <View style={styles.headingIcon}>
            <UserRound size={20} color={colors.brand.primary} />
          </View>
        </View>

        {error ? <Text style={styles.error} accessibilityRole="alert">{error}</Text> : null}
        {notice ? <Text style={styles.notice} accessibilityLiveRegion="polite">{notice}</Text> : null}

        {loading ? (
          <View style={styles.loading}>
            <ActivityIndicator color={colors.brand.teal} />
            <Text style={styles.meta}>جاري تحميل التعيينات...</Text>
          </View>
        ) : pumps.length === 0 ? (
          <Text style={styles.empty}>أضف غطاسًا أولًا حتى تتمكن من توزيع الموظفين.</Text>
        ) : employees.length === 0 ? (
          <Text style={styles.empty}>
            لا توجد حسابات مشغّل أو محصّل أو مشرف في المؤسسة. أنشئ حسابات الموظفين أولًا من إدارة الحسابات.
          </Text>
        ) : (
          <View style={styles.pumpList}>
            {pumps.map((pump) => {
              const pumpAssignments = assignments.filter(
                (assignment) => assignment.pump_id === pump.id,
              );

              return (
                <View key={pump.id} style={styles.pumpBlock}>
                  <View style={styles.pumpHeading}>
                    <Text style={styles.pumpName}>{pump.name}</Text>
                    <Text style={styles.pumpCode}>{pump.code}</Text>
                  </View>

                  {roleOrder.map((role) => {
                    const roleAssignments = pumpAssignments.filter(
                      (assignment) => assignment.assignment_role === role,
                    );
                    const isSingleSlot = role !== "supervisor";
                    const hasAssignedEmployee = isSingleSlot && roleAssignments.length > 0;
                    const available = getAssignableEmployees(role, pump.id, employees, assignments);
                    const canAdd = !hasAssignedEmployee && available.length > 0;
                    const hasRoleAccounts = employees.some((employee) => employee.role === role);

                    return (
                      <View key={role} style={styles.roleBlock}>
                        <View style={styles.roleHeading}>
                          <Text style={styles.roleLabel}>{roleLabels[role]}</Text>
                          {role === "supervisor" ? <Text style={styles.roleHint}>متعدد</Text> : null}
                        </View>

                        {roleAssignments.length > 0 ? (
                          roleAssignments.map((assignment) => (
                            <View key={assignment.id} style={styles.assignmentRow}>
                              <View style={styles.assignedPerson}>
                                <Check size={15} color={colors.status.success.text} />
                                <Text style={styles.employeeName}>
                                  {employeeNames.get(assignment.user_id) ?? "موظف غير معروف"}
                                </Text>
                              </View>
                              <Pressable
                                accessibilityRole="button"
                                accessibilityLabel={`إلغاء إسناد ${roleLabels[role]}`}
                                onPress={() => void removeAssignment(assignment, pump.name)}
                                disabled={saving}
                                style={({ pressed }) => [
                                  styles.removeButton,
                                  pressed && styles.pressed,
                                  saving && styles.disabled,
                                ]}
                              >
                                <Trash2 size={15} color={colors.status.danger.text} />
                                <Text style={styles.removeText}>إزالة</Text>
                              </Pressable>
                            </View>
                          ))
                        ) : (
                          <Text style={styles.unassigned}>لم يتم إسناد موظف بعد.</Text>
                        )}

                        {canAdd ? (
                          <Pressable
                            accessibilityRole="button"
                            onPress={() => openAssignment(pump, role)}
                            disabled={saving}
                            style={({ pressed }) => [
                              styles.addButton,
                              pressed && styles.pressed,
                              saving && styles.disabled,
                            ]}
                          >
                            <Plus size={16} color={colors.brand.primary} />
                            <Text style={styles.addText}>
                              {role === "supervisor" && roleAssignments.length > 0
                                ? "إضافة مشرف آخر"
                                : "إسناد موظف"}
                            </Text>
                          </Pressable>
                        ) : hasAssignedEmployee ? (
                          <Text style={styles.roleHint}>أزل التعيين الحالي أولًا لإسناد موظف بديل.</Text>
                        ) : !hasRoleAccounts ? (
                          <Text style={styles.roleHint}>لا توجد حسابات بهذا الدور في المؤسسة.</Text>
                        ) : null}
                      </View>
                    );
                  })}
                </View>
              );
            })}
          </View>
        )}

        <Button
          label="تحديث التوزيع"
          variant="secondary"
          size="small"
          onPress={() => void load()}
          disabled={loading || saving}
          fullWidth
        />
      </Card>

      <Modal visible={activeSlot !== null} transparent animationType="slide" onRequestClose={closeModal}>
        <View style={styles.modalOverlay}>
          <View style={styles.modalCard}>
            <View style={styles.modalHeading}>
              <View style={styles.modalTitleBlock}>
                <Text style={styles.modalTitle}>
                  إسناد {activeSlot ? roleLabels[activeSlot.role] : "موظف"}
                </Text>
                <Text style={styles.meta}>{activeSlot?.pump.name ?? ""}</Text>
              </View>
              <Pressable
                accessibilityRole="button"
                accessibilityLabel="إغلاق نافذة الإسناد"
                onPress={closeModal}
                style={styles.closeButton}
              >
                <X size={19} color={colors.text.primary} />
              </Pressable>
            </View>

            {error ? <Text style={styles.error} accessibilityRole="alert">{error}</Text> : null}
            <Text style={styles.fieldLabel}>اختر الموظف</Text>
            <ScrollView style={styles.employeeList} keyboardShouldPersistTaps="handled">
              {eligibleEmployees.map((employee) => (
                <Pressable
                  key={employee.id}
                  accessibilityRole="radio"
                  accessibilityState={{ selected: selectedEmployeeId === employee.id }}
                  onPress={() => setSelectedEmployeeId(employee.id)}
                  style={[
                    styles.employeeOption,
                    selectedEmployeeId === employee.id && styles.employeeOptionSelected,
                  ]}
                >
                  <View style={styles.employeeOptionText}>
                    <Text style={styles.employeeName}>{employee.display_name}</Text>
                    <Text style={styles.meta}>{roleLabels[employee.role]}</Text>
                  </View>
                  {selectedEmployeeId === employee.id ? (
                    <Check size={18} color={colors.brand.primary} />
                  ) : null}
                </Pressable>
              ))}
              {eligibleEmployees.length === 0 ? (
                <Text style={styles.empty}>
                  لا يوجد موظف متاح لهذا الدور على هذا الغطاس. تحقق من حسابات الموظفين والتعيينات الحالية.
                </Text>
              ) : null}
            </ScrollView>

            <View style={styles.modalActions}>
              <Button label="إلغاء" variant="secondary" onPress={closeModal} disabled={saving} />
              <View style={styles.actionSpacer}>
                <Button
                  label="حفظ الإسناد"
                  onPress={() => void saveAssignment()}
                  loading={saving}
                  disabled={!selectedEmployeeId || eligibleEmployees.length === 0}
                  fullWidth
                />
              </View>
            </View>
          </View>
        </View>
      </Modal>
    </>
  );
}

const styles = StyleSheet.create({
  card: { gap: spacing.md },
  heading: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  headingText: { flex: 1, alignItems: "flex-end", gap: 3 },
  headingIcon: {
    width: 40,
    height: 40,
    borderRadius: 12,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.background.subtle,
  },
  title: {
    color: colors.text.primary,
    fontSize: typography.fontSize.lg,
    fontFamily: typography.fontFamily.bold,
    textAlign: "right",
  },
  subtitle: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.xs,
    lineHeight: 20,
    fontFamily: typography.fontFamily.regular,
    textAlign: "right",
  },
  loading: { minHeight: 72, alignItems: "center", justifyContent: "center", gap: spacing.sm },
  meta: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  empty: {
    color: colors.text.secondary,
    fontSize: typography.fontSize.sm,
    lineHeight: 22,
    fontFamily: typography.fontFamily.regular,
    textAlign: "right",
    paddingVertical: spacing.sm,
  },
  error: {
    color: colors.status.danger.text,
    backgroundColor: colors.status.danger.background,
    borderRadius: radius.sm,
    padding: spacing.sm,
    fontSize: typography.fontSize.xs,
    lineHeight: 20,
    fontFamily: typography.fontFamily.medium,
    textAlign: "right",
  },
  notice: {
    color: colors.status.success.text,
    backgroundColor: colors.status.success.background,
    borderRadius: radius.sm,
    padding: spacing.sm,
    fontSize: typography.fontSize.xs,
    lineHeight: 20,
    fontFamily: typography.fontFamily.medium,
    textAlign: "right",
  },
  pumpList: { gap: spacing.md },
  pumpBlock: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    padding: spacing.md,
    gap: spacing.sm,
  },
  pumpHeading: {
    flexDirection: "row-reverse",
    alignItems: "center",
    justifyContent: "space-between",
    paddingBottom: spacing.xs,
  },
  pumpName: { color: colors.text.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold },
  pumpCode: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  roleBlock: {
    borderTopWidth: 1,
    borderTopColor: colors.background.subtle,
    paddingTop: spacing.sm,
    gap: spacing.xs,
  },
  roleHeading: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.xs },
  roleLabel: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.semiBold },
  roleHint: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  unassigned: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  assignmentRow: { minHeight: 42, flexDirection: "row-reverse", alignItems: "center", justifyContent: "space-between", gap: spacing.sm },
  assignedPerson: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.xs },
  employeeName: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  removeButton: {
    minHeight: 34,
    paddingHorizontal: spacing.sm,
    borderRadius: radius.sm,
    backgroundColor: colors.status.danger.background,
    flexDirection: "row-reverse",
    alignItems: "center",
    justifyContent: "center",
    gap: 5,
  },
  removeText: { color: colors.status.danger.text, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  addButton: {
    alignSelf: "flex-start",
    minHeight: 38,
    paddingHorizontal: spacing.md,
    borderRadius: radius.sm,
    backgroundColor: colors.background.subtle,
    borderWidth: 1,
    borderColor: colors.brand.aqua,
    flexDirection: "row-reverse",
    alignItems: "center",
    justifyContent: "center",
    gap: spacing.xs,
  },
  addText: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.semiBold },
  pressed: { opacity: 0.75 },
  disabled: { opacity: 0.45 },
  modalOverlay: { flex: 1, justifyContent: "flex-end", backgroundColor: "rgba(11,52,73,0.32)" },
  modalCard: {
    backgroundColor: colors.background.surface,
    borderTopLeftRadius: radius.xl,
    borderTopRightRadius: radius.xl,
    padding: spacing.lg,
    gap: spacing.md,
    maxHeight: "82%",
  },
  modalHeading: { flexDirection: "row-reverse", alignItems: "center", justifyContent: "space-between" },
  modalTitleBlock: { alignItems: "flex-end", gap: 3 },
  modalTitle: { color: colors.text.primary, fontSize: typography.fontSize.lg, fontFamily: typography.fontFamily.bold },
  closeButton: {
    width: 38,
    height: 38,
    borderRadius: radius.md,
    backgroundColor: colors.background.subtle,
    alignItems: "center",
    justifyContent: "center",
  },
  fieldLabel: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.semiBold, textAlign: "right" },
  employeeList: { flexGrow: 0, maxHeight: 320 },
  employeeOption: {
    minHeight: 58,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.md,
    marginBottom: spacing.xs,
    flexDirection: "row-reverse",
    alignItems: "center",
    justifyContent: "space-between",
  },
  employeeOptionSelected: { borderColor: colors.brand.primary, backgroundColor: colors.background.subtle },
  employeeOptionText: { alignItems: "flex-end", gap: 3 },
  modalActions: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  actionSpacer: { flex: 1 },
});
