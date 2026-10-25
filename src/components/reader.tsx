"use client";
import { Fragment, useEffect, useMemo, useRef, useState } from "react";
import type { ContentResponse, Item } from "@/lib/types";
import { useSettings, type Settings } from "@/hooks/use-settings";
import { SourceBadge } from "./badge";
import { SendToButton } from "./send-to";
import {
  BackIcon,
  BookmarkIcon,
  CheckIcon,
  CollapseIcon,
  CommentIcon,
  ExpandIcon,
  ExternalIcon,
  ShareIcon,
} from "./icons";
import { formatDate, formatDuration, hostOf, isXPost, stripHtml } from "./text";

type ContentState =
  | { status: "loading" }
  | { status: "ok"; html: string; leadImage: string | null; rendered: boolean }
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
          s: d.contentHtml
            ? { status: "ok", html: d.contentHtml, leadImage: d.leadImage, rendered: !!d.rendered }
            : { status: "failed" },
        });
      })
      .catch(() => !cancelled && setState({ id: item.id, s: { status: "failed" } }));
    return () => {
      cancelled = true;
    };
  }, [item.id, item.source.kind]);
  return state && state.id === item.id ? state.s : ({ status: "loading" } as ContentState);
}

// Article headline size per text-size setting; "m" is the original size. Body size lives in
// globals.css (.prose-openfeed[data-size]).
const HEADLINE_SIZE: Record<Settings["textSize"], string> = {
  s: "text-[26px] md:text-[32px]",
  m: "text-[30px] md:text-[36px]",
  l: "text-[34px] md:text-[40px]",
};

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
  desktopOnly = false,
}: {
  label: string;
  onClick?: () => void;
  href?: string;
  children: React.ReactNode;
  desktopOnly?: boolean;
}) {
  const cls = `${
    desktopOnly ? "hidden lg:inline-flex" : "inline-flex"
  } h-9 w-9 items-center justify-center rounded-lg text-[var(--muted)] hover:bg-[var(--hover)] hover:text-[var(--ink)] lg:h-[30px] lg:w-[30px]`;
  if (href)
    return (
      <a href={href} target="_blank" rel="noopener noreferrer" className={cls} aria-label={label} title={label}>
        {children}
      </a>
    );
  return (
    <button type="button" onClick={onClick} className={cls} aria-label={label} title={label}>
      {children}
    </button>
  );
}

export function Reader({
  item,
  onBack,
  onToggleSaved,
  showBack,
  focused = false,
  onToggleFocus,
  onOpenIntegrations,
}: {
  item: Item;
  onBack: () => void;
  onToggleSaved: (item: Item) => void;
  showBack: boolean;
  focused?: boolean;
  onToggleFocus?: () => void;
  /** Opens Settings on the Integrations tab (Send to, when no target is set up). */
  onOpenIntegrations: () => void;
}) {
  const content = useContent(item);
  const [settings] = useSettings();
  const [copied, setCopied] = useState(false);
  const isVideo = item.source.kind === "youtube";
  // Podcasts read like articles (title, show notes) with an audio player between header and notes.
  const isPodcast = item.source.kind === "podcast" && !!item.audio_url;
  // Posts on X have no headline: the extracted markup carries the author row, text and cards.
  const isPost = isXPost(item.url) && content.status !== "failed";
  const host = hostOf(item.url) || item.source.host;
  const summaryText = stripHtml(item.summary);
  const meta = [host, formatDate(item.published_at)];

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

  const leadArt = item.thumbnail_url || (content.status === "ok" ? content.leadImage : null);
  // A podcast's art sits beside its player, so it is never also the hero.
  const hero = !isVideo && !isPost && !isPodcast ? leadArt : null;
  const podcastArt = isPodcast ? leadArt : null;
  const contentHtml = content.status === "ok" ? content.html : null;
  // Show notes often open with the same episode/show art; drop it so it does not appear twice.
  const html = useMemo(
    () => (contentHtml && podcastArt ? stripImage(contentHtml, podcastArt) : contentHtml),
    [contentHtml, podcastArt],
  );
  // A page's hero video comes first in the extracted HTML; it replaces the hero image.
  const contentHasHero =
    html != null && hero != null && (html.includes(hero) || /^\s*<(?:iframe|video)\b/.test(html));

  return (
    <article className="min-h-full bg-[var(--surface)] pb-[calc(env(safe-area-inset-bottom)+32px)]">
      <div className="sticky top-0 z-10 border-b border-[var(--hairline)] bg-[var(--surface)]/95 px-4 pt-[env(safe-area-inset-top)] backdrop-blur lg:border-b-0">
        <div className="flex min-h-14 flex-wrap items-center gap-2 py-2 lg:min-h-[54px] lg:gap-1.5">
          {showBack && (
            <button
              type="button"
              onClick={onBack}
              aria-label="Back to list"
              className="-ml-2 inline-flex h-11 w-11 items-center justify-center rounded-lg text-[var(--ink)] hover:bg-[var(--hover)] lg:ml-0 lg:h-[30px] lg:w-[30px] lg:text-[var(--muted)] lg:hover:text-[var(--ink)]"
            >
              <BackIcon size={22} className="lg:size-[18px]" />
            </button>
          )}
          <div className="flex min-w-0 flex-1 items-center gap-2">
            <SourceBadge host={item.source.host} title={item.source.title} size={20} />
            <span className="truncate text-[13px] text-[var(--muted)]">{meta.filter(Boolean).join(" · ")}</span>
          </div>
          <div className="flex items-center gap-0.5">
            <ActionButton label={item.is_saved ? "Remove from saved" : "Save"} onClick={() => onToggleSaved(item)}>
              <BookmarkIcon size={17} filled={item.is_saved} className={item.is_saved ? "text-[var(--accent)]" : ""} />
            </ActionButton>
            <ActionButton label="Open original" href={item.url}>
              <ExternalIcon size={17} />
            </ActionButton>
            <ActionButton label={copied ? "Link copied" : "Share"} onClick={share}>
              {copied ? <CheckIcon size={17} className="text-[var(--accent)]" /> : <ShareIcon size={17} />}
            </ActionButton>
            <SendToButton item={item} onSetup={onOpenIntegrations} />
            {onToggleFocus && (
              <ActionButton
                label={focused ? "Exit full screen (esc)" : "Full screen (⇧⌘F)"}
                onClick={onToggleFocus}
                desktopOnly
              >
                {focused ? <CollapseIcon size={17} /> : <ExpandIcon size={17} />}
              </ActionButton>
            )}
          </div>
        </div>
      </div>

      {isVideo ? (
        <VideoBody item={item} summaryText={summaryText} autoplay={settings.autoplay} theater={settings.theater} />
      ) : (
        <>
          {!isPost && (
          <div className="mx-auto max-w-[640px] px-5 pt-8 md:px-0 lg:pt-10">
            <h1
              className={`text-balance ${settings.readerFont === "sans" ? "font-sans" : "font-serif"} ${HEADLINE_SIZE[settings.textSize]} font-semibold leading-[1.12] tracking-[-0.01em] text-[var(--ink)]`}
            >
              <a href={item.url} target="_blank" rel="noopener noreferrer" className="hover:underline">
                {item.title}
              </a>
            </h1>
            <div className="mt-3.5 flex flex-wrap items-center gap-x-3.5 gap-y-1 text-[14px] text-[var(--muted)]">
              <span className="font-medium text-[var(--ink)]">{item.source.title}</span>
              {item.author && item.author !== item.source.title && <span>{item.author}</span>}
              {isPodcast && formatDuration(item.duration_sec) && (
                <span className="tabular-nums">{formatDuration(item.duration_sec)}</span>
              )}
              {item.hn_comments_url && (
                <a
                  href={item.hn_comments_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 text-[var(--accent)] hover:underline"
                >
                  <CommentIcon size={14} />
                  Discussion
                </a>
              )}
            </div>
            {content.status === "ok" && content.rendered && (
              <p className="mt-1.5 text-[12px] text-[var(--muted)]">Rendered copy</p>
            )}
            {isPodcast && <PodcastPlayer key={item.id} item={item} art={podcastArt} />}
          </div>
          )}

          <div
            className={`prose-openfeed mx-auto px-5 md:px-0 ${isPost ? "mt-6 lg:mt-8" : "mt-7"}`}
            data-font={settings.readerFont}
            data-size={settings.textSize}
          >
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
              {html != null && <div dangerouslySetInnerHTML={{ __html: html }} />}
              {content.status === "failed" && (
                <div>
                  {summaryText && <p>{summaryText}</p>}
                  <p className="not-prose mt-6">
                    <a
                      href={item.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex h-11 items-center gap-2 rounded-lg bg-[var(--accent)] px-4 font-sans text-[15px] font-medium !text-white !no-underline"
                    >
                      Open original
                      <ExternalIcon size={16} />
                    </a>
                  </p>
                </div>
              )}
            </>
          </div>
        </>
      )}
    </article>
  );
}

/** Removes <img> tags whose src is `src` (raw or HTML-escaped). */
function stripImage(html: string, src: string): string {
  const variants = [src, src.replace(/&/g, "&amp;")];
  return html.replace(/<img\b[^>]*>/gi, (tag) =>
    variants.some((v) => tag.includes(`"${v}"`) || tag.includes(`'${v}'`)) ? "" : tag,
  );
}

const POSITION_KEY = (id: number) => `openfeed:podcast-pos:${id}`;
const SAVE_EVERY_MS = 5000;

function savePosition(id: number, a: HTMLAudioElement | null) {
  if (!a || a.ended || !(a.currentTime > 0)) return;
  try {
    window.localStorage.setItem(POSITION_KEY(id), String(Math.floor(a.currentTime)));
  } catch {
    /* storage unavailable */
  }
}

/** Native audio player with the episode art beside it. Never autoplays; resumes where you left off. */
function PodcastPlayer({ item, art }: { item: Item; art: string | null }) {
  const ref = useRef<HTMLAudioElement>(null);
  const lastSave = useRef(0);
  const id = item.id;

  // Save when the player unmounts mid-episode (switching items, closing the reader).
  useEffect(() => {
    const a = ref.current;
    return () => savePosition(id, a);
  }, [id]);

  const restore = () => {
    const a = ref.current;
    if (!a) return;
    try {
      const saved = Number(window.localStorage.getItem(POSITION_KEY(id)));
      if (saved > 0 && (!Number.isFinite(a.duration) || saved < a.duration - 5)) a.currentTime = saved;
    } catch {
      /* storage unavailable */
    }
  };

  const onTimeUpdate = () => {
    const now = Date.now();
    if (now - lastSave.current < SAVE_EVERY_MS) return;
    lastSave.current = now;
    savePosition(id, ref.current);
  };

  const onEnded = () => {
    try {
      window.localStorage.removeItem(POSITION_KEY(id));
    } catch {
      /* storage unavailable */
    }
  };

  return (
    <div className="mt-6 flex items-center gap-3.5 rounded-[10px] border border-[var(--hairline)] bg-[var(--ground)] p-3">
      {art && (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={art}
          alt=""
          width={72}
          height={72}
          className="h-[64px] w-[64px] shrink-0 rounded-[6px] bg-[var(--code)] object-cover md:h-[72px] md:w-[72px]"
        />
      )}
      <audio
        ref={ref}
        controls
        preload="none"
        src={item.audio_url ?? undefined}
        onLoadedMetadata={restore}
        onTimeUpdate={onTimeUpdate}
        onPause={() => savePosition(id, ref.current)}
        onEnded={onEnded}
        aria-label={`Play ${item.title}`}
        className="h-10 min-w-0 flex-1"
      />
    </div>
  );
}

function VideoBody({
  item,
  summaryText,
  autoplay,
  theater,
}: {
  item: Item;
  summaryText: string;
  autoplay: boolean;
  theater: boolean;
}) {
  const [expanded, setExpanded] = useState(false);
  const dur = formatDuration(item.duration_sec);
  const long = summaryText.length > 280 || summaryText.split("\n").length > 3;
  const player = item.video_id && (
    <iframe
      key={item.video_id}
      src={`https://www.youtube-nocookie.com/embed/${item.video_id}?${autoplay ? "autoplay=1&" : ""}rel=0`}
      title={item.title}
      allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
      allowFullScreen
      className="absolute inset-0 h-full w-full border-0"
    />
  );
  return (
    <>
      {/* Theater: full-width black band above the title. Otherwise the player sits in the text
          column below the title and meta row, like an article's hero image. */}
      {theater && player && (
        <div className="bg-black px-0 lg:px-4">
          <div className="relative mx-auto aspect-video w-full max-w-[960px]">{player}</div>
        </div>
      )}
      <div className={`mx-auto max-w-[640px] px-5 md:px-0 ${theater ? "pt-6" : "pt-8 lg:pt-10"}`}>
        <h1 className="text-balance text-[20px] font-semibold leading-[1.3] tracking-[-0.01em] text-[var(--ink)] md:text-[22px]">
          {item.title}
        </h1>
        <div className="mt-3 flex flex-wrap items-center gap-x-3.5 gap-y-2 text-[13px] text-[var(--muted)]">
          <span className="inline-flex items-center gap-2 font-medium text-[var(--ink)]">
            <SourceBadge host={item.source.host} title={item.source.title} size={22} />
            {item.source.title}
          </span>
          {dur && <span className="tabular-nums">{dur}</span>}
          <span>{formatDate(item.published_at)}</span>
          <a
            href={item.url}
            target="_blank"
            rel="noopener noreferrer"
            className="ml-auto inline-flex h-8 items-center gap-1.5 rounded-[6px] border border-[var(--hairline)] px-2.5 text-[12.5px] text-[var(--ink)] hover:bg-[var(--hover)]"
          >
            Watch on YouTube
            <ExternalIcon size={13} />
          </a>
        </div>
        {!theater && player && (
          <div className="relative mt-5 aspect-video w-full overflow-hidden rounded-[10px] bg-black">{player}</div>
        )}
        {summaryText && (
          <div className="mt-5 text-[14.5px] leading-[1.55] text-[var(--ink)]">
            <div className={expanded ? "" : "line-clamp-3"}>
              <Linkified text={item.summary ?? ""} />
            </div>
            {long && (
              <button
                type="button"
                onClick={() => setExpanded((v) => !v)}
                className="mt-1.5 text-[13px] font-medium text-[var(--accent)] hover:underline"
              >
                {expanded ? "Show less" : "Show more"}
              </button>
            )}
          </div>
        )}
      </div>
    </>
  );
}

export function ReaderEmpty() {
  return (
    <div className="flex h-full items-center justify-center bg-[var(--surface)]">
      <div className="text-center">
        <p className="text-[15px] font-medium text-[var(--ink)]">Nothing selected</p>
        <p className="mt-1 text-[13px] text-[var(--muted)]">Pick an item from the list</p>
      </div>
    </div>
  );
}
