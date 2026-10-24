"use client";
import type { Filter, Source, View } from "@/lib/types";
import { SourceBadge } from "./badge";
import { ArcIcon, BookmarkIcon, InboxIcon, PlusIcon, SidebarIcon, VideoIcon } from "./icons";

export interface NavState {
  view: View;
  source: number | null;
  filter: Filter | null;
}

function Row({
  active,
  onClick,
  icon,
  label,
}: {
  active: boolean;
  onClick: () => void;
  icon: React.ReactNode;
  label: string;
}) {
  return (
    <li>
      <button
        type="button"
        onClick={onClick}
        aria-current={active ? "page" : undefined}
        className={`flex h-[34px] w-full items-center gap-[10px] rounded-[4px] px-2 text-left text-[14px] text-[var(--ink)] ${
          active ? "bg-[var(--nav-selection)]" : "hover:bg-[var(--nav-hover)]"
        }`}
      >
        <span className="flex w-[22px] shrink-0 justify-center text-[var(--muted)]">{icon}</span>
        <span className="min-w-0 flex-1 truncate">{label}</span>
      </button>
    </li>
  );
}

function Label({ children }: { children: React.ReactNode }) {
  return (
    <h3 className="px-2 pb-1 pt-3.5 text-[11px] font-semibold tracking-[0.01em] text-[var(--faint)]">
      {children}
    </h3>
  );
}

const FILTERS: { id: Filter; label: string }[] = [
  { id: "hn100", label: "HN ≥ 100" },
  { id: "labs", label: "Labs" },
  { id: "blogs", label: "Blogs" },
];

export function Sidebar({
  nav,
  setNav,
  sources,
  onAdd,
  onCollapse,
}: {
  nav: NavState;
  setNav: (n: NavState) => void;
  sources: Source[];
  onAdd: () => void;
  onCollapse?: () => void;
}) {
  const rss = sources.filter((s) => s.kind !== "youtube");
  const yt = sources.filter((s) => s.kind === "youtube");
  const isView = (v: View) => nav.view === v && nav.source == null && nav.filter == null;
  const sourceRow = (s: Source) => (
    <Row
      key={s.id}
      active={nav.source === s.id}
      onClick={() => setNav({ view: "all", source: s.id, filter: null })}
      icon={<SourceBadge host={s.host} title={s.title} size={22} />}
      label={s.title}
    />
  );

  return (
    <nav aria-label="Feeds" className="flex h-full flex-col">
      <div className="mt-2.5 flex h-[54px] shrink-0 items-center gap-2 pl-[18px] pr-2.5">
        <span className="flex h-[22px] w-[22px] items-center justify-center rounded-[6px] bg-(--logo) text-white">
          <ArcIcon size={14} strokeWidth={2.4} />
        </span>
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
        <Label>Views</Label>
        <ul>
          <Row active={isView("all")} onClick={() => setNav({ view: "all", source: null, filter: null })} icon={<InboxIcon size={19} />} label="All" />
          <Row active={isView("saved")} onClick={() => setNav({ view: "saved", source: null, filter: null })} icon={<BookmarkIcon size={19} />} label="Saved" />
          <Row active={isView("video")} onClick={() => setNav({ view: "video", source: null, filter: null })} icon={<VideoIcon size={19} />} label="Video" />
        </ul>
        {rss.length > 0 && (
          <>
            <Label>Sources</Label>
            <ul>{rss.map(sourceRow)}</ul>
          </>
        )}
        {yt.length > 0 && (
          <>
            <Label>YouTube</Label>
            <ul>{yt.map(sourceRow)}</ul>
          </>
        )}
        <Label>Filters</Label>
        <ul>
          {FILTERS.map((f) => (
            <Row
              key={f.id}
              active={nav.filter === f.id}
              onClick={() => setNav({ view: "all", source: null, filter: f.id })}
              icon={<span className="text-[14px]">#</span>}
              label={f.label}
            />
          ))}
        </ul>
      </div>
      <div className="shrink-0 px-2.5 pb-3 pt-1">
        <button
          type="button"
          onClick={onAdd}
          className="flex h-[34px] w-full items-center gap-[10px] rounded-[4px] px-2 text-left text-[13.5px] text-[var(--muted)] hover:bg-[var(--nav-hover)] hover:text-[var(--ink)]"
        >
          <span className="flex w-[22px] shrink-0 justify-center">
            <PlusIcon size={16} />
          </span>
          Add source
        </button>
      </div>
    </nav>
  );
}
