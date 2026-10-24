"use client";
/**
 * Client-side user settings, persisted to localStorage under `openfeed.settings` (JSON).
 *
 *   const [settings, update] = useSettings();
 *   update({ theme: "dark" });          // shallow-merges, persists, notifies every subscriber
 *
 * API
 * - `Settings`            the settings shape (see type below).
 * - `DEFAULT_SETTINGS`    defaults; also the server snapshot, so SSR always renders defaults and
 *                         the client switches to stored values right after hydration.
 * - `useSettings()`       `[settings, update]`. `update(patch: Partial<Settings>)` is stable
 *                         (module-level), so it is safe in deps arrays. Invalid values in a patch
 *                         are dropped. Changing `theme` applies it to <html> immediately.
 * - `getSettings()`       current settings outside React (reads storage; never throws).
 * - `applyTheme(theme)`   sets `data-theme="light"|"dark"` on <html>, or removes it for "system".
 *
 * The inline script in src/app/layout.tsx applies the stored theme before first paint; keep it
 * in sync with `SETTINGS_KEY` and the theme values here.
 */
import { useSyncExternalStore } from "react";

export type Theme = "system" | "light" | "dark";

export type Settings = {
  theme: Theme;
  readerFont: "serif" | "sans";
  textSize: "s" | "m" | "l";
  autoplay: boolean;
  theater: boolean;
};

export const SETTINGS_KEY = "openfeed.settings";

export const DEFAULT_SETTINGS: Settings = Object.freeze({
  theme: "system",
  readerFont: "serif",
  textSize: "m",
  autoplay: true,
  theater: true,
});

const ALLOWED: { [K in keyof Settings]: readonly Settings[K][] } = {
  theme: ["system", "light", "dark"],
  readerFont: ["serif", "sans"],
  textSize: ["s", "m", "l"],
  autoplay: [true, false],
  theater: [true, false],
};

/** Keeps only known keys with allowed values. */
function sanitize(input: unknown): Partial<Settings> {
  const out: Record<string, unknown> = {};
  if (!input || typeof input !== "object") return out;
  for (const key of Object.keys(ALLOWED) as (keyof Settings)[]) {
    const v = (input as Record<string, unknown>)[key];
    if ((ALLOWED[key] as readonly unknown[]).includes(v)) out[key] = v;
  }
  return out as Partial<Settings>;
}

let cached: Settings = DEFAULT_SETTINGS;
let cachedRaw: string | null = null;
const listeners = new Set<() => void>();

export function getSettings(): Settings {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(SETTINGS_KEY);
  } catch {}
  if (raw === cachedRaw) return cached;
  cachedRaw = raw;
  let parsed: unknown = null;
  try {
    parsed = raw ? JSON.parse(raw) : null;
  } catch {}
  cached = { ...DEFAULT_SETTINGS, ...sanitize(parsed) };
  return cached;
}

export function applyTheme(theme: Theme) {
  if (typeof document === "undefined") return;
  const el = document.documentElement;
  if (theme === "light" || theme === "dark") el.setAttribute("data-theme", theme);
  else el.removeAttribute("data-theme");
}

function updateSettings(patch: Partial<Settings>) {
  const prev = getSettings();
  const next: Settings = { ...prev, ...sanitize(patch) };
  const raw = JSON.stringify(next);
  if (raw === JSON.stringify(prev)) return;
  try {
    localStorage.setItem(SETTINGS_KEY, raw);
  } catch {}
  cached = next;
  cachedRaw = raw;
  if (next.theme !== prev.theme) applyTheme(next.theme);
  listeners.forEach((l) => l());
}

function subscribe(cb: () => void) {
  listeners.add(cb);
  // Another tab changed settings: re-read and re-apply the theme there too.
  const onStorage = (e: StorageEvent) => {
    if (e.key !== SETTINGS_KEY && e.key !== null) return;
    applyTheme(getSettings().theme);
    cb();
  };
  window.addEventListener("storage", onStorage);
  return () => {
    listeners.delete(cb);
    window.removeEventListener("storage", onStorage);
  };
}

export function useSettings(): [Settings, (patch: Partial<Settings>) => void] {
  const settings = useSyncExternalStore(subscribe, getSettings, () => DEFAULT_SETTINGS);
  return [settings, updateSettings];
}
