import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { CheckCircle2, Clock3, Droplets, Pause, Play, RefreshCw, Waves } from "lucide-react-native";
import { SectionTitle, StatusBadge } from "@/components/UI";
import { Card, RoleGate } from "@/components/ui";
import { colors, radius, spacing, typography } from "@/constants/theme";
import { useAuth } from "@/lib/auth";
import { supabase } from "@/lib/supabase";

type Pump = { id: string; name: string; code: string; status: "active" | "paused" | "maintenance" | "inactive" };
type Subscriber = { id: string; full_name: string; subscriber_number: number; pump_id: string; created_at: string };
type Operation = {
  id: string;
  pump_id: string;
  subscriber_id: string | null;
  subscriber_name: string;
  planned_minutes: number;
  status: "running" | "paused" | "completed";
  started_at: string;
  paused_at: string | null;
  paused_seconds: number;
  ended_at: string | null;
  actual_seconds: number | null;
  operation_date: string;
};

function localOperationDate() {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Hebron",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function formatClock(seconds: number) {
  const safe = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(safe / 3600);
  const minutes = Math.floor((safe % 3600) / 60);
  const secs = safe % 60;
  return [hours, minutes, secs].map((part) => String(part).padStart(2, "0")).join(":");
}

function formatTime(value: string | null) {
  if (!value) return "—";
  return new Date(value).toLocaleTimeString("ar-PS", { hour: "2-digit", minute: "2-digit" });
}

function friendlyError(error: { code?: string; message?: string }) {
  if (error.code === "23505") return "يوجد تشغيل قائم بالفعل على هذا الغطاس.";
  if (error.code === "42501") return "ليس لديك صلاحية التشغيل على هذا الغطاس.";
  if (error.code === "P0002") return "تغيّرت حالة العملية. حدّث الشاشة وحاول مجددًا.";
  if (error.code === "22023") return "تحقق من بيانات المشترك ومدة التعبئة.";
  return "تعذر تنفيذ العملية. تحقق من الاتصال ثم أعد المحاولة.";
}

export default function OperationsScreen() {
  return (
    <RoleGate feature="operations" featureName="التشغيل">
      <OperationsScreenContent />
    </RoleGate>
  );
}

function OperationsScreenContent() {
  const { profile } = useAuth();
  const organizationId = profile?.organization_id ?? null;
  const [pumps, setPumps] = useState<Pump[]>([]);
  const [selectedPumpId, setSelectedPumpId] = useState("");
  const [subscribers, setSubscribers] = useState<Subscriber[]>([]);
  const [operations, setOperations] = useState<Operation[]>([]);
  const [minutes, setMinutes] = useState("30");
  const [emergencyName, setEmergencyName] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const [dataPumpId, setDataPumpId] = useState<string | null>(null);
  const dataRequestSequence = useRef(0);

  const selectedPump = useMemo(
    () => pumps.find((pump) => pump.id === selectedPumpId) ?? null,
    [pumps, selectedPumpId],
  );
  const activeOperation = useMemo(
    () => operations.find((operation) => operation.status === "running" || operation.status === "paused") ?? null,
    [operations],
  );
  const completedSubscriberIds = useMemo(
    () => new Set(operations.filter((operation) => operation.status === "completed" && operation.subscriber_id)
      .map((operation) => operation.subscriber_id as string)),
    [operations],
  );
  const queue = useMemo(
    () => subscribers.filter((subscriber) => !completedSubscriberIds.has(subscriber.id)),
    [subscribers, completedSubscriberIds],
  );
  const completedOperations = useMemo(
    () => operations.filter((operation) => operation.status === "completed"),
    [operations],
  );

  const loadPumps = useCallback(async () => {
    if (!organizationId) {
      setPumps([]);
      setSelectedPumpId("");
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    const { data, error: queryError } = await supabase
      .from("pumps")
      .select("id,name,code,status")
      .eq("organization_id", organizationId)
      .order("created_at", { ascending: true });
    if (queryError) {
      console.error("operation pumps load failed", queryError);
      setPumps([]);
      setError("تعذر تحميل الغواطس المسموح بها لحسابك.");
    } else {
      const rows = (data ?? []) as Pump[];
      setPumps(rows);
      setSelectedPumpId((current) => rows.some((pump) => pump.id === current) ? current : rows[0]?.id ?? "");
    }
    setLoading(false);
  }, [organizationId]);

  const loadPumpData = useCallback(async () => {
    if (!selectedPumpId || !organizationId) {
      dataRequestSequence.current += 1;
      setSubscribers([]);
      setOperations([]);
      setDataPumpId(null);
      setRefreshing(false);
      return;
    }
    const requestId = ++dataRequestSequence.current;
    setDataPumpId(null);
    setRefreshing(true);
    setError(null);
    const day = localOperationDate();
    const [subscriberResult, operationResult] = await Promise.all([
      supabase.from("subscribers")
        .select("id,full_name,subscriber_number,pump_id,created_at")
        .eq("organization_id", organizationId)
        .eq("pump_id", selectedPumpId)
        .eq("is_active", true)
        .order("subscriber_number", { ascending: true }),
      supabase.from("pump_operations")
        .select("id,pump_id,subscriber_id,subscriber_name,planned_minutes,status,started_at,paused_at,paused_seconds,ended_at,actual_seconds,operation_date")
        .eq("organization_id", organizationId)
        .eq("pump_id", selectedPumpId)
        .or(`operation_date.eq.${day},status.in.(running,paused)`)
        .order("started_at", { ascending: false }),
    ]);
    if (requestId !== dataRequestSequence.current) return;
    if (subscriberResult.error || operationResult.error) {
      console.error("operation queue load failed", subscriberResult.error ?? operationResult.error);
      setSubscribers([]);
      setOperations([]);
      setError("تعذر تحميل طابور المشتركين أو سجل التشغيل. حدّث الشاشة.");
    } else {
      setSubscribers((subscriberResult.data ?? []) as Subscriber[]);
      setOperations((operationResult.data ?? []) as Operation[]);
      setDataPumpId(selectedPumpId);
    }
    setRefreshing(false);
  }, [organizationId, selectedPumpId]);

  useEffect(() => { void loadPumps(); }, [loadPumps]);
  useEffect(() => { void loadPumpData(); }, [loadPumpData]);
  useEffect(() => {
    if (!activeOperation) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [activeOperation?.id, activeOperation?.status, activeOperation?.started_at]);

  const elapsedSeconds = activeOperation
    ? Math.max(0, Math.floor(
      ((activeOperation.status === "paused" && activeOperation.paused_at
        ? new Date(activeOperation.paused_at).getTime()
        : now) - new Date(activeOperation.started_at).getTime()) / 1000,
    ) - activeOperation.paused_seconds)
    : 0;
  const remainingSeconds = activeOperation
    ? Math.max(0, activeOperation.planned_minutes * 60 - elapsedSeconds)
    : 0;
  const progress = activeOperation
    ? Math.min(1, elapsedSeconds / (activeOperation.planned_minutes * 60))
    : 0;

  const startOperation = async (subscriber: Subscriber | null) => {
    if (!selectedPumpId || busy) return;
    const plannedMinutes = Number(minutes);
    if (!Number.isInteger(plannedMinutes) || plannedMinutes < 1 || plannedMinutes > 1440) {
      setError("أدخل مدة صحيحة من دقيقة واحدة إلى 24 ساعة.");
      return;
    }
    if (!subscriber && emergencyName.trim().length < 2) {
      setError("أدخل اسم الحالة الطارئة بصورة صحيحة.");
      return;
    }
    setBusy(true);
    setError(null);
    setNotice(null);
    const { error: actionError } = await supabase.rpc("start_pump_operation", {
      p_pump_id: selectedPumpId,
      p_subscriber_id: subscriber?.id ?? null,
      p_subscriber_name: subscriber ? null : emergencyName.trim(),
      p_planned_minutes: plannedMinutes,
    });
    if (actionError) {
      console.error("pump operation start failed", actionError);
      setError(friendlyError(actionError));
    } else {
      setEmergencyName("");
      setNotice(`بدأ تشغيل ${subscriber?.full_name ?? "الحالة الطارئة"} بنجاح.`);
      await loadPumpData();
    }
    setBusy(false);
  };

  const runAction = useCallback(async (
    action: "pause_pump_operation" | "resume_pump_operation" | "complete_pump_operation",
  ) => {
    if (!activeOperation || busy) return;
    setBusy(true);
    setError(null);
    setNotice(null);
    const { error: actionError } = await supabase.rpc(action, { p_operation_id: activeOperation.id });
    if (actionError) {
      console.error("pump operation state change failed", action, actionError);
      setError(friendlyError(actionError));
    } else {
      const messages = {
        pause_pump_operation: "تم إيقاف المؤقت مؤقتًا.",
        resume_pump_operation: "تم استئناف التشغيل.",
        complete_pump_operation: "انتهت مدة التعبئة، وتم حفظ زمنها الفعلي.",
      };
      setNotice(messages[action]);
      await loadPumpData();
    }
    setBusy(false);
  }, [activeOperation, busy, loadPumpData]);

  const autoCompletedOperationId = useRef<string | null>(null);
  useEffect(() => {
    if (
      !activeOperation ||
      activeOperation.status !== "running" ||
      remainingSeconds > 0 ||
      busy ||
      autoCompletedOperationId.current === activeOperation.id
    ) return;

    autoCompletedOperationId.current = activeOperation.id;
    void runAction("complete_pump_operation");
  }, [activeOperation, remainingSeconds, busy, runAction]);

  const activeStatus = activeOperation?.status === "paused" ? "متوقف مؤقتًا" : "قيد التشغيل";

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
      <View style={styles.heading}>
        <View style={styles.headingText}>
          <Text style={styles.eyebrow}>غرفة التشغيل</Text>
          <Text style={styles.title}>إدارة تعبئة المياه</Text>
          <Text style={styles.subtitle}>بدء الجلسات والتحكم بالوقت وحفظ سجل التنفيذ الفعلي</Text>
        </View>
        <View style={styles.headingIcon}><Waves size={24} color={colors.brand.primary} /></View>
      </View>

      {error ? <Text style={styles.error} accessibilityRole="alert">{error}</Text> : null}
      {notice ? <Text style={styles.notice} accessibilityLiveRegion="polite">{notice}</Text> : null}

      <Card style={styles.card}>
        <View style={styles.sectionHeader}>
          <SectionTitle title="الغطاس" />
          <Pressable onPress={() => { void loadPumps(); void loadPumpData(); }} disabled={loading || refreshing} style={styles.refresh}>
            <RefreshCw size={15} color={colors.brand.primary} />
            <Text style={styles.refreshText}>تحديث</Text>
          </Pressable>
        </View>
        {loading ? <ActivityIndicator color={colors.brand.teal} /> : pumps.length === 0 ? (
          <Text style={styles.empty}>لا يوجد غطاس مسند إلى حسابك. اطلب من المدير مراجعة التعيينات.</Text>
        ) : (
          <View style={styles.pumpChoices}>
            {pumps.map((pump) => (
              <Pressable key={pump.id} onPress={() => setSelectedPumpId(pump.id)}
                style={[styles.pumpChoice, selectedPumpId === pump.id && styles.pumpChoiceSelected]}>
                <Droplets size={17} color={selectedPumpId === pump.id ? colors.text.inverse : colors.brand.primary} />
                <Text style={[styles.pumpChoiceName, selectedPumpId === pump.id && styles.pumpChoiceTextSelected]}>{pump.name}</Text>
                <Text style={[styles.pumpChoiceCode, selectedPumpId === pump.id && styles.pumpChoiceTextSelected]}>{pump.code}</Text>
              </Pressable>
            ))}
          </View>
        )}
      </Card>

      {selectedPump && dataPumpId !== selectedPumpId ? (
        <Card style={styles.card}><ActivityIndicator color={colors.brand.teal} /><Text style={styles.empty}>جاري تحميل بيانات هذا الغطاس...</Text></Card>
      ) : null}

      {selectedPump && dataPumpId === selectedPumpId && (
        <>
          {activeOperation ? (
            <View style={styles.activeCard}>
              <View style={styles.activeHeader}>
                <View>
                  <Text style={styles.activeEyebrow}>التعبئة الحالية · {selectedPump.name}</Text>
                  <Text style={styles.activeName}>{activeOperation.subscriber_name}</Text>
                </View>
                <StatusBadge label={activeStatus} status={activeOperation.status === "paused" ? "warning" : "success"} />
              </View>
              <View style={styles.timerBlock}>
                <Text style={styles.timerLabel}>{remainingSeconds === 0 ? "انتهت المدة المحددة — تحقّق من التعبئة وأنهِها عند اكتمالها" : "الوقت المتبقي"}</Text>
                <Text style={styles.timer}>{formatClock(remainingSeconds)}</Text>
                <View style={styles.progressTrack}>
                  <View style={[styles.progressFill, { width: `${progress * 100}%` }]} />
                </View>
                <Text style={styles.timerMeta}>
                  المنفذ {formatClock(elapsedSeconds)} من {formatClock(activeOperation.planned_minutes * 60)}
                </Text>
              </View>
              <View style={styles.activeDetails}>
                <Text style={styles.detailText}>بدأت: {formatTime(activeOperation.started_at)}</Text>
                <Text style={styles.detailText}>المدة المحددة: {activeOperation.planned_minutes} دقيقة</Text>
              </View>
              <View style={styles.actionRow}>
                {activeOperation.status === "running" ? (
                  <Pressable disabled={busy} onPress={() => void runAction("pause_pump_operation")} style={[styles.actionButton, styles.pauseButton, busy && styles.disabled]}>
                    <Pause size={18} color="#fff" /><Text style={styles.actionText}>إيقاف مؤقت</Text>
                  </Pressable>
                ) : (
                  <Pressable disabled={busy} onPress={() => void runAction("resume_pump_operation")} style={[styles.actionButton, styles.resumeButton, busy && styles.disabled]}>
                    <Play size={18} color="#fff" /><Text style={styles.actionText}>استئناف</Text>
                  </Pressable>
                )}
                <Pressable disabled={busy} onPress={() => void runAction("complete_pump_operation")} style={[styles.actionButton, styles.completeButton, busy && styles.disabled]}>
                  <CheckCircle2 size={18} color="#fff" /><Text style={styles.actionText}>إنهاء التعبئة</Text>
                </Pressable>
              </View>
            </View>
          ) : (
            <Card style={styles.card}>
              <View style={styles.sectionHeader}>
                <SectionTitle title="بدء تعبئة جديدة" />
                <StatusBadge label="جاهز للتشغيل" status="info" />
              </View>
              <Text style={styles.fieldLabel}>مدة التعبئة بالدقائق</Text>
              <TextInput value={minutes} onChangeText={setMinutes} keyboardType="number-pad"
                placeholder="30" style={styles.durationInput} accessibilityLabel="مدة التعبئة بالدقائق" />
              <View style={styles.queueHeader}>
                <Text style={styles.fieldLabel}>طابور المشتركين اليوم</Text>
                <Text style={styles.count}>{queue.length} متبقٍ</Text>
              </View>
              {refreshing ? <ActivityIndicator color={colors.brand.teal} /> : queue.length === 0 ? (
                <Text style={styles.empty}>اكتمل طابور المشتركين النشطين لهذا اليوم، أو لا يوجد مشتركون على هذا الغطاس.</Text>
              ) : queue.map((subscriber, index) => (
                <View key={subscriber.id} style={styles.queueRow}>
                  <View style={styles.queueNumber}><Text style={styles.queueNumberText}>{index + 1}</Text></View>
                  <View style={styles.queueInfo}>
                    <Text style={styles.queueName}>{subscriber.full_name}</Text>
                    <Text style={styles.queueMeta}>رقم المشترك {String(subscriber.subscriber_number).padStart(6, "0")}</Text>
                  </View>
                  <Pressable disabled={busy || selectedPump.status !== "active"} onPress={() => void startOperation(subscriber)}
                    style={[styles.startButton, (busy || selectedPump.status !== "active") && styles.disabled]}>
                    <Play size={14} color="#fff" /><Text style={styles.startText}>بدء</Text>
                  </Pressable>
                </View>
              ))}
              <View style={styles.emergencyBlock}>
                <Text style={styles.fieldLabel}>تعبئة طارئة باسم غير مسجل</Text>
                <TextInput value={emergencyName} onChangeText={setEmergencyName}
                  placeholder="اسم الحالة الطارئة" style={styles.emergencyInput}
                  maxLength={120} textAlign="right" />
                <Pressable disabled={busy || selectedPump.status !== "active" || emergencyName.trim().length < 2}
                  onPress={() => void startOperation(null)}
                  style={[styles.emergencyButton, (busy || selectedPump.status !== "active" || emergencyName.trim().length < 2) && styles.disabled]}>
                  <Play size={15} color={colors.status.warning.text} /><Text style={styles.emergencyText}>بدء تعبئة طارئة</Text>
                </Pressable>
              </View>
            </Card>
          )}

          <Card style={styles.card}>
            <View style={styles.sectionHeader}>
              <SectionTitle title="سجل عمليات اليوم" />
              <Text style={styles.count}>{completedOperations.length} مكتملة</Text>
            </View>
            {completedOperations.length === 0 ? (
              <Text style={styles.empty}>لا توجد عمليات مكتملة مسجلة لهذا الغطاس اليوم.</Text>
            ) : completedOperations.map((operation) => (
              <View style={styles.historyRow} key={operation.id}>
                <View style={styles.historyIcon}><Clock3 size={16} color={colors.brand.primary} /></View>
                <View style={styles.historyBody}>
                  <Text style={styles.historyName}>{operation.subscriber_name}</Text>
                  <Text style={styles.historyMeta}>{formatTime(operation.started_at)} – {formatTime(operation.ended_at)}</Text>
                </View>
                <View style={styles.historyEnd}>
                  <Text style={styles.actualTime}>{formatClock(operation.actual_seconds ?? 0)}</Text>
                  <Text style={styles.historyMeta}>المدة الفعلية</Text>
                </View>
              </View>
            ))}
          </Card>
        </>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: "rtl" },
  content: { padding: spacing.md, paddingTop: spacing.lg, gap: spacing.md, maxWidth: 820, width: "100%", alignSelf: "center" },
  heading: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  headingText: { flex: 1, alignItems: "flex-end", gap: 4 },
  eyebrow: { color: colors.brand.teal, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.semiBold },
  title: { color: colors.text.primary, fontSize: typography.fontSize["2xl"], fontFamily: typography.fontFamily.bold },
  subtitle: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  headingIcon: { width: 44, height: 44, borderRadius: radius.md, backgroundColor: colors.background.surface, alignItems: "center", justifyContent: "center" },
  card: { gap: spacing.md },
  sectionHeader: { flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center", gap: spacing.sm },
  refresh: { flexDirection: "row-reverse", gap: 5, alignItems: "center", padding: spacing.xs },
  refreshText: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.semiBold },
  pumpChoices: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.sm },
  pumpChoice: { minWidth: 112, flexGrow: 1, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.sm, alignItems: "center", gap: 4, backgroundColor: colors.background.surface },
  pumpChoiceSelected: { backgroundColor: colors.brand.primary, borderColor: colors.brand.primary },
  pumpChoiceName: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  pumpChoiceCode: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  pumpChoiceTextSelected: { color: colors.text.inverse },
  activeCard: { backgroundColor: colors.brand.navy, borderRadius: radius.lg, padding: spacing.lg, gap: spacing.md },
  activeHeader: { flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center", gap: spacing.sm },
  activeEyebrow: { color: "#B7DDE4", fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  activeName: { color: colors.text.inverse, fontSize: typography.fontSize.xl, fontFamily: typography.fontFamily.bold, marginTop: 5 },
  timerBlock: { alignItems: "center", gap: spacing.sm, paddingVertical: spacing.md },
  timerLabel: { color: "#B7DDE4", fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.medium },
  timer: { color: colors.text.inverse, fontSize: 48, fontVariant: ["tabular-nums"], fontWeight: "700" },
  progressTrack: { width: "100%", height: 9, backgroundColor: "#31586B", borderRadius: 5, overflow: "hidden" },
  progressFill: { height: "100%", backgroundColor: colors.brand.aqua, borderRadius: 5 },
  timerMeta: { color: "#C3D4DC", fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  activeDetails: { flexDirection: "row-reverse", flexWrap: "wrap", justifyContent: "space-between", gap: spacing.sm },
  detailText: { color: "#C3D4DC", fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  actionRow: { flexDirection: "row-reverse", gap: spacing.sm },
  actionButton: { flex: 1, minHeight: 50, borderRadius: radius.md, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.xs },
  pauseButton: { backgroundColor: "#C17A24" },
  resumeButton: { backgroundColor: colors.brand.teal },
  completeButton: { backgroundColor: "#27815D" },
  actionText: { color: "#fff", fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  fieldLabel: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.semiBold, textAlign: "right" },
  durationInput: { minHeight: 48, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.md, color: colors.text.primary, textAlign: "center", backgroundColor: colors.background.surface, fontSize: typography.fontSize.md },
  queueHeader: { flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center" },
  count: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  queueRow: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm, minHeight: 62, borderTopWidth: 1, borderTopColor: colors.background.subtle, paddingTop: spacing.xs },
  queueNumber: { width: 28, height: 28, borderRadius: 14, backgroundColor: colors.background.subtle, alignItems: "center", justifyContent: "center" },
  queueNumberText: { color: colors.brand.primary, fontFamily: typography.fontFamily.bold },
  queueInfo: { flex: 1, alignItems: "flex-end", gap: 3 },
  queueName: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  queueMeta: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  startButton: { minWidth: 72, minHeight: 40, borderRadius: radius.sm, backgroundColor: colors.brand.primary, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: 4 },
  startText: { color: "#fff", fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.bold },
  emergencyBlock: { borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.md, gap: spacing.sm },
  emergencyInput: { minHeight: 46, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.md, color: colors.text.primary, backgroundColor: colors.background.surface },
  emergencyButton: { minHeight: 44, borderRadius: radius.md, borderWidth: 1, borderColor: colors.status.warning.main, backgroundColor: colors.status.warning.background, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.xs },
  emergencyText: { color: colors.status.warning.text, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.semiBold },
  historyRow: { minHeight: 64, flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm, borderTopWidth: 1, borderTopColor: colors.background.subtle },
  historyIcon: { width: 34, height: 34, borderRadius: 10, alignItems: "center", justifyContent: "center", backgroundColor: colors.background.subtle },
  historyBody: { flex: 1, alignItems: "flex-end", gap: 3 },
  historyName: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  historyMeta: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  historyEnd: { alignItems: "flex-end", gap: 2 },
  actualTime: { color: colors.brand.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold, fontVariant: ["tabular-nums"] },
  empty: { color: colors.text.secondary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.regular, textAlign: "right", lineHeight: 22, paddingVertical: spacing.sm },
  error: { color: colors.status.danger.text, backgroundColor: colors.status.danger.background, padding: spacing.sm, borderRadius: radius.sm, fontSize: typography.fontSize.xs, textAlign: "right", lineHeight: 20 },
  notice: { color: colors.status.success.text, backgroundColor: colors.status.success.background, padding: spacing.sm, borderRadius: radius.sm, fontSize: typography.fontSize.xs, textAlign: "right", lineHeight: 20 },
  disabled: { opacity: 0.5 },
});
