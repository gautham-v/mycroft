"use client";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { Filter, Folder, Source, View } from "@/lib/types";
import { createFolder, deleteFolder, moveSource, renameFolder, reorderFolders, reorderSources } from "@/hooks/use-data";
import {
  ArcIcon,
  ArticleIcon,
  BookmarkIcon,
  ChevronIcon,
  GearIcon,
  HeadphonesIcon,
  InboxIcon,
  MoreIcon,
  PlusIcon,
  PostIcon,
  SidebarIcon,
  VideoIcon,
} from "./icons";

export interface NavState {
  view: View;
  source: number | null;
  /** Feed filtered to one sidebar folder. */
  folder: number | null;
  filter: Filter | null;
}

export const HOME: NavState = { view: "all", source: null, folder: null, filter: null };

const ROW = "flex h-[32px] w-full items-center gap-[10px] rounded-[4px] px-2 text-left text-[14px]";
const ICON_BTN = "inline-flex h-[22px] w-[22px] shrink-0 items-center justify-center rounded-[4px] text-[var(--faint)] hover:bg-[var(--nav-selection)] hover:text-[var(--ink)]";

// --- collapsed folders (per device) -------------------------------------------------------

const STORE = "openfeed.sidebar.collapsed";

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

// --- small pieces -------------------------------------------------------------------------

function ViewRow({ active, onClick, icon, label }: { active: boolean; onClick: () => void; icon: React.ReactNode; label: string }) {
  return (
    <li>
      <button
        type="button"
        onClick={onClick}
        aria-current={active ? "page" : undefined}
        className={`${ROW} text-[var(--ink)] ${active ? "bg-[var(--nav-selection)]" : "hover:bg-[var(--nav-hover)]"}`}
      >
        <span className="flex w-[20px] shrink-0 justify-center text-[var(--muted)]">{icon}</span>
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
      className={`${ROW} min-w-0 flex-1 text-[13.5px] text-[var(--muted)] hover:bg-[var(--nav-hover)] hover:text-[var(--ink)]`}
    >
      <span className="flex w-[20px] shrink-0 justify-center">{icon}</span>
      {label}
    </button>
  );
}

/** One-line text field used for renaming a folder or naming a new one. Enter commits, Escape cancels. */
function InlineInput({
  initial,
  placeholder,
  onCommit,
  onCancel,
  className,
}: {
  initial: string;
  placeholder: string;
  onCommit: (v: string) => void;
  onCancel: () => void;
  className?: string;
}) {
  const [v, setV] = useState(initial);
  const done = useRef(false);
  const commit = () => {
    if (done.current) return;
    done.current = true;
    const t = v.trim();
    if (t && t !== initial) onCommit(t);
    else onCancel();
  };
  return (
    <input
      autoFocus
      value={v}
      placeholder={placeholder}
      aria-label={placeholder}
      onChange={(e) => setV(e.target.value)}
      onBlur={commit}
      onKeyDown={(e) => {
        if (e.key === "Enter") commit();
        else if (e.key === "Escape") {
          done.current = true;
          onCancel();
        }
        e.stopPropagation();
      }}
      className={`h-[24px] w-full min-w-0 rounded-[4px] border border-[var(--accent)] bg-[var(--surface)] px-1.5 text-[13px] text-[var(--ink)] outline-none ${className ?? ""}`}
    />
  );
}

type MenuItem = { label: string; onSelect: () => void; checked?: boolean; danger?: boolean } | "sep";

/** Context menu anchored below its trigger. Closes on outside click or Escape. */
function Menu({ items, onClose, label }: { items: MenuItem[]; onClose: () => void; label: string }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const onDown = (e: PointerEvent) => {
      if (!ref.current?.contains(e.target as Node)) onClose();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      }
    };
    document.addEventListener("pointerdown", onDown, true);
    document.addEventListener("keydown", onKey, true);
    ref.current?.querySelector<HTMLButtonElement>("button")?.focus();
    return () => {
      document.removeEventListener("pointerdown", onDown, true);
      document.removeEventListener("keydown", onKey, true);
    };
  }, [onClose]);
  return (
    <div
      ref={ref}
      role="menu"
      aria-label={label}
      className="absolute right-2 top-full z-30 mt-0.5 min-w-[180px] rounded-lg border border-[var(--hairline)] bg-[var(--surface)] p-1 text-[13px] shadow-xl"
    >
      {items.map((it, i) =>
        it === "sep" ? (
          <hr key={i} className="my-1 border-0 border-t border-[var(--hairline)]" />
        ) : (
          <button
            key={i}
            type="button"
            role="menuitem"
            onClick={() => {
              onClose();
              it.onSelect();
            }}
            className={`flex h-[28px] w-full items-center gap-2 rounded-[5px] px-2 text-left hover:bg-[var(--hover)] ${
              it.danger ? "text-[var(--danger)]" : "text-[var(--ink)]"
            }`}
          >
            <span className="min-w-0 flex-1 truncate">{it.label}</span>
            {it.checked && <span aria-label="current" className="text-[var(--muted)]">✓</span>}
          </button>
        ),
      )}
    </div>
  );
}

// --- drag model ---------------------------------------------------------------------------

type Drag = { kind: "source"; id: number } | { kind: "folder"; id: number };
/** Where a drop would land: before a source row, at the end of a folder, or before a folder header. */
type Over = { kind: "row"; id: number } | { kind: "end"; folder: number | null } | { kind: "folder"; id: number };

const sameOver = (a: Over | null, b: Over | null) =>
  a === b || (!!a && !!b && a.kind === b.kind && (a.kind === "end" ? a.folder === (b as typeof a).folder : a.id === (b as typeof a).id));

const UNFILED_KEY = "unfiled";
const byPosition = (a: Source, b: Source) => a.position - b.position || a.title.localeCompare(b.title);

// --- sidebar -------------------------------------------------------------------------------

export function Sidebar({
  nav,
  setNav,
  sources,
  folders,
  onChanged,
  onAdd,
  onSettings,
  onCollapse,
}: {
  nav: NavState;
  setNav: (n: NavState) => void;
  sources: Source[];
  folders: Folder[];
  /** Called after any folder/order change has been sent, so the app refetches sources. */
  onChanged: () => void;
  onAdd: () => void;
  onSettings: () => void;
  onCollapse?: () => void;
}) {
  const [collapsed, toggle] = useCollapsed();

  // Local copy so drags and renames show immediately; replaced whenever the server list arrives.
  const [base, setBase] = useState({ sources, folders });
  const [local, setLocal] = useState({ sources, folders });
  if (base.sources !== sources || base.folders !== folders) {
    setBase({ sources, folders });
    setLocal({ sources, folders });
  }

  const [menu, setMenu] = useState<{ kind: "source"; id: number } | { kind: "folder"; id: number } | null>(null);
  const [editing, setEditing] = useState<{ kind: "rename"; id: number } | { kind: "new"; withSource: number | null } | null>(null);
  const drag = useRef<Drag | null>(null);
  const [dragging, setDragging] = useState<Drag | null>(null);
  const [over, setOver] = useState<Over | null>(null);

  const isView = (v: View) => nav.view === v && nav.source == null && nav.folder == null && nav.filter == null;
  const view = (v: View) => setNav({ ...HOME, view: v });

  const orderedFolders = [...local.folders].sort((a, b) => a.position - b.position || a.id - b.id);
  const inFolder = (id: number | null) => local.sources.filter((s) => s.folder_id === id).sort(byPosition);

  // --- mutations (optimistic local update, then server, then refetch) ---------------------
  const commit = (p: Promise<unknown>) => {
    p.then(onChanged, onChanged);
  };

  const moveTo = (sourceId: number, folderId: number | null) => {
    setLocal((l) => ({
      ...l,
      sources: l.sources.map((s) => (s.id === sourceId ? { ...s, folder_id: folderId, position: Number.MAX_SAFE_INTEGER } : s)),
    }));
    commit(moveSource(sourceId, folderId));
  };

  const addFolder = async (title: string, withSource: number | null) => {
    try {
      const { folder } = await createFolder(title);
      if (withSource != null) await moveSource(withSource, folder.id);
    } finally {
      onChanged();
    }
  };

  const rename = (id: number, title: string) => {
    setLocal((l) => ({ ...l, folders: l.folders.map((f) => (f.id === id ? { ...f, title } : f)) }));
    commit(renameFolder(id, title));
  };

  const remove = (id: number) => {
    setLocal((l) => ({
      folders: l.folders.filter((f) => f.id !== id),
      sources: l.sources.map((s) => (s.folder_id === id ? { ...s, folder_id: null } : s)),
    }));
    if (nav.folder === id) setNav(HOME);
    commit(deleteFolder(id));
  };

  /** Apply a drop of the dragged source at `target`. */
  const dropSource = (id: number, target: Over) => {
    const moving = local.sources.find((s) => s.id === id);
    if (!moving) return;
    // Flatten in sidebar order, pull the moving source out, splice it back in at the target.
    const lanes: (number | null)[] = [...orderedFolders.map((f) => f.id), null];
    const list = lanes.flatMap((fid) => inFolder(fid).filter((s) => s.id !== id).map((s) => ({ ...s, folder_id: fid })));
    let at: number;
    let folderId: number | null;
    if (target.kind === "row") {
      at = list.findIndex((s) => s.id === target.id);
      if (at < 0) return;
      folderId = list[at].folder_id;
    } else {
      folderId = target.kind === "end" ? target.folder : target.id;
      // after the last source in that folder (or where the folder would start, if empty)
      const laneIdx = lanes.indexOf(folderId);
      at = list.findIndex((s) => lanes.indexOf(s.folder_id) > laneIdx);
      if (at < 0) at = list.length;
      if (target.kind === "folder") {
        // dropping on a header puts it first in that folder
        const first = list.findIndex((s) => s.folder_id === folderId);
        at = first < 0 ? at : first;
      }
    }
    list.splice(at, 0, { ...moving, folder_id: folderId });
    const pos = new Map<number | null, number>();
    const next = list.map((s) => {
      const p = pos.get(s.folder_id) ?? 0;
      pos.set(s.folder_id, p + 1);
      return { ...s, position: p };
    });
    if (next.every((s) => local.sources.find((o) => o.id === s.id)?.position === s.position && local.sources.find((o) => o.id === s.id)?.folder_id === s.folder_id)) return;
    setLocal((l) => ({ ...l, sources: next }));
    commit(reorderSources(next.map((s) => ({ id: s.id, folder_id: s.folder_id }))));
  };

  const dropFolder = (id: number, target: Over) => {
    if (target.kind !== "folder" || target.id === id) return;
    const ids = orderedFolders.map((f) => f.id).filter((f) => f !== id);
    ids.splice(ids.indexOf(target.id), 0, id);
    setLocal((l) => ({ ...l, folders: l.folders.map((f) => ({ ...f, position: ids.indexOf(f.id) })) }));
    commit(reorderFolders(ids));
  };

  // --- drag handlers -------------------------------------------------------------------------
  const startDrag = (d: Drag) => (e: React.DragEvent) => {
    drag.current = d;
    setDragging(d);
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", `${d.kind}:${d.id}`);
  };
  const endDrag = () => {
    drag.current = null;
    setDragging(null);
    setOver(null);
  };
  const dragOver = (target: Over) => (e: React.DragEvent) => {
    const d = drag.current;
    if (!d) return;
    if (d.kind === "folder" && target.kind !== "folder") return;
    e.preventDefault();
    e.stopPropagation();
    e.dataTransfer.dropEffect = "move";
    setOver((o) => (sameOver(o, target) ? o : target));
  };
  const drop = (target: Over) => (e: React.DragEvent) => {
    const d = drag.current;
    if (!d) return;
    e.preventDefault();
    e.stopPropagation();
    if (d.kind === "source") dropSource(d.id, target);
    else dropFolder(d.id, target);
    endDrag();
  };

  // --- rendering ---------------------------------------------------------------------------
  const folderMenu = (f: Folder): MenuItem[] => [
    { label: "Rename", onSelect: () => setEditing({ kind: "rename", id: f.id }) },
    { label: "New folder", onSelect: () => setEditing({ kind: "new", withSource: null }) },
    "sep",
    { label: inFolder(f.id).length ? "Delete folder (keep sources)" : "Delete folder", onSelect: () => remove(f.id), danger: true },
  ];
  const sourceMenu = (s: Source): MenuItem[] => [
    ...orderedFolders.map((f) => ({ label: f.title, checked: s.folder_id === f.id, onSelect: () => moveTo(s.id, f.id) })),
    { label: "Unfiled", checked: s.folder_id == null, onSelect: () => moveTo(s.id, null) },
    "sep",
    { label: "New folder with this", onSelect: () => setEditing({ kind: "new", withSource: s.id }) },
  ];

  const renderSource = (s: Source) => {
    const active = nav.source === s.id;
    const isOver = over?.kind === "row" && over.id === s.id;
    const badge =
      s.type === "post" ? "post" : s.type === "podcast" || s.kind === "podcast" ? "podcast" : s.kind === "page" ? "page" : undefined;
    return (
      <li
        key={s.id}
        className={`group/row relative ${dragging?.kind === "source" && dragging.id === s.id ? "opacity-40" : ""} ${isOver ? "shadow-[inset_0_2px_0_var(--accent)]" : ""}`}
        draggable
        onDragStart={startDrag({ kind: "source", id: s.id })}
        onDragEnd={endDrag}
        onDragOver={dragOver({ kind: "row", id: s.id })}
        onDrop={drop({ kind: "row", id: s.id })}
        onContextMenu={(e) => {
          e.preventDefault();
          setMenu({ kind: "source", id: s.id });
        }}
      >
        <div className={`${ROW} cursor-grab text-[var(--ink)] active:cursor-grabbing ${active ? "bg-[var(--nav-selection)]" : "hover:bg-[var(--nav-hover)]"}`}>
          <button
            type="button"
            onClick={() => setNav({ ...HOME, source: s.id })}
            aria-current={active ? "page" : undefined}
            className="min-w-0 flex-1 truncate text-left"
          >
            {s.title}
          </button>
          {badge && <span className="shrink-0 text-[11px] text-[var(--faint)] group-hover/row:hidden">{badge}</span>}
          <button
            type="button"
            aria-label={`Options for ${s.title}`}
            aria-haspopup="menu"
            onClick={() => setMenu(menu?.kind === "source" && menu.id === s.id ? null : { kind: "source", id: s.id })}
            className={`${ICON_BTN} opacity-0 group-hover/row:opacity-100 focus-visible:opacity-100`}
          >
            <MoreIcon size={14} />
          </button>
        </div>
        {menu?.kind === "source" && menu.id === s.id && <Menu label={`Move ${s.title}`} items={sourceMenu(s)} onClose={() => setMenu(null)} />}
      </li>
    );
  };

  const renderFolder = (f: Folder | null) => {
    const id = f?.id ?? null;
    const key = f ? `f${f.id}` : UNFILED_KEY;
    const list = inFolder(id);
    if (!f && list.length === 0) return null;
    const open = !collapsed.has(key);
    const active = f != null && nav.folder === f.id;
    const headerOver = f != null && over?.kind === "folder" && over.id === f.id;
    const endOver = over?.kind === "end" && over.folder === id;
    const title = f?.title ?? "Unfiled";
    return (
      <div
        key={key}
        className={`relative pt-3 ${endOver ? "shadow-[inset_0_-2px_0_var(--accent)]" : ""}`}
        onDragOver={dragOver({ kind: "end", folder: id })}
        onDrop={drop({ kind: "end", folder: id })}
      >
        <div
          className={`group/hdr relative flex h-[26px] items-center gap-1 rounded-[4px] pl-2 pr-1 text-[11px] font-semibold tracking-[0.01em] ${
            active ? "bg-[var(--nav-selection)] text-[var(--ink)]" : "text-[var(--faint)] hover:text-[var(--muted)]"
          } ${headerOver ? "shadow-[inset_0_2px_0_var(--accent)]" : ""} ${dragging?.kind === "folder" && dragging.id === id ? "opacity-40" : ""}`}
          draggable={f != null}
          onDragStart={f ? startDrag({ kind: "folder", id: f.id }) : undefined}
          onDragEnd={endDrag}
          onDragOver={f ? dragOver({ kind: "folder", id: f.id }) : undefined}
          onDrop={f ? drop({ kind: "folder", id: f.id }) : undefined}
          onContextMenu={
            f
              ? (e) => {
                  e.preventDefault();
                  setMenu({ kind: "folder", id: f.id });
                }
              : undefined
          }
        >
          {editing?.kind === "rename" && f && editing.id === f.id ? (
            <InlineInput initial={f.title} placeholder="Folder name" onCommit={(t) => { setEditing(null); rename(f.id, t); }} onCancel={() => setEditing(null)} />
          ) : (
            <>
              <button
                type="button"
                onClick={() => (f ? setNav(active ? HOME : { ...HOME, folder: f.id }) : toggle(key))}
                aria-current={active ? "page" : undefined}
                title={f ? `Show everything in ${f.title}` : undefined}
                className="min-w-0 flex-1 truncate text-left"
              >
                {title}
              </button>
              {!open && <span className="tabular-nums">{list.length}</span>}
              {f && (
                <button
                  type="button"
                  aria-label={`Options for ${f.title}`}
                  aria-haspopup="menu"
                  onClick={() => setMenu(menu?.kind === "folder" && menu.id === f.id ? null : { kind: "folder", id: f.id })}
                  className={`${ICON_BTN} h-[20px] w-[20px] opacity-0 group-hover/hdr:opacity-100 focus-visible:opacity-100`}
                >
                  <MoreIcon size={13} />
                </button>
              )}
              <button
                type="button"
                onClick={() => toggle(key)}
                aria-expanded={open}
                aria-controls={`sidebar-${key}`}
                aria-label={open ? `Collapse ${title}` : `Expand ${title}`}
                className={`${ICON_BTN} h-[20px] w-[20px]`}
              >
                <ChevronIcon size={12} strokeWidth={2.2} className={`transition-transform ${open ? "rotate-90" : ""}`} />
              </button>
            </>
          )}
          {menu?.kind === "folder" && f && menu.id === f.id && <Menu label={f.title} items={folderMenu(f)} onClose={() => setMenu(null)} />}
        </div>
        <ul id={`sidebar-${key}`} hidden={!open}>
          {list.map(renderSource)}
          {open && list.length === 0 && (
            <li className="px-2 py-1.5 text-[12px] text-[var(--faint)]">Drop sources here</li>
          )}
        </ul>
      </div>
    );
  };

  return (
    <nav aria-label="Feeds" className="flex h-full flex-col">
      <div className="mt-2.5 flex h-[54px] shrink-0 items-center gap-2 pl-[18px] pr-2.5">
        <ArcIcon size={20} strokeWidth={2.6} className="shrink-0 text-(--logo)" />
        <span className="min-w-0 flex-1 truncate font-serif text-[17px] font-semibold tracking-[-0.01em] text-[var(--ink)]">Openfeed</span>
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
          <ViewRow active={isView("all")} onClick={() => view("all")} icon={<InboxIcon size={18} />} label="All" />
          <ViewRow active={isView("saved")} onClick={() => view("saved")} icon={<BookmarkIcon size={18} />} label="Saved" />
          <ViewRow active={isView("articles")} onClick={() => view("articles")} icon={<ArticleIcon size={18} />} label="Articles" />
          <ViewRow active={isView("posts")} onClick={() => view("posts")} icon={<PostIcon size={18} />} label="Posts" />
          <ViewRow active={isView("video")} onClick={() => view("video")} icon={<VideoIcon size={18} />} label="Video" />
          <ViewRow
            active={isView("podcasts")}
            onClick={() => view("podcasts")}
            icon={<HeadphonesIcon size={18} />}
            label="Podcasts"
          />
        </ul>
        {orderedFolders.map(renderFolder)}
        {renderFolder(null)}
        <div className="pt-3">
          {editing?.kind === "new" ? (
            <div className="px-1">
              <InlineInput
                initial=""
                placeholder="New folder name"
                onCommit={(t) => {
                  const withSource = editing.withSource;
                  setEditing(null);
                  void addFolder(t, withSource);
                }}
                onCancel={() => setEditing(null)}
              />
            </div>
          ) : (
            <button
              type="button"
              onClick={() => setEditing({ kind: "new", withSource: null })}
              className="flex h-[26px] w-full items-center gap-1.5 rounded-[4px] px-2 text-[11px] font-semibold tracking-[0.01em] text-[var(--faint)] hover:text-[var(--muted)]"
            >
              <PlusIcon size={12} strokeWidth={2.2} />
              New folder
            </button>
          )}
        </div>
      </div>
      <div className="flex shrink-0 items-center gap-1 px-2.5 pb-3 pt-1">
        <FooterRow onClick={onAdd} icon={<PlusIcon size={16} />} label="Add source" />
        <button
          type="button"
          onClick={onSettings}
          aria-label="Settings"
          title="Settings"
          className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-[var(--muted)] hover:bg-[var(--nav-hover)] hover:text-[var(--ink)]"
        >
          <GearIcon size={16} />
        </button>
      </div>
    </nav>
  );
}
