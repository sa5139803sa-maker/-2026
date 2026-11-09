import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ActivityIndicator,
  Alert,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { router } from "expo-router";
import { ArrowRight, CalendarDays, CheckCircle2, Plus, Save, ShieldCheck, Trash2 } from "lucide-react-native";
import { RoleGate } from "@/components/ui";
import { colors, radius, spacing, typography } from "@/constants/theme";
import { useAuth } from "@/lib/auth";
import {
  weeklySchedulesRepository,
  type WeeklyScheduleAllocation,
  type WeeklyScheduleMember,
  type WeeklySchedulePump,
  type WeeklyScheduleSubscriber,
  type WeeklyScheduleVersion,
} from "@/lib/repositories/weekly-schedules";

const WEEKDAYS = [
  { value: 1, label: "الاثنين", short: "اثن" },
  { value: 2, label: "الثلاثاء", short: "ثلا" },
  { value: 3, label: "الأربعاء", short: "أرب" },
  { value: 4, label: "الخميس", short: "خمي" },
  { value: 5, label: "الجمعة", short: "جمع" },
  { value: 6, label: "السبت", short: "سبت" },
  { value: 7, label: "الأحد", short: "أحد" },
] as const;

type AllocationDraft = {
  weekday: number;
  minutes: string;
};

type SubscriberDraft = {
  id: string;
  fullName: string;
  subscriberNumber: number;
  included: boolean;
  weeklyQuota: string;
  defaultWeekday: number;
  allocations: AllocationDraft[];
};

function dateInHebron() {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Hebron",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());
  const map = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${map.year}-${map.month}-${map.day}`;
}

function weekdayOf(date: string) {
  return new Date(`${date}T12:00:00Z`).getUTCDay() || 7;
}

function shiftDate(date: string, days: number) {
  const [year, month, day] = date.split("-").map(Number);
  const shifted = new Date(Date.UTC(year, month - 1, day + days));
  return `${shifted.getUTCFullYear()}-${String(shifted.getUTCMonth() + 1).padStart(2, "0")}-${String(shifted.getUTCDate()).padStart(2, "0")}`;
}

function cycleStart(date: string, weekStartsOn: number) {
  return shiftDate(date, -((weekdayOf(date) - weekStartsOn + 7) % 7));
}

function nextCycleStart(date: string, weekStartsOn: number) {
  return shiftDate(cycleStart(date, weekStartsOn), 7);
}

function weekdayLabel(value: number) {
  return WEEKDAYS.find((day) => day.value === value)?.label ?? "غير محدد";
}

function formatStatus(status: WeeklyScheduleVersion["status"]) {
  if (status === "active") return "نشط";
  if (status === "archived") return "مؤرشف";
  return "مسودة";
}

function emptyDraft(subscriber: WeeklyScheduleSubscriber): SubscriberDraft {
  const quota = subscriber.weekly_quota_minutes ?? null;
  const defaultWeekday = subscriber.default_weekday ?? 1;
  return {
    id: subscriber.id,
    fullName: subscriber.full_name,
    subscriberNumber: subscriber.subscriber_number,
    included: quota !== null,
    weeklyQuota: quota === null ? "" : String(quota),
    defaultWeekday,
    allocations: quota === null ? [] : [{ weekday: defaultWeekday, minutes: String(quota) }],
  };
}

export default function WeeklyScheduleScreen() {
  return (
    <RoleGate feature="management" featureName="إدارة الجداول الأسبوعية">
      <WeeklyScheduleScreenContent />
    </RoleGate>
  );
}

function WeeklyScheduleScreenContent() {
  const { profile } = useAuth();
  const organizationId = profile?.organization_id ?? null;
  const [pumps, setPumps] = useState<WeeklySchedulePump[]>([]);
  const [selectedPumpId, setSelectedPumpId] = useState("");
  const [subscribers, setSubscribers] = useState<WeeklyScheduleSubscriber[]>([]);
  const [versions, setVersions] = useState<WeeklyScheduleVersion[]>([]);
  const [selectedScheduleId, setSelectedScheduleId] = useState<string | null>(null);
  const [selectedVersion, setSelectedVersion] = useState<WeeklyScheduleVersion | null>(null);
  const [scheduleName, setScheduleName] = useState("الجدول الأسبوعي");
  const [effectiveFrom, setEffectiveFrom] = useState(() => cycleStart(dateInHebron(), 1));
  const [effectiveTo, setEffectiveTo] = useState("");
  const [weekStartsOn, setWeekStartsOn] = useState(1);
  const [subscriberDrafts, setSubscriberDrafts] = useState<SubscriberDraft[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [activating, setActivating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const requestSequence = useRef(0);

  const isManager = profile?.role === "manager";
  const activeVersion = useMemo(
    () => versions.find((version) => version.status === "active") ?? null,
    [versions],
  );
  const selectedIsDraft = !selectedVersion || selectedVersion.status === "draft";
  const includedCount = subscriberDrafts.filter((subscriber) => subscriber.included).length;
  const includedMinutes = subscriberDrafts
    .filter((subscriber) => subscriber.included)
    .reduce((sum, subscriber) => sum + (Number(subscriber.weeklyQuota) || 0), 0);

  const loadPumpList = useCallback(async () => {
    if (!organizationId || !isManager) {
      setPumps([]);
      setLoading(false);
      return;
    }
    setLoading(true);
    const result = await weeklySchedulesRepository.listPumps(organizationId);
    if (result.error) {
      console.error("weekly schedule pump list failed", result.error);
      setError("تعذر تحميل الغواطس الخاصة بمؤسستك.");
      setPumps([]);
    } else {
      const rows = (result.data ?? []) as WeeklySchedulePump[];
      setPumps(rows);
      setSelectedPumpId((current) =>
        current && rows.some((pump) => pump.id === current)
          ? current
          : rows.find((pump) => pump.status === "active")?.id ?? rows[0]?.id ?? "",
      );
    }
    setLoading(false);
  }, [isManager, organizationId]);

  useEffect(() => {
    void loadPumpList();
  }, [loadPumpList]);

  const buildDrafts = useCallback((
    pumpSubscribers: WeeklyScheduleSubscriber[],
    members: WeeklyScheduleMember[],
  ) => {
    const memberMap = new Map(members.map((member) => [member.subscriber_id, member]));
    return pumpSubscribers.map((subscriber) => {
      const member = memberMap.get(subscriber.id);
      if (!member) {
        return {
          ...emptyDraft(subscriber),
          included: false,
          weeklyQuota: "",
          allocations: [],
        };
      }
      return {
        id: subscriber.id,
        fullName: subscriber.full_name,
        subscriberNumber: subscriber.subscriber_number,
        included: true,
        weeklyQuota: String(member.weekly_quota_minutes),
        defaultWeekday: member.default_weekday,
        allocations: member.allocations.map((allocation) => ({
          weekday: allocation.weekday,
          minutes: String(allocation.planned_minutes),
        })),
      } satisfies SubscriberDraft;
    });
  }, []);

  const loadPumpData = useCallback(async (pumpId: string, preferredScheduleId?: string) => {
    if (!organizationId || !pumpId) return;
    const requestId = ++requestSequence.current;
    setLoading(true);
    setError(null);
    try {
      const [subscriberResult, versionsResult] = await Promise.all([
        weeklySchedulesRepository.listActiveSubscribers(organizationId, pumpId),
        weeklySchedulesRepository.listScheduleVersions(organizationId, pumpId),
      ]);
      if (requestId !== requestSequence.current) return;
      if (subscriberResult.error || versionsResult.error) {
        throw subscriberResult.error ?? versionsResult.error;
      }

      const subscriberRows = (subscriberResult.data ?? []) as WeeklyScheduleSubscriber[];
      const versionRows = (versionsResult.data ?? []) as WeeklyScheduleVersion[];
      setSubscribers(subscriberRows);
      setVersions(versionRows);

      const preferredVersion =
        versionRows.find((version) => version.id === preferredScheduleId)
        ?? versionRows.find((version) => version.status === "draft")
        ?? versionRows.find((version) => version.status === "active")
        ?? versionRows[0]
        ?? null;

      setSelectedVersion(preferredVersion);
      setSelectedScheduleId(preferredVersion?.id ?? null);

      if (preferredVersion) {
        const memberResult = await weeklySchedulesRepository.loadScheduleMembers(
          organizationId,
          preferredVersion.id,
        );
        if (requestId !== requestSequence.current) return;
        if (memberResult.error) throw memberResult.error;
        setScheduleName(preferredVersion.name);
        setEffectiveFrom(preferredVersion.effective_from);
        setEffectiveTo(preferredVersion.effective_to ?? "");
        setWeekStartsOn(preferredVersion.week_starts_on);
        setSubscriberDrafts(buildDrafts(
          subscriberRows,
          (memberResult.data ?? []) as WeeklyScheduleMember[],
        ));
      } else {
        setSelectedVersion(null);
        setSelectedScheduleId(null);
        setScheduleName("الجدول الأسبوعي");
        setEffectiveTo("");
        setWeekStartsOn(1);
        setEffectiveFrom(cycleStart(dateInHebron(), 1));
        setSubscriberDrafts(subscriberRows.map(emptyDraft));
      }
    } catch (loadError) {
      console.error("weekly schedule load failed", loadError);
      if (requestId === requestSequence.current) {
        setError("تعذر تحميل بيانات الجدول. حدّث الصفحة وحاول مرة أخرى.");
      }
    } finally {
      if (requestId === requestSequence.current) setLoading(false);
    }
  }, [buildDrafts, organizationId]);

  useEffect(() => {
    if (selectedPumpId) void loadPumpData(selectedPumpId);
    return () => { requestSequence.current += 1; };
  }, [loadPumpData, selectedPumpId]);

  const selectVersion = async (version: WeeklyScheduleVersion) => {
    if (!organizationId) return;
    const requestId = ++requestSequence.current;
    setLoading(true);
    setError(null);
    try {
      const membersResult = await weeklySchedulesRepository.loadScheduleMembers(organizationId, version.id);
      if (requestId !== requestSequence.current) return;
      if (membersResult.error) throw membersResult.error;
      setSelectedVersion(version);
      setSelectedScheduleId(version.id);
      setScheduleName(version.name);
      setEffectiveFrom(version.effective_from);
      setEffectiveTo(version.effective_to ?? "");
      setWeekStartsOn(version.week_starts_on);
      setSubscriberDrafts(buildDrafts(
        subscribers,
        (membersResult.data ?? []) as WeeklyScheduleMember[],
      ));
    } catch (loadError) {
      console.error("weekly schedule version load failed", loadError);
      setError("تعذر تحميل تفاصيل إصدار الجدول.");
    } finally {
      if (requestId === requestSequence.current) setLoading(false);
    }
  };

  const startNewVersion = () => {
    let nextStart = nextCycleStart(dateInHebron(), weekStartsOn);
    const baselineEffectiveFrom = activeVersion?.effective_from ?? selectedVersion?.effective_from;
    if (baselineEffectiveFrom) {
      const afterActiveVersion = shiftDate(baselineEffectiveFrom, 7);
      if (nextStart < afterActiveVersion) nextStart = afterActiveVersion;
    }
    setSelectedVersion(null);
    setSelectedScheduleId(null);
    setScheduleName(activeVersion ? `${activeVersion.name} — نسخة جديدة` : "الجدول الأسبوعي");
    setEffectiveFrom(nextStart);
    setEffectiveTo("");
    setSubscriberDrafts((current) => current.map((subscriber) => ({
      ...subscriber,
      allocations: subscriber.included && Number(subscriber.weeklyQuota) > 0
        ? [{ weekday: subscriber.defaultWeekday, minutes: subscriber.weeklyQuota }]
        : [],
    })));
    setNotice("أنشأت نسخة إعداد جديدة. لن تتغير الحصص الحالية حتى اعتماد هذه النسخة.");
    setError(null);
  };

  const updateSubscriber = (subscriberId: string, update: (current: SubscriberDraft) => SubscriberDraft) => {
    setSubscriberDrafts((current) => current.map((subscriber) =>
      subscriber.id === subscriberId ? update(subscriber) : subscriber,
    ));
  };

  const toggleSubscriber = (subscriberId: string) => {
    updateSubscriber(subscriberId, (subscriber) => {
      const included = !subscriber.included;
      const quota = subscriber.weeklyQuota || "30";
      return {
        ...subscriber,
        included,
        weeklyQuota: quota,
        allocations: included
          ? [{ weekday: subscriber.defaultWeekday, minutes: quota }]
          : [],
      };
    });
  };

  const setSubscriberQuota = (subscriberId: string, value: string) => {
    updateSubscriber(subscriberId, (subscriber) => ({
      ...subscriber,
      included: true,
      weeklyQuota: value.replace(/[^0-9]/g, ""),
    }));
  };

  const setDefaultWeekday = (subscriberId: string, weekday: number) => {
    updateSubscriber(subscriberId, (subscriber) => ({
      ...subscriber,
      defaultWeekday: weekday,
      allocations: subscriber.allocations.length === 1
        ? [{ ...subscriber.allocations[0], weekday }]
        : subscriber.allocations,
    }));
  };

  const addAllocation = (subscriberId: string) => {
    updateSubscriber(subscriberId, (subscriber) => {
      const used = new Set(subscriber.allocations.map((allocation) => allocation.weekday));
      const nextDay = WEEKDAYS.find((day) => !used.has(day.value))?.value;
      if (!nextDay) return subscriber;
      return {
        ...subscriber,
        included: true,
        allocations: [...subscriber.allocations, { weekday: nextDay, minutes: "" }],
      };
    });
  };

  const updateAllocation = (
    subscriberId: string,
    index: number,
    update: (allocation: AllocationDraft) => AllocationDraft,
  ) => {
    updateSubscriber(subscriberId, (subscriber) => ({
      ...subscriber,
      allocations: subscriber.allocations.map((allocation, allocationIndex) =>
        allocationIndex === index ? update(allocation) : allocation,
      ),
    }));
  };

  const removeAllocation = (subscriberId: string, index: number) => {
    updateSubscriber(subscriberId, (subscriber) => ({
      ...subscriber,
      allocations: subscriber.allocations.filter((_, allocationIndex) => allocationIndex !== index),
    }));
  };

  const validateAndBuildPayload = () => {
    if (!selectedPumpId) throw new Error("اختر الغطاس أولًا.");
    if (scheduleName.trim().length < 2) throw new Error("أدخل اسمًا واضحًا للجدول.");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(effectiveFrom)) throw new Error("أدخل تاريخ بداية السريان بصيغة YYYY-MM-DD.");
    if (weekdayOf(effectiveFrom) !== weekStartsOn) {
      throw new Error(`تاريخ بداية السريان يجب أن يكون يوم ${weekdayLabel(weekStartsOn)}.`);
    }
    if (effectiveTo.trim() && !/^\d{4}-\d{2}-\d{2}$/.test(effectiveTo)) {
      throw new Error("تحقق من تاريخ نهاية السريان.");
    }
    if (effectiveTo.trim() && effectiveTo < effectiveFrom) throw new Error("تاريخ نهاية السريان يسبق بداية السريان.");

    const included = subscriberDrafts.filter((subscriber) => subscriber.included);
    if (included.length === 0) throw new Error("أدرج مشتركًا واحدًا على الأقل في الجدول.");
    return included.map((subscriber) => {
      const quota = Number(subscriber.weeklyQuota);
      if (!Number.isInteger(quota) || quota < 1 || quota > 10080) {
        throw new Error(`الحصة الأسبوعية للمشترك ${subscriber.fullName} يجب أن تكون من 1 إلى 10080 دقيقة.`);
      }
      if (subscriber.defaultWeekday < 1 || subscriber.defaultWeekday > 7) {
        throw new Error(`حدد اليوم الافتراضي للمشترك ${subscriber.fullName}.`);
      }
      if (subscriber.allocations.length === 0) {
        throw new Error(`حدد يومًا واحدًا على الأقل لتوزيع حصة ${subscriber.fullName}.`);
      }
      const days = subscriber.allocations.map((allocation) => allocation.weekday);
      if (new Set(days).size !== days.length) {
        throw new Error(`يوجد تكرار في أيام توزيع حصة ${subscriber.fullName}.`);
      }
      const allocations: WeeklyScheduleAllocation[] = subscriber.allocations.map((allocation) => {
        const minutes = Number(allocation.minutes);
        if (!Number.isInteger(minutes) || minutes < 1 || minutes > 1440) {
          throw new Error(`كل حصة يومية للمشترك ${subscriber.fullName} يجب أن تكون من 1 إلى 1440 دقيقة.`);
        }
        return { weekday: allocation.weekday, planned_minutes: minutes };
      });
      const sum = allocations.reduce((total, allocation) => total + allocation.planned_minutes, 0);
      if (sum !== quota) {
        throw new Error(`مجموع أيام ${subscriber.fullName} هو ${sum} دقيقة، بينما حصته الأسبوعية ${quota} دقيقة.`);
      }
      return {
        subscriber_id: subscriber.id,
        weekly_quota_minutes: quota,
        default_weekday: subscriber.defaultWeekday,
        allocations,
      };
    });
  };

  const saveDraft = async () => {
    if (!organizationId || !selectedPumpId || saving) return;
    setSaving(true);
    setError(null);
    setNotice(null);
    try {
      const payload = validateAndBuildPayload();
      const result = await weeklySchedulesRepository.saveDraft({
        scheduleId: selectedIsDraft ? selectedScheduleId : null,
        pumpId: selectedPumpId,
        name: scheduleName,
        effectiveFrom,
        effectiveTo: effectiveTo.trim() || null,
        weekStartsOn,
        subscribers: payload,
      });
      if (result.error) {
        console.error("weekly schedule save failed", result.error);
        throw new Error(result.error.code === "23514" || result.error.code === "22023"
          ? "لم تُقبل بيانات الحصص. تأكد من مجموع الدقائق وتوزيعها على الأيام."
          : "تعذر حفظ مسودة الجدول.");
      }
      const savedId = String(result.data);
      setNotice("حُفظت مسودة الجدول. لم تتغير الحصص الحالية للمشتركين.");
      await loadPumpData(selectedPumpId, savedId);
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "تعذر حفظ الجدول.");
    } finally {
      setSaving(false);
    }
  };

  const confirmActivation = () => {
    if (!selectedScheduleId || !selectedVersion || selectedVersion.status !== "draft" || activating) return;
    Alert.alert(
      "اعتماد الجدول الأسبوعي",
      "سيصبح هذا الإصدار هو الجدول المعتمد من تاريخ بدايته. ستُحفظ النسخة السابقة للأيام الماضية، ولن تُرحّل الدقائق غير المستخدمة بين الأسابيع.",
      [
        { text: "مراجعة لاحقًا", style: "cancel" },
        { text: "اعتماد الجدول", onPress: () => void activateSchedule() },
      ],
    );
  };

  const activateSchedule = async () => {
    if (!selectedScheduleId || activating) return;
    setActivating(true);
    setError(null);
    setNotice(null);
    const result = await weeklySchedulesRepository.activate(selectedScheduleId);
    if (result.error) {
      console.error("weekly schedule activation failed", result.error);
      setError(result.error.code === "23P01"
        ? "يتداخل تاريخ هذا الإصدار مع جدول سابق. عدّل تاريخ بداية السريان."
        : result.error.code === "55000"
          ? "يوجد طابور يومي محفوظ لهذه الفترة. اختر بداية دورة أسبوعية لم يبدأ طابورها بعد."
          : result.error.code === "23514"
            ? "لا يمكن اعتماد الجدول لأن مجموع حصة أحد المشتركين لا يساوي مجموع أيامه."
            : "تعذر اعتماد الجدول. تحقق من أن بداية السريان دورة صحيحة وأن المسودة مكتملة.");
    } else {
      setNotice("تم اعتماد الجدول. ستُحفظ حصص هذا الإصدار وتُطبق عند بداية سريانه.");
      await loadPumpData(selectedPumpId);
    }
    setActivating(false);
  };

  if (!isManager || !organizationId) {
    return (
      <View style={styles.screen}>
        <View style={styles.noticeCard}>
          <ShieldCheck size={26} color={colors.brand.primary} />
          <Text style={styles.title}>إعداد الجداول الأسبوعية للمدير فقط</Text>
          <Text style={styles.muted}>لا يستطيع المشغّل أو المشرف تغيير الحصص أو اعتماد نسخ الجداول.</Text>
        </View>
      </View>
    );
  }

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <ArrowRight size={20} color={colors.text.primary} />
        </Pressable>
        <View style={styles.headerText}>
          <Text style={styles.eyebrow}>إدارة المؤسسة</Text>
          <Text style={styles.title}>الجداول والحصص الأسبوعية</Text>
          <Text style={styles.subtitle}>توزيع حصة كل مشترك وحفظ إصدارات الجداول</Text>
        </View>
        <View style={styles.headerIcon}><CalendarDays size={22} color={colors.brand.primary} /></View>
      </View>

      {error ? <Text style={styles.error}>{error}</Text> : null}
      {notice ? <Text style={styles.notice}>{notice}</Text> : null}

      <View style={styles.card}>
        <Text style={styles.sectionTitle}>اختيار الغطاس والإصدار</Text>
        {loading && pumps.length === 0 ? <ActivityIndicator color={colors.brand.teal} /> : (
          <View style={styles.pumpChoices}>
            {pumps.map((pump) => (
              <Pressable key={pump.id} onPress={() => setSelectedPumpId(pump.id)}
                style={[styles.pumpChoice, selectedPumpId === pump.id && styles.pumpChoiceSelected]}>
                <Text style={[styles.pumpName, selectedPumpId === pump.id && styles.textInverse]}>{pump.name}</Text>
                <Text style={[styles.pumpCode, selectedPumpId === pump.id && styles.textInverse]}>{pump.code}</Text>
              </Pressable>
            ))}
          </View>
        )}
        {versions.length > 0 ? (
          <View style={styles.versionList}>
            <Text style={styles.fieldLabel}>الإصدارات المحفوظة</Text>
            {versions.map((version) => (
              <Pressable key={version.id} onPress={() => void selectVersion(version)}
                style={[styles.versionRow, selectedScheduleId === version.id && styles.versionRowSelected]}>
                <View style={styles.versionInfo}>
                  <Text style={styles.versionName}>{version.name}</Text>
                  <Text style={styles.mutedSmall}>{version.effective_from}{version.effective_to ? ` إلى ${version.effective_to}` : " وما بعده"}</Text>
                </View>
                <View style={[styles.statusPill, version.status === "active" ? styles.statusActive : version.status === "archived" ? styles.statusArchived : styles.statusDraft]}>
                  <Text style={styles.statusLabel}>{formatStatus(version.status)}</Text>
                </View>
              </Pressable>
            ))}
          </View>
        ) : null}
        {selectedVersion && selectedVersion.status !== "draft" ? (
          <Pressable onPress={startNewVersion} style={styles.secondaryButton}>
            <Plus size={16} color={colors.brand.primary} />
            <Text style={styles.secondaryButtonText}>إنشاء إصدار جديد انطلاقًا من هذا الجدول</Text>
          </Pressable>
        ) : null}
      </View>

      {loading ? <ActivityIndicator color={colors.brand.teal} /> : selectedPumpId ? (
        <>
          <View style={styles.card}>
            <Text style={styles.sectionTitle}>{selectedScheduleId && selectedVersion?.status === "draft" ? "تحرير المسودة" : "بيانات إصدار الجدول"}</Text>
            <Text style={styles.fieldLabel}>اسم الجدول</Text>
            <TextInput editable={selectedIsDraft} value={scheduleName} onChangeText={setScheduleName}
              style={[styles.input, !selectedIsDraft && styles.inputReadOnly]} textAlign="right" />
            <Text style={styles.fieldLabel}>بداية الأسبوع</Text>
            <View style={styles.weekdayChoices}>
              {WEEKDAYS.map((day) => (
                <Pressable key={day.value} disabled={!selectedIsDraft}
                  onPress={() => {
                    setWeekStartsOn(day.value);
                    if (weekdayOf(effectiveFrom) !== day.value) setEffectiveFrom(cycleStart(effectiveFrom, day.value));
                  }}
                  style={[styles.weekdayChoice, weekStartsOn === day.value && styles.weekdayChoiceSelected, !selectedIsDraft && styles.disabled]}>
                  <Text style={[styles.weekdayText, weekStartsOn === day.value && styles.textInverse]}>{day.short}</Text>
                </Pressable>
              ))}
            </View>
            <Text style={styles.fieldLabel}>يبدأ سريان الجدول في يوم {weekdayLabel(weekStartsOn)}</Text>
            <TextInput editable={selectedIsDraft} value={effectiveFrom} onChangeText={setEffectiveFrom}
              placeholder="YYYY-MM-DD" autoCapitalize="none" style={[styles.input, !selectedIsDraft && styles.inputReadOnly]} />
            <Text style={styles.fieldLabel}>نهاية السريان (اختياري)</Text>
            <TextInput editable={selectedIsDraft} value={effectiveTo} onChangeText={setEffectiveTo}
              placeholder="اتركه فارغًا للاستمرار حتى الإصدار التالي" autoCapitalize="none"
              style={[styles.input, !selectedIsDraft && styles.inputReadOnly]} />
            {selectedVersion?.status === "active" ? (
              <Text style={styles.helper}>هذا هو الإصدار النشط. أنشئ نسخة جديدة لتعديل الحصص دون تغيير الأسابيع السابقة.</Text>
            ) : selectedVersion?.status === "archived" ? (
              <Text style={styles.helper}>هذا إصدار تاريخي للقراءة فقط؛ استخدم «إنشاء إصدار جديد» لإعداد جدول مستقبلي.</Text>
            ) : (
              <Text style={styles.helper}>تُحفظ هذه البيانات في مسودة مستقلة. لا تتغير حصص المشتركين الحالية حتى الاعتماد.</Text>
            )}
          </View>

          <View style={styles.card}>
            <View style={styles.subscriberHeader}>
              <Text style={styles.sectionTitle}>توزيع حصص المشتركين</Text>
              <Text style={styles.count}>{includedCount} مشترك · {includedMinutes} دقيقة</Text>
            </View>
            <Text style={styles.helper}>
              أدخل إجمالي الحصة الأسبوعية، ثم وزّعها على يوم واحد أو عدة أيام. مجموع الأيام يجب أن يساوي الحصة بالضبط.
            </Text>
            {subscriberDrafts.length === 0 ? <Text style={styles.muted}>لا يوجد مشتركون نشطون مرتبطون بهذا الغطاس.</Text> : subscriberDrafts.map((subscriber) => (
              <View key={subscriber.id} style={[styles.subscriberCard, !subscriber.included && styles.subscriberCardExcluded]}>
                <View style={styles.subscriberTop}>
                  <View style={styles.subscriberIdentity}>
                    <Text style={styles.subscriberName}>{subscriber.fullName}</Text>
                    <Text style={styles.mutedSmall}>رقم المشترك {String(subscriber.subscriberNumber).padStart(6, "0")}</Text>
                  </View>
                  {selectedIsDraft ? (
                    <Pressable onPress={() => toggleSubscriber(subscriber.id)}
                      style={[styles.includeButton, subscriber.included ? styles.includeButtonOn : styles.includeButtonOff]}>
                      <Text style={styles.includeButtonText}>{subscriber.included ? "ضمن الجدول" : "إضافة للحصة"}</Text>
                    </Pressable>
                  ) : (
                    <View style={[styles.statusPill, subscriber.included ? styles.statusActive : styles.statusArchived]}>
                      <Text style={styles.statusLabel}>{subscriber.included ? "مجدول" : "غير مجدول"}</Text>
                    </View>
                  )}
                </View>
                {subscriber.included ? (
                  <>
                    <View style={styles.subscriberInputs}>
                      <View style={styles.inputGroup}>
                        <Text style={styles.fieldLabel}>الحصة الأسبوعية بالدقائق</Text>
                        <TextInput editable={selectedIsDraft} keyboardType="number-pad"
                          value={subscriber.weeklyQuota}
                          onChangeText={(value) => setSubscriberQuota(subscriber.id, value)}
                          style={[styles.input, styles.numericInput, !selectedIsDraft && styles.inputReadOnly]} />
                      </View>
                      <View style={styles.inputGroup}>
                        <Text style={styles.fieldLabel}>اليوم الافتراضي</Text>
                        <Pressable disabled={!selectedIsDraft}
                          onPress={() => setDefaultWeekday(subscriber.id, subscriber.defaultWeekday === 7 ? 1 : subscriber.defaultWeekday + 1)}
                          style={[styles.dayPicker, !selectedIsDraft && styles.inputReadOnly]}>
                          <Text style={styles.dayPickerText}>{weekdayLabel(subscriber.defaultWeekday)}</Text>
                        </Pressable>
                      </View>
                    </View>
                    <View style={styles.allocationHeader}>
                      <Text style={styles.fieldLabel}>توزيع الأيام</Text>
                      {selectedIsDraft ? (
                        <Pressable onPress={() => addAllocation(subscriber.id)} style={styles.addDayButton}>
                          <Plus size={14} color={colors.brand.primary} />
                          <Text style={styles.secondaryButtonText}>إضافة يوم</Text>
                        </Pressable>
                      ) : null}
                    </View>
                    {subscriber.allocations.map((allocation, index) => (
                      <View key={`${subscriber.id}-${index}`} style={styles.allocationRow}>
                        <Pressable disabled={!selectedIsDraft}
                          onPress={() => updateAllocation(subscriber.id, index, (current) => ({
                            ...current,
                            weekday: current.weekday === 7 ? 1 : current.weekday + 1,
                          }))}
                          style={[styles.allocationDay, !selectedIsDraft && styles.inputReadOnly]}>
                          <Text style={styles.dayPickerText}>{weekdayLabel(allocation.weekday)}</Text>
                        </Pressable>
                        <TextInput editable={selectedIsDraft} keyboardType="number-pad"
                          value={allocation.minutes}
                          onChangeText={(value) => updateAllocation(subscriber.id, index, (current) => ({
                            ...current,
                            minutes: value.replace(/[^0-9]/g, ""),
                          }))}
                          placeholder="الدقائق" style={[styles.input, styles.allocationMinutes, !selectedIsDraft && styles.inputReadOnly]} />
                        {selectedIsDraft && subscriber.allocations.length > 1 ? (
                          <Pressable onPress={() => removeAllocation(subscriber.id, index)} style={styles.removeDayButton}>
                            <Trash2 size={15} color={colors.status.danger.text} />
                          </Pressable>
                        ) : <View style={styles.removeDayPlaceholder} />}
                      </View>
                    ))}
                    <View style={styles.allocationSummary}>
                      <Text style={styles.mutedSmall}>
                        مجموع الموزع: {subscriber.allocations.reduce((sum, allocation) => sum + (Number(allocation.minutes) || 0), 0)} دقيقة
                      </Text>
                      <Text style={styles.mutedSmall}>المطلوب: {Number(subscriber.weeklyQuota) || 0} دقيقة</Text>
                    </View>
                  </>
                ) : null}
              </View>
            ))}
          </View>

          <View style={styles.actions}>
            {selectedIsDraft ? (
              <>
                <Pressable disabled={saving || loading} onPress={() => void saveDraft()}
                  style={[styles.saveButton, (saving || loading) && styles.disabled]}>
                  {saving ? <ActivityIndicator color="#fff" /> : <Save size={17} color="#fff" />}
                  <Text style={styles.saveButtonText}>حفظ المسودة</Text>
                </Pressable>
                {selectedScheduleId && selectedVersion?.status === "draft" ? (
                  <Pressable disabled={activating || saving} onPress={confirmActivation}
                    style={[styles.activateButton, (activating || saving) && styles.disabled]}>
                    {activating ? <ActivityIndicator color="#fff" /> : <CheckCircle2 size={17} color="#fff" />}
                    <Text style={styles.saveButtonText}>اعتماد الجدول</Text>
                  </Pressable>
                ) : null}
              </>
            ) : null}
          </View>
        </>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: "rtl" },
  content: { padding: spacing.md, paddingTop: spacing.lg, paddingBottom: spacing.xxl, gap: spacing.md, maxWidth: 900, width: "100%", alignSelf: "center" },
  header: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  backButton: { width: 40, height: 40, borderRadius: radius.md, backgroundColor: colors.background.surface, alignItems: "center", justifyContent: "center" },
  headerText: { flex: 1, alignItems: "flex-end" },
  eyebrow: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  title: { color: colors.text.primary, fontSize: typography.fontSize.xl, fontFamily: typography.fontFamily.bold, textAlign: "right" },
  subtitle: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  headerIcon: { width: 42, height: 42, borderRadius: radius.md, backgroundColor: colors.background.subtle, alignItems: "center", justifyContent: "center" },
  card: { backgroundColor: colors.background.surface, borderRadius: radius.lg, borderWidth: 1, borderColor: colors.border, padding: spacing.md, gap: spacing.sm },
  sectionTitle: { color: colors.text.primary, fontSize: typography.fontSize.md, fontFamily: typography.fontFamily.bold, textAlign: "right" },
  fieldLabel: { color: colors.text.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  pumpChoices: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.xs },
  pumpChoice: { minWidth: 105, padding: spacing.sm, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.background.subtle, alignItems: "center", gap: 2 },
  pumpChoiceSelected: { backgroundColor: colors.brand.primary, borderColor: colors.brand.primary },
  pumpName: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  pumpCode: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  textInverse: { color: colors.text.inverse },
  versionList: { gap: spacing.xs, borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm },
  versionRow: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm, padding: spacing.sm, borderRadius: radius.md, borderWidth: 1, borderColor: colors.border },
  versionRowSelected: { borderColor: colors.brand.primary, backgroundColor: colors.background.subtle },
  versionInfo: { flex: 1, alignItems: "flex-end" },
  versionName: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  statusPill: { borderRadius: radius.pill, paddingHorizontal: spacing.sm, paddingVertical: 4 },
  statusActive: { backgroundColor: colors.status.success.background },
  statusArchived: { backgroundColor: colors.background.subtle },
  statusDraft: { backgroundColor: colors.status.warning.background },
  statusLabel: { color: colors.text.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  secondaryButton: { minHeight: 42, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.xs, borderRadius: radius.md, backgroundColor: colors.background.subtle, paddingHorizontal: spacing.sm },
  secondaryButtonText: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  weekdayChoices: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.xs },
  weekdayChoice: { minWidth: 42, minHeight: 38, paddingHorizontal: spacing.xs, borderRadius: radius.sm, borderWidth: 1, borderColor: colors.border, alignItems: "center", justifyContent: "center", backgroundColor: colors.background.subtle },
  weekdayChoiceSelected: { backgroundColor: colors.brand.primary, borderColor: colors.brand.primary },
  weekdayText: { color: colors.text.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  input: { minHeight: 42, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, paddingHorizontal: spacing.sm, color: colors.text.primary, backgroundColor: colors.background.surface, fontFamily: typography.fontFamily.regular },
  numericInput: { fontVariant: ["tabular-nums"], textAlign: "center" },
  inputReadOnly: { opacity: 0.65, backgroundColor: colors.background.subtle },
  helper: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, textAlign: "right", lineHeight: 20 },
  subscriberHeader: { flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center", gap: spacing.xs },
  count: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.bold },
  subscriberCard: { borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm, gap: spacing.sm },
  subscriberCardExcluded: { opacity: 0.92 },
  subscriberTop: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  subscriberIdentity: { flex: 1, alignItems: "flex-end" },
  subscriberName: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  mutedSmall: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular },
  includeButton: { paddingHorizontal: spacing.sm, paddingVertical: 7, borderRadius: radius.md },
  includeButtonOn: { backgroundColor: colors.status.success.background },
  includeButtonOff: { backgroundColor: colors.background.subtle },
  includeButtonText: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  subscriberInputs: { flexDirection: "row-reverse", gap: spacing.sm },
  inputGroup: { flex: 1, gap: 5 },
  dayPicker: { minHeight: 42, borderWidth: 1, borderColor: colors.border, borderRadius: radius.md, alignItems: "center", justifyContent: "center", backgroundColor: colors.background.surface },
  dayPickerText: { color: colors.text.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  allocationHeader: { flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center" },
  addDayButton: { flexDirection: "row-reverse", alignItems: "center", gap: 4, paddingHorizontal: spacing.xs, paddingVertical: 4 },
  allocationRow: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.xs },
  allocationDay: { width: 105, minHeight: 40, borderWidth: 1, borderColor: colors.border, borderRadius: radius.sm, alignItems: "center", justifyContent: "center" },
  allocationMinutes: { flex: 1, textAlign: "center" },
  removeDayButton: { width: 36, height: 36, borderRadius: radius.sm, alignItems: "center", justifyContent: "center", backgroundColor: colors.status.danger.background },
  removeDayPlaceholder: { width: 36 },
  allocationSummary: { flexDirection: "row-reverse", justifyContent: "space-between" },
  actions: { gap: spacing.sm },
  saveButton: { minHeight: 50, backgroundColor: colors.brand.primary, borderRadius: radius.md, flexDirection: "row-reverse", justifyContent: "center", alignItems: "center", gap: spacing.xs },
  activateButton: { minHeight: 50, backgroundColor: "#27815D", borderRadius: radius.md, flexDirection: "row-reverse", justifyContent: "center", alignItems: "center", gap: spacing.xs },
  saveButtonText: { color: colors.text.inverse, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold },
  disabled: { opacity: 0.45 },
  noticeCard: { margin: spacing.md, backgroundColor: colors.background.surface, borderRadius: radius.lg, padding: spacing.lg, alignItems: "center", gap: spacing.sm },
  muted: { color: colors.text.secondary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  error: { color: colors.status.danger.text, backgroundColor: colors.status.danger.background, padding: spacing.sm, borderRadius: radius.md, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  notice: { color: colors.status.success.text, backgroundColor: colors.status.success.background, padding: spacing.sm, borderRadius: radius.md, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium, textAlign: "right" },
});
