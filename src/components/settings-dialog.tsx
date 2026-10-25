"use client";
import { useEffect, useId, useRef, useState } from "react";
import type { ApiError, Folder, IntegrationsResponse, OpmlImportResult, PutIntegrationsBody, SendTarget, Source } from "@/lib/types";
import { relativeTime } from "@/lib/time";
import { moveSource } from "@/hooks/use-data";
import { useSettings, type Settings } from "@/hooks/use-settings";
import { setIntegrations, useIntegrations } from "@/hooks/use-integrations";
import { CloseIcon, PlusIcon } from "./icons";

export type SettingsTab = "sources" | "appearance" | "playback" | "integrations";

const TABS: { id: SettingsTab; label: string }[] = [
  { id: "sources", label: "Sources" },
  { id: "appearance", label: "Appearance" },
  { id: "playback", label: "Playback" },
  { id: "integrations", label: "Integrations" },
];

const NAV_ROW = "flex h-[32px] w-full items-center rounded-[4px] px-2 text-left text-[14px] text-[var(--ink)]";
const ROW = "flex items-center gap-3 border-t border-[var(--hairline)] py-2.5";

/**
 * Settings sheet: Sources / Appearance / Playback / Integrations. Stays mounted while closed; the
 * selected tab is owned by the app (so the reader can open Integrations) and survives reopening
 * within a session. Full-screen with a segmented section switcher below md.
 */
export function SettingsDialog({
  open,
  onClose,
  tab,
  onTabChange: setTab,
  sources,
  folders,
  now,
  onAdd,
  onChanged,
  onRemoved,
  onOpen,
  onShowShortcuts,
}: {
  open: boolean;
  onClose: () => void;
  tab: SettingsTab;
  onTabChange: (tab: SettingsTab) => void;
  sources: Source[];
  folders: Folder[];
  now: number;
  /** Called after a source was moved to another folder. */
  onChanged: () => void;
  /** Opens the app's AddSourceDialog (it stacks above this one). */
  onAdd: () => void;
  /** Called after a source is deleted on the server. */
  onRemoved: (id: number) => void;
  /** Tapping a source title opens its feed. */
  onOpen: (s: Source) => void;
  /** Opens the keyboard shortcuts overlay (it stacks above this one). */
  onShowShortcuts: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);

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
          {tab === "sources" && (
            <SourcesPane sources={sources} folders={folders} now={now} onAdd={onAdd} onChanged={onChanged} onRemoved={onRemoved} onOpen={onOpen} />
          )}
          {tab === "appearance" && <AppearancePane onShowShortcuts={onShowShortcuts} />}
          {tab === "playback" && <PlaybackPane />}
          {tab === "integrations" && <IntegrationsPane />}
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
  folders,
  now,
  onAdd,
  onChanged,
  onRemoved,
  onOpen,
}: {
  sources: Source[];
  folders: Folder[];
  now: number;
  onAdd: () => void;
  onChanged: () => void;
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
  const byPos = (a: Source, b: Source) => a.position - b.position || a.title.localeCompare(b.title);
  const orderedFolders = [...folders].sort((a, b) => a.position - b.position || a.id - b.id);
  const groups: [string, Source[]][] = [
    ...orderedFolders.map((f): [string, Source[]] => [f.title, visible.filter((s) => s.folder_id === f.id).sort(byPos)]),
    ["Unfiled", visible.filter((s) => s.folder_id == null).sort(byPos)],
  ];
  const move = (s: Source, raw: string) => {
    const folderId = raw === "" ? null : Number(raw);
    if (folderId === s.folder_id) return;
    void moveSource(s.id, folderId).then(onChanged, onChanged);
  };

  return (
    <>
      <PaneHeading title="Sources" hint="Pick a folder to move a source. Removing a source also removes its items." />
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
                        {s.type === "post"
                          ? " · posts"
                          : s.type === "podcast" || s.kind === "podcast"
                            ? " · podcast"
                            : s.kind === "page"
                              ? " · scraped page"
                              : ""} · {fetchedLabel(s.last_fetched_at, now)}
                      </p>
                    )}
                  </div>
                  {folders.length > 0 && confirming !== s.id && (
                    <select
                      aria-label={`Folder for ${s.title}`}
                      value={s.folder_id ?? ""}
                      onChange={(e) => move(s, e.target.value)}
                      className="h-7 max-w-[120px] shrink-0 rounded-md border border-[var(--border)] bg-[var(--surface)] px-1.5 text-[12px] text-[var(--muted)]"
                    >
                      {orderedFolders.map((f) => (
                        <option key={f.id} value={f.id}>
                          {f.title}
                        </option>
                      ))}
                      <option value="">Unfiled</option>
                    </select>
                  )}
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
      <div className="mt-1 flex flex-wrap items-center gap-2">
        <button type="button" onClick={onAdd} className={`${PANE_BUTTON} gap-1.5 text-[var(--accent)]`}>
          <PlusIcon size={15} />
          Add source
        </button>
        <OpmlButtons onChanged={onChanged} />
      </div>
    </>
  );
}

const PANE_BUTTON =
  "inline-flex h-8 items-center rounded-md bg-[var(--code)] px-3 text-[13px] font-medium hover:bg-[var(--hover)] max-md:h-11";

/** Import (file picker → POST /api/opml) and export (download GET /api/opml) of the subscription list. */
function OpmlButtons({ onChanged }: { onChanged: () => void }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<{ text: string; error: boolean } | null>(null);

  const importFile = async (file: File) => {
    setBusy(true);
    setStatus(null);
    try {
      const form = new FormData();
      form.append("file", file);
      const res = await fetch("/api/opml", { method: "POST", body: form });
      const body = (await res.json().catch(() => null)) as (OpmlImportResult & { error?: string }) | null;
      if (!res.ok || !body) throw new Error(body?.error || `Request failed (${res.status})`);
      const parts = [`Added ${body.added}`, `skipped ${body.skipped}`];
      if (body.folders_created) parts.push(`${body.folders_created} new folder${body.folders_created === 1 ? "" : "s"}`);
      if (body.errors.length) parts.push(`${body.errors.length} failed`);
      setStatus({
        text: `${parts.join(", ")}.${body.added ? " New sources load on the next refresh." : ""}`,
        error: body.added === 0 && body.errors.length > 0,
      });
      if (body.added || body.folders_created) onChanged();
    } catch (err) {
      setStatus({ text: `Import failed: ${err instanceof Error ? err.message : "unknown error"}`, error: true });
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <input
        ref={inputRef}
        type="file"
        accept=".opml,.xml,text/x-opml,text/xml,application/xml"
        className="hidden"
        onChange={(e) => {
          const file = e.target.files?.[0];
          // Reset so picking the same file again still fires onChange.
          e.target.value = "";
          if (file) void importFile(file);
        }}
      />
      <button type="button" disabled={busy} onClick={() => inputRef.current?.click()} className={`${PANE_BUTTON} text-[var(--ink)] disabled:opacity-60`}>
        {busy ? "Importing…" : "Import OPML"}
      </button>
      <a href="/api/opml" download className={`${PANE_BUTTON} text-[var(--ink)]`}>
        Export OPML
      </a>
      {status && (
        <p role="status" className={`basis-full text-[12px] ${status.error ? "text-[var(--danger)]" : "text-[var(--muted)]"}`}>
          {status.text}
        </p>
      )}
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

function AppearancePane({ onShowShortcuts }: { onShowShortcuts: () => void }) {
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
        {/* Shortcuts need a hardware keyboard and the side-by-side layout, so tablet/desktop only. */}
        <SettingRow label="Keyboard shortcuts" hint="Or press ? anywhere" className="max-md:hidden">
          {() => (
            <button
              type="button"
              aria-label="Show keyboard shortcuts"
              onClick={onShowShortcuts}
              className="h-8 rounded-md bg-[var(--code)] px-3 text-[13px] font-medium text-[var(--ink)] hover:bg-[var(--hover)]"
            >
              Show
            </button>
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

// --- Integrations ------------------------------------------------------------------

const INPUT =
  "mt-1.5 h-11 w-full rounded-lg border border-[var(--border)] bg-[var(--ground)] px-3 text-[15px] text-[var(--ink)] outline-none focus:border-[var(--accent)] md:h-10 md:text-[14px]";
const SMALL_BUTTON =
  "h-11 rounded-md border border-[var(--border)] px-3 text-[13px] font-medium text-[var(--ink)] hover:bg-[var(--hover)] disabled:opacity-60 md:h-8";

type TestState = { status: "running" } | { status: "ok"; message: string } | { status: "error"; message: string };

async function putIntegrations(body: PutIntegrationsBody): Promise<IntegrationsResponse> {
  const res = await fetch("/api/integrations", {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = (await res.json().catch(() => null)) as IntegrationsResponse | ApiError | null;
  if (!res.ok || !data || "error" in data) throw new Error((data && "error" in data && data.error) || `Request failed (${res.status})`);
  return data;
}

/** Readwise token and webhook URL, stored server-side; each target has its own test. */
function IntegrationsPane() {
  const integrations = useIntegrations();
  const id = useId();
  // Drafts: the token field always starts empty (the saved token never reaches the client); the
  // webhook field shows the saved URL until edited (null = untouched).
  const [token, setToken] = useState("");
  const [webhookDraft, setWebhookDraft] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tests, setTests] = useState<Partial<Record<SendTarget, TestState>>>({});

  const savedUrl = integrations?.webhook.url ?? "";
  const webhook = webhookDraft ?? savedUrl;
  const dirty = token.trim() !== "" || webhook.trim() !== savedUrl;

  const apply = (next: IntegrationsResponse) => {
    setIntegrations(next);
    setToken("");
    setWebhookDraft(null);
    setTests({});
  };

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!dirty || saving) return;
    const body: PutIntegrationsBody = {};
    if (token.trim()) body.readwise_token = token.trim();
    if (webhook.trim() !== savedUrl) body.webhook_url = webhook.trim() || null;
    setSaving(true);
    setError(null);
    try {
      apply(await putIntegrations(body));
      setSaved(true);
      setTimeout(() => setSaved(false), 1500);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not save");
    } finally {
      setSaving(false);
    }
  };

  const remove = async (target: SendTarget) => {
    setError(null);
    try {
      apply(await putIntegrations(target === "readwise" ? { readwise_token: null } : { webhook_url: null }));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not remove");
    }
  };

  const test = async (target: SendTarget) => {
    setTests((t) => ({ ...t, [target]: { status: "running" } }));
    let next: TestState;
    try {
      const res = await fetch("/api/integrations/test", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ target }),
      });
      const data = (await res.json().catch(() => null)) as ApiError | null;
      next = res.ok
        ? { status: "ok", message: target === "readwise" ? "Token works" : "Test payload delivered" }
        : { status: "error", message: data?.error || `Request failed (${res.status})` };
    } catch (err) {
      next = { status: "error", message: err instanceof Error ? err.message : "Request failed" };
    }
    setTests((t) => ({ ...t, [target]: next }));
  };

  const actions = (target: SendTarget, testLabel: string) => {
    const t = tests[target];
    return (
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <button type="button" onClick={() => void test(target)} disabled={t?.status === "running"} className={SMALL_BUTTON}>
          {t?.status === "running" ? "Testing…" : testLabel}
        </button>
        <button
          type="button"
          onClick={() => void remove(target)}
          className="h-11 rounded-md px-3 text-[13px] font-medium text-[var(--muted)] hover:bg-[var(--hover)] hover:text-[var(--danger)] md:h-8"
        >
          Remove
        </button>
        {t && t.status !== "running" && (
          <p
            role={t.status === "error" ? "alert" : "status"}
            className={`min-w-0 text-[12.5px] ${t.status === "error" ? "text-[var(--danger)]" : "text-[var(--ok)]"}`}
          >
            {t.message}
          </p>
        )}
      </div>
    );
  };

  const status = (on: boolean, text: string) => (
    <span className={`shrink-0 text-[12px] ${on ? "text-[var(--ok)]" : "text-[var(--faint)]"}`}>{text}</span>
  );

  return (
    <>
      <PaneHeading
        title="Integrations"
        hint="Send an item from the reader to Readwise Reader or your own webhook. Stored on the server, not this device."
      />
      <form onSubmit={save}>
        <section className="border-t border-[var(--hairline)] py-3">
          <div className="flex items-baseline justify-between gap-3">
            <label htmlFor={`${id}-token`} className="text-[14px] text-[var(--ink)]">
              Readwise Reader
            </label>
            {integrations &&
              status(
                integrations.readwise.configured,
                integrations.readwise.configured ? `Token ${integrations.readwise.token_hint}` : "Not set up",
              )}
          </div>
          <p id={`${id}-token-hint`} className="text-[12px] text-[var(--muted)]">
            Access token from{" "}
            <a href="https://readwise.io/access_token" target="_blank" rel="noopener noreferrer" className="text-[var(--accent)] hover:underline">
              readwise.io/access_token
            </a>
            {integrations?.readwise.configured ? ". Paste a new one to replace it." : "."}
          </p>
          <input
            id={`${id}-token`}
            type="password"
            autoComplete="off"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
            aria-describedby={`${id}-token-hint`}
            value={token}
            onChange={(e) => setToken(e.target.value)}
            placeholder={integrations?.readwise.configured ? `Saved (${integrations.readwise.token_hint})` : "Paste your access token"}
            className={INPUT}
          />
          {integrations?.readwise.configured && actions("readwise", "Check token")}
        </section>

        <section className="border-t border-[var(--hairline)] py-3">
          <div className="flex items-baseline justify-between gap-3">
            <label htmlFor={`${id}-webhook`} className="text-[14px] text-[var(--ink)]">
              Webhook
            </label>
            {integrations && status(integrations.webhook.configured, integrations.webhook.configured ? "On" : "Not set up")}
          </div>
          <p id={`${id}-webhook-hint`} className="text-[12px] text-[var(--muted)]">
            Each sent item is POSTed as JSON: id, url, title, author, published_at, summary, source.
          </p>
          <input
            id={`${id}-webhook`}
            type="url"
            inputMode="url"
            autoComplete="off"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
            aria-describedby={`${id}-webhook-hint`}
            value={webhook}
            onChange={(e) => setWebhookDraft(e.target.value)}
            placeholder="https://example.com/hooks/openfeed"
            className={INPUT}
          />
          {integrations?.webhook.configured && actions("webhook", "Send a test")}
        </section>

        <div className="flex items-center justify-end gap-3 border-t border-[var(--hairline)] pt-3">
          {error && (
            <p role="alert" className="mr-auto min-w-0 text-[13px] text-[var(--danger)]">
              {error}
            </p>
          )}
          {saved && (
            <p role="status" className="text-[13px] text-[var(--ok)]">
              Saved
            </p>
          )}
          <button
            type="submit"
            disabled={!dirty || saving}
            className="h-11 rounded-lg bg-[var(--accent)] px-4 text-[14px] font-medium text-white disabled:opacity-50 md:h-9"
          >
            {saving ? "Saving…" : "Save"}
          </button>
        </div>
      </form>
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
  className = "",
  children,
}: {
  label: string;
  hint?: string;
  asLabel?: boolean;
  className?: string;
  children: (id: string, hintId: string | undefined) => React.ReactNode;
}) {
  const id = useId();
  const labelId = `${id}-label`;
  const controlId = `${id}-control`;
  const hintId = hint ? `${id}-hint` : undefined;
  return (
    <li className={`${ROW} min-h-[52px] justify-between ${className}`}>
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
