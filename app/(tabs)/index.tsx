import { useEffect, useState } from "react";
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from "react-native";
import { Activity, CalendarDays, Clock3, Droplets, Users } from "lucide-react-native";
import { BrandMark } from "@/components/BrandMark";
import { SectionTitle, StatCard, StatusBadge } from "@/components/UI";
import { Card } from "@/components/ui";
import { colors, radius, spacing } from "@/constants/theme";
import { useAuth } from "@/lib/auth";
import { supabase } from "@/lib/supabase";
import { canAccessFeature } from "@/lib/permissions";

type Pump = { id: string; name: string; code: string };
type Operation = {
  id: string;
  pump_id: string;
  subscriber_name: string;
  status: "running" | "paused" | "completed";
  started_at: string;
  ended_at: string | null;
  actual_seconds: number | null;
  operation_date: string;
};

type DailyBucket = { date: string; label: string; count: number };
type RecentOperation = Operation & { pump_name: string };

function localDateKey(date: Date) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Hebron",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function createWeekBuckets(): DailyBucket[] {
  return Array.from({ length: 7 }, (_, index) => {
    const date = new Date(Date.now() - (6 - index) * 24 * 60 * 60 * 1000);
    return {
      date: localDateKey(date),
      label: date.toLocaleDateString("ar-PS", { timeZone: "Asia/Hebron", weekday: "short" }),
      count: 0,
    };
  });
}

function formatTime(value: string) {
  return new Date(value).toLocaleTimeString("ar-PS", {
    timeZone: "Asia/Hebron",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function formatDuration(seconds: number | null) {
  if (seconds === null) return "—";
  const safe = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(safe / 3600);
  const minutes = Math.floor((safe % 3600) / 60);
  const remainingSeconds = safe % 60;
  if (hours > 0) return `${hours}س ${minutes}د`;
  if (minutes > 0) return `${minutes}د ${remainingSeconds}ث`;
  return `${remainingSeconds}ث`;
}

function operationStatus(status: Operation["status"]) {
  if (status === "completed") return { label: "مكتملة", tone: "success" as const };
  if (status === "paused") return { label: "متوقفة مؤقتًا", tone: "warning" as const };
  return { label: "قيد التشغيل", tone: "info" as const };
}

export default function DashboardScreen() {
  const { profile } = useAuth();
  const canViewOperations = canAccessFeature(profile?.role, "operations");
  const canViewOrganizationStats = canAccessFeature(profile?.role, "dashboardStats");
  const [stats, setStats] = useState({ pumps: 0, subscribers: 0, todayOperations: 0, activeOperations: 0 });
  const [dailyOperations, setDailyOperations] = useState<DailyBucket[]>([]);
  const [recentOperations, setRecentOperations] = useState<RecentOperation[]>([]);
  const [loading, setLoading] = useState(true);
  const [dataError, setDataError] = useState<string | null>(null);

  useEffect(() => {
    if (!profile?.organization_id || !canViewOperations) {
      setStats({ pumps: 0, subscribers: 0, todayOperations: 0, activeOperations: 0 });
      setDailyOperations([]);
      setRecentOperations([]);
      setDataError(null);
      setLoading(false);
      return;
    }

    let active = true;
    const loadDashboard = async () => {
      setLoading(true);
      setDataError(null);
      const week = createWeekBuckets();
      const today = localDateKey(new Date());
      const weekStart = week[0]?.date ?? today;

      try {
        const [pumpsResult, subscribersResult, operationsResult] = await Promise.all([
          supabase
            .from("pumps")
            .select("id,name,code")
            .eq("organization_id", profile.organization_id as string)
            .order("created_at", { ascending: true }),
          supabase
            .from("subscribers")
            .select("id", { count: "exact", head: true })
            .eq("organization_id", profile.organization_id as string)
            .eq("is_active", true),
          supabase
            .from("pump_operations")
            .select("id,pump_id,subscriber_name,status,started_at,ended_at,actual_seconds,operation_date")
            .eq("organization_id", profile.organization_id as string)
            .or(`operation_date.gte.${weekStart},status.in.(running,paused)`)
            .order("started_at", { ascending: false })
            .limit(5000),
        ]);

        if (!active) return;
        if (pumpsResult.error || subscribersResult.error || operationsResult.error) {
          console.error("dashboard data load failed", pumpsResult.error ?? subscribersResult.error ?? operationsResult.error);
          setStats({ pumps: 0, subscribers: 0, todayOperations: 0, activeOperations: 0 });
          setDailyOperations([]);
          setRecentOperations([]);
          setDataError("تعذر تحميل بيانات لوحة المتابعة. حدّث الصفحة وحاول مرة أخرى.");
          return;
        }

        const pumps = (pumpsResult.data ?? []) as Pump[];
        const operations = (operationsResult.data ?? []) as Operation[];
        const pumpNames = new Map(pumps.map((pump) => [pump.id, pump.name]));
        const todayOperations = operations.filter((operation) => operation.operation_date === today);
        const activeOperations = operations.filter(
          (operation) => operation.status === "running" || operation.status === "paused",
        );

        setStats({
          pumps: pumps.length,
          subscribers: subscribersResult.count ?? 0,
          todayOperations: todayOperations.length,
          activeOperations: activeOperations.length,
        });
        setDailyOperations(week.map((bucket) => ({
          ...bucket,
          count: operations.filter((operation) => operation.operation_date === bucket.date).length,
        })));
        setRecentOperations(operations.slice(0, 6).map((operation) => ({
          ...operation,
          pump_name: pumpNames.get(operation.pump_id) ?? "غطاس",
        })));
      } catch (loadError) {
        console.error("dashboard request failed", loadError);
        if (!active) return;
        setStats({ pumps: 0, subscribers: 0, todayOperations: 0, activeOperations: 0 });
        setDailyOperations([]);
        setRecentOperations([]);
        setDataError("تعذر الاتصال ببيانات التشغيل. تحقق من الاتصال ثم حدّث الصفحة.");
      } finally {
        if (active) setLoading(false);
      }
    };

    void loadDashboard();
    return () => { active = false; };
  }, [profile?.organization_id, canViewOperations]);

  const maxDailyCount = Math.max(1, ...dailyOperations.map((day) => day.count));

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
      <View style={styles.header}>
        <BrandMark compact />
        <View style={styles.headerActions}>
          <StatusBadge label="بيانات التشغيل" status="info" />
          <View style={styles.avatar}>
            <Text style={styles.avatarText}>{profile?.display_name?.slice(0, 1) ?? "م"}</Text>
          </View>
        </View>
      </View>

      <View style={styles.welcome}>
        <View>
          <Text style={styles.eyebrow}>لوحة المؤسسة</Text>
          <Text style={styles.title}>مرحباً، {profile?.display_name ?? "مستخدم"}</Text>
          <Text style={styles.subtitle}>ملخص العمليات المسجلة في نطاق صلاحيات حسابك</Text>
        </View>
        <CalendarDays color={colors.brand.teal} size={27} />
      </View>

      {dataError ? <Text style={styles.dataError}>{dataError}</Text> : null}

      {canViewOperations ? (
        <>
          <View style={styles.stats}>
            <StatCard
              label={canViewOrganizationStats ? "غواطس المؤسسة" : "الغواطس المخصصة"}
              value={loading ? "…" : String(stats.pumps)}
              caption={canViewOrganizationStats ? "جميع غواطس المؤسسة" : "الغواطس ضمن تعيينك"}
              icon={<Droplets size={20} color={colors.brand.primary} />}
              tone="info"
            />
            <StatCard
              label="المشتركون النشطون"
              value={loading ? "…" : String(stats.subscribers)}
              caption="ضمن نطاق الغواطس المتاحة"
              icon={<Users size={20} color={colors.status.info.main} />}
              tone="info"
            />
            <StatCard
              label="عمليات اليوم"
              value={loading ? "…" : String(stats.todayOperations)}
              caption="جلسات بدأ تسجيلها اليوم"
              icon={<Activity size={20} color={colors.status.success.main} />}
              tone="success"
            />
            <StatCard
              label="عمليات جارية"
              value={loading ? "…" : String(stats.activeOperations)}
              caption="تشغيل أو إيقاف مؤقت"
              icon={<Clock3 size={20} color={colors.status.warning.main} />}
              tone="warning"
            />
          </View>

          <Card style={styles.chartCard} padded={false}>
            <View style={styles.sectionHeading}>
              <SectionTitle title="حركة التشغيل خلال آخر 7 أيام" />
              <Text style={styles.chartUnit}>عدد العمليات</Text>
            </View>
            {loading ? (
              <View style={styles.loadingState}><ActivityIndicator color={colors.brand.teal} /></View>
            ) : dailyOperations.length === 0 || dailyOperations.every((day) => day.count === 0) ? (
              <Text style={styles.emptyText}>لا توجد عمليات مسجلة خلال الأيام السبعة الماضية.</Text>
            ) : (
              <>
                <View style={styles.chart}>
                  {dailyOperations.map((day) => (
                    <View style={styles.chartColumn} key={day.date}>
                      <Text style={styles.chartValue}>{day.count}</Text>
                      <View
                        style={[
                          styles.chartBar,
                          {
                            height: day.count === 0 ? 3 : Math.max(8, Math.round((day.count / maxDailyCount) * 112)),
                            backgroundColor: day.date === localDateKey(new Date()) ? colors.brand.primary : colors.brand.teal,
                          },
                        ]}
                      />
                    </View>
                  ))}
                </View>
                <View style={styles.chartLabels}>
                  {dailyOperations.map((day) => (
                    <Text key={day.date} style={styles.chartLabel}>{day.label}</Text>
                  ))}
                </View>
              </>
            )}
          </Card>

          <Card style={styles.listCard} padded={false}>
            <View style={styles.sectionHeading}>
              <SectionTitle title="أحدث العمليات" />
              <Text style={styles.chartUnit}>آخر 6 عمليات</Text>
            </View>
            {loading ? (
              <View style={styles.loadingState}><ActivityIndicator color={colors.brand.teal} /></View>
            ) : recentOperations.length === 0 ? (
              <Text style={styles.emptyText}>لم تُسجّل عمليات بعد. ستظهر هنا بمجرد بدء أول تعبئة.</Text>
            ) : recentOperations.map((operation) => {
              const state = operationStatus(operation.status);
              return (
                <View style={styles.activity} key={operation.id}>
                  <View style={styles.activityIcon}><Droplets size={17} color={colors.brand.teal} /></View>
                  <View style={styles.activityBody}>
                    <Text style={styles.activityTitle}>{operation.subscriber_name}</Text>
                    <Text style={styles.activityMeta}>{operation.pump_name} · {formatDuration(operation.actual_seconds)}</Text>
                  </View>
                  <View style={styles.activityEnd}>
                    <Text style={styles.time}>{formatTime(operation.started_at)}</Text>
                    <StatusBadge label={state.label} status={state.tone} />
                  </View>
                </View>
              );
            })}
          </Card>
        </>
      ) : (
        <Card style={styles.listCard}>
          <SectionTitle title="لوحة المتابعة" />
          <Text style={styles.emptyText}>
            لا تتضمن صلاحية حسابك عرض مؤشرات التشغيل. استخدم شاشة التقارير عند توفر نطاق تقارير الدور الخاص بك.
          </Text>
        </Card>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: "rtl" },
  content: { padding: spacing.md, paddingTop: spacing.lg, gap: spacing.md, maxWidth: 1100, width: "100%", alignSelf: "center" },
  header: { flexDirection: "row-reverse", alignItems: "center", justifyContent: "space-between" },
  headerActions: { flexDirection: "row", alignItems: "center", gap: spacing.md },
  avatar: { width: 34, height: 34, borderRadius: 17, backgroundColor: colors.brand.primary, alignItems: "center", justifyContent: "center" },
  avatarText: { color: colors.text.inverse, fontFamily: "IBMPlexSansArabic_700Bold" },
  welcome: { backgroundColor: colors.brand.navy, borderRadius: radius.lg, padding: spacing.lg, flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center" },
  eyebrow: { color: "#B7DDE4", fontSize: 12, fontFamily: "IBMPlexSansArabic_500Medium", marginBottom: 4 },
  title: { color: colors.text.inverse, fontSize: 25, fontFamily: "IBMPlexSansArabic_700Bold" },
  subtitle: { color: "#C3D4DC", fontSize: 12, fontFamily: "IBMPlexSansArabic_400Regular", marginTop: 4, textAlign: "right" },
  stats: { flexDirection: "row", gap: spacing.sm, flexWrap: "wrap" },
  dataError: { color: colors.status.danger.text, backgroundColor: colors.status.danger.background, borderRadius: radius.sm, padding: spacing.sm, fontSize: 12, fontFamily: "IBMPlexSansArabic_500Medium", textAlign: "right" },
  chartCard: { padding: spacing.md },
  sectionHeading: { flexDirection: "row-reverse", alignItems: "center", justifyContent: "space-between", gap: spacing.sm },
  chartUnit: { color: colors.text.secondary, fontSize: 10, fontFamily: "IBMPlexSansArabic_400Regular" },
  chart: { height: 160, flexDirection: "row-reverse", alignItems: "flex-end", justifyContent: "space-around", paddingHorizontal: spacing.sm, borderBottomWidth: 1, borderBottomColor: colors.border },
  chartColumn: { flex: 1, height: "100%", alignItems: "center", justifyContent: "flex-end", gap: 5 },
  chartValue: { color: colors.text.secondary, fontSize: 10, fontFamily: "IBMPlexSansArabic_500Medium", fontVariant: ["tabular-nums"] },
  chartBar: { width: 24, maxWidth: "70%", borderTopLeftRadius: 6, borderTopRightRadius: 6 },
  chartLabels: { flexDirection: "row-reverse", justifyContent: "space-around", marginTop: spacing.sm },
  chartLabel: { color: colors.text.secondary, fontSize: 10, fontFamily: "IBMPlexSansArabic_400Regular" },
  listCard: { padding: spacing.md },
  loadingState: { minHeight: 100, alignItems: "center", justifyContent: "center" },
  emptyText: { color: colors.text.secondary, fontSize: 12, lineHeight: 22, fontFamily: "IBMPlexSansArabic_400Regular", textAlign: "right", paddingVertical: spacing.md },
  activity: { minHeight: 62, flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm, borderTopWidth: 1, borderTopColor: colors.background.subtle },
  activityIcon: { width: 36, height: 36, borderRadius: 10, alignItems: "center", justifyContent: "center", backgroundColor: colors.background.subtle },
  activityBody: { flex: 1, alignItems: "flex-end" },
  activityTitle: { color: colors.text.primary, fontSize: 13, fontFamily: "IBMPlexSansArabic_700Bold" },
  activityMeta: { color: colors.text.secondary, fontSize: 11, fontFamily: "IBMPlexSansArabic_400Regular", marginTop: 2 },
  activityEnd: { alignItems: "flex-end", gap: 4 },
  time: { color: colors.text.secondary, fontSize: 10, fontFamily: "IBMPlexSansArabic_400Regular" },
});
