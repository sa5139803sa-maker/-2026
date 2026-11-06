import { useCallback, useEffect, useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { ArrowRight, Plus, RefreshCw, ShieldCheck, UsersRound } from "lucide-react-native";
import { Button, Card, StatusBadge, TextField } from "@/components/ui";
import { colors, radius, spacing, typography } from "@/constants/theme";
import { useAuth, type AppRole } from "@/lib/auth";
import { supabase } from "@/lib/supabase";

type EmployeeRole = "operator" | "collector" | "supervisor";
type OrganizationRole = Exclude<AppRole, "platform_admin">;
type Organization = { id: string; name: string; account_limit: number; account_count: number };
type ManagedUser = {
  id: string;
  display_name: string;
  username: string | null;
  role: OrganizationRole;
  must_change_password: boolean;
};
type ListData = { organization: Organization | null; users: ManagedUser[] };

const names: Record<OrganizationRole, string> = {
  manager: "مدير المؤسسة",
  operator: "مشغّل",
  collector: "محصّل",
  supervisor: "مشرف",
};

async function api(body: Record<string, unknown>) {
  const { data, error } = await supabase.functions.invoke("manage-accounts", { body });
  if (error) throw new Error("تعذر الاتصال بخدمة إدارة الحسابات.");
  if (data?.error) throw new Error(data.error);
  return data;
}

export default function AccountManagementScreen() {
  const { profile } = useAuth();
  const organizationId = profile?.organization_id ?? null;
  const [organization, setOrganization] = useState<Organization | null>(null);
  const [users, setUsers] = useState<ManagedUser[]>([]);
  const [username, setUsername] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [role, setRole] = useState<EmployeeRole>("operator");
  const [temporaryUsername, setTemporaryUsername] = useState<string | null>(null);
  const [temporaryPassword, setTemporaryPassword] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async (id: string) => {
    setBusy(true);
    setError(null);
    try {
      const data = await api({ action: "list_users", organization_id: id }) as ListData;
      setOrganization(data.organization);
      setUsers(data.users ?? []);
    } catch (e) {
      setError(e instanceof Error ? e.message : "تعذر تحميل حسابات المؤسسة.");
    } finally {
      setBusy(false);
    }
  }, []);

  useEffect(() => {
    if (profile?.role === "manager" && organizationId) void load(organizationId);
  }, [profile?.role, organizationId, load]);

  const create = async () => {
    if (!organizationId || !username.trim() || !displayName.trim()) {
      setError("أدخل اسم المستخدم والاسم الكامل.");
      return;
    }
    setBusy(true);
    setError(null);
    setNotice(null);
    setTemporaryPassword(null);
    try {
      const data = await api({
        action: "create_user",
        organization_id: organizationId,
        username,
        display_name: displayName,
        role,
      });
      setTemporaryUsername(data.username);
      setTemporaryPassword(data.temporary_password);
      setUsername("");
      setDisplayName("");
      await load(organizationId);
    } catch (e) {
      setError(e instanceof Error ? e.message : "تعذر إنشاء الحساب.");
    } finally {
      setBusy(false);
    }
  };

  const reset = async (user: ManagedUser) => {
    setBusy(true);
    setError(null);
    setNotice(null);
    setTemporaryPassword(null);
    try {
      const data = await api({ action: "reset_password", target_user_id: user.id });
      setTemporaryUsername(data.username ?? user.username ?? "بيانات الدخول");
      setTemporaryPassword(data.temporary_password);
      setNotice("تم إصدار كلمة مؤقتة جديدة. يجب على الموظف تغييرها عند الدخول التالي.");
      if (organizationId) await load(organizationId);
    } catch (e) {
      setError(e instanceof Error ? e.message : "تعذرت إعادة تعيين كلمة المرور.");
    } finally {
      setBusy(false);
    }
  };

  if (profile?.role !== "manager" || !organizationId) {
    return (
      <View style={styles.center}>
        <Text style={styles.error}>هذه الصفحة مخصصة لمدير المؤسسة فقط. إدارة المنصة متاحة عبر لوحة الويب.</Text>
        <Button label="العودة" variant="secondary" onPress={() => router.back()} />
      </View>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <View style={styles.header}>
        <View style={styles.heading}>
          <ShieldCheck color={colors.brand.teal} size={22} />
          <Text style={styles.title}>إدارة حسابات الموظفين</Text>
        </View>
        <Pressable onPress={() => router.back()} style={styles.back}>
          <ArrowRight color={colors.text.primary} size={20} />
        </Pressable>
      </View>

      <Text style={styles.subtitle}>إدارة حسابات موظفي مؤسستك فقط. إدارة المؤسسات ومديريها وحدودها تتم من لوحة إدارة المنصة عبر الويب.</Text>

      {error ? <Text style={styles.error}>{error}</Text> : null}
      {notice ? <Text style={styles.notice}>{notice}</Text> : null}

      {organization ? (
        <Card>
          <View style={styles.row}>
            <UsersRound color={colors.brand.primary} size={20} />
            <Text style={styles.section}>{organization.name}</Text>
          </View>
          <Text style={styles.quota}>{organization.account_count} / {organization.account_limit} حساب</Text>
          <Text style={styles.meta}>يشمل العدد مدير المؤسسة وجميع الموظفين. تعديل الحد متاح لمدير المنصة عبر الويب.</Text>
        </Card>
      ) : null}

      <Card>
        <Text style={styles.section}>إنشاء حساب موظف</Text>
        <TextField
          label="اسم المستخدم"
          value={username}
          onChangeText={setUsername}
          autoCapitalize="none"
          placeholder="مثال: operator01"
          helperText="حروف عربية أو إنجليزية وأرقام ونقطة وشرطة."
        />
        <TextField label="الاسم الكامل" value={displayName} onChangeText={setDisplayName} placeholder="اسم صاحب الحساب" />
        <Text style={styles.label}>نوع الحساب</Text>
        <View style={styles.roles}>
          {(["operator", "collector", "supervisor"] as const).map((item) => (
            <Pressable
              key={item}
              onPress={() => setRole(item)}
              style={[styles.role, role === item && styles.roleSelected]}
            >
              <Text style={styles.meta}>{names[item]}</Text>
            </Pressable>
          ))}
        </View>
        <Text style={styles.meta}>سيُنشأ الحساب بكلمة مرور مؤقتة يجب تغييرها عند أول دخول.</Text>
        <Button
          label="إنشاء الحساب"
          icon={<Plus color={colors.text.inverse} size={17} />}
          onPress={() => void create()}
          loading={busy}
          fullWidth
        />
      </Card>

      <Card>
        <Text style={styles.section}>حسابات المؤسسة</Text>
        {users.map((user) => (
          <View key={user.id} style={styles.user}>
            <View style={styles.flex}>
              <Text style={styles.item}>{user.display_name}</Text>
              <Text style={styles.meta}>{user.username ?? "دخول بالبريد"} · {names[user.role]}</Text>
              {user.must_change_password ? (
                <StatusBadge label="بانتظار تغيير كلمة المرور" status="warning" />
              ) : null}
            </View>
            {user.id !== profile.id && user.role !== "manager" ? (
              <Button
                label="إعادة تعيين"
                size="small"
                variant="secondary"
                icon={<RefreshCw color={colors.brand.primary} size={14} />}
                onPress={() => void reset(user)}
                disabled={busy}
              />
            ) : null}
          </View>
        ))}
        {users.length === 0 ? <Text style={styles.meta}>لا توجد حسابات موظفين لعرضها.</Text> : null}
      </Card>

      {temporaryPassword ? (
        <Card>
          <Text style={styles.section}>كلمة المرور المؤقتة</Text>
          <Text style={styles.meta}>تُعرض مرة واحدة فقط. سلّمها لصاحب الحساب عبر قناة آمنة.</Text>
          <Text selectable style={styles.password}>{temporaryUsername}: {temporaryPassword}</Text>
          <Button
            label="إخفاء كلمة المرور"
            variant="secondary"
            onPress={() => { setTemporaryPassword(null); setTemporaryUsername(null); }}
            fullWidth
          />
        </Card>
      ) : null}

      <Button
        label="تحديث القائمة"
        variant="ghost"
        icon={<RefreshCw color={colors.brand.primary} size={16} />}
        onPress={() => void load(organizationId)}
        disabled={busy}
        fullWidth
      />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: "rtl" },
  content: { padding: spacing.md, paddingTop: spacing.lg, paddingBottom: spacing.xxl, gap: spacing.md, maxWidth: 760, width: "100%", alignSelf: "center" },
  header: { flexDirection: "row-reverse", alignItems: "center", justifyContent: "space-between" },
  heading: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  title: { color: colors.text.primary, fontSize: 23, fontFamily: typography.fontFamily.bold },
  subtitle: { color: colors.text.secondary, fontSize: 12, lineHeight: 21, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  back: { width: 40, height: 40, borderRadius: 12, borderWidth: 1, borderColor: colors.border, alignItems: "center", justifyContent: "center", backgroundColor: colors.background.surface },
  section: { color: colors.text.primary, fontSize: 15, fontFamily: typography.fontFamily.bold, textAlign: "right" },
  row: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  flex: { flex: 1, alignItems: "flex-end", gap: 3 },
  item: { color: colors.text.primary, fontSize: 13, fontFamily: typography.fontFamily.bold, textAlign: "right" },
  meta: { color: colors.text.secondary, fontSize: 11, lineHeight: 18, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  quota: { color: colors.brand.primary, fontSize: 22, fontFamily: typography.fontFamily.bold, textAlign: "right", marginTop: spacing.sm },
  label: { color: colors.text.primary, fontSize: 12, fontFamily: typography.fontFamily.bold, textAlign: "right" },
  roles: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.xs },
  role: { borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.sm },
  roleSelected: { backgroundColor: colors.background.subtle, borderColor: colors.brand.primary },
  user: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm, borderTopWidth: 1, borderTopColor: colors.border, paddingVertical: spacing.sm },
  password: { fontSize: 16, color: colors.text.primary, fontFamily: typography.fontFamily.bold, backgroundColor: colors.background.subtle, padding: spacing.md, borderRadius: radius.md, textAlign: "center" },
  notice: { color: colors.status.success.text, backgroundColor: colors.status.success.background, padding: spacing.sm, borderRadius: radius.sm, textAlign: "right", fontFamily: typography.fontFamily.medium },
  error: { color: colors.status.danger.text, backgroundColor: colors.status.danger.background, padding: spacing.sm, borderRadius: radius.sm, textAlign: "right", fontFamily: typography.fontFamily.medium },
  center: { flex: 1, justifyContent: "center", alignItems: "stretch", gap: spacing.md, padding: spacing.lg, backgroundColor: colors.background.main },
});
