import { useCallback, useEffect, useMemo, useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { router } from "expo-router";
import { ArrowRight, CalendarDays, FileText, RefreshCw } from "lucide-react-native";
import { colors, radius, spacing, typography } from "@/constants/theme";
import { useAuth } from "@/lib/auth";
import {
  pumpOperationsRepository,
  type DailyWorkReportDetails,
  type OperationPump,
} from "@/lib/repositories/pump-operations";

const datePattern = /^\d{4}-\d{2}-\d{2}$/;

function formatLocalTime(value: string) {
  return new Intl.DateTimeFormat("ar", {
    timeZone: "Asia/Hebron",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

function formatDateTime(value: string) {
  return new Intl.DateTimeFormat("ar", {
    timeZone: "Asia/Hebron",
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(value));
}

function formatMinutes(value: number) {
  const minutes = Math.max(0, Number(value) || 0);
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  if (hours === 0) return `${remainder} دقيقة`;
  if (remainder === 0) return `${hours} ساعة`;
  return `${hours} ساعة و${remainder} دقيقة`;
}

function statusLabel(status: DailyWorkReportDetails["status"]) {
  return status === "submitted" ? "معتمد" : "مسودة";
}

function eventLabel(eventType: DailyWorkReportDetails["events"][number]["event_type"]) {
  if (eventType === "draft_created") return "إنشاء مسودة التقرير";
  if (eventType === "draft_updated") return "تعديل مسودة التقرير";
  return "اعتماد التقرير وإرساله";
}

export default function ReportsScreen() {
  const { profile } = useAuth();
  const organizationId = profile?.organization_id ?? null;
  const [pumps, setPumps] = useState<OperationPump[]>([]);
  const [selectedPumpId, setSelectedPumpId] = useState("");
  const [workDate, setWorkDate] = useState(() => new Date().toLocaleDateString("en-CA", { timeZone: "Asia/Hebron" }));
  const [report, setReport] = useState<DailyWorkReportDetails | null>(null);
  const [pumpsLoading, setPumpsLoading] = useState(true);
  const [reportLoading, setReportLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const loadPumps = async () => {
      if (!organizationId) {
        setPumpsLoading(false);
        return;
      }
      setPumpsLoading(true);
      const result = await pumpOperationsRepository.listPumps(organizationId);
      if (cancelled) return;
      if (result.error) {
        setError("تعذر تحميل قائمة الغواطس المسموح بها لهذا الحساب.");
        setPumps([]);
      } else {
        const rows = (result.data ?? []) as OperationPump[];
        setPumps(rows);
        setSelectedPumpId((current) => current && rows.some((pump) => pump.id === current) ? current : rows[0]?.id ?? "");
      }
      setPumpsLoading(false);
    };
    void loadPumps();
    return () => { cancelled = true; };
  }, [organizationId]);

  const loadReport = useCallback(async () => {
    if (!organizationId || !selectedPumpId || !datePattern.test(workDate)) {
      setReport(null);
      return;
    }
    setReportLoading(true);
    setError(null);
    setNotice(null);
    const { data, error: loadError } = await pumpOperationsRepository.getDailyWorkReport(
      organizationId,
      selectedPumpId,
      workDate,
    );
    if (loadError) {
      console.error("daily work report read failed", loadError);
      setReport(null);
      setError("تعذر تحميل التقرير. قد لا تكون ترحيلات التقارير قد طُبقت على قاعدة البيانات بعد.");
    } else {
      setReport(data as DailyWorkReportDetails | null);
      setNotice(data ? "تم تحميل تفاصيل تقرير اليوم." : "لا يوجد تقرير محفوظ لهذا الغطاس في التاريخ المحدد.");
    }
    setReportLoading(false);
  }, [organizationId, selectedPumpId, workDate]);

  useEffect(() => {
    void loadReport();
  }, [loadReport]);

  const durationMinutes = useMemo(() => {
    if (!report) return 0;
    return Math.max(0, Math.floor(
      (new Date(report.work_ended_at).getTime() - new Date(report.work_started_at).getTime()) / 60000,
    ));
  }, [report]);

  const sourceMinutes = useMemo(
    () => report?.sourceTotals.reduce((sum, source) => sum + source.minutes, 0) ?? 0,
    [report],
  );

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
      <View style={styles.header}>
        <Pressable accessibilityRole="button" onPress={() => router.back()} style={styles.backButton}>
          <ArrowRight size={20} color={colors.text.primary} />
        </Pressable>
        <View style={styles.headerText}>
          <Text style={styles.eyebrow}>إدارة المياه</Text>
          <Text style={styles.title}>التقارير التشغيلية</Text>
          <Text style={styles.subtitle}>تفاصيل العمل اليومي ومصادر الكهرباء وتعبئة المشتركين</Text>
        </View>
        <View style={styles.headerIcon}><FileText size={22} color={colors.brand.primary} /></View>
      </View>

      {error ? <Text style={styles.error} accessibilityRole="alert">{error}</Text> : null}
      {notice ? <Text style={styles.notice}>{notice}</Text> : null}

      <View style={styles.card}>
        <Text style={styles.sectionTitle}>تحديد التقرير</Text>
        <Text style={styles.fieldLabel}>الغطاس</Text>
        {pumpsLoading ? <ActivityIndicator color={colors.brand.teal} /> : pumps.length === 0 ? (
          <Text style={styles.muted}>لا توجد غواطس متاحة لهذا الحساب.</Text>
        ) : (
          <View style={styles.pumpChoices}>
            {pumps.map((pump) => (
              <Pressable key={pump.id} onPress={() => setSelectedPumpId(pump.id)}
                style={[styles.pumpChoice, selectedPumpId === pump.id && styles.pumpChoiceSelected]}>
                <Text style={[styles.pumpChoiceText, selectedPumpId === pump.id && styles.pumpChoiceTextSelected]}>
                  {pump.name}
                </Text>
                <Text style={[styles.pumpChoiceCode, selectedPumpId === pump.id && styles.pumpChoiceTextSelected]}>
                  {pump.code}
                </Text>
              </Pressable>
            ))}
          </View>
        )}
        <Text style={styles.fieldLabel}>تاريخ العمل</Text>
        <View style={styles.dateRow}>
          <CalendarDays size={18} color={colors.brand.primary} />
          <TextInput value={workDate} onChangeText={setWorkDate} placeholder="YYYY-MM-DD"
            style={styles.dateInput} autoCapitalize="none" accessibilityLabel="تاريخ التقرير" />
          <Pressable onPress={() => void loadReport()} disabled={reportLoading || !datePattern.test(workDate)}
            style={[styles.refreshButton, (reportLoading || !datePattern.test(workDate)) && styles.disabled]}>
            <RefreshCw size={16} color={colors.brand.primary} />
            <Text style={styles.refreshText}>عرض</Text>
          </Pressable>
        </View>
      </View>

      {reportLoading ? (
        <View style={styles.loading}><ActivityIndicator color={colors.brand.teal} /><Text style={styles.muted}>جاري تحميل التقرير...</Text></View>
      ) : report ? (
        <>
          <View style={styles.card}>
            <View style={styles.sectionHeader}>
              <Text style={styles.sectionTitle}>ملخص يوم العمل</Text>
              <View style={[styles.statusPill, report.status === "submitted" ? styles.statusSubmitted : styles.statusDraft]}>
                <Text style={[styles.statusText, report.status === "submitted" ? styles.statusSubmittedText : styles.statusDraftText]}>
                  {statusLabel(report.status)}
                </Text>
              </View>
            </View>
            <View style={styles.summaryGrid}>
              <Summary label="بداية العمل" value={formatLocalTime(report.work_started_at)} />
              <Summary label="نهاية العمل" value={formatLocalTime(report.work_ended_at)} />
              <Summary label="إجمالي وقت الدوام" value={formatMinutes(durationMinutes)} />
              <Summary label="مجموع التوقفات" value={formatMinutes(report.stoppage_minutes)} />
              <Summary label="وقت التشغيل الصافي" value={formatMinutes(Math.max(0, durationMinutes - report.stoppage_minutes))} />
              <Summary label="مجموع وقت المصادر" value={formatMinutes(sourceMinutes)} />
            </View>
            <Text style={styles.smallNote}>تاريخ العمل: {report.work_date}</Text>
            {report.submitted_at ? <Text style={styles.smallNote}>اعتمد في: {formatDateTime(report.submitted_at)}</Text> : null}
          </View>

          <View style={styles.card}>
            <View style={styles.sectionHeader}>
              <Text style={styles.sectionTitle}>توزيع مصادر الكهرباء</Text>
              <Text style={styles.sectionMeta}>الدقائق</Text>
            </View>
            {report.sourceTotals.length === 0 ? <Text style={styles.muted}>لا توجد تفاصيل مصادر مسجلة.</Text> : (
              <>
                {report.sourceTotals.map((source) => (
                  <View key={source.id} style={styles.dataRow}>
                    <Text style={styles.dataValue}>{formatMinutes(source.minutes)}</Text>
                    <Text style={styles.dataLabel}>{source.source_name_snapshot}</Text>
                  </View>
                ))}
                <View style={[styles.dataRow, styles.totalRow]}>
                  <Text style={styles.totalValue}>{formatMinutes(sourceMinutes)}</Text>
                  <Text style={styles.totalLabel}>الإجمالي النهائي لمصادر الكهرباء</Text>
                </View>
              </>
            )}
            <Text style={styles.smallNote}>عند اعتماد الاستبيان، يعتمد هذا الإجمالي بدل جمعه مرة أخرى فوق فترات التشغيل الآلية.</Text>
          </View>

          <View style={styles.card}>
            <View style={styles.sectionHeader}>
              <Text style={styles.sectionTitle}>تفاصيل تعبئة المشتركين</Text>
              <Text style={styles.sectionMeta}>{report.items.length} بند</Text>
            </View>
            {report.items.length === 0 ? <Text style={styles.muted}>لا توجد بنود تعبئة مسجلة في التقرير.</Text> : report.items.map((item, index) => {
              const delivered = item.app_recorded_minutes + item.manual_minutes;
              const totalWithExtra = delivered + item.extra_minutes;
              const remaining = item.entry_type === "weekly"
                ? Math.max(0, item.scheduled_minutes - item.weekly_minutes_consumed)
                : 0;
              const name = item.subscriber_name_snapshot ?? item.external_beneficiary_name ?? "مشترك إضافي";
              return (
                <View key={item.id} style={styles.reportItem}>
                  <View style={styles.itemHeader}>
                    <Text style={styles.itemIndex}>{index + 1}</Text>
                    <View style={styles.itemTitleBlock}>
                      <Text style={styles.itemName}>{name}</Text>
                      <Text style={styles.itemType}>
                        {item.entry_type === "weekly" ? "حصة أسبوعية" : "حصة إضافية"}
                        {" · "}
                        {item.fulfillment_status === "complete" ? "مكتملة"
                          : item.fulfillment_status === "partial" ? "جزئية"
                            : item.fulfillment_status === "not_done" ? "لم تتم" : "إضافية"}
                      </Text>
                    </View>
                  </View>
                  <View style={styles.metricsGrid}>
                    {item.entry_type === "weekly" ? <Metric label="المقرر" value={item.scheduled_minutes} /> : null}
                    <Metric label="مسجل آليًا" value={item.app_recorded_minutes} />
                    <Metric label="موثق يدويًا" value={item.manual_minutes} />
                    <Metric label="المستهلك من الأسبوعي" value={item.weekly_minutes_consumed} />
                    <Metric label="المتبقي" value={remaining} />
                    <Metric label="إضافي" value={item.extra_minutes} />
                    <Metric label="إجمالي المنفذ" value={totalWithExtra} />
                  </View>
                  {item.app_over_quota_minutes > 0 ? (
                    <Text style={styles.warningNote}>تجاوز مسجل آليًا/يدويًا للحصة الأساسية: {item.app_over_quota_minutes} دقيقة؛ يراجع ضمن الإضافي.</Text>
                  ) : null}
                </View>
              );
            })}
          </View>

          <View style={styles.card}>
            <Text style={styles.sectionTitle}>سجل إجراءات التقرير</Text>
            {report.events.length === 0 ? <Text style={styles.muted}>لا توجد أحداث تدقيق.</Text> : report.events.map((event) => (
              <View key={event.id} style={styles.dataRow}>
                <View style={styles.eventBody}>
                  <Text style={styles.dataLabel}>{eventLabel(event.event_type)}</Text>
                  <Text style={styles.smallNote}>{formatDateTime(event.occurred_at)}</Text>
                </View>
              </View>
            ))}
          </View>
        </>
      ) : (
        <View style={styles.emptyCard}>
          <FileText size={28} color={colors.text.secondary} />
          <Text style={styles.emptyTitle}>لا يوجد تقرير محفوظ</Text>
          <Text style={styles.muted}>اختر الغطاس والتاريخ. بعد حفظ مسودة أو اعتماد استبيان عمل اليوم سيظهر هنا التفصيل الكامل.</Text>
        </View>
      )}
    </ScrollView>
  );
}

function Summary({ label, value }: { label: string; value: string }) {
  return (
    <View style={styles.summaryCell}>
      <Text style={styles.summaryLabel}>{label}</Text>
      <Text style={styles.summaryValue}>{value}</Text>
    </View>
  );
}

function Metric({ label, value }: { label: string; value: number }) {
  return (
    <View style={styles.metric}>
      <Text style={styles.metricValue}>{value}</Text>
      <Text style={styles.metricLabel}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: "rtl" },
  content: { padding: spacing.md, paddingTop: spacing.lg, gap: spacing.md, maxWidth: 900, width: "100%", alignSelf: "center" },
  header: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  backButton: { width: 40, height: 40, borderRadius: radius.md, backgroundColor: colors.background.surface, alignItems: "center", justifyContent: "center" },
  headerText: { flex: 1, alignItems: "flex-end" },
  eyebrow: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  title: { color: colors.text.primary, fontSize: typography.fontSize.xl, fontFamily: typography.fontFamily.bold },
  subtitle: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  headerIcon: { width: 42, height: 42, borderRadius: radius.md, backgroundColor: colors.background.subtle, alignItems: "center", justifyContent: "center" },
  card: { backgroundColor: colors.background.surface, borderRadius: radius.lg, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  sectionHeader: { flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center" },
  sectionTitle: { color: colors.text.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold, textAlign: "right" },
  sectionMeta: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  fieldLabel: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  pumpChoices: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.xs },
  pumpChoice: { backgroundColor: colors.background.subtle, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, padding: spacing.sm, minWidth: 110, alignItems: "center" },
  pumpChoiceSelected: { backgroundColor: colors.brand.primary, borderColor: colors.brand.primary },
  pumpChoiceText: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.medium },
  pumpChoiceTextSelected: { color: colors.text.inverse },
  pumpChoiceCode: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  dateRow: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  dateInput: { flex: 1, minHeight: 44, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.sm, color: colors.text.primary, textAlign: "right", fontFamily: typography.fontFamily.regular },
  refreshButton: { flexDirection: "row-reverse", alignItems: "center", gap: 5, minHeight: 42, paddingHorizontal: spacing.sm, borderRadius: radius.md, backgroundColor: colors.background.subtle },
  refreshText: { color: colors.brand.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.medium },
  disabled: { opacity: 0.45 },
  loading: { flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.sm, padding: spacing.xl },
  summaryGrid: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.sm },
  summaryCell: { width: "48%", minHeight: 65, padding: spacing.sm, borderRadius: radius.md, backgroundColor: colors.background.subtle, alignItems: "flex-end", justifyContent: "center" },
  summaryLabel: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  summaryValue: { color: colors.text.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold },
  smallNote: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  statusPill: { paddingHorizontal: spacing.sm, paddingVertical: 5, borderRadius: radius.pill },
  statusSubmitted: { backgroundColor: colors.status.success.background },
  statusDraft: { backgroundColor: colors.status.warning.background },
  statusText: { fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.bold },
  statusSubmittedText: { color: colors.status.success.text },
  statusDraftText: { color: colors.status.warning.text },
  dataRow: { flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center", paddingVertical: spacing.sm, borderBottomWidth: 1, borderBottomColor: colors.border },
  dataLabel: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  dataValue: { color: colors.brand.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  totalRow: { borderBottomWidth: 0, borderTopWidth: 1, borderTopColor: colors.border },
  totalLabel: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  totalValue: { color: colors.brand.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold },
  reportItem: { paddingVertical: spacing.sm, borderBottomWidth: 1, borderBottomColor: colors.border, gap: spacing.xs },
  itemHeader: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  itemIndex: { width: 28, height: 28, borderRadius: 14, backgroundColor: colors.background.subtle, textAlign: "center", textAlignVertical: "center", color: colors.text.primary, fontFamily: typography.fontFamily.bold },
  itemTitleBlock: { flex: 1, alignItems: "flex-end" },
  itemName: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  itemType: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  metricsGrid: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.xs },
  metric: { flexGrow: 1, minWidth: 82, backgroundColor: colors.background.subtle, padding: spacing.xs, borderRadius: radius.md, alignItems: "center" },
  metricValue: { color: colors.brand.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  metricLabel: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, textAlign: "center" },
  warningNote: { color: colors.status.warning.text, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  eventBody: { flex: 1, alignItems: "flex-end" },
  emptyCard: { backgroundColor: colors.background.surface, borderRadius: radius.lg, padding: spacing.xl, alignItems: "center", gap: spacing.sm, borderWidth: 1, borderColor: colors.border },
  emptyTitle: { color: colors.text.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold },
  muted: { color: colors.text.secondary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  error: { color: colors.status.danger.text, backgroundColor: colors.status.danger.background, padding: spacing.sm, borderRadius: radius.md, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  notice: { color: colors.status.success.text, backgroundColor: colors.status.success.background, padding: spacing.sm, borderRadius: radius.md, fontFamily: typography.fontFamily.medium, textAlign: "right" },
});
