# Openfeed

A personal AI news reader for macOS and iOS. Pulls RSS/Atom feeds, YouTube channels, podcasts and feedless news pages into one chronological feed, extracts full article text, plays videos and podcasts inline, and sends items to Readwise Reader or a webhook.

Single user, no accounts, no server. Everything runs and is stored on the device. Native SwiftUI app (one multiplatform target) on a local Swift package. MIT licensed.

## Requirements

- macOS 15 or later to run the Mac app; iOS/iPadOS 18 or later for iPhone and iPad.
- Xcode 16 or later (built and tested with Xcode 26.3) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Swift packages are fetched by Xcode/SwiftPM on first build: GRDB.swift (SQLite), SwiftSoup (HTML), FeedKit (resolved but not used by the parser).

## Build and run

```bash
cd App
xcodegen generate          # creates Openfeed.xcodeproj and Info.plist from project.yml (both gitignored)
open Openfeed.xcodeproj    # pick the Openfeed scheme, then a Mac or iPhone destination, and Run
```

From the command line:

```bash
cd App
xcodebuild -project Openfeed.xcodeproj -scheme Openfeed -destination 'platform=macOS' build
xcodebuild -project Openfeed.xcodeproj -scheme Openfeed -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build
```

Run `xcodegen generate` again after adding or removing files under `App/Openfeed/`. The Mac build is ad-hoc signed; to install on a physical iPhone, set your team under Signing & Capabilities (or `DEVELOPMENT_TEAM` in `project.yml`).

Core logic tests (feed parsing, detection, OPML, scraping, extraction, refresh, integrations, database):

```bash
cd Core
swift build
swift test                 # set OPENFEED_SKIP_WEBKIT_TESTS=1 to skip the WebKit Readability tests
```

## Where data lives

- Database: a single SQLite file, `openfeed.sqlite` (WAL mode), in the app's Application Support folder:
  - macOS (sandboxed): `~/Library/Containers/com.gauthamv.openfeed/Data/Library/Application Support/Openfeed/`
  - iOS: the app container's `Library/Application Support/Openfeed/`
- Settings → Data shows the path and size, can reveal it in Finder, and can clear cached article text.
- Appearance and playback settings, collapsed folders and podcast positions are in UserDefaults.
- The Readwise token is stored in the Keychain (service `com.gauthamv.openfeed`). The webhook URL is in the database's `meta` table.

The first launch creates the database, seeds the starter sources (list in `Core/Sources/OpenfeedCore/Database/Seed.swift`) and their folders, and runs a refresh.

## How it stays fresh

Feeds are fetched when the app opens or comes to the foreground if the last fetch is older than 15 minutes, every 15 minutes while it is open (change the interval or turn it off in Settings → Data), and when you press refresh (⌘R on the Mac, pull to refresh on iPhone). On iOS a background app refresh task (`com.gauthamv.openfeed.refresh`) also refreshes when the system allows. Items older than 14 days are pruned unless saved.

## Sources

Add sources from the sidebar (Mac/iPad), the Sources tab (iPhone), or ⌘N: paste a site URL, a feed URL, a YouTube channel URL (`youtube.com/@handle`), or an Apple Podcasts link, and the app finds the feed. `openfeed://add?url=<url>` opens the same sheet prefilled.

To move subscriptions in or out, use **Import OPML** / **Export OPML** in Settings → Sources. Import takes an OPML file from Feedly, Inoreader, NetNewsWire and the like: outline folders become sidebar folders (matched to existing ones by name), feeds you already have are skipped, and nothing is fetched until the next refresh. Exports include an `openfeed:kind` attribute so scraped pages and podcasts round-trip.

Pages with no feed (e.g. `anthropic.com/news`) are added as scraped-page sources: the app picks the article links off the listing page and reads each article's Open Graph / JSON-LD metadata. Only new links are fetched on refresh.

## Reading

Selecting an article fetches the page and runs Mozilla Readability (bundled, run in a hidden WKWebView with page scripts off), then cleans and sanitizes the HTML and caches it in the database. If the page is blocked, the feed's own full text or a Jina Reader render is used instead. YouTube items play in an embedded youtube-nocookie player; podcast episodes play with a native audio player that remembers your position.

Keyboard (Mac and iPad with a keyboard): j/k or arrows to move, o or Return to open the original, s to save, r to refresh, / to search, g then a/s/v/p to switch views, ? for the full list.

## Send to

The reader's send button sends the open item to Readwise Reader or to a webhook of your own. Set them up in Settings → Integrations: paste a Readwise access token (from readwise.io/access_token) and/or a webhook URL. With one target set up the button sends straight away; with both it asks which. The webhook gets a JSON POST with `id`, `url`, `title`, `author`, `published_at`, `summary` and `source { title, host }` (10 s timeout). Each target has a test button: the webhook gets a sample payload marked `"test": true`, and the Readwise token is only checked, so nothing is added to your library.

## Layout

- `Core/` — Swift package `OpenfeedCore`: models, SQLite schema and queries (GRDB), feed parsing, feed detection and OPML, page scraping, article extraction (Readability.js in WebKit + SwiftSoup), refresh pipeline, Readwise/webhook integrations. Tests in `Core/Tests`.
- `App/` — SwiftUI app `Openfeed` for macOS and iOS: `project.yml` (XcodeGen), `Openfeed/Model` (AppModel, settings, background refresh), `Openfeed/Design` (colors, type, icons), `Openfeed/Views` (sidebar, item list, reader, sources, settings).
- `PORT.md` — the module contract and design notes from the port to Swift.
- `SPEC.md` — product spec: design, data model, behavior.
