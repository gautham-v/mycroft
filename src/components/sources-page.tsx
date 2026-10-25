"use client";
import type { Folder, Source } from "@/lib/types";
import { orderFolders, sourcesIn } from "@/lib/source-tree";
import { SourceBadge } from "./badge";
import { ChevronIcon, PlusIcon } from "./icons";

const ROW = "flex min-h-[44px] w-full items-center gap-3 rounded-lg px-3 text-left hover:bg-[var(--hover)] active:bg-[var(--hover)]";

/**
 * Phone/tablet Sources tab: folders as sections with their sources underneath, for navigation only.
 * Renaming, reordering and deleting stay in Settings (and the desktop sidebar).
 */
export function SourcesPage({
  sources,
  folders,
  activeSource,
  activeFolder,
  onOpenFolder,
  onOpenSource,
  onAdd,
}: {
  sources: Source[];
  folders: Folder[];
  activeSource: number | null;
  activeFolder: number | null;
  onOpenFolder: (f: Folder) => void;
  onOpenSource: (s: Source) => void;
  onAdd: () => void;
}) {
  const unfiled = sourcesIn(sources, null);

  const renderSources = (list: Source[]) => (
    <ul>
      {list.map((s) => (
        <li key={s.id}>
          <button
            type="button"
            onClick={() => onOpenSource(s)}
            aria-current={activeSource === s.id ? "page" : undefined}
            className={`${ROW} text-[15px] text-[var(--ink)]`}
          >
            <SourceBadge host={s.host} title={s.title} size={24} />
            <span className="min-w-0 flex-1 truncate">{s.title}</span>
          </button>
        </li>
      ))}
    </ul>
  );

  return (
    <div className="px-2 pb-4">
      {orderFolders(folders).map((f) => {
        const list = sourcesIn(sources, f.id);
        return (
          <section key={f.id} aria-labelledby={`sources-folder-${f.id}`} className="pt-3">
            <h2 id={`sources-folder-${f.id}`}>
              {/* The folder header opens everything in the folder. */}
              <button
                type="button"
                onClick={() => onOpenFolder(f)}
                aria-current={activeFolder === f.id ? "page" : undefined}
                aria-label={`Show everything in ${f.title}`}
                className={`${ROW} text-[13px] font-semibold tracking-[0.01em] text-[var(--muted)]`}
              >
                <span className="min-w-0 flex-1 truncate">{f.title}</span>
                <span className="tabular-nums text-[var(--faint)]">{list.length}</span>
                <ChevronIcon size={14} strokeWidth={2.2} className="shrink-0 text-[var(--faint)]" />
              </button>
            </h2>
            {list.length > 0 ? renderSources(list) : <p className="px-3 pb-2 text-[13px] text-[var(--faint)]">No sources</p>}
          </section>
        );
      })}
      {unfiled.length > 0 && (
        <section aria-labelledby="sources-unfiled" className="pt-3">
          <h2 id="sources-unfiled" className="flex min-h-[44px] items-center px-3 text-[13px] font-semibold tracking-[0.01em] text-[var(--muted)]">
            Unfiled
          </h2>
          {renderSources(unfiled)}
        </section>
      )}
      <div className="mt-3 border-t border-[var(--hairline)] pt-3">
        <button type="button" onClick={onAdd} className={`${ROW} text-[15px] font-medium text-[var(--accent)]`}>
          <span className="flex h-6 w-6 shrink-0 items-center justify-center">
            <PlusIcon size={20} />
          </span>
          Add source
        </button>
      </div>
    </div>
  );
}
