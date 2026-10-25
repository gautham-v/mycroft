"use client";
import { memo } from "react";
import type { Item } from "@/lib/types";
import { relativeTime } from "@/lib/time";
import { SourceBadge } from "./badge";
import { HeadphonesIcon, PlayIcon } from "./icons";
import { formatDuration, isXPost, splitHandle, stripHtml } from "./text";

function Thumb({ item }: { item: Item }) {
  const isPodcast = item.source.kind === "podcast";
  // Podcast rows keep a thumb even without art, so the audio indicator and duration still show.
  if (!item.thumbnail_url && !isPodcast) return null;
  const dur = item.source.kind === "youtube" || isPodcast ? formatDuration(item.duration_sec) : null;
  return (
    <span className="relative block h-[50px] w-[76px] shrink-0 overflow-hidden rounded-[3px] bg-[var(--code)]">
      {item.thumbnail_url ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={item.thumbnail_url} alt="" loading="lazy" className="h-full w-full object-cover" />
      ) : (
        <span className="flex h-full w-full items-center justify-center text-[var(--faint)]">
          <HeadphonesIcon size={20} />
        </span>
      )}
      {item.source.kind === "youtube" && (
        <span className="absolute inset-0 flex items-center justify-center">
          <span className="flex h-5 w-5 items-center justify-center rounded-full bg-black/55 text-white">
            <PlayIcon size={10} strokeWidth={0} />
          </span>
        </span>
      )}
      {isPodcast && item.thumbnail_url && (
        <span
          role="img"
          aria-label="Podcast episode"
          className="absolute bottom-0.5 left-0.5 flex h-[14px] w-[14px] items-center justify-center rounded-[4px] bg-black/75 text-white"
        >
          <HeadphonesIcon size={10} strokeWidth={2.25} />
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
        className={`flex gap-3 rounded-[4px] px-2.5 py-[11px] ${
          selected ? "bg-[var(--selection)]" : "hover:bg-[var(--hover)]"
        }`}
      >
        <Thumb item={item} />
        {isXPost(item.url) ? (
          <PostRow item={item} meta={meta} />
        ) : (
        <span className="min-w-0 flex-1">
          <span className="block text-[14.5px] font-medium leading-[1.3] tracking-[-0.005em] text-[var(--ink)]">{item.title}</span>
          {snippet && (
            <span className="mt-1 line-clamp-2 text-[13px] leading-snug text-[var(--muted)] md:hidden">{snippet}</span>
          )}
          <span className="mt-[5px] flex items-center gap-1.5 text-[12.5px] text-[var(--muted)]">
            <SourceBadge host={item.source.host} title={item.source.title} size={16} />
            <span className="truncate">
              <b className="font-medium text-[var(--body)]">{item.source.title}</b>
              {meta.map((m) => ` · ${m}`).join("")}
            </span>
          </span>
        </span>
        )}
      </a>
    </li>
  );
});

/** A post on X: author line first, then the text, then "Quoting …" when it quotes a post. */
function PostRow({ item, meta }: { item: Item; meta: string[] }) {
  const { name, handle } = splitHandle(item.author);
  const snippet = stripHtml(item.summary);
  return (
    <span className="min-w-0 flex-1">
      <span className="flex items-center gap-1.5 text-[12.5px] text-[var(--muted)]">
        <SourceBadge host={item.source.host} title={item.source.title} size={16} />
        <span className="truncate">
          <b className="font-medium text-[var(--ink)]">{name || item.source.title}</b>
          {handle && ` @${handle}`}
          {meta.map((m) => ` · ${m}`).join("")}
        </span>
      </span>
      <span className="mt-1 line-clamp-2 text-[14.5px] leading-[1.35] text-[var(--ink)]">{item.title}</span>
      {snippet && <span className="mt-1 line-clamp-1 text-[13px] leading-snug text-[var(--muted)]">{snippet}</span>}
    </span>
  );
}
