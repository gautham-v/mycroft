"use client";
import { memo } from "react";
import type { Item } from "@/lib/types";
import { relativeTime } from "@/lib/time";
import { SourceBadge } from "./badge";
import { PlayIcon } from "./icons";
import { formatDuration, stripHtml } from "./text";

function Thumb({ item }: { item: Item }) {
  if (!item.thumbnail_url) return null;
  if (item.source.kind === "youtube") {
    const dur = formatDuration(item.duration_sec);
    return (
      <span className="relative block h-[56px] w-[96px] shrink-0 overflow-hidden rounded-md bg-[var(--code)]">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src={item.thumbnail_url} alt="" loading="lazy" className="h-full w-full object-cover" />
        <span className="absolute inset-0 flex items-center justify-center">
          <span className="flex h-6 w-6 items-center justify-center rounded-full bg-black/55 text-white">
            <PlayIcon size={12} strokeWidth={0} />
          </span>
        </span>
        {dur && (
          <span className="absolute bottom-1 right-1 rounded bg-black/75 px-1 font-mono text-[10px] leading-4 text-white">
            {dur}
          </span>
        )}
      </span>
    );
  }
  return (
    <span className="block h-[72px] w-[72px] shrink-0 overflow-hidden rounded-md bg-[var(--code)]">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={item.thumbnail_url} alt="" loading="lazy" className="h-full w-full object-cover" />
    </span>
  );
}

export const ItemRow = memo(function ItemRow({
  item,
  selected,
  onOpen,
}: {
  item: Item;
  selected: boolean;
  onOpen: (item: Item) => void;
}) {
  const snippet = stripHtml(item.summary);
  const meta: string[] = [item.source.title];
  if (item.hn_points != null) meta.push(`${item.hn_points} pts`);
  if (item.hn_comments != null) meta.push(`${item.hn_comments} comments`);
  meta.push(relativeTime(item.published_at));

  return (
    <li>
      <a
        href={`/?item=${item.id}`}
        onClick={(e) => {
          if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
          e.preventDefault();
          onOpen(item);
        }}
        aria-current={selected ? "true" : undefined}
        className={`flex gap-3 border-b border-[var(--hairline)] border-l-[3px] py-3 pl-[13px] pr-4 transition-colors ${
          selected ? "border-l-[var(--accent)] bg-[var(--surface)]" : "border-l-transparent hover:bg-[var(--surface)]/60"
        }`}
      >
        <span className="flex shrink-0 items-start pt-1">
          <SourceBadge host={item.source.host} title={item.source.title} size={32} />
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-[15px] font-medium leading-snug text-[var(--ink)]">{item.title}</span>
          {snippet && (
            <span className="mt-1 line-clamp-2 text-[13px] leading-snug text-[var(--muted)] md:hidden">{snippet}</span>
          )}
          <span className="mt-1.5 block truncate font-mono text-[11.5px] text-[var(--muted)]">{meta.join(" · ")}</span>
        </span>
        <Thumb item={item} />
      </a>
    </li>
  );
});
