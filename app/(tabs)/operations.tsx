import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  Alert,
  AppState,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { CheckCircle2, Clock3, Droplets, Pause, Play, Plus, RefreshCw, Waves } from "lucide-react-native";
import { loadAlertSettings, type AlertSettings } from "@/lib/alerts/settings";
import {
  pausePersistentPumpTimerNotification,
  resumePersistentPumpTimerNotification,
  startPersistentPumpTimerNotification,
  stopPersistentPumpTimerNotification,
  syncPersistentPumpTimerNotification,
} from "@/lib/alerts/persistent-timer";
import {
  cancelHandoverNotification,
  cancelOperationTimerNotifications,
  requestAndroidNotificationPermission,
  syncPumpTimerNotifications,
  syncQueueHandoverNotification,
} from "@/lib/alerts/native-notifications";
import { SectionTitle, StatusBadge } from "@/components/UI";
import { Card, RoleGate } from "@/components/ui";
import { colors, radius, spacing, typography } from "@/constants/theme";
import { useAuth } from "@/lib/auth";
import { allocateWholeMinutesByLargestRemainder } from "@/lib/power-usage-rules";
import {
  pumpOperationsRepository,
  type OperationPump as Pump,
  type OperationSubscriber as Subscriber,
  type PumpOperation as Operation,
  type PumpPowerSource,
  type PowerUsageRow,
  type DailyScheduleEntry,
  type DailyWorkReportDetails,
  type DailyQueue,
  type DailyQueueItem,
  type WeeklyEntitlementAllocationForDay,
  type WeeklyEntitlementTransferOption,
  type WeeklyQueueOperationLink,
} from "@/lib/repositories/pump-operations";

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
  return new Date(value).toLocaleTimeString("ar-PS", { timeZone: "Asia/Hebron", hour: "2-digit", minute: "2-digit" });
}

function localTimeInput(value: string) {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Hebron",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).format(new Date(value));
}

function hebrewLocalToIso(date: string, time: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !/^([01]\d|2[0-3]):[0-5]\d$/.test(time)) {
    throw new Error("أدخل تاريخًا ووقتًا صحيحين.");
  }
  const [year, month, day] = date.split("-").map(Number);
  const [hour, minute] = time.split(":").map(Number);
  const localTarget = Date.UTC(year, month - 1, day, hour, minute, 0);
  let utcMillis = localTarget;

  for (let attempt = 0; attempt < 4; attempt += 1) {
    const parts = new Intl.DateTimeFormat("en-CA", {
      timeZone: "Asia/Hebron",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    }).formatToParts(new Date(utcMillis));
    const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
    const representedAsUtc = Date.UTC(
      Number(values.year), Number(values.month) - 1, Number(values.day),
      Number(values.hour), Number(values.minute), Number(values.second),
    );
    const offset = representedAsUtc - utcMillis;
    const nextUtc = localTarget - offset;
    if (nextUtc === utcMillis) break;
    utcMillis = nextUtc;
  }

  const result = new Date(utcMillis);
  const check = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Hebron",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(result);
  const values = Object.fromEntries(check.map((part) => [part.type, part.value]));
  if (`${values.year}-${values.month}-${values.day}` !== date
      || `${values.hour}:${values.minute}` !== time) {
    throw new Error("الوقت المدخل غير موجود في التوقيت المحلي لهذا التاريخ.");
  }
  return result.toISOString();
}

function powerDateRange(period: "day" | "week" | "month") {
  const today = localOperationDate();
  const [year, month, day] = today.split("-").map(Number);
  const todayUtc = new Date(Date.UTC(year, month - 1, day));
  if (period === "day") return { from: today, to: today };
  if (period === "month") {
    return { from: `${year}-${String(month).padStart(2, "0")}-01`, to: today };
  }
  const fromDate = new Date(todayUtc);
  fromDate.setUTCDate(fromDate.getUTCDate() - 6);
  return { from: fromDate.toISOString().slice(0, 10), to: today };
}

function friendlyError(error: { code?: string; message?: string }) {
  if (error.code === "23505") return "يوجد تشغيل قائم بالفعل على هذا الغطاس.";
  if (error.code === "42501") return "ليس لديك صلاحية التشغيل على هذا الغطاس.";
  if (error.code === "P0002") return "تغيّرت حالة العملية. حدّث الشاشة وحاول مجددًا.";
  if (error.code === "22023") return "تحقق من عدد الدقائق، وألا يتجاوز إجمالي مدة التعبئة 24 ساعة.";
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
  const [reportOperators, setReportOperators] = useState<{ id: string; display_name: string }[]>([]);
  const [selectedReportOperatorId, setSelectedReportOperatorId] = useState("");
  const [sharedEnergySubmitted, setSharedEnergySubmitted] = useState(false);
  const [sharedEnergyReadOnly, setSharedEnergyReadOnly] = useState(false);
  const [subscribers, setSubscribers] = useState<Subscriber[]>([]);
  const [operations, setOperations] = useState<Operation[]>([]);
  const [dailyQueue, setDailyQueue] = useState<DailyQueue | null>(null);
  const [dailyQueueError, setDailyQueueError] = useState<string | null>(null);
  const [operationLoadFailed, setOperationLoadFailed] = useState(false);
  const [dailyQueueLoadFailed, setDailyQueueLoadFailed] = useState(false);
  const [queueAdditionOpen, setQueueAdditionOpen] = useState(false);
  const [queueAdditionType, setQueueAdditionType] = useState<"additional_registered" | "additional_guest" | "emergency">("emergency");
  const [queueAdditionSubscriberId, setQueueAdditionSubscriberId] = useState("");
  const [queueAdditionName, setQueueAdditionName] = useState("");
  const [queueAdditionMinutes, setQueueAdditionMinutes] = useState("30");
  const [queueOverrideReason, setQueueOverrideReason] = useState("");
  const [queueItemActionReason, setQueueItemActionReason] = useState("");
  const [powerSources, setPowerSources] = useState<PumpPowerSource[]>([]);
  const [surveyPowerSources, setSurveyPowerSources] = useState<PumpPowerSource[]>([]);
  const [selectedPowerSourceId, setSelectedPowerSourceId] = useState("");
  const [resumePowerSourceId, setResumePowerSourceId] = useState("");
  const [showAddPowerSource, setShowAddPowerSource] = useState(false);
  const [newPowerSourceName, setNewPowerSourceName] = useState("");
  const [newPowerSourceType, setNewPowerSourceType] = useState<PumpPowerSource["source_type"]>("solar");
  const [usagePeriod, setUsagePeriod] = useState<"day" | "week" | "month">("day");
  const [powerUsageRows, setPowerUsageRows] = useState<PowerUsageRow[]>([]);
  const [powerUsageLoading, setPowerUsageLoading] = useState(false);
  const [powerUsageError, setPowerUsageError] = useState<string | null>(null);
  const [dailyWorkReport, setDailyWorkReport] = useState<DailyWorkReportDetails | null>(null);
  const [dailyWorkReportLoading, setDailyWorkReportLoading] = useState(false);
  const [dailyWorkReportError, setDailyWorkReportError] = useState<string | null>(null);
  const [surveyOpen, setSurveyOpen] = useState(false);
  const [surveyStep, setSurveyStep] = useState<1 | 2>(1);
  const [surveyLoading, setSurveyLoading] = useState(false);
  const [surveySaving, setSurveySaving] = useState(false);
  const [surveyDate, setSurveyDate] = useState(localOperationDate());
  const [workStartTime, setWorkStartTime] = useState("");
  const [workEndTime, setWorkEndTime] = useState("");
  const [stoppageMinutes, setStoppageMinutes] = useState("0");
  const [sourceMinutes, setSourceMinutes] = useState<Record<string, string>>({});
  const [surveyEntries, setSurveyEntries] = useState<DailyScheduleEntry[]>([]);
  const [surveyOperations, setSurveyOperations] = useState<Operation[]>([]);
  const [surveyManualMinutes, setSurveyManualMinutes] = useState<Record<string, string>>({});
  const [surveyExtraMinutes, setSurveyExtraMinutes] = useState<Record<string, string>>({});
  const [surveyQueueItems, setSurveyQueueItems] = useState<WeeklyQueueOperationLink[]>([]);
  const [weeklyTransferOpen, setWeeklyTransferOpen] = useState(false);
  const [weeklyTransferLoading, setWeeklyTransferLoading] = useState(false);
  const [weeklyTransferOptions, setWeeklyTransferOptions] = useState<WeeklyEntitlementTransferOption[]>([]);
  const [weeklyTransferMinutes, setWeeklyTransferMinutes] = useState<Record<string, string>>({});
  const [weeklyTransferReason, setWeeklyTransferReason] = useState("");
  const [weeklyTransferTargetDate, setWeeklyTransferTargetDate] = useState(localOperationDate());
  const autoAdvanceInFlight = useRef<string | null>(null);
  const [alertSettings, setAlertSettings] = useState<AlertSettings | null>(null);
  const [pauseReason, setPauseReason] = useState("");
  const [extensionMinutes, setExtensionMinutes] = useState("5");
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
  const groupedPowerUsage = useMemo(() => {
    const selectedRows = usagePeriod === "week" && powerUsageRows.length > 0
      ? powerUsageRows.filter((row) => row.period_start === powerUsageRows.reduce(
        (latest, item) => item.period_start > latest ? item.period_start : latest,
        powerUsageRows[0].period_start,
      ))
      : powerUsageRows;
    const grouped = new Map<string, { id: string; name: string; minutes: number; sources: Set<string> }>();
    for (const row of selectedRows) {
      const current = grouped.get(row.power_source_id) ?? {
        id: row.power_source_id,
        name: row.power_source_name,
        minutes: 0,
        sources: new Set<string>(),
      };
      current.minutes += Number(row.total_minutes ?? 0);
      current.sources.add(row.data_source);
      grouped.set(row.power_source_id, current);
    }
    return [...grouped.values()].sort((a, b) => a.name.localeCompare(b.name, "ar"));
  }, [powerUsageRows, usagePeriod]);
  const activeOperation = useMemo(
    () => dataPumpId === selectedPumpId && selectedPumpId
      ? operations.find((operation) =>
          operation.pump_id === selectedPumpId &&
          (operation.status === "running" || operation.status === "paused"),
        ) ?? null
      : null,
    [dataPumpId, operations, selectedPumpId],
  );
  const queuedItems = useMemo(
    () => (dailyQueue?.items ?? [])
      .filter((item) => item.status === "queued")
      .sort((a, b) => a.sort_order - b.sort_order || a.id.localeCompare(b.id)),
    [dailyQueue],
  );
  const completedQueueItems = useMemo(
    () => (dailyQueue?.items ?? []).filter((item) => item.status === "completed")
      .sort((a, b) => (b.completed_at ?? "").localeCompare(a.completed_at ?? "")),
    [dailyQueue],
  );
  const hasForeignRunningQueueItem = (dailyQueue?.items ?? []).some(
    (item) => item.is_owned === false && item.status === "running",
  );
  const autoAdvanceTargetItem = dailyQueue?.items.find(
    (item) => item.id === dailyQueue.auto_advance_queue_item_id,
  );
  const canControlAutoAdvance = profile?.role === "manager"
    || (profile?.role === "operator" && autoAdvanceTargetItem?.is_owned === true);
  const autoAdvanceRemainingSeconds = dailyQueue?.auto_advance_at
    ? Math.max(0, Math.ceil((new Date(dailyQueue.auto_advance_at).getTime() - now) / 1000))
    : null;
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
    const { data, error: queryError } = await pumpOperationsRepository.listPumps(organizationId);
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
      setDailyQueue(null);
      setDailyQueueError(null);
      setOperationLoadFailed(false);
      setDailyQueueLoadFailed(false);
      setDataPumpId(null);
      setRefreshing(false);
      return;
    }
    const requestId = ++dataRequestSequence.current;
    setDataPumpId(null);
    setSubscribers([]);
    setOperations([]);
    setDailyQueue(null);
    setDailyQueueError(null);
    setOperationLoadFailed(false);
    setDailyQueueLoadFailed(false);
    setQueueAdditionOpen(false);
    setQueueAdditionSubscriberId("");
    setQueueAdditionName("");
    setRefreshing(true);
    setError(null);
    try {
      const day = localOperationDate();
      const [subscriberResult, operationResult, sourceResult] = await Promise.all([
        pumpOperationsRepository.listActiveSubscribers(organizationId, selectedPumpId),
        pumpOperationsRepository.listPumpOperations(organizationId, selectedPumpId, day),
        pumpOperationsRepository.listPowerSources(organizationId, selectedPumpId),
      ]);
      if (requestId !== dataRequestSequence.current) return;
      if (subscriberResult.error || operationResult.error || sourceResult.error) {
        console.error("operation queue load failed", subscriberResult.error ?? operationResult.error ?? sourceResult.error);
        setSubscribers([]);
        setOperations([]);
        setPowerSources([]);
        setDailyQueue(null);
        setDailyQueueError("تعذر تحميل طابور اليوم.");
        setOperationLoadFailed(true);
        setDailyQueueLoadFailed(true);
        setSelectedPowerSourceId("");
        setDataPumpId(selectedPumpId);
        setError("تعذر تحميل بيانات التشغيل أو مصادر الكهرباء. تحقق من تحديث قاعدة البيانات ثم حدّث الشاشة.");
      } else {
        const loadedOperations = (operationResult.data ?? []) as Operation[];
        const loadedSources = (sourceResult.data ?? []) as PumpPowerSource[];
        setOperationLoadFailed(false);
        setSubscribers((subscriberResult.data ?? []) as Subscriber[]);
        setOperations(loadedOperations);
        setPowerSources(loadedSources);
        setSelectedPowerSourceId((current) =>
          loadedSources.some((source) => source.id === current) ? current : loadedSources[0]?.id ?? "",
        );
        const paused = loadedOperations.find((operation) =>
          operation.pump_id === selectedPumpId && operation.status === "paused",
        );
        setResumePowerSourceId(paused?.last_power_source_id ?? loadedSources[0]?.id ?? "");
        const queueResult = await pumpOperationsRepository.loadOrCreateDailyQueue(
          organizationId,
          selectedPumpId,
          day,
        );
        if (requestId !== dataRequestSequence.current) return;
        if (queueResult.error) {
          console.error("daily queue load failed", queueResult.error);
          setDailyQueueLoadFailed(true);
          setDailyQueue(null);
          setDailyQueueError(queueResult.error.code === "P0002"
            ? "لا يوجد جدول أسبوعي نشط لهذا الغطاس في تاريخ اليوم. يلزم اعتماد الجدول أولًا."
            : "تعذر تحميل طابور اليوم. تحقق من صلاحيات الجدول أو حدّث قاعدة البيانات.");
        } else {
          setDailyQueueLoadFailed(false);
          setDailyQueue((queueResult.data ?? null) as DailyQueue | null);
          setDailyQueueError(queueResult.data ? null : "لا يوجد طابور يومي محفوظ لهذا التاريخ.");
        }
        setDataPumpId(selectedPumpId);
      }
    } catch (loadError) {
      console.error("operation queue request failed", loadError);
      if (requestId === dataRequestSequence.current) {
        setSubscribers([]);
        setOperations([]);
        setDailyQueue(null);
        setDailyQueueError("تعذر الاتصال بطابور اليوم.");
        setOperationLoadFailed(true);
        setDailyQueueLoadFailed(true);
        setDataPumpId(selectedPumpId);
        setError("انقطع الاتصال أثناء تحميل بيانات التشغيل. حاول التحديث.");
      }
    } finally {
      if (requestId === dataRequestSequence.current) setRefreshing(false);
    }
  }, [organizationId, selectedPumpId]);

  const loadPowerUsage = useCallback(async () => {
    if (!selectedPumpId) {
      setPowerUsageRows([]);
      return;
    }
    setPowerUsageLoading(true);
    setPowerUsageError(null);
    const range = powerDateRange(usagePeriod);
    const { data, error: queryError } = await pumpOperationsRepository.getPowerUsage(
      range.from, range.to, usagePeriod, selectedPumpId,
    );
    if (queryError) {
      console.error("power usage report load failed", queryError);
      setPowerUsageRows([]);
      setPowerUsageError("تعذر تحميل إحصاءات مصادر الكهرباء.");
    } else {
      setPowerUsageRows((data ?? []) as PowerUsageRow[]);
    }
    setPowerUsageLoading(false);
  }, [selectedPumpId, usagePeriod]);

  const loadDailyWorkReport = useCallback(async (workDate: string, operatorIdOverride?: string) => {
    if (!organizationId || !selectedPumpId) {
      setDailyWorkReport(null);
      return;
    }
    const targetOperatorId = operatorIdOverride
      ?? (profile?.role === "operator" ? profile.id : selectedReportOperatorId);
    setDailyWorkReportLoading(true);
    setDailyWorkReportError(null);
    const { data, error: reportError } = await pumpOperationsRepository.getDailyWorkReport(
      organizationId, selectedPumpId, workDate, targetOperatorId || undefined,
    );
    if (reportError) {
      console.error("daily work report load failed", reportError);
      setDailyWorkReport(null);
      setDailyWorkReportError("تعذر تحميل تقرير العمل اليومي.");
    } else {
      setDailyWorkReport((data ?? null) as DailyWorkReportDetails | null);
    }
    setDailyWorkReportLoading(false);
  }, [organizationId, profile?.id, profile?.role, selectedPumpId, selectedReportOperatorId]);

  useEffect(() => {
    let mounted = true;
    void loadAlertSettings()
      .then((loadedSettings) => { if (mounted) setAlertSettings(loadedSettings); })
      .catch((settingsError) => console.warn("Could not load local alert settings.", settingsError));
    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => { void loadPumps(); }, [loadPumps]);
  useEffect(() => { void loadPumpData(); }, [loadPumpData]);
  useEffect(() => { void loadPowerUsage(); }, [loadPowerUsage]);
  useEffect(() => { void loadDailyWorkReport(localOperationDate()); }, [loadDailyWorkReport]);
  useEffect(() => {
    const subscription = AppState.addEventListener("change", (state) => {
      if (state === "active") {
        setNow(Date.now());
        autoAdvanceInFlight.current = null;
        void loadPumpData();
      }
    });
    return () => subscription.remove();
  }, [loadPumpData]);
  useEffect(() => {
    if (!activeOperation && !dailyQueue?.auto_advance_at) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [activeOperation?.id, activeOperation?.status, activeOperation?.started_at, dailyQueue?.auto_advance_at]);

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

  useEffect(() => {
    if (!selectedPumpId || dataPumpId !== selectedPumpId || !alertSettings || operationLoadFailed) return;
    void syncPumpTimerNotifications(selectedPumpId, operations, alertSettings).catch((syncError) => {
      console.warn("Android pump timer notification sync failed.", syncError);
      setError("تعذرت جدولة تنبيهات المؤقت. تحقق من إذن الإشعارات والمنبّهات الدقيقة في Android.");
    });
  }, [
    selectedPumpId,
    dataPumpId,
    operations,
    alertSettings?.minuteWarning.enabled,
    alertSettings?.minuteWarning.vibrate,
    alertSettings?.handover.enabled,
    alertSettings?.handover.vibrate,
    operationLoadFailed,
  ]);

  useEffect(() => {
    if (
      Platform.OS !== "android"
      || !selectedPumpId
      || dataPumpId !== selectedPumpId
      || operationLoadFailed
    ) return;

    void syncPersistentPumpTimerNotification(selectedPumpId, operations).catch((syncError) => {
      console.warn("Android persistent timer notification sync failed.", syncError);
      setError("تعذر تشغيل عداد التعبئة المستمر في إشعارات Android. تحقق من إذن الإشعارات.");
    });
  }, [selectedPumpId, dataPumpId, operations, operationLoadFailed]);

  useEffect(() => {
    if (!selectedPumpId || dataPumpId !== selectedPumpId || !alertSettings || dailyQueueLoadFailed) return;
    void syncQueueHandoverNotification(selectedPumpId, dailyQueue, alertSettings).catch((syncError) => {
      console.warn("Android queue handover notification sync failed.", syncError);
      setError("تعذرت جدولة تنبيه الانتقال المحفوظ في الطابور.");
    });
  }, [
    selectedPumpId,
    dataPumpId,
    dailyQueue?.id,
    dailyQueue?.auto_advance_token,
    dailyQueue?.auto_advance_at,
    alertSettings?.handover.enabled,
    alertSettings?.handover.vibrate,
    dailyQueueLoadFailed,
  ]);

  const addPowerSource = async () => {
    if (!selectedPumpId || busy || profile?.role !== "manager") return;
    if (newPowerSourceName.trim().length < 2) {
      setError("اسم مصدر الكهرباء يجب أن يحتوي على حرفين على الأقل.");
      return;
    }
    setBusy(true);
    setError(null);
    const { error: insertError } = await pumpOperationsRepository.createPowerSource(
      selectedPumpId, newPowerSourceName.trim(), newPowerSourceType,
    );
    if (insertError) {
      console.error("power source creation failed", insertError);
      setError(insertError.code === "23505"
        ? "يوجد مصدر بهذا الاسم لهذا الغطاس."
        : "تعذر إضافة مصدر الكهرباء. تحقق من الصلاحية والبيانات.");
    } else {
      setNewPowerSourceName("");
      setShowAddPowerSource(false);
      setNotice("تمت إضافة مصدر الكهرباء.");
      await loadPumpData();
    }
    setBusy(false);
  };

  const archivePowerSource = async (sourceId: string) => {
    if (profile?.role !== "manager" || busy) return;
    setBusy(true);
    setError(null);
    const { error: archiveError } = await pumpOperationsRepository.archivePowerSource(sourceId);
    if (archiveError) {
      console.error("power source archival failed", archiveError);
      setError("تعذر أرشفة مصدر الكهرباء.");
    } else {
      setNotice("تمت أرشفة المصدر، وحُفظت سجلاته السابقة.");
      await loadPumpData();
    }
    setBusy(false);
  };

  const extendActiveOperation = async () => {
    if (!activeOperation || busy) return;
    const addedMinutes = Number(extensionMinutes);
    if (!Number.isInteger(addedMinutes) || addedMinutes < 1 || addedMinutes > 1440) {
      setError("أدخل عددًا صحيحًا موجبًا من الدقائق.");
      return;
    }
    if (activeOperation.planned_minutes + addedMinutes > 1440) {
      setError("لا يمكن أن تتجاوز مدة التعبئة الإجمالية 1440 دقيقة (24 ساعة).");
      return;
    }

    setBusy(true);
    setError(null);
    setNotice(null);
    const { error: extensionError } = await pumpOperationsRepository.extendTime(
      activeOperation.id,
      addedMinutes,
    );
    if (extensionError) {
      console.error("pump operation time extension failed", extensionError);
      setError(friendlyError(extensionError));
    } else {
      setNotice(`تمت إضافة ${addedMinutes} دقيقة إلى التعبئة الحالية، وسُجلت الزيادة في سجل العملية.`);
      setExtensionMinutes("5");
      try {
        await cancelOperationTimerNotifications(activeOperation.id);
      } catch (cancelError) {
        console.warn("Android operation notification cancellation after extension failed.", cancelError);
      }
      try {
        await syncPersistentPumpTimerNotification(selectedPumpId, [{
          ...activeOperation,
          planned_minutes: activeOperation.planned_minutes + addedMinutes,
        }]);
      } catch (nativeTimerError) {
        console.warn("Could not update the persistent Android timer after extension.", nativeTimerError);
      }
      await loadPumpData();
    }
    setBusy(false);
  };

  const stopHandoverAlert = (token: string | null | undefined) => {
    if (!token) return;
    void cancelHandoverNotification(token).catch((cancelError) => {
      console.warn("Android handover notification cancellation failed.", cancelError);
    });
  };

  const startQueueItem = async (item: DailyQueueItem) => {
    if (!dailyQueue || busy || activeOperation) return;
    if (item.is_owned === false) {
      setError("هذا الدور تابع لمشغّل آخر. سيظهر لك ترتيب الدور دون بيانات المشترك.");
      return;
    }
    if (!selectedPowerSourceId) {
      setError("اختر مصدر الكهرباء المستخدم قبل بدء التعبئة.");
      return;
    }
    const firstWaitingItem = queuedItems[0];
    if (!firstWaitingItem || firstWaitingItem.id !== item.id) {
      setError("يمكن بدء أول عنصر منتظر فقط. أعد ترتيب الطابور أولًا عند الحاجة.");
      return;
    }
    setBusy(true);
    setError(null);
    setNotice(null);
    let notificationsGranted = true;
    let persistentCounterStarted = false;
    if (Platform.OS === "android") {
      try {
        notificationsGranted = await requestAndroidNotificationPermission();
        if (notificationsGranted) {
          // Promote the service while this user action is still foregrounded.
          // The subsequent server refresh corrects this provisional end time.
          persistentCounterStarted = await startPersistentPumpTimerNotification(
            item.id,
            item.planned_minutes,
          );
        }
      } catch (permissionError) {
        notificationsGranted = false;
        console.warn("Android notification setup failed before starting the pump operation.", permissionError);
      }
    }
    const { error: startError } = await pumpOperationsRepository.startDailyQueueItem(
      dailyQueue.id,
      item.id,
      selectedPowerSourceId,
    );
    if (startError) {
      console.error("daily queue item start failed", startError);
      if (persistentCounterStarted) {
        try {
          await stopPersistentPumpTimerNotification(item.id);
        } catch (stopError) {
          console.warn("Could not stop provisional Android timer after server start failed.", stopError);
        }
      }
      setError(friendlyError(startError));
    } else {
      stopHandoverAlert(dailyQueue.auto_advance_token);
      setNotice(Platform.OS !== "android"
        ? `بدأت تعبئة ${item.subscriber_name_snapshot} من الطابور اليومي.`
        : !notificationsGranted
          ? "بدأت التعبئة، لكن إذن إشعارات Android غير مفعّل؛ فعّله لإظهار العداد المستمر."
          : !persistentCounterStarted
            ? "بدأت التعبئة، لكن تعذر تشغيل عداد الإشعارات المستمر. حاول تحديث الشاشة أو تحقق من إعدادات Android."
            : `بدأت تعبئة ${item.subscriber_name_snapshot} من الطابور اليومي، وسيظهر عداد الوقت المتبقي في إشعارات Android.`);
      await loadPumpData();
    }
    setBusy(false);
  };

  const appendQueueItem = async () => {
    if (!dailyQueue || busy) return;
    const planned = Number(queueAdditionMinutes);
    if (!Number.isInteger(planned) || planned < 1 || planned > 1440) {
      setError("أدخل مدة صحيحة للإضافة من دقيقة واحدة إلى 24 ساعة.");
      return;
    }
    if (queueAdditionType === "additional_registered" && !queueAdditionSubscriberId) {
      setError("اختر المشترك المسجل الذي تريد إضافة حصة له.");
      return;
    }
    if (queueAdditionType !== "additional_registered" && queueAdditionName.trim().length < 2) {
      setError("أدخل اسم المستفيد بصورة صحيحة.");
      return;
    }

    setBusy(true);
    setError(null);
    setNotice(null);
    const { error: appendError } = await pumpOperationsRepository.addDailyQueueItem(
      dailyQueue.id,
      queueAdditionType,
      planned,
      queueAdditionType === "additional_registered" ? queueAdditionSubscriberId : null,
      queueAdditionType === "additional_registered" ? null : queueAdditionName.trim(),
    );
    if (appendError) {
      console.error("daily queue append failed", appendError);
      setError(appendError.code === "22023"
        ? "تحقق من اسم المستفيد أو مدة التعبئة أو أن المشترك تابع للغطاس المحدد."
        : friendlyError(appendError));
    } else {
      setQueueAdditionName("");
      setQueueAdditionSubscriberId("");
      setQueueAdditionMinutes("30");
      setQueueAdditionOpen(false);
      setNotice("أضيف العنصر إلى نهاية الطابور دون تغيير ترتيب الأدوار السابقة.");
      await loadPumpData();
    }
    setBusy(false);
  };

  const moveQueueItem = async (itemId: string, direction: -1 | 1) => {
    if (!dailyQueue || busy) return;
    const fromIndex = queuedItems.findIndex((item) => item.id === itemId);
    const toIndex = fromIndex + direction;
    if (fromIndex < 0 || toIndex < 0 || toIndex >= queuedItems.length) return;

    const nextOrder = queuedItems.map((item) => item.id);
    [nextOrder[fromIndex], nextOrder[toIndex]] = [nextOrder[toIndex], nextOrder[fromIndex]];

    setBusy(true);
    setError(null);
    setNotice(null);
    const { error: reorderError } = await pumpOperationsRepository.reorderDailyQueue(
      dailyQueue.id,
      dailyQueue.queue_version,
      nextOrder,
      queueOverrideReason.trim() || null,
    );
    if (reorderError) {
      console.error("daily queue reorder failed", reorderError);
      setError(reorderError.code === "22023"
        ? "هذا الترتيب يضع عنصرين من التفرع نفسه متتاليين. أدخل سبب التجاوز ثم أعد المحاولة."
        : reorderError.code === "40001"
          ? "تغير الطابور من جهاز آخر. حدّث الطابور ثم حاول مجددًا."
          : friendlyError(reorderError));
    } else {
      setQueueOverrideReason("");
      setNotice("تم حفظ ترتيب الطابور وسجل التعديل.");
      await loadPumpData();
    }
    setBusy(false);
  };

  const manageQueueItem = async (item: DailyQueueItem, action: "defer" | "cancel") => {
    if (!dailyQueue || busy) return;
    if (item.is_owned === false) {
      setError("لا يمكنك تأجيل أو إلغاء دور مشغّل آخر.");
      return;
    }
    const reason = queueItemActionReason.trim();
    if (reason.length < 2 || reason.length > 240) {
      setError("أدخل سببًا واضحًا للتأجيل أو الإلغاء (من حرفين إلى 240 حرفًا).");
      return;
    }
    if (action === "defer" && queuedItems.length < 2) {
      setError("لا يوجد دور آخر يمكن تقديمه؛ أضف دورًا أو اترك الطابور كما هو.");
      return;
    }

    setBusy(true);
    setError(null);
    setNotice(null);
    const wasAutoAdvanceTarget = dailyQueue.auto_advance_queue_item_id === item.id;
    const previousToken = dailyQueue.auto_advance_token;
    const result = action === "defer"
      ? await pumpOperationsRepository.deferDailyQueueItem(
          dailyQueue.id, item.id, dailyQueue.queue_version, reason,
        )
      : await pumpOperationsRepository.cancelDailyQueueItem(
          dailyQueue.id, item.id, dailyQueue.queue_version, reason,
        );

    if (result.error) {
      console.error(`daily queue item ${action} failed`, result.error);
      setError(result.error.code === "40001"
        ? "تغير الطابور من جهاز آخر. حدّث الطابور ثم أعد المحاولة."
        : result.error.code === "22023"
          ? "تحقق من سبب الإجراء وحالة الطابور."
          : friendlyError(result.error));
    } else {
      if (wasAutoAdvanceTarget && previousToken) stopHandoverAlert(previousToken);
      setQueueItemActionReason("");
      setNotice(action === "defer"
        ? `تم تأجيل ${item.subscriber_name_snapshot} إلى نهاية طابور اليوم، وسُجل السبب.`
        : `تم إلغاء دور ${item.subscriber_name_snapshot} مع الاحتفاظ بسجل التدقيق ودون احتساب دقائق منفذة.`);
      await loadPumpData();
    }
    setBusy(false);
  };

  const confirmCancelQueueItem = (item: DailyQueueItem) => {
    Alert.alert(
      "تأكيد إلغاء الدور",
      `سيبقى الدور محفوظًا في السجل ولن يبدأ. هل تريد إلغاء ${item.subscriber_name_snapshot}؟`,
      [
        { text: "تراجع", style: "cancel" },
        { text: "إلغاء الدور", style: "destructive", onPress: () => void manageQueueItem(item, "cancel") },
      ],
    );
  };

  const cancelAutoAdvance = async () => {
    if (!dailyQueue?.auto_advance_token || !canControlAutoAdvance || busy) return;
    setBusy(true);
    setError(null);
    const { error: cancelError } = await pumpOperationsRepository.cancelDailyQueueAutoAdvance(
      dailyQueue.id,
      dailyQueue.auto_advance_token,
      "ألغى المشغّل الانتقال التلقائي",
    );
    if (cancelError) {
      console.error("daily queue auto-advance cancellation failed", cancelError);
      setError(friendlyError(cancelError));
    } else {
      stopHandoverAlert(dailyQueue.auto_advance_token);
      setNotice("تم إلغاء بدء الدور التالي تلقائيًا. يمكنك بدءه يدويًا.");
      await loadPumpData();
    }
    setBusy(false);
  };

  useEffect(() => {
    const queue = dailyQueue;
    const token = queue?.auto_advance_token;
    const itemId = queue?.auto_advance_queue_item_id;
    if (
      !queue
      || !token
      || !itemId
      || !queue.auto_advance_at
      || !(profile?.role === "manager"
        || (profile?.role === "operator"
          && queue.items.some((item) => item.id === itemId && item.is_owned === true)))
      || activeOperation
      || busy
      || !selectedPump
      || selectedPump.status !== "active"
      || !selectedPowerSourceId
      || new Date(queue.auto_advance_at).getTime() > now
      || autoAdvanceInFlight.current === token
    ) {
      return;
    }

    autoAdvanceInFlight.current = token;
    setBusy(true);
    setError(null);
    void (async () => {
      try {
        const { error: advanceError } = await pumpOperationsRepository.startNextDailyQueueItem(
          queue.id,
          itemId,
          token,
          selectedPowerSourceId,
        );
        if (advanceError) {
          console.error("daily queue auto-advance failed", advanceError);
          setError(advanceError.code === "P0002"
            ? "تغير الطابور أو أُلغي الانتقال التلقائي قبل بدء الدور التالي."
            : friendlyError(advanceError));
        } else {
          setNotice("بدأ الدور التالي تلقائيًا بعد انتهاء مهلة الثلاث ثوانٍ.");
        }
        await loadPumpData();
      } finally {
        setBusy(false);
      }
    })();
  }, [
    activeOperation,
    busy,
    dailyQueue?.id,
    dailyQueue?.auto_advance_at,
    dailyQueue?.auto_advance_queue_item_id,
    dailyQueue?.auto_advance_token,
    loadPumpData,
    now,
    profile?.role,
    selectedPowerSourceId,
    selectedPump,
  ]);

  const runAction = useCallback(async (
    action: "pause_pump_operation" | "resume_pump_operation" | "complete_pump_operation",
  ) => {
    if (!activeOperation || busy) return;
    setBusy(true);
    setError(null);
    setNotice(null);
    const { error: actionError } = action === "pause_pump_operation"
      ? await pumpOperationsRepository.pause(activeOperation.id, pauseReason.trim())
      : action === "resume_pump_operation"
        ? await pumpOperationsRepository.resume(
          activeOperation.id,
          resumePowerSourceId || activeOperation.last_power_source_id || "",
        )
        : await pumpOperationsRepository.complete(activeOperation.id);
    if (actionError) {
      console.error("pump operation state change failed", action, actionError);
      setError(friendlyError(actionError));
    } else {
      try {
        if (action === "pause_pump_operation") {
          await pausePersistentPumpTimerNotification(activeOperation);
        } else if (action === "resume_pump_operation") {
          await resumePersistentPumpTimerNotification(activeOperation);
        } else {
          await stopPersistentPumpTimerNotification(activeOperation.id);
        }
      } catch (nativeTimerError) {
        console.warn("Could not update the persistent Android timer notification immediately.", nativeTimerError);
      }

      if (action !== "resume_pump_operation") {
        try {
          await cancelOperationTimerNotifications(activeOperation.id);
        } catch (cancelError) {
          console.warn("Android operation notification cancellation failed.", cancelError);
        }
      }
      const messages = {
        pause_pump_operation: "تم إيقاف المؤقت مؤقتًا.",
        resume_pump_operation: "تم استئناف التشغيل.",
        complete_pump_operation: "انتهت مدة التعبئة، وتم حفظ زمنها الفعلي.",
      };
      setNotice(messages[action]);
      if (action === "pause_pump_operation") setPauseReason("");
      await loadPumpData();
    }
    setBusy(false);
  }, [activeOperation, busy, loadPumpData, pauseReason, resumePowerSourceId]);

  const reloadSurveySeed = async (date: string, requestedOperatorId?: string) => {
    if (!organizationId || !selectedPumpId) return;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      setError("أدخل تاريخًا صحيحًا بصيغة YYYY-MM-DD.");
      return;
    }
    setSurveyLoading(true);
    setSurveyStep(1);
    try {
      let targetOperatorId = requestedOperatorId
        ?? (profile?.role === "operator" ? profile.id : selectedReportOperatorId);

      if (profile?.role === "manager") {
        const operatorsResult = await pumpOperationsRepository.listPumpOperators(organizationId, selectedPumpId, date);
        if (operatorsResult.error) throw operatorsResult.error;
        const operators = (operatorsResult.data ?? []) as { id: string; display_name: string }[];
        setReportOperators(operators);
        if (!targetOperatorId || !operators.some((operator) => operator.id === targetOperatorId)) {
          targetOperatorId = operators[0]?.id ?? "";
        }
        setSelectedReportOperatorId(targetOperatorId);
      } else if (profile?.role === "operator") {
        targetOperatorId = profile.id;
      }

      if (!targetOperatorId) {
        setSurveyEntries([]);
        setSurveyOperations([]);
        setSurveyQueueItems([]);
        setError("لا يوجد مشغّل مكلّف بهذا الغطاس لإعداد التقرير.");
        return;
      }

      if (profile?.role === "manager" || profile?.role === "operator") {
        const preparationResult = await pumpOperationsRepository.prepareDailyWorkReport(
          selectedPumpId,
          date,
        );
        if (preparationResult.error) throw preparationResult.error;
      }

      const [
        operationsResult,
        usageResult,
        sourceResult,
        allocationResult,
        queueItemsResult,
        energyResult,
      ] = await Promise.all([
        pumpOperationsRepository.listPumpOperations(organizationId, selectedPumpId, date),
        pumpOperationsRepository.getPowerUsage(date, date, "day", selectedPumpId),
        pumpOperationsRepository.listPowerSourcesForReport(organizationId, selectedPumpId),
        pumpOperationsRepository.listWeeklyEntitlementAllocationsForDay(organizationId, selectedPumpId, date),
        pumpOperationsRepository.listWeeklyQueueItemsForReport(organizationId, selectedPumpId, date),
        pumpOperationsRepository.getDailyPumpEnergyReport(organizationId, selectedPumpId, date),
      ]);
      if (operationsResult.error || sourceResult.error
          || allocationResult.error || queueItemsResult.error || energyResult.error) {
        throw operationsResult.error ?? sourceResult.error
          ?? allocationResult.error ?? queueItemsResult.error ?? energyResult.error;
      }

      // The server resolves subscriber ownership as of this work date. Using
      // subscribers.operator_id here would silently hide former owners' history.
      const allocations = ((allocationResult.data ?? []) as WeeklyEntitlementAllocationForDay[])
        .filter((allocation) => allocation.subscribers.operator_id === targetOperatorId);
      const allocationIds = new Set(allocations.map((allocation) => allocation.id));
      const scheduledEntries: DailyScheduleEntry[] = allocations
        .filter((allocation) => allocation.source_schedule_entry_id !== null)
        .map((allocation) => ({
          id: allocation.source_schedule_entry_id as string,
          subscriber_id: allocation.subscriber_id,
          weekday: allocation.weekday,
          sort_order: allocation.sort_order,
          planned_minutes: allocation.allocated_minutes,
          entry_type: "weekly" as const,
          schedule_entry_id: allocation.source_schedule_entry_id,
          weekly_entitlement_allocation_id: allocation.id,
          subscribers: allocation.subscribers,
        }));
      const reassignedEntries: DailyScheduleEntry[] = allocations
        .filter((allocation) => allocation.source_schedule_entry_id === null)
        .map((allocation, index) => ({
          id: allocation.id,
          subscriber_id: allocation.subscriber_id,
          weekday: allocation.weekday,
          sort_order: scheduledEntries.length + index,
          planned_minutes: allocation.allocated_minutes,
          entry_type: "weekly_reassigned" as const,
          schedule_entry_id: null,
          weekly_entitlement_allocation_id: allocation.id,
          subscribers: allocation.subscribers,
        }));
      const entries = [...scheduledEntries, ...reassignedEntries];
      const energyReport = energyResult.data as {
        created_by: string;
        work_started_at: string; work_ended_at: string; stoppage_minutes: number;
        status: "draft" | "submitted";
        sourceTotals: { power_source_id: string; minutes: number }[];
      } | null;

      setSurveyPowerSources((sourceResult.data ?? []) as PumpPowerSource[]);
      setSurveyEntries(entries);
      const operatorOperations = ((operationsResult.data ?? []) as Operation[]).filter((operation) =>
        operation.subscriber_operator_id === targetOperatorId
        || (operation.subscriber_id === null && operation.operator_id === targetOperatorId),
      );
      setSurveyOperations(operatorOperations);
      setSurveyQueueItems(((queueItemsResult.data ?? []) as unknown as WeeklyQueueOperationLink[])
        .filter((item) => item.weekly_entitlement_allocation_id && allocationIds.has(item.weekly_entitlement_allocation_id)));
      setSurveyManualMinutes(Object.fromEntries(entries.map((entry) => [entry.id, ""])));
      setSurveyExtraMinutes(Object.fromEntries(entries.map((entry) => [entry.id, ""])));
      const energyIsSubmitted = energyReport?.status === "submitted";
      const energyDraftBelongsToAnotherOperator = Boolean(
        profile?.role === "operator"
        && energyReport
        && energyReport.created_by !== profile.id,
      );
      setSharedEnergySubmitted(energyIsSubmitted);
      setSharedEnergyReadOnly(energyIsSubmitted || energyDraftBelongsToAnotherOperator);

      if (energyReport) {
        setWorkStartTime(localTimeInput(energyReport.work_started_at));
        setWorkEndTime(localTimeInput(energyReport.work_ended_at));
        setStoppageMinutes(String(energyReport.stoppage_minutes));
        setSourceMinutes(Object.fromEntries(
          energyReport.sourceTotals.map((row) => [row.power_source_id, String(row.minutes)]),
        ));
      } else {
        if (usageResult.error) {
          console.error("daily source prefill failed", usageResult.error);
        }
        const usage = (usageResult.data ?? []) as PowerUsageRow[];
        const automatic = usage.filter((row) => row.data_source === "automatic");
        setWorkStartTime("");
        setWorkEndTime("");
        setStoppageMinutes("0");
        setSourceMinutes(allocateWholeMinutesByLargestRemainder(
          automatic.map((row) => ({
            sourceId: row.power_source_id,
            totalSeconds: Number(row.total_seconds ?? 0),
          })),
        ));
      }
      await loadDailyWorkReport(date, targetOperatorId);
    } catch (loadError) {
      console.error("daily work survey seed failed", loadError);
      setError("تعذر تحميل الجدول أو سجلات التشغيل لهذا التاريخ.");
      setSurveyEntries([]);
      setSurveyOperations([]);
      setSurveyQueueItems([]);
    } finally {
      setSurveyLoading(false);
    }
  };

  const saveDailySurvey = async (submit: boolean) => {
    const targetOperatorId = profile?.role === "operator" ? profile.id : selectedReportOperatorId;
    if (!selectedPumpId || !targetOperatorId || surveySaving || activeOperation) return;
    setSurveySaving(true);
    setError(null);
    try {
      const startIso = hebrewLocalToIso(surveyDate, workStartTime);
      const endIso = hebrewLocalToIso(surveyDate, workEndTime);
      const elapsedMinutes = Math.floor((new Date(endIso).getTime() - new Date(startIso).getTime()) / 60000);
      const stops = Number(stoppageMinutes);
      if (!Number.isInteger(stops) || stops < 0 || stops > elapsedMinutes) {
        throw new Error("تحقق من مجموع التوقفات بالدقائق.");
      }
      const expectedPowerMinutes = elapsedMinutes - stops;
      const sourceTotals = Object.entries(sourceMinutes)
        .map(([power_source_id, value]) => ({ power_source_id, minutes: Number(value || 0) }))
        .filter((row) => row.minutes > 0);
      if (sourceTotals.some((row) => !Number.isInteger(row.minutes) || row.minutes < 0)) {
        throw new Error("أدخل دقائق صحيحة لكل مصدر كهرباء.");
      }
      const enteredSourceMinutes = sourceTotals.reduce((sum, row) => sum + row.minutes, 0);
      if (submit && enteredSourceMinutes !== expectedPowerMinutes) {
        throw new Error(`مجموع دقائق المصادر ${enteredSourceMinutes}، بينما مدة التشغيل الصافية ${expectedPowerMinutes} دقيقة. صحح التوزيع قبل الإرسال.`);
      }
      const items = surveyEntries.map((entry, index) => {
        const manual = Number(surveyManualMinutes[entry.id] || 0);
        const extra = Number(surveyExtraMinutes[entry.id] || 0);
        if (!Number.isInteger(manual) || manual < 0 || !Number.isInteger(extra) || extra < 0) {
          throw new Error(`تحقق من الدقائق اليدوية والإضافية للمشترك ${entry.subscribers?.full_name ?? ""}.`);
        }
        const entryType = entry.entry_type ?? "weekly";
        return {
          entry_type: entryType,
          schedule_entry_id: entryType === "weekly_reassigned" ? null : (entry.schedule_entry_id ?? entry.id),
          weekly_entitlement_allocation_id: entry.weekly_entitlement_allocation_id ?? null,
          subscriber_id: entry.subscriber_id,
          sort_order: index,
          manual_minutes: manual,
          extra_minutes: extra,
          note: entryType === "weekly_reassigned" ? "حصة أسبوعية منقولة" : null,
        };
      });
      const { error: saveError } = await pumpOperationsRepository.saveDailyWorkReport({
        pumpId: selectedPumpId,
        operatorId: targetOperatorId,
        workStartedAt: startIso,
        workEndedAt: endIso,
        stoppageMinutes: stops,
        sourceTotals,
        items,
        submit,
      });
      if (saveError) {
        console.error("daily work report save failed", saveError);
        if (saveError.code === "23514") throw new Error("بيانات التقرير لا تطابق الجدول أو مجموع دقائق الطاقة.");
        if (saveError.code === "42501") throw new Error("ليس لديك صلاحية إرسال تقرير هذا الغطاس.");
        if (saveError.code === "55000") throw new Error("يوجد تشغيل لم يُنهَ بعد، أو أن الطاقة المشتركة معتمدة أو محفوظة كمسودة بواسطة مشغّل آخر بقيم مختلفة.");
        throw new Error("تعذر حفظ تقرير العمل اليومي. تحقق من الاتصال والبيانات.");
      }
      setNotice(submit ? "تم اعتماد تقرير العمل اليومي." : "تم حفظ مسودة تقرير العمل اليومي.");
      await loadDailyWorkReport(surveyDate, targetOperatorId);
      if (submit) {
        setSurveyOpen(false);
        setSurveyStep(1);
        await loadPowerUsage();
      }
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "تعذر حفظ تقرير العمل اليومي.");
    } finally {
      setSurveySaving(false);
    }
  };

  const loadWeeklyTransferOptions = async () => {
    if (!selectedPumpId) return;
    setWeeklyTransferLoading(true);
    setError(null);
    const { data, error: optionsError } = await pumpOperationsRepository.getWeeklyEntitlementTransferOptions(
      selectedPumpId,
      weeklyTransferTargetDate,
    );
    if (optionsError) {
      console.error("weekly entitlement transfer options failed", optionsError);
      setWeeklyTransferOptions([]);
      setError(optionsError.code === "P0002"
        ? "لا يوجد جدول أسبوعي فعّال لهذا التاريخ المستهدف أو أن التاريخ خارج الدورة الحالية."
        : "تعذر تحميل الأرصدة الأسبوعية القابلة للنقل.");
    } else {
      const rows = (data ?? []) as WeeklyEntitlementTransferOption[];
      setWeeklyTransferOptions(rows);
      setWeeklyTransferMinutes(Object.fromEntries(
        rows.map((item) => [item.allocation_id, String(Math.min(5, item.available_minutes))]),
      ));
    }
    setWeeklyTransferLoading(false);
  };

  const toggleWeeklyTransfer = () => {
    const next = !weeklyTransferOpen;
    setWeeklyTransferOpen(next);
    if (next) void loadWeeklyTransferOptions();
  };

  const transferWeeklyMinutes = async (item: WeeklyEntitlementTransferOption) => {
    if (!selectedPumpId || busy) return;
    const minutes = Number(weeklyTransferMinutes[item.allocation_id] ?? "");
    const reason = weeklyTransferReason.trim();
    const targetDate = weeklyTransferTargetDate.trim();
    const today = localOperationDate();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(targetDate) || targetDate < today || targetDate > item.cycle_end) {
      setError(`اختر تاريخًا من ${today} إلى ${item.cycle_end} داخل الدورة الأسبوعية الحالية.`);
      return;
    }
    if (!Number.isInteger(minutes) || minutes < 1 || minutes > item.available_minutes) {
      setError(`أدخل دقائق من 1 إلى ${item.available_minutes} لهذه الحصة.`);
      return;
    }
    if (reason.length < 2) {
      setError("سبب نقل الحصة مطلوب ويجب ألا يقل عن حرفين.");
      return;
    }

    setBusy(true);
    setError(null);
    setNotice(null);
    const { error: transferError } = await pumpOperationsRepository.transferWeeklyEntitlementMinutes({
      sourceAllocationId: item.allocation_id,
      targetDate,
      minutes,
      reason,
    });
    if (transferError) {
      console.error("weekly entitlement transfer failed", transferError);
      if (transferError.code === "22023") {
        setError("تعذر النقل: تحقق من الدقائق والسبب، وتأكد أن المصدر والهدف داخل الأسبوع نفسه.");
      } else if (transferError.code === "55000") {
        setError("تعذر النقل لأن الدورة انتهت أو أن أحد الدورين بدأ أو اكتمل.");
      } else if (transferError.code === "42501") {
        setError("ليس لديك صلاحية نقل حصص هذا الغطاس.");
      } else {
        setError("تعذر نقل الحصة. حدّث الطابور ثم أعد المحاولة.");
      }
    } else {
      setNotice(`تم نقل ${minutes} دقيقة من ${item.subscriber_name} إلى ${targetDate} داخل الدورة الأسبوعية، وسُجلت الحركة في دفتر الاستحقاق.`);
      setWeeklyTransferReason("");
      await loadPumpData();
      await loadWeeklyTransferOptions();
    }
    setBusy(false);
  };

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
                <Text style={styles.detailText}>
                  مصدر الطاقة: {powerSources.find((source) => source.id === (activeOperation.current_power_source_id ?? activeOperation.last_power_source_id))?.name ?? "غير محدد"}
                </Text>
                {activeOperation.pause_reason ? <Text style={styles.detailText}>سبب التوقف: {activeOperation.pause_reason}</Text> : null}
              </View>
              <View style={styles.extensionBlock}>
                <Text style={styles.fieldLabel}>إضافة دقائق إلى التعبئة الحالية</Text>
                <View style={styles.extensionRow}>
                  <TextInput
                    value={extensionMinutes}
                    onChangeText={setExtensionMinutes}
                    keyboardType="number-pad"
                    maxLength={4}
                    placeholder="5"
                    style={styles.extensionInput}
                    accessibilityLabel="عدد الدقائق الإضافية"
                  />
                  <Pressable
                    disabled={busy || !/^\d+$/.test(extensionMinutes) || Number(extensionMinutes) < 1}
                    onPress={() => void extendActiveOperation()}
                    style={[styles.extensionButton, (busy || !/^\d+$/.test(extensionMinutes) || Number(extensionMinutes) < 1) && styles.disabled]}
                  >
                    <Plus size={17} color="#fff" />
                    <Text style={styles.actionText}>إضافة الوقت</Text>
                  </Pressable>
                </View>
                <Text style={styles.detailText}>تُضاف المدة إلى الجلسة نفسها دون إنشاء دور جديد، ويُحفظ كل تمديد في سجل التدقيق. الحد الإجمالي 24 ساعة.</Text>
              </View>
              {activeOperation.status === "paused" ? (
                <View style={styles.sourceSelector}>
                  <Text style={styles.fieldLabel}>مصدر الكهرباء عند الاستئناف</Text>
                  <View style={styles.sourceChoices}>
                    {powerSources.map((source) => (
                      <Pressable key={source.id} onPress={() => setResumePowerSourceId(source.id)}
                        style={[styles.sourceChoice, resumePowerSourceId === source.id && styles.sourceChoiceSelected]}>
                        <Text style={[styles.sourceChoiceText, resumePowerSourceId === source.id && styles.sourceChoiceTextSelected]}>{source.name}</Text>
                      </Pressable>
                    ))}
                  </View>
                </View>
              ) : null}
              <View style={styles.actionRow}>
                {activeOperation.status === "running" ? (
                  <View style={styles.pauseControl}>
                    <Text style={styles.fieldLabel}>سبب الإيقاف المؤقت</Text>
                    <TextInput
                      value={pauseReason}
                      onChangeText={setPauseReason}
                      placeholder="مثال: انقطاع الكهرباء أو انتظار إصلاح"
                      maxLength={240}
                      textAlign="right"
                      style={styles.pauseReasonInput}
                      accessibilityLabel="سبب الإيقاف المؤقت"
                    />
                    <Pressable
                      disabled={busy || pauseReason.trim().length < 2}
                      onPress={() => void runAction("pause_pump_operation")}
                      style={[styles.actionButton, styles.pauseButton, (busy || pauseReason.trim().length < 2) && styles.disabled]}
                    >
                      <Pause size={18} color="#fff" /><Text style={styles.actionText}>إيقاف مؤقت مع حفظ السبب</Text>
                    </Pressable>
                  </View>
                ) : (
                  <Pressable disabled={busy || !resumePowerSourceId} onPress={() => void runAction("resume_pump_operation")} style={[styles.actionButton, styles.resumeButton, (busy || !resumePowerSourceId) && styles.disabled]}>
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
              <View style={styles.sourceSelector}>
                <Text style={styles.fieldLabel}>مصدر الكهرباء المستخدم</Text>
                {powerSources.length === 0 ? (
                  <Text style={styles.empty}>لا توجد مصادر كهرباء نشطة لهذا الغطاس. اطلب من المدير إعداد المصادر.</Text>
                ) : (
                  <>
                    <View style={styles.sourceChoices}>
                    {powerSources.map((source) => (
                      <View key={source.id} style={styles.sourceChoiceRow}>
                        <Pressable onPress={() => setSelectedPowerSourceId(source.id)}
                          style={[styles.sourceChoice, styles.sourceChoiceGrow, selectedPowerSourceId === source.id && styles.sourceChoiceSelected]}>
                          <Text style={[styles.sourceChoiceText, selectedPowerSourceId === source.id && styles.sourceChoiceTextSelected]}>{source.name}</Text>
                        </Pressable>
                        {profile?.role === "manager" ? (
                          <Pressable disabled={busy} onPress={() => void archivePowerSource(source.id)} style={styles.archiveSourceButton}>
                            <Text style={styles.archiveSourceText}>أرشفة</Text>
                          </Pressable>
                        ) : null}
                      </View>
                    ))}
                  </View>
                  {profile?.role === "manager" ? (
                    <View style={styles.addSourceBlock}>
                      <Pressable onPress={() => setShowAddPowerSource((open) => !open)} style={styles.refresh}>
                        <Text style={styles.refreshText}>{showAddPowerSource ? "إلغاء إضافة مصدر" : "+ إضافة مصدر جديد"}</Text>
                      </Pressable>
                      {showAddPowerSource ? (
                        <View style={styles.addSourceForm}>
                          <TextInput value={newPowerSourceName} onChangeText={setNewPowerSourceName}
                            style={styles.emergencyInput} placeholder="اسم مصدر الكهرباء" textAlign="right" maxLength={100} />
                          <View style={styles.sourceChoices}>
                            {([
                              ["solar", "شمسي"],
                              ["generator", "مولد"],
                              ["grid", "شبكة"],
                              ["other", "آخر"],
                            ] as const).map(([type, label]) => (
                              <Pressable key={type} onPress={() => setNewPowerSourceType(type)}
                                style={[styles.sourceChoice, newPowerSourceType === type && styles.sourceChoiceSelected]}>
                                <Text style={[styles.sourceChoiceText, newPowerSourceType === type && styles.sourceChoiceTextSelected]}>{label}</Text>
                              </Pressable>
                            ))}
                          </View>
                          <Pressable disabled={busy || newPowerSourceName.trim().length < 2}
                            onPress={() => void addPowerSource()} style={[styles.addSourceButton, (busy || newPowerSourceName.trim().length < 2) && styles.disabled]}>
                            <Text style={styles.actionText}>حفظ المصدر</Text>
                          </Pressable>
                        </View>
                      ) : null}
                    </View>
                  ) : null}
                  </>
                )}
              </View>
            </Card>
          )}

          <Card style={styles.card}>
            {activeOperation ? (
              <View style={styles.sourceSelector}>
                <Text style={styles.fieldLabel}>مصدر الكهرباء للدور التالي</Text>
                {powerSources.length === 0 ? (
                  <Text style={styles.empty}>لا يوجد مصدر طاقة نشط متاح. أوقف الانتقال التلقائي واطلب من المدير تفعيل مصدر.</Text>
                ) : (
                  <View style={styles.sourceChoices}>
                  {powerSources.map((source) => (
                    <Pressable key={source.id} onPress={() => setSelectedPowerSourceId(source.id)}
                      style={[styles.sourceChoice, selectedPowerSourceId === source.id && styles.sourceChoiceSelected]}>
                      <Text style={[styles.sourceChoiceText, selectedPowerSourceId === source.id && styles.sourceChoiceTextSelected]}>
                        {source.name}
                      </Text>
                    </Pressable>
                  ))}
                  </View>
                )}
              </View>
            ) : null}
            <View style={styles.queueHeader}>
                <View style={styles.queueHeaderTitle}>
                  <SectionTitle title="طابور اليوم المعتمد" />
                  <Text style={styles.count}>{queuedItems.length} منتظر</Text>
                </View>
                <Pressable disabled={refreshing || busy} onPress={() => void loadPumpData()} style={styles.refresh}>
                  <RefreshCw size={15} color={colors.brand.primary} />
                  <Text style={styles.refreshText}>تحديث</Text>
                </Pressable>
              </View>

              {dailyQueueError ? (
                <Text style={styles.error}>{dailyQueueError}</Text>
              ) : !dailyQueue ? (
                <Text style={styles.empty}>سيظهر طابور الغطاس هنا بعد اعتماد جدول أسبوعي نشط.</Text>
              ) : (
                <>
                  <View style={styles.queueMetaBlock}>
                    <Text style={styles.queueMeta}>
                      {dailyQueue.queue_date} · الدورة تبدأ {dailyQueue.weekly_cycle_start}
                    </Text>
                    <Text style={styles.queueMeta}>
                      {dailyQueue.status === "closed" ? "مغلق بعد اكتمال الأدوار"
                        : dailyQueue.status === "running" ? "قيد التشغيل" : "جاهز"}
                      {" · إصدار الطابور "}{dailyQueue.queue_version}
                    </Text>
                  </View>

                  {dailyQueue.auto_advance_token && dailyQueue.auto_advance_at ? (
                    <View style={styles.autoAdvanceCard}>
                      <View style={styles.autoAdvanceInfo}>
                        <Text style={styles.autoAdvanceTitle}>الانتقال التلقائي إلى الدور التالي</Text>
                        <Text style={styles.autoAdvanceCountdown}>
                          {autoAdvanceRemainingSeconds === null
                            ? "بانتظار مزامنة موعد الانتقال..."
                            : autoAdvanceRemainingSeconds <= 0
                              ? canControlAutoAdvance
                                ? "جارٍ بدء الدور التالي..."
                                : "حان موعد الدور التالي، بانتظار المشغّل المسؤول."
                              : `سيبدأ خلال ${autoAdvanceRemainingSeconds} ثوانٍ`}
                        </Text>
                      </View>
                      {canControlAutoAdvance && (
                        <Pressable disabled={busy} onPress={() => void cancelAutoAdvance()}
                          style={[styles.cancelAdvanceButton, busy && styles.disabled]}>
                          <Text style={styles.cancelAdvanceText}>إلغاء</Text>
                        </Pressable>
                      )}
                    </View>
                  ) : null}

                  {refreshing ? <ActivityIndicator color={colors.brand.teal} /> : queuedItems.length === 0 ? (
                    <Text style={styles.empty}>
                      {dailyQueue.status === "closed"
                        ? "اكتملت جميع أدوار هذا اليوم."
                        : "لا توجد أدوار منتظرة في الطابور حاليًا."}
                    </Text>
                  ) : queuedItems.map((item, index) => {
                    const isFirst = index === 0;
                    const canManageItem = profile?.role === "manager"
                      || (profile?.role === "operator" && item.is_owned === true);
                    const sourceLabel = item.source_type === "other" ? "دور لمشغّل آخر"
                      : item.source_type === "weekly" ? "حصة أسبوعية"
                        : item.source_type === "weekly_reassigned" ? "حصة أسبوعية منقولة"
                        : item.source_type === "additional_registered" ? "حصة إضافية لمشترك"
                          : item.source_type === "additional_guest" ? "مستفيد إضافي" : "حالة طارئة";
                    return (
                      <View key={item.id} style={styles.queueRow}>
                        <View style={styles.queueNumber}>
                          <Text style={styles.queueNumberText}>{index + 1}</Text>
                        </View>
                        <View style={styles.queueInfo}>
                          <Text style={styles.queueName}>{item.subscriber_name_snapshot}</Text>
                          <Text style={styles.queueMeta}>
                            {sourceLabel}{item.source_type !== "other" ? ` · ${item.planned_minutes} دقيقة` : ""}
                            {item.branch_name_snapshot ? ` · ${item.branch_name_snapshot}` : ""}
                          </Text>
                        </View>
                        <View style={styles.queueReorderControls}>
                          {profile?.role === "manager" && <>
                            <Pressable accessibilityLabel="تحريك الدور إلى أعلى" disabled={busy || index === 0}
                              onPress={() => void moveQueueItem(item.id, -1)}
                              style={[styles.reorderButton, (busy || index === 0) && styles.disabled]}>
                              <Text style={styles.reorderText}>↑</Text>
                            </Pressable>
                            <Pressable accessibilityLabel="تحريك الدور إلى أسفل" disabled={busy || index === queuedItems.length - 1}
                              onPress={() => void moveQueueItem(item.id, 1)}
                              style={[styles.reorderButton, (busy || index === queuedItems.length - 1) && styles.disabled]}>
                              <Text style={styles.reorderText}>↓</Text>
                            </Pressable>
                          </>}
                          {canManageItem && <>
                            <Pressable accessibilityLabel="تأجيل الدور إلى نهاية الطابور"
                              disabled={busy || queuedItems.length < 2 || queueItemActionReason.trim().length < 2}
                              onPress={() => void manageQueueItem(item, "defer")}
                              style={[styles.reorderButton, (busy || queuedItems.length < 2 || queueItemActionReason.trim().length < 2) && styles.disabled]}>
                              <Text style={styles.reorderText}>تأجيل</Text>
                            </Pressable>
                            <Pressable accessibilityLabel="إلغاء هذا الدور"
                              disabled={busy || queueItemActionReason.trim().length < 2}
                              onPress={() => confirmCancelQueueItem(item)}
                              style={[styles.cancelAdvanceButton, (busy || queueItemActionReason.trim().length < 2) && styles.disabled]}>
                              <Text style={styles.cancelAdvanceText}>إلغاء</Text>
                            </Pressable>
                          </>}
                        </View>
                        {canManageItem ? (
                          <Pressable disabled={busy || Boolean(activeOperation) || hasForeignRunningQueueItem || !isFirst || selectedPump.status !== "active" || !selectedPowerSourceId}
                            onPress={() => void startQueueItem(item)}
                            style={[styles.startButton, (busy || Boolean(activeOperation) || hasForeignRunningQueueItem || !isFirst || selectedPump.status !== "active" || !selectedPowerSourceId) && styles.disabled]}>
                            <Play size={14} color="#fff" /><Text style={styles.startText}>{isFirst ? "بدء" : "انتظار"}</Text>
                          </Pressable>
                        ) : (
                          <Text style={styles.queueMeta}>
                            {item.source_type === "other" ? "بانتظار المشغّل المسؤول" : "عرض للقراءة فقط"}
                          </Text>
                        )}
                      </View>
                    );
                  })}

                  <Text style={styles.fieldLabel}>سبب تجاوز قاعدة التفرعات (عند الحاجة)</Text>
                  <TextInput value={queueOverrideReason} onChangeText={setQueueOverrideReason}
                    placeholder="يُحفظ السبب عند وضع دورين من التفرع نفسه متتاليين"
                    maxLength={240} textAlign="right" style={styles.queueReasonInput} />

                  <Text style={styles.fieldLabel}>سبب التأجيل أو الإلغاء (إلزامي)</Text>
                  <TextInput value={queueItemActionReason} onChangeText={setQueueItemActionReason}
                    placeholder="مثال: طلب المستفيد تأجيل دوره أو إلغاء الحصة"
                    maxLength={240} textAlign="right" style={styles.queueReasonInput} />

                  {completedQueueItems.length > 0 ? (
                    <View style={styles.completedQueueBlock}>
                      <Text style={styles.fieldLabel}>أدوار مكتملة اليوم ({completedQueueItems.length})</Text>
                      {completedQueueItems.slice(0, 5).map((item) => (
                        <View key={item.id} style={styles.completedQueueRow}>
                          <CheckCircle2 size={15} color={colors.status.success.main} />
                          <Text style={styles.completedQueueName}>{item.subscriber_name_snapshot}</Text>
                          <Text style={styles.queueMeta}>{formatTime(item.completed_at)}</Text>
                        </View>
                      ))}
                    </View>
                  ) : null}

                  {dailyQueue.events.length > 0 ? (
                    <View style={styles.completedQueueBlock}>
                      <Text style={styles.fieldLabel}>آخر أحداث الطابور وسجل التدقيق</Text>
                      {dailyQueue.events.slice(0, 6).map((event) => {
                        const eventLabels: Record<string, string> = {
                          queue_generated: "إنشاء طابور اليوم",
                          item_created: "إضافة دور",
                          item_deferred: "تأجيل إلى نهاية الطابور",
                          item_cancelled: "إلغاء دور",
                          item_operator_reassigned: "تغيير المشغّل المسؤول",
                          reordered: "إعادة ترتيب الطابور",
                          branch_order_override: "تجاوز قاعدة التفرعات",
                          started: "بدء تعبئة",
                          completed: "اكتمال تعبئة",
                          auto_advance_scheduled: "جدولة الانتقال التلقائي",
                          auto_advance_retargeted: "تحديث هدف الانتقال التلقائي",
                          auto_advance_cancelled: "إلغاء الانتقال التلقائي",
                          queue_closed: "إغلاق طابور اليوم",
                          weekly_minutes_transferred: "نقل دقائق حصة أسبوعية",
                        };
                        return (
                          <View key={event.id} style={styles.completedQueueRow}>
                            <View style={{ flex: 1, alignItems: "flex-end", gap: 2 }}>
                              <Text style={styles.completedQueueName}>{eventLabels[event.event_type] ?? event.event_type}</Text>
                              <Text style={styles.queueMeta}>
                                {formatTime(event.occurred_at)}{event.reason ? ` · السبب: ${event.reason}` : ""}
                              </Text>
                            </View>
                          </View>
                        );
                      })}
                    </View>
                  ) : null}

                  {(profile?.role === "manager" || profile?.role === "operator") ? (
                    <View style={styles.weeklyTransferBlock}>
                      <Pressable onPress={toggleWeeklyTransfer} style={styles.refresh}>
                        <Text style={styles.refreshText}>
                          {weeklyTransferOpen ? "إغلاق نقل الحصة الأسبوعية" : "نقل دقائق حصة أسبوعية من يوم آخر"}
                        </Text>
                      </Pressable>
                      {weeklyTransferOpen ? (
                        <View style={styles.weeklyTransferForm}>
                          <Text style={styles.detailText}>
                            انقل الدقائق غير المستخدمة إلى أي يوم قادم داخل الدورة الأسبوعية نفسها. لا يمكن نقل الدقائق المنفذة أو ترحيلها إلى أسبوع آخر.
                          </Text>
                          <Text style={styles.fieldLabel}>تاريخ اليوم المستهدف (YYYY-MM-DD)</Text>
                          <TextInput
                            value={weeklyTransferTargetDate}
                            onChangeText={(value) => setWeeklyTransferTargetDate(value)}
                            placeholder="YYYY-MM-DD"
                            keyboardType="numbers-and-punctuation"
                            maxLength={10}
                            textAlign="center"
                            style={styles.queueReasonInput}
                          />
                          {weeklyTransferLoading ? (
                            <ActivityIndicator color={colors.brand.teal} />
                          ) : weeklyTransferOptions.length === 0 ? (
                            <Text style={styles.empty}>لا توجد دقائق أسبوعية متبقية قابلة للنقل إلى التاريخ المحدد.</Text>
                          ) : (
                            weeklyTransferOptions.map((item) => {
                              const entered = Number(weeklyTransferMinutes[item.allocation_id] ?? "");
                              const valid = Number.isInteger(entered) && entered >= 1 && entered <= item.available_minutes;
                              return (
                                <View key={item.allocation_id} style={styles.weeklyTransferRow}>
                                  <View style={styles.weeklyTransferInfo}>
                                    <Text style={styles.queueName}>{item.subscriber_name}</Text>
                                    <Text style={styles.queueMeta}>
                                      من تاريخ {item.source_date} · المتاح في هذا اليوم {item.available_minutes} د
                                      {" · استهلك أسبوعيًا "}{item.weekly_consumed_minutes} من {item.weekly_quota_minutes} د
                                      {" · المتبقي من الحصة الأسبوعية "}{item.weekly_remaining_minutes} د
                                    </Text>
                                  </View>
                                  <View style={styles.weeklyTransferAction}>
                                    <TextInput
                                      value={weeklyTransferMinutes[item.allocation_id] ?? ""}
                                      onChangeText={(value) => setWeeklyTransferMinutes((current) => ({
                                        ...current,
                                        [item.allocation_id]: value,
                                      }))}
                                      keyboardType="number-pad"
                                      maxLength={4}
                                      placeholder="الدقائق"
                                      accessibilityLabel={`دقائق النقل للمشترك ${item.subscriber_name}`}
                                      style={styles.weeklyTransferInput}
                                    />
                                    <Pressable
                                      disabled={busy || !valid || weeklyTransferReason.trim().length < 2
                                        || (weeklyTransferTargetDate === localOperationDate() && dailyQueue.status === "closed")}
                                      onPress={() => void transferWeeklyMinutes(item)}
                                      style={[styles.weeklyTransferButton, (busy || !valid || weeklyTransferReason.trim().length < 2
                                        || (weeklyTransferTargetDate === localOperationDate() && dailyQueue.status === "closed")) && styles.disabled]}
                                    >
                                      <Text style={styles.actionText}>نقل إلى اليوم</Text>
                                    </Pressable>
                                  </View>
                                </View>
                              );
                            })
                          )}
                          <Text style={styles.fieldLabel}>سبب النقل (إلزامي)</Text>
                          <TextInput
                            value={weeklyTransferReason}
                            onChangeText={setWeeklyTransferReason}
                            placeholder="مثال: تعذر إكمال الحصة في يومها"
                            maxLength={240}
                            textAlign="right"
                            style={styles.queueReasonInput}
                          />
                          <Pressable
                            disabled={weeklyTransferLoading || busy}
                            onPress={() => void loadWeeklyTransferOptions()}
                            style={[styles.refresh, (weeklyTransferLoading || busy) && styles.disabled]}
                          >
                            <Text style={styles.refreshText}>تحديث الأرصدة المتاحة</Text>
                          </Pressable>
                        </View>
                      ) : null}
                    </View>
                  ) : null}

                  <View style={styles.emergencyBlock}>
                    <Pressable onPress={() => setQueueAdditionOpen((open) => !open)} style={styles.refresh}>
                      <Text style={styles.refreshText}>
                        {queueAdditionOpen ? "إغلاق الإضافة" : "+ إضافة حصة إلى آخر الطابور"}
                      </Text>
                    </Pressable>
                    {queueAdditionOpen ? (
                      <View style={styles.queueAdditionForm}>
                        <Text style={styles.fieldLabel}>نوع الإضافة</Text>
                        <View style={styles.sourceChoices}>
                          {([
                            ["additional_registered", "مشترك مسجل"],
                            ["additional_guest", "مستفيد إضافي"],
                            ["emergency", "حالة طارئة"],
                          ] as const).map(([type, label]) => (
                            <Pressable key={type} onPress={() => setQueueAdditionType(type)}
                              style={[styles.sourceChoice, queueAdditionType === type && styles.sourceChoiceSelected]}>
                              <Text style={[styles.sourceChoiceText, queueAdditionType === type && styles.sourceChoiceTextSelected]}>{label}</Text>
                            </Pressable>
                          ))}
                        </View>
                        {queueAdditionType === "additional_registered" ? (
                          <View style={styles.queueSubscriberChoices}>
                            {subscribers.length === 0 ? <Text style={styles.empty}>لا يوجد مشتركون نشطون لهذا الغطاس.</Text>
                              : subscribers.map((subscriber) => (
                                <Pressable key={subscriber.id} onPress={() => setQueueAdditionSubscriberId(subscriber.id)}
                                  style={[styles.queueSubscriberChoice, queueAdditionSubscriberId === subscriber.id && styles.sourceChoiceSelected]}>
                                  <Text style={[styles.queueSubscriberName, queueAdditionSubscriberId === subscriber.id && styles.sourceChoiceTextSelected]}>
                                    {subscriber.full_name}
                                  </Text>
                                </Pressable>
                              ))}
                          </View>
                        ) : (
                          <TextInput value={queueAdditionName} onChangeText={setQueueAdditionName}
                            placeholder="اسم المستفيد" style={styles.emergencyInput} textAlign="right" maxLength={120} />
                        )}
                        <Text style={styles.fieldLabel}>مدة الحصة بالدقائق</Text>
                        <TextInput value={queueAdditionMinutes} onChangeText={setQueueAdditionMinutes}
                          keyboardType="number-pad" placeholder="30" style={styles.durationInput} />
                        <Pressable disabled={busy || !Number.isInteger(Number(queueAdditionMinutes)) || Number(queueAdditionMinutes) < 1 || Number(queueAdditionMinutes) > 1440}
                          onPress={() => void appendQueueItem()}
                          style={[styles.addSourceButton, (busy || !Number.isInteger(Number(queueAdditionMinutes)) || Number(queueAdditionMinutes) < 1 || Number(queueAdditionMinutes) > 1440) && styles.disabled]}>
                          <Text style={styles.actionText}>إضافة إلى نهاية الطابور</Text>
                        </Pressable>
                      </View>
                    ) : null}
                  </View>
                </>
              )}
            </Card>

          <Card style={styles.card}>
            <Pressable onPress={() => {
              if (!surveyOpen) {
                setSurveyStep(1);
                const day = localOperationDate();
                setSurveyDate(day);
                setWorkStartTime("");
                setWorkEndTime("");
                setStoppageMinutes("0");
                void reloadSurveySeed(day);
              }
              setSurveyOpen((open) => !open);
            }} style={styles.surveyToggle}>
              <View style={styles.sectionHeader}>
                <SectionTitle title="استبيان عمل اليوم" />
                <Text style={styles.refreshText}>{surveyOpen ? "إخفاء" : "تسجيل عمل اليوم"}</Text>
              </View>
              <Text style={styles.empty}>يوثّق ما تم بعد انتهاء العمل، بما في ذلك التعبئات التي نُفذت خارج التطبيق.</Text>
            </Pressable>
            {surveyOpen ? (
              surveyLoading ? <ActivityIndicator color={colors.brand.teal} /> : (
                <View style={styles.surveyBody}>
                  {profile?.role === "manager" ? (
                    <View style={{ gap: 8 }}>
                      <Text style={styles.fieldLabel}>التقرير الخاص بالمشغّل</Text>
                      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
                        {reportOperators.map((operator) => {
                          const selected = operator.id === selectedReportOperatorId;
                          return (
                            <Pressable
                              key={operator.id}
                              onPress={() => {
                                setSelectedReportOperatorId(operator.id);
                                void reloadSurveySeed(surveyDate, operator.id);
                              }}
                              style={[styles.reorderButton, selected && { backgroundColor: colors.brand.teal }]}
                            >
                              <Text style={[styles.reorderText, selected && { color: "#ffffff" }]}>
                                {operator.display_name}
                              </Text>
                            </Pressable>
                          );
                        })}
                      </ScrollView>
                    </View>
                  ) : null}
                  {surveyStep === 1 ? (
                    <>
                      <Text style={styles.surveyStep}>الخطوة 1 من 2 — وقت العمل ومصادر الكهرباء</Text>
                      <Text style={styles.fieldLabel}>تاريخ العمل (YYYY-MM-DD)</Text>
                      <View style={styles.surveyInputsRow}>
                        <TextInput value={surveyDate} onChangeText={setSurveyDate} style={[styles.durationInput, { flex: 1 }]}
                          autoCapitalize="none" placeholder="2026-11-09" />
                        <Pressable onPress={() => void reloadSurveySeed(surveyDate)} style={styles.reorderButton}>
                          <Text style={styles.reorderText}>تحميل التاريخ</Text>
                        </Pressable>
                      </View>
                      <View style={styles.surveyInputsRow}>
                        <View style={styles.surveyInputCell}>
                          <Text style={styles.fieldLabel}>بداية العمل</Text>
                          <TextInput value={workStartTime} onChangeText={setWorkStartTime} style={styles.surveyTimeInput}
                            editable={!sharedEnergyReadOnly} placeholder="07:00" keyboardType="numbers-and-punctuation" />
                        </View>
                        <View style={styles.surveyInputCell}>
                          <Text style={styles.fieldLabel}>نهاية العمل</Text>
                          <TextInput value={workEndTime} onChangeText={setWorkEndTime} style={styles.surveyTimeInput}
                            editable={!sharedEnergyReadOnly} placeholder="15:00" keyboardType="numbers-and-punctuation" />
                        </View>
                        <View style={styles.surveyInputCell}>
                          <Text style={styles.fieldLabel}>التوقفات بالدقائق</Text>
                          <TextInput value={stoppageMinutes} onChangeText={setStoppageMinutes} style={styles.surveyTimeInput}
                            editable={!sharedEnergyReadOnly} keyboardType="number-pad" placeholder="0" />
                        </View>
                      </View>
                      <Text style={styles.fieldLabel}>إجمالي دقائق كل مصدر كهرباء (يشمل التشغيل المسجل آليًا)</Text>
                      {surveyPowerSources.map((source) => (
                        <View key={source.id} style={styles.surveySourceRow}>
                          <Text style={styles.surveySourceName}>
                            {source.name}{source.is_active ? "" : " (مؤرشف)"}
                          </Text>
                          <TextInput value={sourceMinutes[source.id] ?? ""} onChangeText={(value) =>
                            setSourceMinutes((current) => ({ ...current, [source.id]: value }))
                          } style={styles.surveyMinutesInput} editable={!sharedEnergyReadOnly}
                            keyboardType="number-pad" placeholder="الدقائق" />
                        </View>
                      ))}
                      <Text style={styles.historyMeta}>
                        {sharedEnergySubmitted
                          ? "تم اعتماد توزيع طاقة الغطاس لهذا اليوم، ويُستخدم نفسه في تقارير جميع المشغّلين ولا يمكن تغييره."
                          : sharedEnergyReadOnly
                            ? "هذه مسودة طاقة مشتركة أنشأها مشغّل آخر. يمكنك استخدام الأرقام نفسها في تقريرك، ويستطيع منشئ المسودة أو المدير تعديلها."
                            : "توزيع طاقة واحد مشترك للغطاس في هذا اليوم. يجب أن يساوي مجموع دقائق المصادر مدة العمل بعد خصم التوقفات."}
                      </Text>
                      <View style={styles.surveyActions}>
                        <Pressable
                          disabled={surveyLoading || Boolean(activeOperation)}
                          onPress={() => {
                            try {
                              const startIso = hebrewLocalToIso(surveyDate, workStartTime);
                              const endIso = hebrewLocalToIso(surveyDate, workEndTime);
                              const elapsedMinutes = Math.floor((new Date(endIso).getTime() - new Date(startIso).getTime()) / 60000);
                              const stops = Number(stoppageMinutes);
                              if (elapsedMinutes <= 0 || !Number.isInteger(stops) || stops < 0 || stops > elapsedMinutes) {
                                throw new Error("تحقق من وقت البداية والنهاية ومجموع التوقفات.");
                              }
                              const invalidSourceMinutes = Object.values(sourceMinutes).some((value) =>
                                value.trim() !== "" && (!Number.isInteger(Number(value)) || Number(value) < 0),
                              );
                              if (invalidSourceMinutes) {
                                throw new Error("أدخل أعدادًا صحيحة وغير سالبة لدقائق مصادر الكهرباء.");
                              }
                              const enteredSourceMinutes = Object.values(sourceMinutes)
                                .reduce((sum, value) => sum + (value.trim() === "" ? 0 : Number(value)), 0);
                              const expectedMinutes = elapsedMinutes - stops;
                              if (enteredSourceMinutes !== expectedMinutes) {
                                throw new Error(`مجموع دقائق المصادر ${enteredSourceMinutes}، بينما مدة العمل بعد التوقفات ${expectedMinutes} دقيقة.`);
                              }
                              setError(null);
                              setSurveyStep(2);
                            } catch (validationError) {
                              setError(validationError instanceof Error ? validationError.message : "تحقق من بيانات وقت العمل والطاقة.");
                            }
                          }}
                          style={[styles.surveySubmitButton, (surveyLoading || Boolean(activeOperation)) && styles.disabled]}
                        >
                          <Text style={styles.actionText}>التالي: جدول تعبئة المشتركين</Text>
                        </Pressable>
                      </View>
                    </>
                  ) : (
                    <>
                      <Text style={styles.surveyStep}>الخطوة 2 من 2 — مراجعة وتنفيذ جدول اليوم</Text>
                      <Text style={styles.historyMeta}>
                        {surveyDate} · {workStartTime} إلى {workEndTime} · التوقفات {stoppageMinutes} دقيقة
                      </Text>
                      <Pressable onPress={() => setSurveyStep(1)} style={styles.refresh}>
                        <Text style={styles.refreshText}>العودة لتعديل الوقت ومصادر الكهرباء</Text>
                      </Pressable>
                      <Text style={styles.empty}>الجدول الافتراضي لهذا اليوم. يمكنك تغيير الترتيب. لا تُعد إدخال الدقائق المسجلة آليًا؛ أدخل فقط ما نُفذ خارج التطبيق، مع السماح بالتعبئة الجزئية.</Text>
                      {surveyEntries.length === 0 ? (
                        <Text style={styles.empty}>لا توجد حصص أسبوعية في الجدول لهذا اليوم. يمكن حفظ تقرير المصادر، وسيظل الجدول فارغًا.</Text>
                      ) : surveyEntries.map((entry, index) => {
                        const subscriber = entry.subscribers;
                        const allocationId = entry.weekly_entitlement_allocation_id;
                        const automaticSeconds = surveyQueueItems
                          .filter((item) => item.weekly_entitlement_allocation_id === allocationId && item.operation_id)
                          .reduce((sum, item) => {
                            const operation = surveyOperations.find((candidate) => candidate.id === item.operation_id);
                            return sum + (operation?.status === "completed" ? operation.actual_seconds ?? 0 : 0);
                          }, 0);
                        const automaticMinutes = Math.floor(automaticSeconds / 60);
                        return (
                          <View key={entry.id} style={styles.surveyEntry}>
                            <View style={styles.surveyEntryHeader}>
                              <View style={styles.surveyReorder}>
                                <Pressable disabled={index === 0} onPress={() => setSurveyEntries((current) => {
                                  const next = [...current]; [next[index - 1], next[index]] = [next[index], next[index - 1]]; return next;
                                })} style={styles.reorderButton}><Text style={styles.reorderText}>↑</Text></Pressable>
                                <Pressable disabled={index === surveyEntries.length - 1} onPress={() => setSurveyEntries((current) => {
                                  const next = [...current]; [next[index + 1], next[index]] = [next[index], next[index + 1]]; return next;
                                })} style={styles.reorderButton}><Text style={styles.reorderText}>↓</Text></Pressable>
                              </View>
                              <View style={styles.surveyEntryInfo}>
                                <Text style={styles.queueName}>{subscriber?.full_name ?? "مشترك"}</Text>
                                <Text style={styles.queueMeta}>
                                  {entry.entry_type === "weekly_reassigned" ? "حصة أسبوعية منقولة" : "الحصة الأسبوعية"}
                                  {" · المخصص "}{entry.planned_minutes} د · المسجل آليًا {automaticMinutes} د
                                </Text>
                              </View>
                            </View>
                            <View style={styles.surveyInputsRow}>
                              <View style={styles.surveyInputCell}>
                                <Text style={styles.fieldLabel}>المنفذ خارج التطبيق</Text>
                                <TextInput value={surveyManualMinutes[entry.id] ?? ""} onChangeText={(value) =>
                                  setSurveyManualMinutes((current) => ({ ...current, [entry.id]: value }))
                                } style={styles.surveyTimeInput} keyboardType="number-pad" placeholder="0" />
                              </View>
                              <View style={styles.surveyInputCell}>
                                <Text style={styles.fieldLabel}>الإجمالي الفعلي</Text>
                                <Text style={styles.surveyActual}>
                                  {automaticMinutes + (Number(surveyManualMinutes[entry.id] || 0) || 0)} دقيقة
                                </Text>
                              </View>
                              <View style={styles.surveyInputCell}>
                                <Text style={styles.fieldLabel}>دقائق إضافية خارج الحصة</Text>
                                <TextInput value={surveyExtraMinutes[entry.id] ?? ""} onChangeText={(value) =>
                                  setSurveyExtraMinutes((current) => ({ ...current, [entry.id]: value }))
                                } style={styles.surveyTimeInput} keyboardType="number-pad" placeholder="0" />
                              </View>
                            </View>
                          </View>
                        );
                      })}
                      <View style={styles.surveyActions}>
                        <Pressable disabled={surveySaving || Boolean(activeOperation)} onPress={() => void saveDailySurvey(false)}
                          style={[styles.surveySaveButton, (surveySaving || Boolean(activeOperation)) && styles.disabled]}>
                          <Text style={styles.actionText}>حفظ مسودة</Text>
                        </Pressable>
                        <Pressable disabled={surveySaving || Boolean(activeOperation)} onPress={() => void saveDailySurvey(true)}
                          style={[styles.surveySubmitButton, (surveySaving || Boolean(activeOperation)) && styles.disabled]}>
                          <Text style={styles.actionText}>إرسال التقرير واعتماده</Text>
                        </Pressable>
                      </View>
                    </>
                  )}
                </View>
              )
            ) : null}
          </Card>

          <Card style={styles.card}>
            <View style={styles.sectionHeader}>
              <SectionTitle title="استهلاك مصادر الكهرباء" />
              <Text style={styles.count}>بالدقائق</Text>
            </View>
            <View style={styles.usagePeriods}>
              {(["day", "week", "month"] as const).map((period) => (
                <Pressable key={period} onPress={() => setUsagePeriod(period)}
                  style={[styles.usagePeriodButton, usagePeriod === period && styles.usagePeriodButtonSelected]}>
                  <Text style={[styles.usagePeriodText, usagePeriod === period && styles.usagePeriodTextSelected]}>
                    {period === "day" ? "اليوم" : period === "week" ? "الأسبوع" : "الشهر"}
                  </Text>
                </Pressable>
              ))}
            </View>
            {powerUsageLoading ? <ActivityIndicator color={colors.brand.teal} /> : powerUsageError ? (
              <Text style={styles.error}>{powerUsageError}</Text>
            ) : groupedPowerUsage.length === 0 ? (
              <Text style={styles.empty}>لا توجد دقائق مسجلة لمصادر الكهرباء في هذه الفترة.</Text>
            ) : groupedPowerUsage.map((row) => (
              <View key={row.id} style={styles.usageRow}>
                <Text style={styles.queueName}>{row.name}</Text>
                <Text style={styles.usageMinutes}>{row.minutes.toFixed(2)} دقيقة</Text>
                <Text style={styles.historyMeta}>
                  {row.sources.has("daily_survey") ? "يشمل استبيان عمل اليوم" : "من سجل التشغيل الآلي"}
                </Text>
              </View>
            ))}
          </Card>

          {dailyWorkReportLoading ? (
            <Card style={styles.card}>
              <ActivityIndicator color={colors.brand.teal} />
              <Text style={styles.empty}>جاري تحميل التقرير اليومي...</Text>
            </Card>
          ) : dailyWorkReportError ? (
            <Card style={styles.card}>
              <Text style={styles.error}>{dailyWorkReportError}</Text>
            </Card>
          ) : dailyWorkReport ? (
            <Card style={styles.card}>
              <View style={styles.sectionHeader}>
                <SectionTitle title="تفاصيل تقرير العمل اليومي" />
                <StatusBadge
                  label={dailyWorkReport.status === "submitted" ? "معتمد" : "مسودة"}
                  status={dailyWorkReport.status === "submitted" ? "success" : "warning"}
                />
              </View>
              <Text style={styles.historyMeta}>
                {dailyWorkReport.work_date} · {formatTime(dailyWorkReport.work_started_at)} – {formatTime(dailyWorkReport.work_ended_at)}
              </Text>
              <Text style={styles.detailText}>مجموع التوقفات: {dailyWorkReport.stoppage_minutes} دقيقة</Text>
              <Text style={styles.surveyStep}>توزيع دقائق مصادر الكهرباء</Text>
              {dailyWorkReport.sourceTotals.map((source) => (
                <View key={source.id} style={styles.usageRow}>
                  <Text style={styles.queueName}>{source.source_name_snapshot}</Text>
                  <Text style={styles.usageMinutes}>{source.minutes} دقيقة</Text>
                </View>
              ))}
              <Text style={styles.surveyStep}>تفصيل التعبئات</Text>
              {dailyWorkReport.items.map((item) => (
                <View key={item.id} style={styles.surveyEntry}>
                  <View style={styles.surveyEntryHeader}>
                    <View style={styles.surveyEntryInfo}>
                      <Text style={styles.queueName}>
                        {item.subscriber_name_snapshot ?? item.external_beneficiary_name ?? "مستفيد إضافي"}
                      </Text>
                      <Text style={styles.historyMeta}>
                        {item.entry_type === "weekly_reassigned" ? "حصة أسبوعية منقولة · " :
                          item.entry_type === "weekly" ? "حصة أسبوعية · " : "حصة إضافية · "}
                        {item.fulfillment_status === "complete" ? "مكتملة" :
                          item.fulfillment_status === "partial" ? "جزئية" :
                            item.fulfillment_status === "not_done" ? "لم تتم" : "إضافية"}
                      </Text>
                    </View>
                  </View>
                  <View style={styles.reportMetricRow}>
                    <Text style={styles.reportMetric}>المقرر: {item.scheduled_minutes} د</Text>
                    <Text style={styles.reportMetric}>آلي: {item.app_recorded_minutes} د</Text>
                    <Text style={styles.reportMetric}>يدوي: {item.manual_minutes} د</Text>
                    <Text style={styles.reportMetric}>مستهلك أسبوعيًا: {item.weekly_minutes_consumed} د</Text>
                    <Text style={styles.reportMetric}>إضافي: {item.extra_minutes + item.app_over_quota_minutes} د</Text>
                  </View>
                </View>
              ))}
              <Text style={styles.historyMeta}>
                سجل التدقيق: {dailyWorkReport.events.length} أحداث محفوظة · آخر تحديث {formatTime(dailyWorkReport.updated_at)}
              </Text>
            </Card>
          ) : null}

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
  sourceSelector: { gap: spacing.xs },
  sourceChoices: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.xs },
  sourceChoice: { borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingVertical: spacing.sm, paddingHorizontal: spacing.md, backgroundColor: colors.background.surface },
  sourceChoiceSelected: { backgroundColor: colors.brand.primary, borderColor: colors.brand.primary },
  sourceChoiceText: { color: colors.text.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  sourceChoiceTextSelected: { color: colors.text.inverse },
  surveyToggle: { gap: spacing.xs },
  surveyBody: { gap: spacing.md },
  sourceChoiceRow: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.xs, width: "100%" },
  sourceChoiceGrow: { flex: 1 },
  archiveSourceButton: { paddingVertical: spacing.sm, paddingHorizontal: spacing.sm, borderRadius: radius.sm, backgroundColor: colors.status.warning.background },
  archiveSourceText: { color: colors.status.warning.text, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  addSourceBlock: { borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.xs, gap: spacing.sm },
  addSourceForm: { gap: spacing.sm },
  addSourceButton: { minHeight: 44, borderRadius: radius.md, backgroundColor: colors.brand.primary, alignItems: "center", justifyContent: "center" },
  surveyStep: { color: colors.brand.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold, textAlign: "right", paddingTop: spacing.sm },
  surveyInputsRow: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.sm },
  surveyInputCell: { flex: 1, minWidth: 110, gap: 5 },
  surveyTimeInput: { minHeight: 44, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.sm, color: colors.text.primary, backgroundColor: colors.background.surface, textAlign: "center" },
  surveySourceRow: { flexDirection: "row-reverse", alignItems: "center", justifyContent: "space-between", gap: spacing.sm },
  surveySourceName: { flex: 1, color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  surveyMinutesInput: { width: 100, minHeight: 42, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, color: colors.text.primary, textAlign: "center", backgroundColor: colors.background.surface },
  surveyEntry: { gap: spacing.xs, borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm },
  surveyEntryHeader: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  surveyReorder: { flexDirection: "row", gap: 4 },
  reorderButton: { width: 32, height: 32, borderRadius: radius.sm, backgroundColor: colors.background.subtle, alignItems: "center", justifyContent: "center" },
  reorderText: { color: colors.brand.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold },
  surveyEntryInfo: { flex: 1, alignItems: "flex-end", gap: 4 },
  surveyActual: { color: colors.brand.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold, minHeight: 44, textAlignVertical: "center" },
  surveyActions: { flexDirection: "row-reverse", gap: spacing.sm },
  surveySaveButton: { flex: 1, backgroundColor: colors.brand.teal, minHeight: 48, borderRadius: radius.md, alignItems: "center", justifyContent: "center" },
  surveySubmitButton: { flex: 1, backgroundColor: "#27815D", minHeight: 48, borderRadius: radius.md, alignItems: "center", justifyContent: "center" },
  usagePeriods: { flexDirection: "row-reverse", gap: spacing.xs },
  usagePeriodButton: { flex: 1, padding: spacing.sm, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, alignItems: "center" },
  usagePeriodButtonSelected: { backgroundColor: colors.brand.primary, borderColor: colors.brand.primary },
  usagePeriodText: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.medium },
  usagePeriodTextSelected: { color: colors.text.inverse },
  usageRow: { gap: 4, paddingVertical: spacing.sm, borderTopWidth: 1, borderTopColor: colors.background.subtle, alignItems: "flex-end" },
  reportMetricRow: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.xs },
  reportMetric: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium, backgroundColor: colors.background.subtle, borderRadius: radius.sm, paddingVertical: 4, paddingHorizontal: spacing.xs },
  usageMinutes: { color: colors.brand.primary, fontSize: typography.fontSize.lg, fontFamily: typography.fontFamily.bold, fontVariant: ["tabular-nums"] },
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
  extensionBlock: { gap: spacing.xs, paddingTop: spacing.sm, borderTopWidth: 1, borderTopColor: "#31586B" },
  extensionRow: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  extensionInput: { width: 94, minHeight: 46, borderWidth: 1, borderColor: "#55788A", borderRadius: radius.md, paddingHorizontal: spacing.md, color: colors.text.inverse, backgroundColor: "#24485A", textAlign: "center", fontSize: typography.fontSize.md },
  extensionButton: { flex: 1, minHeight: 46, borderRadius: radius.md, backgroundColor: colors.brand.teal, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.xs },
  detailText: { color: "#C3D4DC", fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  actionRow: { flexDirection: "row-reverse", gap: spacing.sm },
  actionButton: { flex: 1, minHeight: 56, borderRadius: radius.md, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.xs },
  pauseButton: { backgroundColor: "#C17A24" },
  pauseControl: { flex: 1, gap: spacing.xs },
  pauseReasonInput: { minHeight: 46, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.md, color: colors.text.primary, backgroundColor: colors.background.surface },
  resumeButton: { backgroundColor: colors.brand.teal },
  completeButton: { backgroundColor: "#27815D" },
  actionText: { color: "#fff", fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  fieldLabel: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.semiBold, textAlign: "right" },
  durationInput: { minHeight: 48, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.md, color: colors.text.primary, textAlign: "center", backgroundColor: colors.background.surface, fontSize: typography.fontSize.md },
  queueHeaderTitle: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  queueMetaBlock: { gap: 3, paddingVertical: spacing.xs },
  autoAdvanceCard: { flexDirection: "row-reverse", alignItems: "center", justifyContent: "space-between", gap: spacing.sm, backgroundColor: colors.status.info.background, padding: spacing.sm, borderRadius: radius.md },
  autoAdvanceInfo: { flex: 1, alignItems: "flex-end", gap: 2 },
  autoAdvanceTitle: { color: colors.status.info.text, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.semiBold },
  autoAdvanceCountdown: { color: colors.status.info.text, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  cancelAdvanceButton: { minHeight: 36, minWidth: 60, borderRadius: radius.sm, backgroundColor: colors.background.surface, alignItems: "center", justifyContent: "center", paddingHorizontal: spacing.sm },
  cancelAdvanceText: { color: colors.status.danger.text, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.bold },
  queueReorderControls: { flexDirection: "column", gap: 3 },
  queueReasonInput: { minHeight: 42, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.md, color: colors.text.primary, backgroundColor: colors.background.surface, textAlign: "right" },
  completedQueueBlock: { borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm, gap: spacing.xs },
  completedQueueRow: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.xs, paddingVertical: 3 },
  completedQueueName: { flex: 1, color: colors.text.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  weeklyTransferBlock: { borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm, gap: spacing.sm },
  weeklyTransferForm: { gap: spacing.sm },
  weeklyTransferRow: { borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, padding: spacing.sm, gap: spacing.xs, backgroundColor: colors.background.surface },
  weeklyTransferInfo: { alignItems: "flex-end", gap: 3 },
  weeklyTransferAction: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  weeklyTransferInput: { width: 88, minHeight: 44, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.sm, color: colors.text.primary, backgroundColor: colors.background.surface, textAlign: "center" },
  weeklyTransferButton: { flex: 1, minHeight: 44, borderRadius: radius.md, backgroundColor: colors.brand.teal, alignItems: "center", justifyContent: "center" },
  queueAdditionForm: { gap: spacing.sm },
  queueSubscriberChoices: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.xs },
  queueSubscriberChoice: { borderWidth: 1, borderColor: colors.border, backgroundColor: colors.background.surface, borderRadius: radius.md, paddingHorizontal: spacing.sm, paddingVertical: spacing.xs },
  queueSubscriberName: { color: colors.text.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  queueHeader: { flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center" },
  count: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  queueRow: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm, minHeight: 62, borderTopWidth: 1, borderTopColor: colors.background.subtle, paddingTop: spacing.xs },
  queueNumber: { width: 28, height: 28, borderRadius: 14, backgroundColor: colors.background.subtle, alignItems: "center", justifyContent: "center" },
  queueNumberText: { color: colors.brand.primary, fontFamily: typography.fontFamily.bold },
  queueInfo: { flex: 1, alignItems: "flex-end", gap: 3 },
  queueName: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  queueMeta: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  startButton: { minWidth: 72, minHeight: 48, borderRadius: radius.sm, backgroundColor: colors.brand.primary, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: 4 },
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
