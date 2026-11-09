import { Platform } from "react-native";
import { requireNativeModule } from "expo-modules-core";
import type { PumpOperation } from "@/lib/repositories/pump-operations";
import { getPersistentTimerSnapshot } from "@/lib/alerts/timing-rules";

type PumpTimerNativeModule = {
  startTimer(operationId: string, endAtEpochMs: number): Promise<void>;
  pauseTimer(operationId: string, remainingMs: number): Promise<void>;
  stopTimer(): Promise<void>;
};

let nativeModule: PumpTimerNativeModule | null = null;
function getNativeModule() {
  if (Platform.OS !== "android") return null;
  if (!nativeModule) nativeModule = requireNativeModule<PumpTimerNativeModule>("PumpTimer");
  return nativeModule;
}

let queuedSync: Promise<void> = Promise.resolve();

/** Android's own Chronometer updates the visible countdown; JS does not tick in background. */
export async function syncPersistentPumpTimerNotification(
  pumpId: string,
  operations: PumpOperation[],
) {
  if (Platform.OS !== "android" || !pumpId) return;
  const current = queuedSync.catch(() => undefined).then(async () => {
    const native = getNativeModule();
    if (!native) return;

    const active = operations.find((operation) =>
      operation.pump_id === pumpId
      && (operation.status === "running" || operation.status === "paused"),
    );
    if (!active) {
      await native.stopTimer();
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
  queuedSync = current;
  return current;
}
