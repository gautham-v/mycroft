"use client";
import { useEffect, useId, useRef, useState } from "react";
import type { Source } from "@/lib/types";
import { relativeTime } from "@/lib/time";
import { useSettings, type Settings } from "@/hooks/use-settings";
import { CloseIcon, PlusIcon } from "./icons";

export type SettingsTab = "sources" | "appearance" | "playback";

const TABS: { id: SettingsTab; label: string }[] = [
  { id: "sources", label: "Sources" },
  { id: "appearance", label: "Appearance" },
  { id: "playback", label: "Playback" },
];

const NAV_ROW = "flex h-[32px] w-full items-center rounded-[4px] px-2 text-left text-[14px] text-[var(--ink)]";
const ROW = "flex items-center gap-3 border-t border-[var(--hairline)] py-2.5";

/**
 * Settings sheet: Sources / Appearance / Playback. Stays mounted while closed, so the selected
 * tab survives reopening within a session. Full-screen with a segmented section switcher below md.
 */
export function SettingsDialog({
  open,
  onClose,
  sources,
  now,
  onAdd,
  onRemoved,
  onOpen,
}: {
  open: boolean;
  onClose: () => void;
  sources: Source[];
  now: number;
  /** Opens the app's AddSourceDialog (it stacks above this one). */
  onAdd: () => void;
  /** Called after a source is deleted on the server. */
  onRemoved: (id: number) => void;
  /** Tapping a source title filters the feed to it (the only way to do so on phones). */
  onOpen: (s: Source) => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const [tab, setTab] = useState<SettingsTab>("sources");

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);

  const tabProps = (id: SettingsTab) => ({
    role: "tab" as const,
    type: "button" as const,
    "aria-selected": tab === id,
    "aria-controls": "settings-panel",
    tabIndex: tab === id ? 0 : -1,
    onClick: () => setTab(id),
    onKeyDown: (e: React.KeyboardEvent<HTMLButtonElement>) => {
      const keys = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"];
      if (!keys.includes(e.key)) return;
      e.preventDefault();
      const i = TABS.findIndex((t) => t.id === id);
      const step = e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : 1;
      const next = TABS[(i + step + TABS.length) % TABS.length].id;
      setTab(next);
      e.currentTarget.parentElement?.querySelector<HTMLButtonElement>(`[data-tab="${next}"]`)?.focus();
    },
    "data-tab": id,
  });

  return (
    <dialog
      ref={ref}
      onClose={onClose}
      // Keep Escape from also reaching the app's global shortcuts (e.g. leaving the full-screen reader).
      onKeyDown={(e) => e.key === "Escape" && e.stopPropagation()}
      aria-label="Settings"
      className="m-auto h-[min(86dvh,480px)] w-[min(94vw,640px)] overflow-hidden rounded-xl border border-[var(--hairline)] bg-[var(--surface)] p-0 text-[var(--body)] shadow-2xl backdrop:bg-black/30 max-md:m-0 max-md:h-dvh max-md:max-h-none max-md:w-screen max-md:max-w-none max-md:rounded-none max-md:border-0"
    >
      <div className="flex h-full flex-col md:flex-row">
        {/* Phone: title + segmented section switcher */}
        <div className="shrink-0 px-4 pt-[calc(env(safe-area-inset-top)+12px)] md:hidden">
          <h2 className="pr-10 text-[17px] font-semibold tracking-[-0.01em] text-[var(--ink)]">Settings</h2>
          <div role="tablist" aria-label="Settings sections" className="mt-3 flex rounded-md bg-[var(--code)] p-0.5">
            {TABS.map((t) => (
              <button
                key={t.id}
                {...tabProps(t.id)}
                className={`h-8 flex-1 rounded-[4px] text-[13px] font-medium ${
                  tab === t.id ? "bg-[var(--surface)] text-[var(--ink)] shadow-sm" : "text-[var(--muted)]"
                }`}
              >
                {t.label}
              </button>
            ))}
          </div>
        </div>

        {/* Tablet/desktop: left nav column */}
        <div className="hidden w-[140px] shrink-0 flex-col bg-[var(--ground)] px-2 pt-4 md:flex">
          <h2 className="px-2 pb-2 text-[11px] font-semibold tracking-[0.01em] text-[var(--faint)]">Settings</h2>
          <div role="tablist" aria-label="Settings sections" aria-orientation="vertical" className="flex flex-col gap-px">
            {TABS.map((t) => (
              <button
                key={t.id}
                {...tabProps(t.id)}
                className={`${NAV_ROW} ${tab === t.id ? "bg-[var(--nav-selection)]" : "hover:bg-[var(--nav-hover)]"}`}
              >
                {t.label}
              </button>
            ))}
          </div>
        </div>

        <div
          id="settings-panel"
          role="tabpanel"
          aria-label={TABS.find((t) => t.id === tab)?.label}
          className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 pb-[calc(env(safe-area-inset-bottom)+20px)] pt-4 md:px-5 md:pb-5 md:pt-4"
        >
          {tab === "sources" && <SourcesPane sources={sources} now={now} onAdd={onAdd} onRemoved={onRemoved} onOpen={onOpen} />}
          {tab === "appearance" && <AppearancePane />}
          {tab === "playback" && <PlaybackPane />}
        </div>
      </div>

      <button
        type="button"
        onClick={onClose}
        aria-label="Close settings"
        className="absolute right-3 top-[calc(env(safe-area-inset-top)+8px)] inline-flex h-[30px] w-[30px] items-center justify-center rounded-lg text-[var(--muted)] hover:bg-[var(--hover)] md:top-3"
      >
        <CloseIcon size={18} />
      </button>
    </dialog>
  );
}

function PaneHeading({ title, hint }: { title: string; hint: string }) {
  return (
    <div className="pb-3 md:pr-10">
      <h3 className="hidden text-[17px] font-semibold tracking-[-0.01em] text-[var(--ink)] md:block">{title}</h3>
      <p className="text-[13px] text-[var(--muted)] md:mt-0.5">{hint}</p>
    </div>
  );
}

// --- Sources -------------------------------------------------------------------

const UNIT: Record<string, string> = { m: "min", h: "hr", d: "d", w: "wk", y: "yr" };

function fetchedLabel(at: string | null, now: number) {
  if (!at) return "Never fetched";
  const rel = relativeTime(at, now);
  if (!rel) return "Never fetched";
  if (rel === "now") return "Fetched just now";
  const m = /^(\d+)([a-z])$/.exec(rel);
  return m ? `Fetched ${m[1]} ${UNIT[m[2]] ?? m[2]} ago` : `Fetched ${rel} ago`;
}

function hostOf(s: Source) {
  if (s.host) return s.host;
  try {
    return new URL(s.url).hostname.replace(/^www\./, "");
  } catch {
    return s.url;
  }
}

function SourcesPane({
  sources,
  now,
  onAdd,
  onRemoved,
  onOpen,
}: {
  sources: Source[];
  now: number;
  onAdd: () => void;
  onRemoved: (id: number) => void;
  onOpen: (s: Source) => void;
}) {
  const [confirming, setConfirming] = useState<number | null>(null);
  const [removed, setRemoved] = useState<Set<number>>(() => new Set());
  const [errors, setErrors] = useState<Record<number, string>>({});

  const remove = async (s: Source) => {
    setConfirming(null);
    setErrors((e) => {
      const next = { ...e };
      delete next[s.id];
      return next;
    });
    setRemoved((prev) => new Set(prev).add(s.id));
    try {
      const res = await fetch(`/api/sources/${s.id}`, { method: "DELETE" });
      if (!res.ok && res.status !== 404) {
        const body = (await res.json().catch(() => null)) as { error?: string } | null;
        throw new Error(body?.error || `Request failed (${res.status})`);
      }
      onRemoved(s.id);
    } catch (err) {
      setRemoved((prev) => {
        const next = new Set(prev);
        next.delete(s.id);
        return next;
      });
      setErrors((e) => ({ ...e, [s.id]: err instanceof Error ? err.message : "Could not remove source" }));
    }
  };

  const visible = sources.filter((s) => !removed.has(s.id));
  const groups: [string, Source[]][] = [
    ["Sources", visible.filter((s) => s.kind !== "youtube")],
    ["YouTube", visible.filter((s) => s.kind === "youtube")],
  ];

  return (
    <>
      <PaneHeading title="Sources" hint="Removing a source also removes its items." />
      {visible.length === 0 && <p className="border-t border-[var(--hairline)] py-6 text-center text-[13px] text-[var(--muted)]">No sources yet</p>}
      {groups.map(([label, list]) =>
        list.length ? (
          <section key={label} className="pb-3">
            <h4 className="pb-1.5 text-[11px] font-semibold tracking-[0.01em] text-[var(--faint)]">{label}</h4>
            <ul>
              {list.map((s) => (
                <li key={s.id} className={ROW}>
                  <SourceIcon source={s} />
                  <div className="min-w-0 flex-1">
                    <button
                      type="button"
                      onClick={() => onOpen(s)}
                      className="block max-w-full truncate text-left text-[14px] text-[var(--ink)] hover:underline"
                    >
                      {s.title}
                    </button>
                    {errors[s.id] ? (
                      <p role="alert" className="truncate text-[12px] text-[var(--danger)]">
                        Could not remove: {errors[s.id]}
                      </p>
                    ) : s.last_error ? (
                      <p className="truncate text-[12px] text-[var(--danger)]" title={s.last_error}>
                        Error: {s.last_error}
                      </p>
                    ) : (
                      <p className="truncate text-[12px] text-[var(--muted)]">
                        {hostOf(s)}
                        {s.kind === "page" && " · scraped page"} · {fetchedLabel(s.last_fetched_at, now)}
                      </p>
                    )}
                  </div>
                  {confirming === s.id ? (
                    <div className="flex shrink-0 gap-1.5">
                      <button
                        type="button"
                        onClick={() => setConfirming(null)}
                        className="h-7 rounded-md border border-[var(--border)] px-2.5 text-[13px] font-medium text-[var(--ink)] hover:bg-[var(--hover)]"
                      >
                        Keep
                      </button>
                      <button
                        type="button"
                        autoFocus
                        onClick={() => void remove(s)}
                        aria-label={`Remove ${s.title}`}
                        className="h-7 rounded-md bg-[var(--danger)] px-2.5 text-[13px] font-medium text-white"
                      >
                        Remove
                      </button>
                    </div>
                  ) : (
                    <button
                      type="button"
                      onClick={() => setConfirming(s.id)}
                      aria-label={`Remove ${s.title}`}
                      className="h-7 shrink-0 rounded-md px-2.5 text-[13px] font-medium text-[var(--muted)] hover:bg-[var(--hover)] hover:text-[var(--ink)]"
                    >
                      Remove
                    </button>
                  )}
                </li>
              ))}
            </ul>
          </section>
        ) : null,
      )}
      <button
        type="button"
        onClick={onAdd}
        className="mt-1 inline-flex h-8 items-center gap-1.5 rounded-md bg-[var(--code)] px-3 text-[13px] font-medium text-[var(--accent)] hover:bg-[var(--hover)]"
      >
        <PlusIcon size={15} />
        Add source
      </button>
    </>
  );
}

function SourceIcon({ source }: { source: Source }) {
  const [failed, setFailed] = useState(false);
  const letter = (source.title || source.host || "?").replace(/^the\s+/i, "").charAt(0).toUpperCase();
  if (source.icon_url && !failed) {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={source.icon_url}
        alt=""
        width={22}
        height={22}
        loading="lazy"
        onError={() => setFailed(true)}
        className="h-[22px] w-[22px] shrink-0 rounded-[5px] object-cover"
      />
    );
  }
  return (
    <span
      aria-hidden="true"
      className="inline-flex h-[22px] w-[22px] shrink-0 items-center justify-center rounded-[5px] bg-[var(--code)] text-[12px] font-semibold text-[var(--muted)]"
    >
      {letter}
    </span>
  );
}

// --- Appearance ------------------------------------------------------------------

function AppearancePane() {
  const [settings, update] = useSettings();
  return (
    <>
      <PaneHeading title="Appearance" hint="Applies on this device." />
      <ul>
        <SettingRow label="Theme">
          {(id) => (
            <Segmented
              labelledBy={id}
              value={settings.theme}
              onChange={(theme) => update({ theme })}
              options={[
                ["light", "Light"],
                ["system", "System"],
                ["dark", "Dark"],
              ]}
            />
          )}
        </SettingRow>
        <SettingRow label="Reader font" hint="Headline and body in the article view">
          {(id) => (
            <Segmented
              labelledBy={id}
              value={settings.readerFont}
              onChange={(readerFont) => update({ readerFont })}
              options={[
                ["serif", "Serif"],
                ["sans", "Sans"],
              ]}
            />
          )}
        </SettingRow>
        <SettingRow label="Text size">
          {(id) => (
            <Segmented
              labelledBy={id}
              value={settings.textSize}
              onChange={(textSize) => update({ textSize })}
              options={[
                ["s", "S"],
                ["m", "M"],
                ["l", "L"],
              ]}
            />
          )}
        </SettingRow>
      </ul>
    </>
  );
}

// --- Playback --------------------------------------------------------------------

function PlaybackPane() {
  const [settings, update] = useSettings();
  const toggles: { key: keyof Pick<Settings, "autoplay" | "theater">; label: string; hint: string }[] = [
    { key: "autoplay", label: "Autoplay on select", hint: "Start playing when you open a video" },
    { key: "theater", label: "Theater layout", hint: "Full-width player above the title" },
  ];
  return (
    <>
      <PaneHeading title="Playback" hint="For YouTube sources." />
      <ul>
        {toggles.map((t) => (
          <SettingRow key={t.key} label={t.label} hint={t.hint} asLabel>
            {(id, hintId) => (
              <Switch id={id} describedBy={hintId} checked={settings[t.key]} onChange={(v) => update({ [t.key]: v })} />
            )}
          </SettingRow>
        ))}
      </ul>
    </>
  );
}

// --- Controls ----------------------------------------------------------------------

/** A settings row: label (and optional hint) on the left, a control on the right. With `asLabel`,
 *  the label is a <label> for the control (whose id is the first render arg); otherwise the label's
 *  id is passed so the control can reference it via aria-labelledby. */
function SettingRow({
  label,
  hint,
  asLabel,
  children,
}: {
  label: string;
  hint?: string;
  asLabel?: boolean;
  children: (id: string, hintId: string | undefined) => React.ReactNode;
}) {
  const id = useId();
  const labelId = `${id}-label`;
  const controlId = `${id}-control`;
  const hintId = hint ? `${id}-hint` : undefined;
  return (
    <li className={`${ROW} min-h-[52px] justify-between`}>
      <div className="min-w-0">
        {asLabel ? (
          <label htmlFor={controlId} id={labelId} className="block text-[14px] text-[var(--ink)]">
            {label}
          </label>
        ) : (
          <p id={labelId} className="text-[14px] text-[var(--ink)]">
            {label}
          </p>
        )}
        {hint && (
          <p id={hintId} className="text-[12px] text-[var(--muted)]">
            {hint}
          </p>
        )}
      </div>
      <div className="shrink-0">{children(asLabel ? controlId : labelId, hintId)}</div>
    </li>
  );
}

function Segmented<T extends string>({
  value,
  options,
  onChange,
  labelledBy,
}: {
  value: T;
  options: [T, string][];
  onChange: (v: T) => void;
  labelledBy: string;
}) {
  const onKeyDown = (e: React.KeyboardEvent<HTMLButtonElement>, i: number) => {
    const step = e.key === "ArrowLeft" || e.key === "ArrowUp" ? -1 : e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : 0;
    if (!step) return;
    e.preventDefault();
    const next = (i + step + options.length) % options.length;
    onChange(options[next][0]);
    (e.currentTarget.parentElement?.children[next] as HTMLElement | undefined)?.focus();
  };
  return (
    <div role="radiogroup" aria-labelledby={labelledBy} className="inline-flex rounded-md bg-[var(--code)] p-0.5">
      {options.map(([v, label], i) => {
        const selected = v === value;
        return (
          <button
            key={v}
            type="button"
            role="radio"
            aria-checked={selected}
            tabIndex={selected ? 0 : -1}
            onClick={() => onChange(v)}
            onKeyDown={(e) => onKeyDown(e, i)}
            className={`h-7 min-w-[40px] rounded-[4px] px-3 text-[13px] font-medium ${
              selected ? "bg-[var(--surface)] text-[var(--ink)] shadow-sm" : "text-[var(--muted)] hover:text-[var(--ink)]"
            }`}
          >
            {label}
          </button>
        );
      })}
    </div>
  );
}

function Switch({
  id,
  checked,
  onChange,
  describedBy,
}: {
  id: string;
  checked: boolean;
  onChange: (v: boolean) => void;
  describedBy?: string;
}) {
  return (
    <button
      id={id}
      type="button"
      role="switch"
      aria-checked={checked}
      aria-describedby={describedBy}
      onClick={() => onChange(!checked)}
      className={`relative inline-flex h-5 w-[34px] shrink-0 items-center rounded-full transition-colors ${
        checked ? "bg-[var(--ok)]" : "bg-[var(--border)]"
      }`}
    >
      <span
        aria-hidden="true"
        className={`absolute left-0.5 h-4 w-4 rounded-full bg-white shadow-sm transition-transform ${checked ? "translate-x-[14px]" : ""}`}
      />
    </button>
  );
}
