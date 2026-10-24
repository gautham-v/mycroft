"use client";
import { memo } from "react";
import type { Item } from "@/lib/types";
import { relativeTime } from "@/lib/time";
import { SourceBadge } from "./badge";
import { PlayIcon } from "./icons";
import { formatDuration, stripHtml } from "./text";

function Thumb({ item }: { item: Item }) {
  if (!item.thumbnail_url) return null;
  const dur = item.source.kind === "youtube" ? formatDuration(item.duration_sec) : null;
  return (
    <span className="relative block h-[50px] w-[76px] shrink-0 overflow-hidden rounded-[7px] bg-[var(--code)]">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={item.thumbnail_url} alt="" loading="lazy" className="h-full w-full object-cover" />
      {item.source.kind === "youtube" && (
        <span className="absolute inset-0 flex items-center justify-center">
          <span className="flex h-5 w-5 items-center justify-center rounded-full bg-black/55 text-white">
            <PlayIcon size={10} strokeWidth={0} />
          </span>
        </span>
      )}
      {dur && (
        <span className="absolute bottom-0.5 right-0.5 rounded-[4px] bg-black/75 px-1 text-[10px] font-medium leading-[14px] tabular-nums text-white">
          {dur}
        </span>
      )}
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
  const meta: string[] = [];
  if (item.hn_points != null) meta.push(`${item.hn_points} pts`);
  if (item.hn_comments != null) meta.push(`${item.hn_comments} comments`);
  meta.push(relativeTime(item.published_at));

  return (
    <li className="item-row" data-selected={selected ? "" : undefined}>
      <a
        href={`/?item=${item.id}`}
        onClick={(e) => {
          if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
          e.preventDefault();
          onOpen(item);
        }}
        aria-current={selected ? "true" : undefined}
        className={`flex gap-3 rounded-[9px] px-2.5 py-[11px] ${
          selected ? "bg-[var(--selection)]" : "hover:bg-[var(--hover)]"
        }`}
      >
        <span className="flex shrink-0 items-start pt-px">
          <SourceBadge host={item.source.host} title={item.source.title} size={24} />
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-[14.5px] font-medium leading-[1.3] tracking-[-0.005em] text-[var(--ink)]">{item.title}</span>
          {snippet && (
            <span className="mt-1 line-clamp-2 text-[13px] leading-snug text-[var(--muted)] md:hidden">{snippet}</span>
          )}
          <span className="mt-[3px] block truncate text-[12.5px] text-[var(--muted)]">
            <b className="font-medium text-[var(--body)]">{item.source.title}</b>
            {meta.map((m) => ` · ${m}`).join("")}
          </span>
        </span>
        <Thumb item={item} />
      </a>
    </li>
  );
});
