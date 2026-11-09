import { useEffect, useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  View,
} from "react-native";
import { router } from "expo-router";
import { AlarmClock, ArrowRight, BellRing, CheckCircle2, Music2, RotateCcw, Vibrate } from "lucide-react-native";
import * as DocumentPicker from "expo-document-picker";
import * as Haptics from "expo-haptics";
import { Platform } from "react-native";
import { colors, radius, spacing, typography } from "@/constants/theme";
import {
  copyAlertSoundToAppStorage,
  ensureDefaultAlertSound,
  loadAlertSettings,
  saveAlertSettings,
  type AlertKind,
  type AlertSettings,
} from "@/lib/alerts/settings";
import { playAlertSound, stopAlertSound } from "@/lib/alerts/audio";
import { openAndroidExactAlarmSettings, requestAndroidNotificationPermission } from "@/lib/alerts/native-notifications";

const ALERTS: { kind: AlertKind; title: string; detail: string; durationMs: number; timing: string }[] = [
  {
    kind: "minuteWarning",
    title: "تنبيه قرب انتهاء التعبئة",
    detail: "يبدأ عند بقاء دقيقة واحدة من التعبئة، ويعمل لمدة خمس ثوانٍ كحد أقصى.",
    durationMs: 5000,
    timing: "قبل نهاية التعبئة بدقيقة",
  },
  {
    kind: "handover",
    title: "تنبيه نهاية التعبئة والانتقال",
    detail: "تنبيه واحد موحّد يبدأ في آخر ثانيتين من مهلة الانتقال الثلاثية، ويتوقف عند بدء الدور التالي أو إلغاء الانتقال.",
    durationMs: 2000,
    timing: "آخر ثانيتين من مهلة الانتقال (3 ثوانٍ)",
  },
];

export default function AlertSettingsScreen() {
  const [settings, setSettings] = useState<AlertSettings | null>(null);
  const [loading, setLoading] = useState(true);
  const [busyKind, setBusyKind] = useState<AlertKind | null>(null);
  const [nativeBusy, setNativeBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    void loadAlertSettings()
      .then((loaded) => {
        if (mounted) setSettings(loaded);
      })
      .catch((loadError) => {
        console.error("alert settings load failed", loadError);
        if (mounted) setError("تعذر تحميل إعدادات التنبيهات من مساحة الهاتف.");
      })
      .finally(() => {
        if (mounted) setLoading(false);
      });
    return () => {
      mounted = false;
      stopAlertSound();
    };
  }, []);

  const persist = async (next: AlertSettings, successMessage?: string) => {
    setSettings(next);
    setError(null);
    try {
      await saveAlertSettings(next);
      if (successMessage) setNotice(successMessage);
    } catch (saveError) {
      console.error("alert settings save failed", saveError);
      setError("تعذر حفظ الإعدادات محليًا. أعد المحاولة.");
    }
  };

  const updatePreference = async (
    kind: AlertKind,
    update: (current: AlertSettings[AlertKind]) => AlertSettings[AlertKind],
  ) => {
    if (!settings) return;
    const next = { ...settings, [kind]: update(settings[kind]) };
    await persist(next, "تم حفظ إعدادات التنبيه على هذا الجهاز.");
  };

  const pickSound = async (kind: AlertKind) => {
    if (!settings || busyKind) return;
    if (Platform.OS === "web") {
      setError("اختيار ملفات الأصوات المحلية متاح من تطبيق الهاتف.");
      return;
    }
    setBusyKind(kind);
    setError(null);
    setNotice(null);
    try {
      const selection = await DocumentPicker.getDocumentAsync({
        type: "audio/*",
        multiple: false,
        copyToCacheDirectory: true,
      });
      if (selection.canceled) return;
      const asset = selection.assets[0];
      if (!asset) throw new Error("لم يتم اختيار ملف صوتي.");
      const copied = await copyAlertSoundToAppStorage(asset.uri, asset.name);
      const next = {
        ...settings,
        [kind]: {
          ...settings[kind],
          soundUri: copied.uri,
          soundName: copied.name,
        },
      };
      await persist(next, "تم حفظ الصوت المختار داخل التطبيق.");
    } catch (pickError) {
      console.error("alert sound selection failed", pickError);
      setError(pickError instanceof Error ? pickError.message : "تعذر اختيار الملف الصوتي.");
    } finally {
      setBusyKind(null);
    }
  };

  const resetSound = async (kind: AlertKind) => {
    if (!settings) return;
    setBusyKind(kind);
    try {
      const defaultUri = await ensureDefaultAlertSound();
      await updatePreference(kind, (current) => ({
        ...current,
        soundUri: defaultUri,
        soundName: "الصوت الافتراضي",
      }));
      setNotice("تمت إعادة صوت هذا التنبيه إلى الصوت الافتراضي.");
    } catch (resetError) {
      console.error("alert sound reset failed", resetError);
      setError("تعذرت إعادة الصوت الافتراضي.");
    } finally {
      setBusyKind(null);
    }
  };

  const enableAndroidNotifications = async () => {
    if (Platform.OS !== "android" || nativeBusy) return;
    setNativeBusy(true);
    setError(null);
    setNotice(null);
    try {
      const granted = await requestAndroidNotificationPermission();
      if (!granted) setError("لم يُمنح إذن الإشعارات. فعّله من إعدادات Android.");
      else setNotice("تم تفعيل إذن الإشعارات. اضبط المنبّهات الدقيقة من الزر التالي.");
    } catch (permissionError) {
      console.error("Android notification permission setup failed", permissionError);
      setError("تعذر طلب إذن الإشعارات من Android.");
    } finally {
      setNativeBusy(false);
    }
  };

  const openExactAlarmSettings = async () => {
    if (Platform.OS !== "android" || nativeBusy) return;
    setNativeBusy(true);
    setError(null);
    setNotice(null);
    try {
      await openAndroidExactAlarmSettings();
      setNotice("تحقق يدويًا من تفعيل «المنبّهات والتذكيرات» لهذا التطبيق في إعدادات Android.");
    } catch (permissionError) {
      console.error("Android exact alarm settings could not be opened", permissionError);
      setError(permissionError instanceof Error ? permissionError.message : "تعذر فتح إعداد المنبّهات الدقيقة.");
    } finally {
      setNativeBusy(false);
    }
  };

  const preview = async (kind: AlertKind, durationMs: number) => {
    if (!settings || busyKind) return;
    setError(null);
    const preference = settings[kind];
    if (!preference.enabled) {
      setError("فعّل هذا التنبيه أولًا حتى تتمكن من معاينة صوته.");
      return;
    }
    await playAlertSound(preference.soundUri, durationMs, `preview:${kind}`);
    if (preference.vibrate) {
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning).catch(() => undefined);
    }
    setNotice(kind === "minuteWarning"
      ? "تتم معاينة صوت تنبيه الدقيقة لمدة خمس ثوانٍ كحد أقصى."
      : "تتم معاينة صوت التنبيه الموحد لمدة ثانيتين.");
  };

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content} showsVerticalScrollIndicator={false}>
      <View style={styles.header}>
        <Pressable onPress={() => router.back()} style={styles.backButton}>
          <ArrowRight size={20} color={colors.text.primary} />
        </Pressable>
        <View style={styles.headerText}>
          <Text style={styles.eyebrow}>إعدادات الهاتف</Text>
          <Text style={styles.title}>أصوات التنبيهات</Text>
          <Text style={styles.subtitle}>اختر صوت كل تنبيه وجرّبه قبل استخدامه</Text>
        </View>
        <View style={styles.headerIcon}><BellRing size={22} color={colors.brand.primary} /></View>
      </View>

      {error ? <Text style={styles.error}>{error}</Text> : null}
      {notice ? <Text style={styles.notice}>{notice}</Text> : null}

      {Platform.OS === "android" ? (
        <View style={styles.nativeCard}>
          <View style={styles.nativeHeading}>
            <AlarmClock size={19} color={colors.brand.primary} />
            <Text style={styles.nativeTitle}>تنبيهات Android وشاشة القفل</Text>
          </View>
          <Text style={styles.nativeDescription}>
            تُجدول التنبيهات في نظام Android لتصل بعد قفل الشاشة أو إغلاق واجهة التطبيق. فعّل إذن الإشعارات أولًا، ثم اسمح بالمنبّهات الدقيقة.
          </Text>
          <View style={styles.nativeActions}>
            <Pressable disabled={nativeBusy} onPress={() => void enableAndroidNotifications()}
              style={[styles.nativeButton, nativeBusy && styles.disabled]}>
              <BellRing size={15} color="#fff" />
              <Text style={styles.nativeButtonText}>تفعيل إشعارات Android</Text>
            </Pressable>
            <Pressable disabled={nativeBusy} onPress={() => void openExactAlarmSettings()}
              style={[styles.nativeSecondaryButton, nativeBusy && styles.disabled]}>
              <AlarmClock size={15} color={colors.brand.primary} />
              <Text style={styles.nativeSecondaryButtonText}>فتح إعداد المنبّهات الدقيقة</Text>
            </Pressable>
          </View>
          <Text style={styles.nativeFootnote}>
            يعتمد ظهور Heads-up وشاشة القفل على إعدادات Android. لا يفرض التطبيق فتح نافذة كاملة فوق القفل أو تجاوز عدم الإزعاج.
          </Text>
        </View>
      ) : null}

      {loading || !settings ? (
        <View style={styles.loading}><ActivityIndicator color={colors.brand.teal} /></View>
      ) : (
        <>
          {ALERTS.map((alert) => {
            const preference = settings[alert.kind];
            return (
              <View key={alert.kind} style={styles.card}>
                <View style={styles.alertHeading}>
                  <View style={styles.alertIcon}><Music2 size={18} color={colors.brand.primary} /></View>
                  <View style={styles.alertTitleArea}>
                    <Text style={styles.cardTitle}>{alert.title}</Text>
                    <Text style={styles.timing}>{alert.timing}</Text>
                  </View>
                  <Switch
                    value={preference.enabled}
                    onValueChange={(enabled) => void updatePreference(alert.kind, (current) => ({ ...current, enabled }))}
                    trackColor={{ false: colors.border, true: colors.brand.aqua }}
                    thumbColor={preference.enabled ? colors.brand.primary : colors.text.secondary}
                  />
                </View>

                <Text style={styles.description}>{alert.detail}</Text>

                <View style={styles.soundRow}>
                  <View style={styles.soundInfo}>
                    <Text style={styles.fieldLabel}>الصوت المستخدم</Text>
                    <Text style={styles.soundName} numberOfLines={1}>{preference.soundName}</Text>
                  </View>
                  <Pressable disabled={busyKind === alert.kind} onPress={() => void resetSound(alert.kind)}
                    style={[styles.iconButton, busyKind === alert.kind && styles.disabled]}>
                    <RotateCcw size={16} color={colors.brand.primary} />
                  </Pressable>
                </View>

                <View style={styles.actions}>
                  <Pressable disabled={!preference.enabled || busyKind === alert.kind}
                    onPress={() => void pickSound(alert.kind)}
                    style={[styles.secondaryButton, (!preference.enabled || busyKind === alert.kind) && styles.disabled]}>
                    {busyKind === alert.kind ? <ActivityIndicator size="small" color={colors.brand.primary} /> : <Music2 size={15} color={colors.brand.primary} />}
                    <Text style={styles.secondaryButtonText}>اختيار صوت من الهاتف</Text>
                  </Pressable>
                  <Pressable disabled={!preference.enabled || busyKind === alert.kind}
                    onPress={() => void preview(alert.kind, alert.durationMs)}
                    style={[styles.previewButton, (!preference.enabled || busyKind === alert.kind) && styles.disabled]}>
                    <BellRing size={15} color="#fff" />
                    <Text style={styles.previewText}>معاينة</Text>
                  </Pressable>
                </View>

                <View style={styles.vibrationRow}>
                  <View style={styles.vibrationLabel}>
                    <Vibrate size={16} color={colors.text.secondary} />
                    <Text style={styles.fieldLabel}>اهتزاز مع التنبيه</Text>
                  </View>
                  <Switch
                    value={preference.vibrate}
                    onValueChange={(vibrate) => void updatePreference(alert.kind, (current) => ({ ...current, vibrate }))}
                    trackColor={{ false: colors.border, true: colors.brand.aqua }}
                    thumbColor={preference.vibrate ? colors.brand.primary : colors.text.secondary}
                  />
                </View>
              </View>
            );
          })}

          <View style={styles.infoCard}>
            <CheckCircle2 size={18} color={colors.status.success.text} />
            <Text style={styles.infoText}>
              تُحفظ الأصوات المختارة داخل مساحة التطبيق على هذا الهاتف، ولا تُرفع إلى حساب المؤسسة أو Supabase.
              إذا حذفت التطبيق أو بياناته فستحتاج إلى اختيار الملف من جديد.
            </Text>
          </View>
          <Text style={styles.note}>
            نغمات Android مضمنة في نسخة التطبيق: تنبيه الدقيقة خمس ثوانٍ وتنبيه الانتقال ثانيتان. الملف المختار من الهاتف للمعاينة داخل التطبيق فقط؛ تغيير صوت قناة Android يتطلب تضمين الملف في بناء جديد. يلزم اختبار هاتف فعلي.
          </Text>
        </>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background.main, direction: "rtl" },
  content: { padding: spacing.md, paddingTop: spacing.lg, paddingBottom: spacing.xxl, gap: spacing.md, maxWidth: 760, width: "100%", alignSelf: "center" },
  header: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm, marginBottom: spacing.xs },
  backButton: { width: 40, height: 40, borderRadius: radius.md, backgroundColor: colors.background.surface, alignItems: "center", justifyContent: "center" },
  headerText: { flex: 1, alignItems: "flex-end" },
  eyebrow: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  title: { color: colors.text.primary, fontSize: typography.fontSize.xl, fontFamily: typography.fontFamily.bold, textAlign: "right" },
  subtitle: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, textAlign: "right" },
  headerIcon: { width: 42, height: 42, borderRadius: radius.md, backgroundColor: colors.background.subtle, alignItems: "center", justifyContent: "center" },
  nativeCard: { backgroundColor: colors.background.surface, borderWidth: 1, borderColor: colors.brand.aqua, borderRadius: radius.lg, padding: spacing.md, gap: spacing.sm },
  nativeHeading: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.xs },
  nativeTitle: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold, textAlign: "right" },
  nativeDescription: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, lineHeight: 20, textAlign: "right" },
  nativeActions: { flexDirection: "row-reverse", flexWrap: "wrap", gap: spacing.xs },
  nativeButton: { flexGrow: 1, minHeight: 42, borderRadius: radius.md, backgroundColor: colors.brand.primary, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.xs, paddingHorizontal: spacing.md },
  nativeButtonText: { color: "#fff", fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.bold },
  nativeSecondaryButton: { flexGrow: 1, minHeight: 42, borderRadius: radius.md, borderWidth: 1, borderColor: colors.brand.aqua, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.xs, paddingHorizontal: spacing.md },
  nativeSecondaryButtonText: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  nativeFootnote: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, lineHeight: 18, textAlign: "right" },
  card: { backgroundColor: colors.background.surface, borderWidth: 1, borderColor: colors.border, borderRadius: radius.lg, padding: spacing.md, gap: spacing.sm },
  alertHeading: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.sm },
  alertIcon: { width: 36, height: 36, borderRadius: radius.md, backgroundColor: colors.background.subtle, alignItems: "center", justifyContent: "center" },
  alertTitleArea: { flex: 1, alignItems: "flex-end", gap: 2 },
  cardTitle: { color: colors.text.primary, fontSize: typography.fontSize.sm, fontFamily: typography.fontFamily.bold, textAlign: "right" },
  timing: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  description: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, lineHeight: 20, textAlign: "right" },
  soundRow: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.xs },
  soundInfo: { flex: 1, alignItems: "flex-end", gap: 3 },
  fieldLabel: { color: colors.text.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  soundName: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, maxWidth: "100%" },
  iconButton: { width: 36, height: 36, borderRadius: radius.sm, backgroundColor: colors.background.subtle, alignItems: "center", justifyContent: "center" },
  actions: { flexDirection: "row-reverse", gap: spacing.xs },
  secondaryButton: { flex: 1, minHeight: 42, borderRadius: radius.md, borderWidth: 1, borderColor: colors.brand.aqua, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.xs, paddingHorizontal: spacing.xs },
  secondaryButtonText: { color: colors.brand.primary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium },
  previewButton: { minHeight: 42, borderRadius: radius.md, backgroundColor: colors.brand.primary, flexDirection: "row-reverse", alignItems: "center", justifyContent: "center", gap: spacing.xs, paddingHorizontal: spacing.md },
  previewText: { color: "#fff", fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.bold },
  vibrationRow: { flexDirection: "row-reverse", justifyContent: "space-between", alignItems: "center", borderTopWidth: 1, borderTopColor: colors.border, paddingTop: spacing.sm },
  vibrationLabel: { flexDirection: "row-reverse", alignItems: "center", gap: spacing.xs },
  infoCard: { flexDirection: "row-reverse", alignItems: "flex-start", gap: spacing.xs, backgroundColor: colors.status.success.background, padding: spacing.md, borderRadius: radius.md },
  infoText: { flex: 1, color: colors.status.success.text, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, lineHeight: 20, textAlign: "right" },
  note: { color: colors.text.secondary, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.regular, lineHeight: 19, textAlign: "right" },
  loading: { minHeight: 180, alignItems: "center", justifyContent: "center" },
  disabled: { opacity: 0.45 },
  error: { color: colors.status.danger.text, backgroundColor: colors.status.danger.background, padding: spacing.sm, borderRadius: radius.md, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium, textAlign: "right" },
  notice: { color: colors.status.success.text, backgroundColor: colors.status.success.background, padding: spacing.sm, borderRadius: radius.md, fontSize: typography.fontSize.xs, fontFamily: typography.fontFamily.medium, textAlign: "right" },
});
