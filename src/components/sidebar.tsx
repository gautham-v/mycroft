"use client";
import { useSyncExternalStore } from "react";
import type { Filter, Source, View } from "@/lib/types";
import { ArcIcon, BookmarkIcon, ChevronIcon, GearIcon, InboxIcon, PlusIcon, SidebarIcon, VideoIcon } from "./icons";

export interface NavState {
  view: View;
  source: number | null;
  filter: Filter | null;
}

const ROW = "flex h-[32px] w-full items-center gap-[10px] rounded-[4px] px-2 text-left text-[14px]";

function Row({
  active,
  onClick,
  icon,
  label,
}: {
  active: boolean;
  onClick: () => void;
  icon?: React.ReactNode;
  label: string;
}) {
  return (
    <li>
      <button
        type="button"
        onClick={onClick}
        aria-current={active ? "page" : undefined}
        className={`${ROW} text-[var(--ink)] ${active ? "bg-[var(--nav-selection)]" : "hover:bg-[var(--nav-hover)]"}`}
      >
        {icon && <span className="flex w-[20px] shrink-0 justify-center text-[var(--muted)]">{icon}</span>}
        <span className="min-w-0 flex-1 truncate">{label}</span>
      </button>
    </li>
  );
}

function FooterRow({ onClick, icon, label }: { onClick: () => void; icon: React.ReactNode; label: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`${ROW} text-[13.5px] text-[var(--muted)] hover:bg-[var(--nav-hover)] hover:text-[var(--ink)]`}
    >
      <span className="flex w-[20px] shrink-0 justify-center">{icon}</span>
      {label}
    </button>
  );
}

const STORE = "mycroft.sidebar.collapsed";

let cached: Set<string> | null = null;
let cachedRaw: string | null = null;
const listeners = new Set<() => void>();
const EMPTY = new Set<string>();

function read(): Set<string> {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(STORE);
  } catch {}
  if (cached && raw === cachedRaw) return cached;
  cachedRaw = raw;
  cached = new Set(raw ? (JSON.parse(raw) as string[]) : []);
  return cached;
}

function useCollapsed(): [Set<string>, (id: string) => void] {
  const set = useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    read,
    () => EMPTY,
  );
  const toggle = (id: string) => {
    const next = new Set(set);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    try {
      localStorage.setItem(STORE, JSON.stringify([...next]));
    } catch {}
    cached = next;
    cachedRaw = JSON.stringify([...next]);
    listeners.forEach((l) => l());
  };
  return [set, toggle];
}

function Section({
  id,
  title,
  count,
  open,
  onToggle,
  children,
}: {
  id: string;
  title: string;
  count: number;
  open: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  return (
    <div className="pt-3">
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={open}
        aria-controls={`sidebar-${id}`}
        className="group flex h-[26px] w-full items-center gap-1 rounded-[4px] px-2 text-left text-[11px] font-semibold tracking-[0.01em] text-[var(--faint)] hover:text-[var(--muted)]"
      >
        <span className="min-w-0 flex-1 truncate">{title}</span>
        {!open && <span className="tabular-nums">{count}</span>}
        <ChevronIcon
          size={12}
          strokeWidth={2.2}
          className={`shrink-0 transition-transform ${open ? "rotate-90" : ""}`}
        />
      </button>
      <ul id={`sidebar-${id}`} hidden={!open}>
        {children}
      </ul>
    </div>
  );
}

export function Sidebar({
  nav,
  setNav,
  sources,
  onAdd,
  onSettings,
  onCollapse,
}: {
  nav: NavState;
  setNav: (n: NavState) => void;
  sources: Source[];
  onAdd: () => void;
  onSettings: () => void;
  onCollapse?: () => void;
}) {
  const [collapsed, toggle] = useCollapsed();
  const groups: [string, string, Source[]][] = [
    ["sources", "Sources", sources.filter((s) => s.kind !== "youtube")],
    ["youtube", "YouTube", sources.filter((s) => s.kind === "youtube")],
  ];
  const isView = (v: View) => nav.view === v && nav.source == null && nav.filter == null;

  return (
    <nav aria-label="Feeds" className="flex h-full flex-col">
      <div className="mt-2.5 flex h-[54px] shrink-0 items-center gap-2 pl-[18px] pr-2.5">
        <ArcIcon size={20} strokeWidth={2.6} className="shrink-0 text-(--logo)" />
        <span className="min-w-0 flex-1 truncate font-serif text-[17px] font-semibold tracking-[-0.01em] text-[var(--ink)]">Mycroft</span>
        {onCollapse && (
          <button
            type="button"
            onClick={onCollapse}
            aria-label="Hide sidebar"
            aria-controls="sidebar"
            aria-expanded="true"
            title="Hide sidebar (⌘\\)"
            className="inline-flex h-[30px] w-[30px] shrink-0 items-center justify-center rounded-lg text-[var(--muted)] hover:bg-[var(--nav-hover)] hover:text-[var(--ink)]"
          >
            <SidebarIcon size={17} />
          </button>
        )}
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto px-2.5 pb-4">
        <ul className="pt-1">
          <Row active={isView("all")} onClick={() => setNav({ view: "all", source: null, filter: null })} icon={<InboxIcon size={18} />} label="All" />
          <Row active={isView("saved")} onClick={() => setNav({ view: "saved", source: null, filter: null })} icon={<BookmarkIcon size={18} />} label="Saved" />
          <Row active={isView("video")} onClick={() => setNav({ view: "video", source: null, filter: null })} icon={<VideoIcon size={18} />} label="Video" />
        </ul>
        {groups.map(([id, title, list]) =>
          list.length > 0 ? (
            <Section key={id} id={id} title={title} count={list.length} open={!collapsed.has(id)} onToggle={() => toggle(id)}>
              {list.map((s) => (
                <Row
                  key={s.id}
                  active={nav.source === s.id}
                  onClick={() => setNav({ view: "all", source: s.id, filter: null })}
                  label={s.title}
                />
              ))}
            </Section>
          ) : null,
        )}
      </div>
      <div className="shrink-0 px-2.5 pb-3 pt-1">
        <FooterRow onClick={onAdd} icon={<PlusIcon size={16} />} label="Add source" />
        <FooterRow onClick={onSettings} icon={<GearIcon size={16} />} label="Settings" />
      </div>
    </nav>
  );
}
