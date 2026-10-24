"use client";
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import type { Filter, Item, Source, View } from "@/lib/types";
import { relativeTime } from "@/lib/time";
import { patchItem, useItems, useSources, useStats } from "@/hooks/use-data";
import { AddSourceDialog } from "./add-source";
import { SourceBadge } from "./badge";
import { BookmarkIcon, InboxIcon, ListIcon, PlusIcon, RefreshIcon, SidebarIcon } from "./icons";
import { ItemRow } from "./item-row";
import { Reader, ReaderEmpty } from "./reader";
import { Sidebar, type NavState } from "./sidebar";

const VIEWS: View[] = ["all", "saved", "video"];
const FILTERS: Filter[] = ["hn100", "labs", "blogs"];

function parseNav(sp: URLSearchParams) {
  const v = sp.get("view") as View | null;
  const f = sp.get("filter") as Filter | null;
  const s = Number(sp.get("source"));
  const i = Number(sp.get("item"));
  return {
    view: v && VIEWS.includes(v) ? v : "all",
    filter: f && FILTERS.includes(f) ? f : null,
    source: Number.isFinite(s) && s > 0 ? s : null,
    item: Number.isFinite(i) && i > 0 ? i : null,
    tab: sp.get("tab") === "sources" ? ("sources" as const) : null,
  };
}

function buildQs(n: NavState & { item?: number | null; tab?: "sources" | null }) {
  const p = new URLSearchParams();
  if (n.view !== "all") p.set("view", n.view);
  if (n.source != null) p.set("source", String(n.source));
  if (n.filter) p.set("filter", n.filter);
  if (n.tab) p.set("tab", n.tab);
  if (n.item != null) p.set("item", String(n.item));
  const s = p.toString();
  return s ? `/?${s}` : "/";
}

type Chip = { id: string; label: string; nav: NavState };
const CHIPS: Chip[] = [
  { id: "all", label: "All", nav: { view: "all", source: null, filter: null } },
  { id: "hn100", label: "HN ≥ 100", nav: { view: "all", source: null, filter: "hn100" } },
  { id: "labs", label: "Labs", nav: { view: "all", source: null, filter: "labs" } },
  { id: "blogs", label: "Blogs", nav: { view: "all", source: null, filter: "blogs" } },
  { id: "video", label: "Video", nav: { view: "video", source: null, filter: null } },
];

// Desktop sidebar collapsed state, persisted in localStorage. A tiny external store so the
// server render (and first client render) uses the default and the saved value applies after hydration.
const SIDEBAR_KEY = "mycroft:sidebar-collapsed";
let sidebarCollapsed: boolean | null = null;
const sidebarListeners = new Set<() => void>();

function getSidebarCollapsed() {
  if (sidebarCollapsed === null) {
    try {
      sidebarCollapsed = window.localStorage.getItem(SIDEBAR_KEY) === "1";
    } catch {
      sidebarCollapsed = false;
    }
  }
  return sidebarCollapsed;
}

function setSidebarCollapsed(v: boolean) {
  sidebarCollapsed = v;
  try {
    window.localStorage.setItem(SIDEBAR_KEY, v ? "1" : "0");
  } catch {
    /* storage unavailable; keep in-memory state */
  }
  sidebarListeners.forEach((l) => l());
}

function subscribeSidebar(l: () => void) {
  sidebarListeners.add(l);
  return () => {
    sidebarListeners.delete(l);
  };
}

function useSidebarCollapsed() {
  return useSyncExternalStore(subscribeSidebar, getSidebarCollapsed, () => false);
}

// Tablet/desktop (md and up): the reader column is always visible, so a default selection makes sense.
const MD_QUERY = "(min-width: 768px)";
function subscribeMd(l: () => void) {
  const mq = window.matchMedia(MD_QUERY);
  mq.addEventListener("change", l);
  return () => mq.removeEventListener("change", l);
}
function useIsMd() {
  return useSyncExternalStore(subscribeMd, () => window.matchMedia(MD_QUERY).matches, () => false);
}

function useNow(intervalMs = 30_000) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(t);
  }, [intervalMs]);
  return now;
}

export function MycroftApp() {
  const router = useRouter();
  const pathname = usePathname();
  const sp = useSearchParams();
  const parsed = useMemo(() => parseNav(new URLSearchParams(sp.toString())), [sp]);
  const nav: NavState = useMemo(
    () => ({ view: parsed.view, source: parsed.source, filter: parsed.filter }),
    [parsed.view, parsed.source, parsed.filter],
  );
  const tab = parsed.tab;
  const isMd = useIsMd();

  const { items, nextCursor, loading, loadingMore, error, reload, loadMore, patchLocal } = useItems(nav);
  const { sources, reload: reloadSources } = useSources();
  const { stats, reload: reloadStats } = useStats();
  const [refreshing, setRefreshing] = useState(false);
  const [addOpen, setAddOpen] = useState(false);
  const [extraItem, setExtraItem] = useState<Item | null>(null);
  const now = useNow();
  const sidebarCollapsed = useSidebarCollapsed();
  // With no ?item in the URL, tablet/desktop shows the first item instead of an empty reader.
  // The URL is left alone so the list keeps its "nothing opened" state on phones and in history.
  const selectedId = parsed.item ?? (isMd && tab !== "sources" && items[0] ? items[0].id : null);
  // Full-screen reader (desktop): hides sidebar and list while an item is open. Session-only.
  const [focus, setFocus] = useState(false);
  const focused = focus && selectedId != null;

  // Cmd/Ctrl+\ toggles the desktop sidebar; Shift+Cmd/Ctrl+F toggles the full-screen reader; Esc exits it.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && e.key === "\\") {
        e.preventDefault();
        setSidebarCollapsed(!getSidebarCollapsed());
      } else if ((e.metaKey || e.ctrlKey) && e.shiftKey && !e.altKey && e.key.toLowerCase() === "f") {
        e.preventDefault();
        setFocus((v) => !v);
      } else if (e.key === "Escape") {
        setFocus(false);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const go = useCallback(
    (n: NavState & { item?: number | null; tab?: "sources" | null }, replace = false) => {
      const url = buildQs(n);
      if (replace) router.replace(url, { scroll: false });
      else router.push(url, { scroll: false });
    },
    [router],
  );
  const setNav = useCallback((n: NavState) => go({ ...n, item: null, tab: null }), [go]);

  // --- refresh ---------------------------------------------------------------
  const reloadAll = useCallback(async () => {
    await Promise.all([reload(), reloadStats(), reloadSources()]);
  }, [reload, reloadStats, reloadSources]);

  const runRefresh = useCallback(
    async (force: boolean) => {
      setRefreshing(true);
      try {
        const r = await fetch(`/api/refresh${force ? "?force=1" : ""}`, { cache: "no-store" });
        const body = (await r.json().catch(() => null)) as { ran?: boolean } | null;
        if (force || body?.ran !== false) await reloadAll();
        else await reloadStats();
      } catch {
        /* offline */
      } finally {
        setRefreshing(false);
      }
    },
    [reloadAll, reloadStats],
  );

  const runRefreshRef = useRef(runRefresh);
  useEffect(() => {
    runRefreshRef.current = runRefresh;
  }, [runRefresh]);
  useEffect(() => {
    void runRefreshRef.current(false);
    const onVis = () => {
      if (document.visibilityState === "visible") void runRefreshRef.current(false);
    };
    document.addEventListener("visibilitychange", onVis);
    return () => document.removeEventListener("visibilitychange", onVis);
  }, []);

  // --- selection --------------------------------------------------------------
  const selected = useMemo(() => {
    if (selectedId == null) return null;
    return items.find((i) => i.id === selectedId) ?? (extraItem?.id === selectedId ? extraItem : null);
  }, [items, selectedId, extraItem]);

  // Deep link to an item that isn't in the current page: try GET /api/items/:id.
  useEffect(() => {
    if (selectedId == null || loading || items.some((i) => i.id === selectedId) || extraItem?.id === selectedId) return;
    let cancelled = false;
    fetch(`/api/items/${selectedId}`)
      .then((r) => (r.ok ? (r.json() as Promise<Item | { item: Item }>) : null))
      .then((d) => {
        if (!cancelled && d) setExtraItem("item" in d ? d.item : d);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [selectedId, loading, items, extraItem]);

  const updateItem = useCallback(
    (item: Item, patch: Partial<Item>) => {
      patchLocal(item.id, patch);
      setExtraItem((e) => (e && e.id === item.id ? { ...e, ...patch } : e));
    },
    [patchLocal],
  );

  const toggleSaved = useCallback(
    (item: Item) => {
      const saved = !item.is_saved;
      updateItem(item, { is_saved: saved });
      void patchItem(item.id, { is_saved: saved }).catch(() => updateItem(item, { is_saved: !saved }));
    },
    [updateItem],
  );

  const openItem = useCallback(
    (item: Item) => {
      go({ ...nav, item: item.id, tab: null }, selectedId != null && window.matchMedia("(min-width: 768px)").matches);
    },
    [go, nav, selectedId],
  );

  const closeItem = useCallback(() => {
    if (window.history.length > 1 && document.referrer.startsWith(window.location.origin)) router.back();
    else go({ ...nav, item: null });
  }, [router, go, nav]);

  // --- infinite scroll ---------------------------------------------------------
  const sentinel = useRef<HTMLLIElement>(null);
  useEffect(() => {
    const el = sentinel.current;
    if (!el || !nextCursor) return;
    const io = new IntersectionObserver((entries) => entries[0]?.isIntersecting && void loadMore(), { rootMargin: "600px" });
    io.observe(el);
    return () => io.disconnect();
  }, [nextCursor, loadMore, items.length]);

  // --- labels -----------------------------------------------------------------
  const activeSource = nav.source != null ? sources.find((s) => s.id === nav.source) : null;
  const listTitle = activeSource
    ? activeSource.title
    : nav.view === "saved"
      ? "Saved"
      : nav.view === "video"
        ? "Video"
        : nav.filter === "hn100"
          ? "HN ≥ 100"
          : nav.filter === "labs"
            ? "Labs"
            : nav.filter === "blogs"
              ? "Blogs"
              : "All";
  const phoneTitle = tab === "sources" ? "Sources" : nav.view === "saved" ? "Saved" : activeSource ? activeSource.title : "All";
  const subline = `updated ${
    stats?.lastRefreshAt ? (relativeTime(stats.lastRefreshAt, now) === "now" ? "just now" : `${relativeTime(stats.lastRefreshAt, now)} ago`) : "never"
  }`;
  const activeChip =
    nav.source != null ? null : nav.view === "video" ? "video" : nav.view === "saved" ? null : (nav.filter ?? "all");

  const refreshButton = (
    <button
      type="button"
      onClick={() => void runRefresh(true)}
      disabled={refreshing}
      aria-label={refreshing ? "Refreshing" : "Refresh feeds"}
      className="inline-flex h-11 w-11 items-center justify-center rounded-lg text-[var(--ink)] hover:bg-[var(--hover)] disabled:opacity-70 lg:h-[30px] lg:w-[30px] lg:text-[var(--muted)] lg:hover:text-[var(--ink)]"
    >
      <RefreshIcon size={20} className={`lg:size-[17px] ${refreshing ? "animate-spin" : ""}`} />
    </button>
  );

  const chips = (
    <div className="no-scrollbar flex gap-2 overflow-x-auto px-4 pb-3" role="toolbar" aria-label="Filters">
      {CHIPS.map((c) => {
        const active = activeChip === c.id;
        return (
          <button
            key={c.id}
            type="button"
            aria-pressed={active}
            onClick={() => setNav(c.nav)}
            className={`h-8 shrink-0 rounded-full px-3.5 text-[13px] font-medium ${
              active ? "bg-[var(--ink)] text-[var(--surface)]" : "bg-[var(--code)] text-[var(--ink)]"
            }`}
          >
            {c.label}
          </button>
        );
      })}
    </div>
  );

  const list = (
    <ul aria-label={listTitle} aria-busy={loading} className="px-2 pb-2">
      {loading && items.length === 0 && <ListSkeleton />}
      {!loading && error && items.length === 0 && (
        <li className="px-6 py-16 text-center text-[14px] text-[var(--muted)]">
          Could not load items.
          <button type="button" onClick={() => void reload()} className="ml-1 font-medium text-[var(--accent)] underline">
            Retry
          </button>
        </li>
      )}
      {!loading && !error && items.length === 0 && (
        <li className="px-6 py-16 text-center">
          <p className="text-[15px] font-medium text-[var(--ink)]">{nav.view === "saved" ? "Nothing saved yet" : "Nothing here yet"}</p>
          <p className="mt-1 text-[13px] text-[var(--muted)]">No items in this view</p>
        </li>
      )}
      {items.map((item) => (
        <ItemRow key={item.id} item={item} selected={item.id === selectedId} onOpen={openItem} />
      ))}
      {nextCursor && (
        <li ref={sentinel} className="py-6 text-center text-[13px] text-[var(--muted)]">
          {loadingMore ? "Loading..." : ""}
        </li>
      )}
    </ul>
  );

  const reader = selected ? (
    <Reader
      key={selected.id}
      item={selected}
      onBack={closeItem}
      onToggleSaved={toggleSaved}
      showBack
      focused={focused}
      onToggleFocus={() => setFocus((v) => !v)}
    />
  ) : selectedId != null ? (
    <div className="h-full bg-[var(--surface)]" aria-busy="true" />
  ) : (
    <ReaderEmpty />
  );

  const phoneSources = (
    <SourcesList
      sources={sources}
      onPick={(s) => setNav({ view: "all", source: s.id, filter: null })}
      onAdd={() => setAddOpen(true)}
    />
  );

  return (
    <div className="flex h-dvh w-full overflow-hidden bg-[var(--ground)]">
      {/* Sidebar (desktop) */}
      <aside id="sidebar" className={`hidden w-[230px] shrink-0 ${sidebarCollapsed || focused ? "" : "lg:block"}`}>
        <Sidebar nav={nav} setNav={setNav} sources={sources} onAdd={() => setAddOpen(true)} onCollapse={() => setSidebarCollapsed(true)} />
      </aside>

      {/* List column */}
      <section
        aria-label="Items"
        className={`relative flex min-w-0 flex-col bg-[var(--surface)] md:w-[380px] md:shrink-0 md:border-r md:border-[var(--hairline)] lg:my-2.5 lg:w-[410px] lg:overflow-hidden lg:rounded-[6px] lg:border-r-0 ${
          sidebarCollapsed ? "lg:ml-2.5" : ""
        } ${selectedId != null ? (focused ? "hidden md:flex lg:hidden" : "hidden md:flex") : "flex flex-1 md:flex-none"}`}
      >
        {/* Phone/tablet header */}
        <header className="shrink-0 pt-[env(safe-area-inset-top)] lg:hidden">
          <div className="flex items-center justify-between gap-2 pl-4 pr-2 pt-3">
            <div className="min-w-0">
              <h1 className="truncate text-[28px] font-bold leading-tight tracking-[-0.02em] text-[var(--ink)]">{phoneTitle}</h1>
              <p className="mt-0.5 text-[12px] text-[var(--muted)]">{subline}</p>
            </div>
            {refreshButton}
          </div>
          <div className="pt-3">{tab !== "sources" && chips}</div>
        </header>

        {/* Desktop header */}
        <header className={`hidden h-[54px] shrink-0 items-center gap-2 pr-3 lg:flex ${sidebarCollapsed ? "pl-3" : "pl-[18px]"}`}>
          {sidebarCollapsed && (
            <button
              type="button"
              onClick={() => setSidebarCollapsed(false)}
              aria-label="Show sidebar"
              aria-controls="sidebar"
              aria-expanded={false}
              title="Show sidebar (⌘\\)"
              className="inline-flex h-[30px] w-[30px] shrink-0 items-center justify-center rounded-lg text-[var(--muted)] hover:bg-[var(--hover)] hover:text-[var(--ink)]"
            >
              <SidebarIcon size={17} />
            </button>
          )}
          <div className="flex min-w-0 flex-1 items-baseline gap-2">
            <h1 className="truncate text-[15px] font-semibold tracking-[-0.01em] text-[var(--ink)]">{listTitle}</h1>
            <p className="truncate text-[13px] text-[var(--muted)]">{subline}</p>
          </div>
          {refreshButton}
        </header>

        <div className="panel-scroll min-h-0 flex-1 overflow-y-auto overscroll-contain pb-[calc(56px+env(safe-area-inset-bottom))] md:pb-0">
          {tab === "sources" ? phoneSources : list}
        </div>

        {/* Bottom tab bar (phone only) */}
        <nav
          aria-label="Primary"
          className="fixed inset-x-0 bottom-0 z-20 border-t border-[var(--hairline)] bg-[var(--surface)]/95 pb-[env(safe-area-inset-bottom)] backdrop-blur md:hidden"
        >
          <ul className="grid grid-cols-3">
            <TabButton
              label="Feed"
              active={tab == null && nav.view !== "saved"}
              icon={<InboxIcon size={20} />}
              onClick={() => setNav({ view: "all", source: null, filter: null })}
            />
            <TabButton
              label="Saved"
              active={tab == null && nav.view === "saved"}
              icon={<BookmarkIcon size={20} />}
              onClick={() => setNav({ view: "saved", source: null, filter: null })}
            />
            <TabButton
              label="Sources"
              active={tab === "sources"}
              icon={<ListIcon size={20} />}
              onClick={() => go({ ...nav, item: null, tab: "sources" })}
            />
          </ul>
        </nav>
      </section>

      {/* Reader */}
      <main
        className={`panel-scroll min-w-0 flex-1 overflow-y-auto bg-[var(--surface)] ${focused ? "" : "lg:m-2.5 lg:rounded-[6px]"} ${selectedId != null ? "block" : "hidden md:block"}`}
        aria-label="Reader"
        data-path={pathname}
      >
        {reader}
      </main>

      <AddSourceDialog
        open={addOpen}
        onClose={() => setAddOpen(false)}
        onAdded={() => {
          void reloadSources();
          void runRefresh(true);
        }}
      />
    </div>
  );
}

function TabButton({ label, active, icon, onClick }: { label: string; active: boolean; icon: React.ReactNode; onClick: () => void }) {
  return (
    <li>
      <button
        type="button"
        onClick={onClick}
        aria-current={active ? "page" : undefined}
        className={`flex min-h-[52px] w-full flex-col items-center justify-center gap-0.5 text-[11px] font-medium ${
          active ? "text-[var(--accent)]" : "text-[var(--muted)]"
        }`}
      >
        {icon}
        {label}
      </button>
    </li>
  );
}

function SourcesList({ sources, onPick, onAdd }: { sources: Source[]; onPick: (s: Source) => void; onAdd: () => void }) {
  const groups: [string, Source[]][] = [
    ["Sources", sources.filter((s) => s.kind !== "youtube")],
    ["YouTube", sources.filter((s) => s.kind === "youtube")],
  ];
  return (
    <div className="pb-6">
      {groups.map(([label, list]) =>
        list.length ? (
          <section key={label}>
            <h2 className="px-4 pb-1 pt-4 text-[13px] font-semibold text-[var(--muted)]">{label}</h2>
            <ul>
              {list.map((s) => (
                <li key={s.id}>
                  <button
                    type="button"
                    onClick={() => onPick(s)}
                    className="flex min-h-[52px] w-full items-center gap-3 border-b border-[var(--hairline)] px-4 text-left"
                  >
                    <SourceBadge host={s.host} title={s.title} size={28} />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[15px] font-medium text-[var(--ink)]">{s.title}</span>
                      {s.last_error && <span className="block truncate text-[12px] text-[var(--danger)]">Error: {s.last_error}</span>}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          </section>
        ) : null,
      )}
      <div className="px-4 pt-5">
        <button
          type="button"
          onClick={onAdd}
          className="flex h-11 w-full items-center justify-center gap-1.5 rounded-lg bg-[var(--code)] text-[14px] font-medium text-[var(--accent)]"
        >
          <PlusIcon size={16} />
          Add source
        </button>
      </div>
    </div>
  );
}

function ListSkeleton() {
  return (
    <>
      {Array.from({ length: 8 }).map((_, i) => (
        <li key={i} className="item-row flex gap-3 px-2.5 py-[11px]">
          <span className="mt-px h-6 w-6 shrink-0 animate-pulse rounded-[7px] bg-[var(--code)]" />
          <span className="flex-1 space-y-2">
            <span className="block h-4 w-[85%] animate-pulse rounded bg-[var(--code)]" />
            <span className="block h-3 w-[40%] animate-pulse rounded bg-[var(--code)]" />
          </span>
        </li>
      ))}
    </>
  );
}
