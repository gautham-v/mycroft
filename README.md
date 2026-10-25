# Openfeed

A personal AI news reader. Pulls RSS feeds and YouTube channels into one chronological feed, extracts full article text, plays videos inline, and installs as a PWA on your phone.

Single user, no accounts. Next.js 16 · Postgres (Neon) · Vercel. MIT licensed.

## Deploy (about 5 minutes, free)

1. **Import the repo on Vercel.** Go to [vercel.com/new](https://vercel.com/new) and pick your fork of this repo. Leave the framework and build settings as detected.

2. **Add a database.** On the same import screen, under Optional Integrations, click **Add** next to Neon, choose the Free plan, and when asked for an environment-variable prefix enter `DATABASE` so the app gets `DATABASE_URL`. (Or add it later from the project's **Storage** tab and redeploy.) Then click **Deploy**.

   Tables are created and the starter sources are seeded on first request. No migration step.

   If your Vercel team has Deployment Protection on, turn off "Vercel Authentication" in Settings → Deployment Protection, otherwise the PWA and cron can't reach the app.

3. **Optional env vars** (Settings → Environment Variables):
   - `APP_PASSWORD` — a password for the whole app. Off when unset. Set it if the URL might leak; the app is otherwise public.
   - `CRON_SECRET` — any random string. Lets the daily Vercel cron hit `/api/refresh` when `APP_PASSWORD` is on.

4. **Install on iPhone.** Open the Vercel URL in Safari → Share → **Add to Home Screen**. It runs full-screen with its own icon. On Android, Chrome offers "Install app".

## How it stays fresh

Feeds are fetched when you open the app (or bring it back to the foreground) if the last fetch is older than 15 minutes, and when you tap refresh. A Vercel cron (`vercel.json`) also runs every 30 minutes. On the Hobby plan crons are limited to once a day; change the schedule to `0 12 * * *` there.

## Sources

Starter list is in `src/db/seed.ts`. Add more from the sidebar (desktop) or Sources tab (phone): paste a site URL, a feed URL, or a YouTube channel URL (`youtube.com/@handle`), and the app finds the feed.

Pages with no feed (e.g. `anthropic.com/news`, `claude.com/resources/articles`) are added as scraped-page sources: the app picks the article links off the listing page and reads each article's Open Graph / JSON-LD metadata. Only new links are fetched on refresh. Anthropic and Meta AI don't publish RSS feeds, so they're not seeded (Anthropic's YouTube channel is). Ars Technica and The Verge block non-browser user agents; the fetcher sends a browser-like UA.

## Local development

```bash
pnpm install
cp .env.example .env.local   # set DATABASE_URL to any Postgres (Neon free tier works)
pnpm dev
```

Scripts: `pnpm db:push` (apply schema), `pnpm db:seed`, `pnpm test:parse` (feed parser checks), `pnpm tsx scripts/live-check.ts` (hit every seeded feed), `pnpm tsx scripts/scrape-check.ts <url>` (preview a scraped-page source), `pnpm tsx scripts/make-icons.ts` (regenerate PWA icons).

## Layout

- `src/db` — Drizzle schema, Neon client with lazy `ensureSchema()` + seed
- `src/lib` — feed fetching/parsing, readability extraction, feed URL detection
- `src/app/api` — route handlers (`/items`, `/sources`, `/refresh`, `/stats`, …)
- `src/components` — UI (phone list, three-pane desktop, reader)
- `public/sw.js`, `public/manifest.webmanifest` — PWA
