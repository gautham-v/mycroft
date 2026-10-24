# Openfeed — build spec

Single-user RSS/YouTube reader. Next.js 16 (App Router, `src/`), TypeScript, Tailwind v4, pnpm. Deployed on Vercel Hobby (free) with Neon Postgres (Vercel marketplace, `DATABASE_URL`). PWA installable on iPhone.

## Design (from approved mockup)

- Light neutral: ground `#FAFAF8`, surface `#FFFFFF`, ink `#1A1A1A`, body text `#2A2A2A`, muted `#6B6B6B`, faint `#9A9A9A`, border `#E2E1DC`, hairline `#ECEBE6`, code bg `#F3F2EE`. One accent `#0F6E6E` (selected item left bar, active source name).
- Fonts: Inter (UI), IBM Plex Mono (metadata: source, time, score, counts, section labels). Load via Google Fonts with `next/font/google`.
- Phone (<768px): header "Feed" + mono subline "updated X ago" + refresh button; horizontal filter chips (All, HN ≥ 100, Labs, Blogs, Video); list of items; bottom tab bar Feed / Saved / Sources (44px targets, safe-area padding).
- Desktop (≥1024px): three panes. Sidebar 240px (app name, views All/Saved/Video with counts, Sources group, YouTube group, Filters, "+ Add source"); item list 420px; reading pane fills the rest.
- Item row: 28–36px source badge (favicon `<img>` from `https://www.google.com/s2/favicons?domain=<host>&sz=64`, fallback colored monogram) · title (15px/500) · snippet (13px muted, 2-line clamp, phone only) · mono meta line (source · HN points · comments · relative time) · optional thumbnail on right (72px square for articles, 96×56 16:9 with play glyph + duration badge for videos).
- Reading pane: source badge + mono meta (host · date · read time); action buttons Save / Open original / Share (36px, bordered); 32px title; 640px max-width body at 17px/1.6; hero image; article HTML (sanitized); for YouTube items a 16:9 `<iframe src="https://www.youtube-nocookie.com/embed/<videoId>">` instead of body.
- No emoji; inline stroke SVG icons only. No gradients.

## Data model (Drizzle, Postgres)

```
sources: id serial pk, title text, url text (site/channel url), feed_url text unique, kind enum('rss','youtube'), group text ('labs'|'blogs'|'news'|'aggregator'|'youtube'), icon_url text null, last_fetched_at timestamptz null, last_error text null, created_at
items: id serial pk, source_id fk, guid text, url text, title text, summary text null, content_html text null (extracted full text, cached), author text null, published_at timestamptz, thumbnail_url text null, video_id text null, duration_sec int null, hn_points int null, hn_comments int null, hn_comments_url text null, is_saved bool default false, created_at; unique(source_id, guid); index(published_at desc)
meta: key text pk, value text  — stores 'last_refresh_at'
```

## Seed sources (`src/db/seed.ts`, idempotent upsert by feed_url)

RSS:
- Hacker News (≥100 points): `https://hnrss.org/newest?points=100` — kind rss, group aggregator. Parse `<description>` for "Points: N" and "# Comments: N", comments URL from `<comments>`.
- Ars Technica AI: `https://feeds.arstechnica.com/arstechnica/technology-lab` — news
- The Verge AI: `https://www.theverge.com/rss/ai-artificial-intelligence/index.xml` — news
- TechCrunch AI: `https://techcrunch.com/category/artificial-intelligence/feed/` — news
- MIT Technology Review AI: `https://www.technologyreview.com/topic/artificial-intelligence/feed` — news
- Simon Willison: `https://simonwillison.net/atom/everything/` — blogs
- Anthropic News: `https://www.anthropic.com/rss.xml` — labs (if 404, try `https://www.anthropic.com/news/rss.xml`; record last_error, don't crash)
- OpenAI News: `https://openai.com/news/rss.xml` — labs
- Google DeepMind Blog: `https://deepmind.google/blog/rss.xml` — labs
- Meta AI Blog: `https://ai.meta.com/blog/rss/` — labs

YouTube (`https://www.youtube.com/feeds/videos.xml?channel_id=`), kind youtube, group youtube:
- Matthew Berman UCawZsQWqfGSbCI5yjkdVkTA
- Lenny's Podcast UC6t1O76G0jYXOAoYCm153dA
- Ryan Peterman UCzB7YGrrxDC_POenf86H3_Q
- Claude UCV03SRZXJEz-hchIAogeJOg
- Anthropic UCrDwWp7EBBv4NwvScIpBDOA
- Casually Explained UCr3cBLTYmIK9kY0F_OdFWFQ
- Lex Clips UCJIfeSCssxSC_Dhc5s7woww
- AI Engineer UCLKPca3kwwd-B59HNr-_lvA
- Fireship UCsBjURrPoezykLs9EqgamOA

## Fetching

- `src/lib/fetcher.ts`: `refreshAll({force})` fetches every source in parallel (Promise.allSettled, 15s timeout each, User-Agent "Openfeed/0.1"). Uses `rss-parser` with custom fields for `media:group`/`media:thumbnail`/`yt:videoId`. Upsert items by (source_id, guid). YouTube: thumbnail `https://i.ytimg.com/vi/<id>/hqdefault.jpg`, summary from `media:description`. Generic: thumbnail from `media:content`/`enclosure` image or first `<img>` in content; else null. Set `meta.last_refresh_at`.
- Stale rule: refresh runs if `last_refresh_at` older than 15 min. Triggered by `GET /api/refresh` (also `POST`), called by the client on app open/foreground and by the refresh button. `vercel.json` cron `0 */6 * * *` → `/api/refresh` (Hobby allows daily; use `0 12 * * *`). Protect cron with `CRON_SECRET` header check when set.
- Full text: `GET /api/items/[id]/content` extracts article with `@mozilla/readability` + `linkedom` (NOT jsdom — too heavy for serverless), sanitizes with `sanitize-html` (allow img, pre, code, a, headings, lists, blockquote, figure, figcaption, video, iframe only from youtube-nocookie), caches into `items.content_html`. Skip for youtube kind.

## API (route handlers, JSON)

- `GET /api/items?view=all|saved|video&source=<id>&filter=hn100|labs|blogs&cursor=<iso>&limit=50` → `{items: Item[], nextCursor}` ordered published_at desc. Item includes joined `source {id,title,kind,group,icon_url,host}`.
- `GET /api/sources` → sources.
- `POST /api/sources` `{url}` → detects feed: if YouTube channel URL (`/@handle` or `/channel/UC..`), fetch page, regex `"channelId":"(UC[\w-]{22})"`, build feed url; else try url as feed, else fetch HTML and find `<link rel="alternate" type="application/rss+xml|atom+xml">`. Returns created source. `DELETE /api/sources/[id]`.
- `PATCH /api/items/[id]` `{is_saved}`.
- `GET /api/refresh?force=1`.
- `GET /api/stats` → `{lastRefreshAt}`.

## PWA

- `public/manifest.webmanifest`: name "Openfeed", short_name "Openfeed", display standalone, background `#FAFAF8`, theme `#FAFAF8`, start_url `/`, icons 192/512 (+ maskable) generated as PNG from a simple SVG (rounded square, accent `#0F6E6E`, white feed-arc glyph) — generate PNGs in a script with `sharp` at build-prep time and commit them.
- `<meta name="apple-mobile-web-app-capable">`, `apple-touch-icon` 180px, `viewport-fit=cover`, status bar style default.
- Service worker `public/sw.js` registered on client: cache-first for static assets and app shell, network-first for `/api/*` with cache fallback so last-loaded list opens offline. Keep it hand-written and small; no workbox.

## Non-goals

No auth (single user; optionally `APP_PASSWORD` env → simple cookie gate middleware, off when unset). No X/Twitter. No multi-user.
