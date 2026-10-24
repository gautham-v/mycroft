"use client";
import { Fragment, useEffect, useState } from "react";
import type { ContentResponse, Item } from "@/lib/types";
import { SourceBadge } from "./badge";
import { BackIcon, BookmarkIcon, CheckIcon, CircleIcon, CommentIcon, ExternalIcon, ShareIcon } from "./icons";
import { formatDate, hostOf, readMinutes, stripHtml } from "./text";

type ContentState =
  | { status: "loading" }
  | { status: "ok"; html: string; leadImage: string | null }
  | { status: "failed" };

function useContent(item: Item) {
  const [state, setState] = useState<{ id: number; s: ContentState } | null>(null);
  useEffect(() => {
    if (item.source.kind === "youtube") return;
    let cancelled = false;
    fetch(`/api/items/${item.id}/content`)
      .then(async (r) => {
        if (!r.ok) throw new Error(String(r.status));
        const d = (await r.json()) as ContentResponse;
        if (cancelled) return;
        setState({
          id: item.id,
          s: d.contentHtml ? { status: "ok", html: d.contentHtml, leadImage: d.leadImage } : { status: "failed" },
        });
      })
      .catch(() => !cancelled && setState({ id: item.id, s: { status: "failed" } }));
    return () => {
      cancelled = true;
    };
  }, [item.id, item.source.kind]);
  return state && state.id === item.id ? state.s : ({ status: "loading" } as ContentState);
}

const URL_RE = /(https?:\/\/[^\s<>"')]+[^\s<>"').,;:!?])/g;

function Linkified({ text }: { text: string }) {
  return (
    <p className="whitespace-pre-wrap">
      {text.split(URL_RE).map((part, i) =>
        i % 2 === 1 ? (
          <a key={i} href={part} target="_blank" rel="noopener noreferrer">
            {part}
          </a>
        ) : (
          <Fragment key={i}>{part}</Fragment>
        ),
      )}
    </p>
  );
}

function ActionButton({
  label,
  onClick,
  href,
  children,
  pressed,
}: {
  label: string;
  onClick?: () => void;
  href?: string;
  children: React.ReactNode;
  pressed?: boolean;
}) {
  const cls =
    "inline-flex h-9 items-center gap-1.5 rounded-lg border border-[var(--border)] bg-[var(--surface)] px-2.5 text-[13px] font-medium text-[var(--body)] hover:bg-[var(--ground)]";
  if (href)
    return (
      <a href={href} target="_blank" rel="noopener noreferrer" className={cls} aria-label={label}>
        {children}
      </a>
    );
  return (
    <button type="button" onClick={onClick} className={cls} aria-label={label} aria-pressed={pressed}>
      {children}
    </button>
  );
}

export function Reader({
  item,
  onBack,
  onToggleSaved,
  onToggleRead,
  showBack,
}: {
  item: Item;
  onBack: () => void;
  onToggleSaved: (item: Item) => void;
  onToggleRead: (item: Item) => void;
  showBack: boolean;
}) {
  const content = useContent(item);
  const [copied, setCopied] = useState(false);
  const isVideo = item.source.kind === "youtube";
  const host = hostOf(item.url) || item.source.host;
  const summaryText = stripHtml(item.summary);
  const lengthText = content.status === "ok" ? stripHtml(content.html) : summaryText;
  const meta = [host, formatDate(item.published_at)];
  if (!isVideo && lengthText && content.status === "ok") meta.push(`${readMinutes(lengthText)} min read`);
  if (item.hn_points != null) meta.push(`${item.hn_points} pts`);

  const share = async () => {
    if (typeof navigator !== "undefined" && "share" in navigator) {
      try {
        await navigator.share({ title: item.title, url: item.url });
        return;
      } catch {
        /* cancelled or unsupported; fall through */
      }
    }
    try {
      await navigator.clipboard.writeText(item.url);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      /* ignore */
    }
  };

  const hero = !isVideo ? item.thumbnail_url || (content.status === "ok" ? content.leadImage : null) : null;
  const contentHasHero = content.status === "ok" && hero != null && content.html.includes(hero);

  return (
    <article className="min-h-full bg-[var(--surface)] pb-[calc(env(safe-area-inset-bottom)+32px)]">
      <div className="sticky top-0 z-10 border-b border-[var(--hairline)] bg-[var(--surface)]/95 px-4 pt-[env(safe-area-inset-top)] backdrop-blur md:px-8">
        <div className="flex min-h-14 flex-wrap items-center gap-2 py-2">
          {showBack && (
            <button
              type="button"
              onClick={onBack}
              aria-label="Back to list"
              className="-ml-2 inline-flex h-11 w-11 items-center justify-center rounded-lg text-[var(--ink)] hover:bg-[var(--ground)]"
            >
              <BackIcon size={22} />
            </button>
          )}
          <div className="flex min-w-0 flex-1 items-center gap-2">
            <SourceBadge host={item.source.host} title={item.source.title} size={28} />
            <span className="truncate font-mono text-[12px] text-[var(--muted)]">{meta.filter(Boolean).join(" · ")}</span>
          </div>
          <div className="flex items-center gap-1.5">
            <ActionButton label={item.is_saved ? "Unsave" : "Save"} onClick={() => onToggleSaved(item)} pressed={item.is_saved}>
              <BookmarkIcon size={16} filled={item.is_saved} className={item.is_saved ? "text-[var(--accent)]" : ""} />
              <span className="hidden lg:inline">{item.is_saved ? "Saved" : "Save"}</span>
            </ActionButton>
            <ActionButton label="Open original" href={item.url}>
              <ExternalIcon size={16} />
              <span className="hidden lg:inline">Open</span>
            </ActionButton>
            <ActionButton label={copied ? "Link copied" : "Share"} onClick={share}>
              <ShareIcon size={16} />
              <span className="hidden lg:inline">{copied ? "Copied" : "Share"}</span>
            </ActionButton>
            <ActionButton label={item.is_read ? "Mark unread" : "Mark read"} onClick={() => onToggleRead(item)}>
              {item.is_read ? <CircleIcon size={16} /> : <CheckIcon size={16} />}
              <span className="hidden lg:inline">{item.is_read ? "Unread" : "Read"}</span>
            </ActionButton>
          </div>
        </div>
      </div>

      <div className="mx-auto max-w-[640px] px-5 pt-8 md:px-0">
        <h1 className="text-[26px] font-semibold leading-tight tracking-[-0.01em] text-[var(--ink)] md:text-[32px]">
          <a href={item.url} target="_blank" rel="noopener noreferrer" className="hover:underline">
            {item.title}
          </a>
        </h1>
        <div className="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-[12px] text-[var(--muted)]">
          <span>{item.source.title}</span>
          {item.author && item.author !== item.source.title && <span>{item.author}</span>}
          {item.hn_comments_url && (
            <a
              href={item.hn_comments_url}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1 text-[var(--accent)] hover:underline"
            >
              <CommentIcon size={13} />
              Comments{item.hn_comments != null ? ` (${item.hn_comments})` : ""}
            </a>
          )}
        </div>
      </div>

      <div className="prose-mycroft mx-auto mt-6 px-5 md:px-0">
        {isVideo ? (
          <>
            {item.video_id && (
              <div className="relative mb-6 aspect-video w-full overflow-hidden rounded-[10px] bg-black">
                <iframe
                  src={`https://www.youtube-nocookie.com/embed/${item.video_id}`}
                  title={item.title}
                  allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                  allowFullScreen
                  className="absolute inset-0 h-full w-full border-0"
                />
              </div>
            )}
            {summaryText && <Linkified text={item.summary ?? ""} />}
          </>
        ) : (
          <>
            {hero && !contentHasHero && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={hero} alt="" />
            )}
            {content.status === "loading" && (
              <div aria-busy="true" aria-label="Loading article" className="space-y-3">
                {[100, 96, 88, 100, 72, 0, 100, 92, 60].map((w, i) =>
                  w ? (
                    <div key={i} className="h-4 animate-pulse rounded bg-[var(--code)]" style={{ width: `${w}%` }} />
                  ) : (
                    <div key={i} className="h-3" />
                  ),
                )}
              </div>
            )}
            {content.status === "ok" && <div dangerouslySetInnerHTML={{ __html: content.html }} />}
            {content.status === "failed" && (
              <div>
                {summaryText && <p>{summaryText}</p>}
                <p className="not-prose mt-6">
                  <a
                    href={item.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex h-11 items-center gap-2 rounded-lg bg-[var(--accent)] px-4 text-[15px] font-medium !text-white !no-underline"
                  >
                    Open original
                    <ExternalIcon size={16} />
                  </a>
                </p>
              </div>
            )}
          </>
        )}
      </div>
    </article>
  );
}

export function ReaderEmpty() {
  return (
    <div className="flex h-full items-center justify-center bg-[var(--surface)]">
      <div className="text-center">
        <p className="text-[15px] font-medium text-[var(--ink)]">Nothing selected</p>
        <p className="mt-1 font-mono text-[12px] text-[var(--muted)]">Pick an item from the list</p>
      </div>
    </div>
  );
}
