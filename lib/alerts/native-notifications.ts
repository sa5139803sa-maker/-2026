import { Platform } from "react-native";
import Constants from "expo-constants";
import * as IntentLauncher from "expo-intent-launcher";
import * as Notifications from "expo-notifications";
import type { AlertSettings } from "@/lib/alerts/settings";
import {
  getHandoverAlertWindow,
  getOperationNotificationSchedule,
  HANDOVER_WARNING_WINDOW_MS,
} from "@/lib/alerts/timing-rules";
import type { DailyQueue, PumpOperation } from "@/lib/repositories/pump-operations";

type NativeAlertKind = "minute" | "handover";
const CHANNEL_VERSION = "v1";
const CHANNELS: Record<NativeAlertKind, { name: string; sound: string }> = {
  minute: { name: "تنبيه بقاء دقيقة", sound: "minute_warning.wav" },
  handover: { name: "تنبيه نهاية التعبئة والانتقال", sound: "handover_warning.wav" },
};
const syncQueues = new Map<string, Promise<void>>();

function serializeSync(key: string, task: () => Promise<void>) {
  const previous = syncQueues.get(key) ?? Promise.resolve();
  const current = previous.catch(() => undefined).then(task);
  syncQueues.set(key, current);
  void current.finally(() => {
    if (syncQueues.get(key) === current) syncQueues.delete(key);
  }).catch(() => undefined);
  return current;
}

function channelId(kind: NativeAlertKind, vibrate: boolean) {
  return "water-timer-" + kind + "-" + CHANNEL_VERSION + "-" + (vibrate ? "vibrate" : "quiet");
}

async function ensureChannel(kind: NativeAlertKind, vibrate: boolean) {
  if (Platform.OS !== "android") return null;
  const channel = CHANNELS[kind];
  const id = channelId(kind, vibrate);
  await Notifications.setNotificationChannelAsync(id, {
    name: channel.name + (vibrate ? " — مع اهتزاز" : " — دون اهتزاز"),
    importance: Notifications.AndroidImportance.MAX,
    lockscreenVisibility: Notifications.AndroidNotificationVisibility.PUBLIC,
    enableVibrate: vibrate,
    vibrationPattern: vibrate ? [0, 280, 150, 280, 150, 280] : [],
    enableLights: false,
    showBadge: false,
    bypassDnd: false,
    sound: channel.sound,
    audioAttributes: {
      usage: Notifications.AndroidAudioUsage.NOTIFICATION,
      contentType: Notifications.AndroidAudioContentType.SONIFICATION,
    },
  });
  return id;
}

export function installTimerNotificationHandler() {
  Notifications.setNotificationHandler({
    handleNotification: async () => ({
      shouldPlaySound: true,
      shouldSetBadge: false,
      shouldShowBanner: true,
      shouldShowList: true,
      priority: Notifications.AndroidNotificationPriority.MAX,
    }),
  });
}

export async function initializeAndroidTimerChannels() {
  if (Platform.OS !== "android") return;
  await ensureChannel("minute", true);
  await ensureChannel("minute", false);
  await ensureChannel("handover", true);
  await ensureChannel("handover", false);
}

export async function requestAndroidNotificationPermission() {
  if (Platform.OS !== "android") return false;
  await initializeAndroidTimerChannels();
  const current = await Notifications.getPermissionsAsync();
  const response = current.granted ? current : await Notifications.requestPermissionsAsync();
  return response.granted;
}

export async function openAndroidExactAlarmSettings() {
  if (Platform.OS !== "android") {
    throw new Error("إعداد المنبّهات الدقيقة متاح على Android فقط.");
  }
  if (Number(Platform.Version) < 31) return;
  const packageName = Constants.applicationId;
  if (!packageName) {
    throw new Error("تعذر تحديد معرّف حزمة التطبيق لفتح إعداد المنبّهات الدقيقة.");
  }
  await IntentLauncher.startActivityAsync(
    "android.settings.REQUEST_SCHEDULE_EXACT_ALARM",
    { data: "package:" + packageName },
  );
}

async function hasNotificationPermission() {
  if (Platform.OS !== "android") return false;
  const permission = await Notifications.getPermissionsAsync();
  return permission.granted;
}

async function cancelScheduledMatching(predicate: (data: Record<string, unknown>) => boolean) {
  const scheduled = await Notifications.getAllScheduledNotificationsAsync();
  const targets = scheduled.filter((notification) => {
    const data = notification.content.data;
    return !!data && typeof data === "object" && predicate(data as Record<string, unknown>);
  });
  await Promise.all(targets.map((notification) =>
    Notifications.cancelScheduledNotificationAsync(notification.identifier),
  ));
}

async function scheduleAlert(
  kind: NativeAlertKind,
  at: number,
  title: string,
  body: string,
  vibrate: boolean,
  data: Record<string, string>,
) {
  if (Platform.OS !== "android" || at <= Date.now()) return;
  const selectedChannel = await ensureChannel(kind, vibrate);
  if (!selectedChannel) return;
  await Notifications.scheduleNotificationAsync({
    content: {
      title,
      body,
      sound: CHANNELS[kind].sound,
      priority: Notifications.AndroidNotificationPriority.MAX,
      data,
    },
    trigger: {
      type: Notifications.SchedulableTriggerInputTypes.DATE,
      date: new Date(at),
      channelId: selectedChannel,
    },
  });
}

export async function cancelOperationTimerNotifications(operationId: string) {
  if (Platform.OS !== "android" || !operationId) return;
  await cancelScheduledMatching((data) =>
    data.alertScope === "pump-operation" && data.operationId === operationId,
  );
}

export async function cancelHandoverNotification(token: string) {
  if (Platform.OS !== "android" || !token) return;
  await cancelScheduledMatching((data) =>
    data.alertScope === "pump-handover" && data.token === token,
  );
}

export async function syncPumpTimerNotifications(
  pumpId: string,
  operations: PumpOperation[],
  settings: AlertSettings,
) {
  if (Platform.OS !== "android" || !pumpId) return;
  return serializeSync("pump:" + pumpId, async () => {
    await cancelScheduledMatching((data) =>
      data.alertScope === "pump-operation" && data.pumpId === pumpId,
    );
    if (!(await hasNotificationPermission())) return;

    const active = operations.find((operation) =>
      operation.pump_id === pumpId && operation.status === "running",
    );
    if (!active) return;

    const timing = getOperationNotificationSchedule(
      active.started_at,
      active.planned_minutes,
      active.paused_seconds,
      Date.now(),
    );
    if (!timing) return;

    if (settings.minuteWarning.enabled && timing.minuteWarningAt) {
      await scheduleAlert(
        "minute",
        timing.minuteWarningAt,
        "بقيت دقيقة على انتهاء التعبئة",
        "اقترب انتهاء دور " + active.subscriber_name + ". افتح التطبيق عند الحاجة.",
        settings.minuteWarning.vibrate,
        {
          alertScope: "pump-operation",
          alertKind: "minute",
          operationId: active.id,
          pumpId,
          scheduledAt: String(timing.minuteWarningAt),
        },
      );
    }

    // This is a fallback reminder only. It cannot complete the server operation.
    if (settings.handover.enabled && timing.endReminderAt) {
      await scheduleAlert(
        "handover",
        timing.endReminderAt,
        "انتهت مدة التعبئة المحددة",
        "افتح التطبيق للتحقق من تسجيل نهاية الدور ومزامنة الطابور التالي.",
        settings.handover.vibrate,
        {
          alertScope: "pump-operation",
          alertKind: "end-reminder",
          operationId: active.id,
          pumpId,
          scheduledAt: String(timing.endReminderAt),
        },
      );
    }
  });
}

export async function syncQueueHandoverNotification(
  pumpId: string,
  queue: DailyQueue | null,
  settings: AlertSettings,
) {
  if (Platform.OS !== "android" || !pumpId) return;
  return serializeSync("queue:" + pumpId, async () => {
    await cancelScheduledMatching((data) =>
      data.alertScope === "pump-handover" && data.pumpId === pumpId,
    );
    if (!queue || !settings.handover.enabled || !queue.auto_advance_token || !queue.auto_advance_at) return;
    if (!(await hasNotificationPermission())) return;

    const now = Date.now();
    const deadline = new Date(queue.auto_advance_at).getTime();
    const window = getHandoverAlertWindow(deadline, now);
    if (!window || window.durationMs < HANDOVER_WARNING_WINDOW_MS) return;
    const triggerAt = deadline - HANDOVER_WARNING_WINDOW_MS;
    if (triggerAt <= now) return;

    await scheduleAlert(
      "handover",
      triggerAt,
      "تنبيه الانتقال إلى الدور التالي",
      "بقيت ثانيتان على نهاية مهلة الانتقال المحفوظة في الطابور.",
      settings.handover.vibrate,
      {
        alertScope: "pump-handover",
        alertKind: "handover",
        pumpId,
        queueId: queue.id,
        token: queue.auto_advance_token,
        scheduledAt: String(triggerAt),
      },
    );
  });
}
