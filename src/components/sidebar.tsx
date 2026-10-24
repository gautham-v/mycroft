"use client";
import type { Filter, Source, View } from "@/lib/types";
import { SourceBadge } from "./badge";
import { ArcIcon, BookmarkIcon, InboxIcon, PlusIcon, VideoIcon } from "./icons";

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
        className={`flex h-9 w-full items-center gap-2.5 rounded-md px-2 text-left text-[14px] ${
          active ? "bg-[var(--surface)] font-medium text-[var(--accent)]" : "text-[var(--body)] hover:bg-[var(--surface)]/70"
        }`}
      >
        <span className="flex w-5 shrink-0 justify-center">{icon}</span>
        <span className="min-w-0 flex-1 truncate">{label}</span>
      </button>
    </li>
  );
}

function Label({ children }: { children: React.ReactNode }) {
  return (
    <h3 className="mb-1 mt-5 px-2 font-mono text-[10.5px] font-medium uppercase tracking-[0.08em] text-[var(--muted)]">
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
}: {
  nav: NavState;
  setNav: (n: NavState) => void;
  sources: Source[];
  onAdd: () => void;
}) {
  const rss = sources.filter((s) => s.kind !== "youtube");
  const yt = sources.filter((s) => s.kind === "youtube");
  const isView = (v: View) => nav.view === v && nav.source == null && nav.filter == null;
  const sourceRow = (s: Source) => (
    <Row
      key={s.id}
      active={nav.source === s.id}
      onClick={() => setNav({ view: "all", source: s.id, filter: null })}
      icon={<SourceBadge host={s.host} title={s.title} size={18} />}
      label={s.title}
    />
  );

  return (
    <nav aria-label="Feeds" className="flex h-full flex-col border-r border-[var(--border)] bg-[var(--ground)]">
      <div className="flex h-14 shrink-0 items-center gap-2 px-4">
        <span className="flex h-7 w-7 items-center justify-center rounded-md bg-[var(--accent)] text-white">
          <ArcIcon size={16} strokeWidth={2.4} />
        </span>
        <span className="text-[16px] font-semibold tracking-[-0.01em] text-[var(--ink)]">Mycroft</span>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto px-2 pb-4">
        <Label>Views</Label>
        <ul>
          <Row active={isView("all")} onClick={() => setNav({ view: "all", source: null, filter: null })} icon={<InboxIcon size={16} />} label="All" />
          <Row active={isView("saved")} onClick={() => setNav({ view: "saved", source: null, filter: null })} icon={<BookmarkIcon size={16} />} label="Saved" />
          <Row active={isView("video")} onClick={() => setNav({ view: "video", source: null, filter: null })} icon={<VideoIcon size={16} />} label="Video" />
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
              icon={<span className="font-mono text-[12px] text-[var(--muted)]">#</span>}
              label={f.label}
            />
          ))}
        </ul>
      </div>
      <div className="shrink-0 border-t border-[var(--hairline)] p-3">
        <button
          type="button"
          onClick={onAdd}
          className="flex h-9 w-full items-center justify-center gap-1.5 rounded-lg border border-[var(--border)] bg-[var(--surface)] text-[13px] font-medium text-[var(--body)] hover:bg-[var(--ground)]"
        >
          <PlusIcon size={15} />
          Add source
        </button>
      </div>
    </nav>
  );
}
