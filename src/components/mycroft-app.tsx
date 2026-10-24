"use client";
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import type { Filter, Item, Source, View } from "@/lib/types";
import { relativeTime } from "@/lib/time";
import { patchItem, useItems, useSources, useStats } from "@/hooks/use-data";
import { AddSourceDialog } from "./add-source";
import { SourceBadge } from "./badge";
import { BookmarkIcon, CheckIcon, InboxIcon, ListIcon, PlusIcon, RefreshIcon, SidebarIcon } from "./icons";
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
  const selectedId = parsed.item;
  const tab = parsed.tab;

  const { items, setItems, nextCursor, loading, loadingMore, error, reload, loadMore, patchLocal } = useItems(nav);
  const { sources, reload: reloadSources } = useSources();
  const { stats, setStats, reload: reloadStats } = useStats();
  const [refreshing, setRefreshing] = useState(false);
  const [addOpen, setAddOpen] = useState(false);
  const [extraItem, setExtraItem] = useState<Item | null>(null);
  const now = useNow();
  const sidebarCollapsed = useSidebarCollapsed();

  // Cmd/Ctrl+\ toggles the desktop sidebar.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && e.key === "\\") {
        e.preventDefault();
        setSidebarCollapsed(!getSidebarCollapsed());
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

  const adjustUnread = useCallback(
    (delta: number) => setStats((s) => (s ? { ...s, unread: Math.max(0, s.unread + delta) } : s)),
    [setStats],
  );

  const updateItem = useCallback(
    (item: Item, patch: Partial<Item>) => {
      patchLocal(item.id, patch);
      setExtraItem((e) => (e && e.id === item.id ? { ...e, ...patch } : e));
    },
    [patchLocal],
  );

  const setRead = useCallback(
    (item: Item, read: boolean) => {
      if (item.is_read === read) return;
      updateItem(item, { is_read: read });
      adjustUnread(read ? -1 : 1);
      void patchItem(item.id, { is_read: read }).catch(() => {
        updateItem(item, { is_read: !read });
        adjustUnread(read ? 1 : -1);
      });
    },
    [updateItem, adjustUnread],
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
      setRead(item, true);
      go({ ...nav, item: item.id, tab: null }, selectedId != null && window.matchMedia("(min-width: 768px)").matches);
    },
    [go, nav, selectedId, setRead],
  );

  const closeItem = useCallback(() => {
    if (window.history.length > 1 && document.referrer.startsWith(window.location.origin)) router.back();
    else go({ ...nav, item: null });
  }, [router, go, nav]);

  const markAllRead = useCallback(async () => {
    const unread = items.filter((i) => !i.is_read);
    setItems((prev) => prev.map((i) => ({ ...i, is_read: true })));
    try {
      await fetch("/api/items/mark-read", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          all: true,
          view: nav.view,
          ...(nav.source != null ? { source: nav.source } : {}),
          ...(nav.filter ? { filter: nav.filter } : {}),
        }),
      });
    } catch {
      /* offline */
    }
    if (unread.length) void reloadStats();
  }, [items, setItems, nav, reloadStats]);

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
              : "Feed";
  const phoneTitle = tab === "sources" ? "Sources" : nav.view === "saved" ? "Saved" : activeSource ? activeSource.title : "Feed";
  const subline = `${stats?.unread ?? 0} unread · updated ${
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
      className="inline-flex h-11 w-11 items-center justify-center rounded-lg text-[var(--ink)] hover:bg-[var(--surface)] disabled:opacity-70"
    >
      <RefreshIcon size={20} className={refreshing ? "animate-spin" : ""} />
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
            className={`h-8 shrink-0 rounded-full border px-3.5 text-[13px] font-medium ${
              active
                ? "border-[var(--ink)] bg-[var(--ink)] text-white"
                : "border-[var(--border)] bg-[var(--surface)] text-[var(--body)]"
            }`}
          >
            {c.label}
          </button>
        );
      })}
    </div>
  );

  const list = (
    <ul aria-label={listTitle} aria-busy={loading}>
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
          <p className="text-[15px] font-medium text-[var(--ink)]">{nav.view === "saved" ? "Nothing saved yet" : "All caught up"}</p>
          <p className="mt-1 font-mono text-[12px] text-[var(--muted)]">No items in this view</p>
        </li>
      )}
      {items.map((item) => (
        <ItemRow key={item.id} item={item} selected={item.id === selectedId} onOpen={openItem} />
      ))}
      {nextCursor && (
        <li ref={sentinel} className="py-6 text-center font-mono text-[12px] text-[var(--muted)]">
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
      onToggleRead={(i) => setRead(i, !i.is_read)}
      showBack
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
      <aside id="sidebar" className={`hidden w-[240px] shrink-0 ${sidebarCollapsed ? "" : "lg:block"}`}>
        <Sidebar nav={nav} setNav={setNav} sources={sources} onAdd={() => setAddOpen(true)} />
      </aside>

      {/* List column */}
      <section
        aria-label="Items"
        className={`relative flex min-w-0 flex-col border-[var(--border)] md:w-[380px] md:shrink-0 md:border-r lg:w-[420px] ${
          selectedId != null ? "hidden md:flex" : "flex flex-1 md:flex-none"
        }`}
      >
        {/* Phone/tablet header */}
        <header className="shrink-0 pt-[env(safe-area-inset-top)] lg:hidden">
          <div className="flex items-center justify-between gap-2 pl-4 pr-2 pt-3">
            <div className="min-w-0">
              <h1 className="truncate text-[28px] font-semibold leading-tight tracking-[-0.02em] text-[var(--ink)]">{phoneTitle}</h1>
              <p className="mt-0.5 font-mono text-[12px] text-[var(--muted)]">{subline}</p>
            </div>
            {refreshButton}
          </div>
          <div className="pt-3">{tab !== "sources" && chips}</div>
        </header>

        {/* Desktop header */}
        <header className="hidden h-14 shrink-0 items-center gap-1 border-b border-[var(--hairline)] pl-2 pr-2 lg:flex">
          <button
            type="button"
            onClick={() => setSidebarCollapsed(!sidebarCollapsed)}
            aria-label={sidebarCollapsed ? "Show sidebar" : "Hide sidebar"}
            aria-controls="sidebar"
            aria-expanded={!sidebarCollapsed}
            title={`${sidebarCollapsed ? "Show sidebar" : "Hide sidebar"} (⌘\\)`}
            className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-[var(--body)] hover:bg-[var(--surface)]"
          >
            <SidebarIcon size={18} />
          </button>
          <div className="min-w-0 flex-1">
            <h1 className="truncate text-[16px] font-semibold text-[var(--ink)]">{listTitle}</h1>
            <p className="font-mono text-[11px] text-[var(--muted)]">{subline}</p>
          </div>
          <div className="flex items-center">
            <button
              type="button"
              onClick={() => void markAllRead()}
              aria-label="Mark all read"
              title="Mark all read"
              className="inline-flex h-11 w-11 items-center justify-center rounded-lg text-[var(--body)] hover:bg-[var(--surface)]"
            >
              <CheckIcon size={18} />
            </button>
            {refreshButton}
          </div>
        </header>

        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain pb-[calc(56px+env(safe-area-inset-bottom))] md:pb-0">
          {tab === "sources" ? phoneSources : list}
        </div>

        {/* Bottom tab bar (phone only) */}
        <nav
          aria-label="Primary"
          className="fixed inset-x-0 bottom-0 z-20 border-t border-[var(--border)] bg-[var(--surface)]/95 pb-[env(safe-area-inset-bottom)] backdrop-blur md:hidden"
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
        className={`min-w-0 flex-1 overflow-y-auto bg-[var(--surface)] ${selectedId != null ? "block" : "hidden md:block"}`}
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
            <h2 className="px-4 pb-1 pt-4 font-mono text-[10.5px] font-medium uppercase tracking-[0.08em] text-[var(--muted)]">{label}</h2>
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
                      {s.last_error && <span className="block truncate font-mono text-[11px] text-[var(--danger)]">Error: {s.last_error}</span>}
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
          className="flex h-11 w-full items-center justify-center gap-1.5 rounded-lg border border-[var(--border)] bg-[var(--surface)] text-[14px] font-medium text-[var(--body)]"
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
        <li key={i} className="flex gap-3 border-b border-[var(--hairline)] px-4 py-3.5">
          <span className="mt-1 h-8 w-8 shrink-0 animate-pulse rounded-lg bg-[var(--code)]" />
          <span className="flex-1 space-y-2">
            <span className="block h-4 w-[85%] animate-pulse rounded bg-[var(--code)]" />
            <span className="block h-3 w-[40%] animate-pulse rounded bg-[var(--code)]" />
          </span>
        </li>
      ))}
    </>
  );
}
