import { createAudioPlayer, setAudioModeAsync } from "expo-audio";

type Player = ReturnType<typeof createAudioPlayer>;

let player: Player | null = null;
let currentSource: string | null = null;
let activeKey: string | null = null;
let stopTimer: ReturnType<typeof setTimeout> | null = null;
let generation = 0;

export async function playAlertSound(uri: string, durationMs: number, key: string) {
  stopAlertSound();
  const currentGeneration = ++generation;

  try {
    await setAudioModeAsync({
      playsInSilentMode: true,
      shouldPlayInBackground: true,
      interruptionMode: "mixWithOthers",
    });
    if (currentGeneration !== generation) return;

    if (!player) {
      player = createAudioPlayer(uri, { updateInterval: 100 });
      currentSource = uri;
    } else if (currentSource !== uri) {
      player.replace(uri);
      currentSource = uri;
    }

    player.loop = true;
    player.volume = 0.9;
    await player.seekTo(0);
    if (currentGeneration !== generation) return;
    activeKey = key;
    player.play();

    stopTimer = setTimeout(() => stopAlertSound(key), Math.max(250, durationMs));
  } catch (error) {
    console.warn("Unable to play configured alert sound.", error);
    stopAlertSound(key);
  }
}

export function stopAlertSound(key?: string) {
  if (key && activeKey !== key) return;
  generation += 1;
  if (stopTimer) clearTimeout(stopTimer);
  stopTimer = null;
  activeKey = null;
  if (player) {
    try {
      player.pause();
      void player.seekTo(0).catch(() => undefined);
    } catch (error) {
      console.warn("Unable to stop alert sound cleanly.", error);
    }
  }
}

export function getActiveAlertSoundKey() {
  return activeKey;
}
