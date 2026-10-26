# OpenDispatch
Shown as **OpenDispatch** (the App Store name). The Xcode target, the `OpenfeedCore` package and the bundle id `com.gauthamv.openfeed` keep the original name Openfeed.
A personal AI news reader for macOS and iOS. Pulls RSS/Atom feeds, YouTube channels, podcasts and feedless news pages into one chronological feed, extracts full article text, plays videos and podcasts inline, and sends items to Readwise Reader or a webhook.
Single user, no accounts, no server. Everything runs and is stored on the device. Native SwiftUI app (one multiplatform target) on a local Swift package. MIT licensed.

## Requirements

- macOS 15 or later to run the Mac app; iOS/iPadOS 26 or later for iPhone and iPad (the iPhone UI uses Liquid Glass).
- Xcode 26 or later (built and tested with Xcode 26.3; the iOS 26 SDK is required) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Swift packages are fetched by Xcode/SwiftPM on first build: GRDB.swift (SQLite) and SwiftSoup (HTML). Feeds are parsed with Foundation's `XMLParser`.

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
xcodebuild -project Openfeed.xcodeproj -scheme Openfeed -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build   # any iOS 26 simulator
```

To keep `/Applications/OpenDispatch.app` current, run `scripts/install-hooks.sh` once per clone. It adds post-commit and post-merge hooks: every commit, merge or pull on `main` that touches `App/` or `Core/` builds Release in the background, quits the app, replaces it in `/Applications` and relaunches it (log in `App/build/install.log`, a notification if the build fails). `scripts/install-mac.sh` does the same by hand.

The app icon and the in-app logo are rendered from `design/app-icon.svg`. After editing it, run `scripts/render-icons.sh` (needs Google Chrome and ImageMagick) to regenerate the PNGs in `Assets.xcassets`.

**Releasing the Mac app** (direct download, updates through [Sparkle](https://sparkle-project.org)): bump `CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION` if it changes) in `project.yml`, commit, then run `scripts/release-mac.sh`. It archives, signs with the Developer ID certificate, notarizes and staples the app and a DMG, and writes `appcast.xml` signed with the Sparkle EdDSA key in the login keychain (export a backup with `generate_keys -x`; losing it means existing installs can't verify updates). It needs `~/.appstoreconnect/opendispatch.env` with the App Store Connect API key for notarization. Attach the DMG and `appcast.xml` to a GitHub release tagged `v<MARKETING_VERSION>`; installed copies read the latest release's `appcast.xml`.

Run `xcodegen generate` again after adding or removing files under `App/Openfeed/`. Both platforms use automatic signing with team `26TVJ92MLZ` (`DEVELOPMENT_TEAM` in `project.yml`); the Mac build signs with the Apple Development certificate in the keychain. To run on a real iPhone, sign in to that team's Apple ID in Xcode → Settings → Accounts, connect the phone, pick it as the destination and Run; Xcode creates the provisioning profile for `com.gauthamv.openfeed`. From the command line, once Xcode is signed in: `xcodebuild -project Openfeed.xcodeproj -scheme Openfeed -destination 'generic/platform=iOS' -allowProvisioningUpdates build`.

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

Add sources from the sidebar (Mac/iPad), the Sources tab (iPhone), or ⌘N: paste a site URL, a feed URL, a YouTube channel URL (`youtube.com/@handle`), or an Apple Podcasts link, and the app finds the feed. `opendispatch://add?url=<url>` opens the same sheet prefilled. `opendispatch://settings?tab=data` opens Settings on a pane (sources, appearance, playback, integrations, data, about).

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
