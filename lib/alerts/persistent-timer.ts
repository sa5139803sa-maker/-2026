import { Platform } from "react-native";
import { requireNativeModule } from "expo-modules-core";
import * as Notifications from "expo-notifications";
import type { PumpOperation } from "@/lib/repositories/pump-operations";
import { getPersistentTimerSnapshot } from "@/lib/alerts/timing-rules";

type PumpTimerNativeModule = {
  startTimer(operationId: string, endAtEpochMs: number): Promise<void>;
  pauseTimer(operationId: string, remainingMs: number): Promise<void>;
  stopTimer(operationId: string): Promise<void>;
};

let nativeModule: PumpTimerNativeModule | null = null;
function getNativeModule() {
  if (Platform.OS !== "android") return null;
  if (!nativeModule) nativeModule = requireNativeModule<PumpTimerNativeModule>("PumpTimer");
  return nativeModule;
}

let queuedSync: Promise<void> = Promise.resolve();

function enqueueNativeTask(task: (native: PumpTimerNativeModule) => Promise<void>) {
  const current = queuedSync.catch(() => undefined).then(async () => {
    const native = getNativeModule();
    if (!native) return;
    await task(native);
  });
  queuedSync = current;
  return current;
}

/**
 * Start while the start action is still foregrounded, before awaiting the
 * server operation. The later server refresh replaces this provisional end
 * timestamp with the authoritative persisted timestamp.
 */
export async function startPersistentPumpTimerNotification(
  operationId: string,
  plannedMinutes: number,
) {
  if (Platform.OS !== "android") return false;
  if (!operationId || !Number.isInteger(plannedMinutes) || plannedMinutes < 1) {
    throw new Error("A valid operation ID and planned duration are required.");
  }
  const permission = await Notifications.getPermissionsAsync();
  if (!permission.granted) return false;
  const provisionalEndAt = Date.now() + plannedMinutes * 60_000;
  await enqueueNativeTask((native) => native.startTimer(operationId, provisionalEndAt));
  return true;
}

export async function stopPersistentPumpTimerNotification() {
  if (Platform.OS !== "android") return;
  await enqueueNativeTask((native) => native.stopTimer());
}

export async function pausePersistentPumpTimerNotification(operation: PumpOperation) {
  if (Platform.OS !== "android") return;
  const permission = await Notifications.getPermissionsAsync();
  if (!permission.granted) {
    await stopPersistentPumpTimerNotification();
    return;
  }
  const pausedAt = Date.now();
  const snapshot = getPersistentTimerSnapshot({
    ...operation,
    status: "paused",
    paused_at: new Date(pausedAt).toISOString(),
  }, pausedAt);
  if (!snapshot || snapshot.mode !== "paused") {
    throw new Error("Could not calculate the paused pump timer state.");
  }
  await enqueueNativeTask((native) =>
    native.pauseTimer(snapshot.operationId, snapshot.remainingMs),
  );
}

export async function resumePersistentPumpTimerNotification(operation: PumpOperation) {
  if (Platform.OS !== "android") return;
  const permission = await Notifications.getPermissionsAsync();
  if (!permission.granted) {
    await stopPersistentPumpTimerNotification();
    return;
  }
  const resumedAt = Date.now();
  const pausedAt = operation.paused_at ? Date.parse(operation.paused_at) : Number.NaN;
  if (!Number.isFinite(pausedAt) || pausedAt > resumedAt) {
    throw new Error("The paused pump operation has an invalid pause timestamp.");
  }
  const currentPauseSeconds = Math.max(0, Math.floor((resumedAt - pausedAt) / 1000));
  const snapshot = getPersistentTimerSnapshot({
    ...operation,
    status: "running",
    paused_seconds: operation.paused_seconds + currentPauseSeconds,
  }, resumedAt);
  if (!snapshot || snapshot.mode !== "running") {
    throw new Error("Could not calculate the resumed pump timer end time.");
  }
  await enqueueNativeTask((native) =>
    native.startTimer(snapshot.operationId, snapshot.endAtEpochMs),
  );
}

/** Android's own Chronometer/** Android's own Chronometer updates the visible countdown; JS does not tick in background. */
export async function syncPersistentPumpTimerNotification(
  pumpId: string,
  operations: PumpOperation[],
) {
  if (Platform.OS !== "android" || !pumpId) return;
  return enqueueNativeTask(async (native) => {
    const permission = await Notifications.getPermissionsAsync();
    if (!permission.granted) {
      await native.stopTimer();
      return;
    }
    const active = operations.find((operation) =>
      operation.pump_id === pumpId
      && (operation.status === "running" || operation.status === "paused"),
    );
    if (!active) {
      // Do not clear a different pump's foreground timer when this pump has
      // no active operation. Remove only a timer whose matching operation
      // is now marked completed in this pump's successfully loaded data.
      const completed = operations.filter((operation) =>
        operation.pump_id === pumpId && operation.status === "completed",
      );
      for (const operation of completed) {
        await native.stopTimer(operation.id);
      }
      return;
    }
    const snapshot = getPersistentTimerSnapshot(active, Date.now());
    if (!snapshot) throw new Error("The persisted pump operation has invalid timer timestamps.");
    if (snapshot.mode === "running") {
      await native.startTimer(snapshot.operationId, snapshot.endAtEpochMs);
    } else {
      await native.pauseTimer(snapshot.operationId, snapshot.remainingMs);
    }
  });
}
