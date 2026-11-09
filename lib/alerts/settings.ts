import * as FileSystem from "expo-file-system/legacy";

export type AlertKind = "minuteWarning" | "handover";

export type AlertPreference = {
  enabled: boolean;
  soundUri: string;
  soundName: string;
  vibrate: boolean;
};

export type AlertSettings = {
  minuteWarning: AlertPreference;
  handover: AlertPreference;
};

const DEFAULT_SOUND_BASE64 = "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";
const SETTINGS_FILE = "water-management-alert-settings.json";
const SOUND_DIRECTORY = "water-management-alerts";

let cachedDefaultSoundUri: string | null = null;

function defaultPreference(uri: string, soundName = "الصوت الافتراضي"): AlertPreference {
  return { enabled: true, soundUri: uri, soundName, vibrate: true };
}

function storageDirectory() {
  if (!FileSystem.documentDirectory) {
    throw new Error("مساحة التخزين الداخلية غير متاحة على هذا الجهاز.");
  }
  return FileSystem.documentDirectory;
}

async function ensureSoundDirectory() {
  const directory = `${storageDirectory()}${SOUND_DIRECTORY}/`;
  const info = await FileSystem.getInfoAsync(directory);
  if (!info.exists) {
    await FileSystem.makeDirectoryAsync(directory, { intermediates: true });
  }
  return directory;
}

export async function ensureDefaultAlertSound() {
  if (cachedDefaultSoundUri) return cachedDefaultSoundUri;
  const directory = await ensureSoundDirectory();
  const uri = `${directory}default-alert.wav`;
  const info = await FileSystem.getInfoAsync(uri);
  if (!info.exists) {
    await FileSystem.writeAsStringAsync(uri, DEFAULT_SOUND_BASE64, {
      encoding: FileSystem.EncodingType.Base64,
    });
  }
  cachedDefaultSoundUri = uri;
  return uri;
}

function settingsFileUri() {
  return `${storageDirectory()}${SETTINGS_FILE}`;
}

function normalizePreference(value: unknown, fallback: AlertPreference): AlertPreference {
  if (!value || typeof value !== "object") return fallback;
  const candidate = value as Partial<AlertPreference>;
  return {
    enabled: typeof candidate.enabled === "boolean" ? candidate.enabled : fallback.enabled,
    soundUri: typeof candidate.soundUri === "string" ? candidate.soundUri : fallback.soundUri,
    soundName: typeof candidate.soundName === "string" ? candidate.soundName : fallback.soundName,
    vibrate: typeof candidate.vibrate === "boolean" ? candidate.vibrate : fallback.vibrate,
  };
}

export async function loadAlertSettings(): Promise<AlertSettings> {
  const defaultUri = await ensureDefaultAlertSound();
  const defaults: AlertSettings = {
    minuteWarning: defaultPreference(defaultUri),
    handover: defaultPreference(defaultUri),
  };
  const fileInfo = await FileSystem.getInfoAsync(settingsFileUri());
  if (!fileInfo.exists) return defaults;

  try {
    const raw = await FileSystem.readAsStringAsync(settingsFileUri());
    const parsed = JSON.parse(raw) as Partial<AlertSettings>;
    const minuteWarning = normalizePreference(parsed.minuteWarning, defaults.minuteWarning);
    const handover = normalizePreference(parsed.handover, defaults.handover);
    const validateStoredFile = async (preference: AlertPreference, fallback: AlertPreference) => {
      if (preference.soundUri === defaultUri) return preference;
      const info = await FileSystem.getInfoAsync(preference.soundUri);
      return info.exists ? preference : { ...fallback, soundName: "الصوت الافتراضي (تعذر العثور على الملف)" };
    };
    return {
      minuteWarning: await validateStoredFile(minuteWarning, defaults.minuteWarning),
      handover: await validateStoredFile(handover, defaults.handover),
    };
  } catch (error) {
    console.warn("Alert settings could not be read; defaults are used.", error);
    return defaults;
  }
}

export async function saveAlertSettings(settings: AlertSettings) {
  await FileSystem.writeAsStringAsync(
    settingsFileUri(),
    JSON.stringify(settings),
    { encoding: FileSystem.EncodingType.UTF8 },
  );
}

export async function copyAlertSoundToAppStorage(sourceUri: string, originalName: string) {
  const directory = await ensureSoundDirectory();
  const extension = originalName.split(".").pop()?.toLowerCase().replace(/[^a-z0-9]/g, "") ?? "m4a";
  const allowed = new Set(["mp3", "m4a", "wav", "aac", "ogg", "3gp", "flac"]);
  if (!allowed.has(extension)) {
    throw new Error("صيغة الصوت غير مدعومة. استخدم MP3 أو M4A أو WAV أو AAC.");
  }
  const info = await FileSystem.getInfoAsync(sourceUri);
  if (!info.exists) throw new Error("تعذر قراءة الملف الصوتي المختار.");
  if (typeof info.size === "number" && info.size > 15 * 1024 * 1024) {
    throw new Error("حجم الملف الصوتي أكبر من 15 ميغابايت.");
  }

  const safeBaseName = originalName
    .replace(/\.[^.]+$/, "")
    .replace(/[^\p{L}\p{N}_-]+/gu, "-")
    .slice(0, 40) || "custom-alert";
  const destinationUri = `${directory}${Date.now()}-${safeBaseName}.${extension}`;
  await FileSystem.copyAsync({ from: sourceUri, to: destinationUri });
  return { uri: destinationUri, name: originalName };
}

export async function deleteCustomAlertSound(uri: string) {
  const directory = await ensureSoundDirectory();
  if (!uri.startsWith(directory) || uri.endsWith("default-alert.wav")) return;
  const info = await FileSystem.getInfoAsync(uri);
  if (info.exists) await FileSystem.deleteAsync(uri, { idempotent: true });
}
