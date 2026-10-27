# OpenDispatch

A native RSS and news reader for macOS and iOS, written in SwiftUI. It pulls RSS/Atom feeds, YouTube channels, podcasts, social posts and feedless news pages into one chronological feed, extracts the full text of articles, plays videos and podcasts inline, and sends items to Readwise Reader or a webhook.

Single user, no accounts, no server. Everything is fetched and stored on the device, and iCloud sync keeps your sources, folders, saved items and settings the same on your Macs, iPhones and iPads through the iCloud account they are already signed in to. MIT licensed.

**Download for Mac:** the latest notarized DMG is on the [releases page](https://github.com/gautham-v/opendispatch/releases/latest). The app updates itself through Sparkle (OpenDispatch → Check for Updates…). Requires macOS 15 or later. The iPhone and iPad app (iOS/iPadOS 26 or later) builds from this repo; see [Build from source](#build-from-source).

## Features

**Sources**
- Add a site URL, a feed URL, a YouTube channel (`youtube.com/@handle`) or an Apple Podcasts link, and the app finds the feed (⌘N, the sidebar's add button, or the Sources tab on iPhone).
- Pages with no feed, like `anthropic.com/news`, are added as scraped sources: the app reads the article links off the listing page and each article's Open Graph / JSON-LD metadata.
- Hacker News items link to their comment threads from the reader (and show points and comment counts on iPhone). X, Bluesky, Threads and Mastodon sources collect in the Posts view, and X posts render with avatars, link cards and quoted posts.
- OPML import and export in Settings → Sources. Imported folders become sidebar folders; feeds you already have are skipped.
- Feeds refresh on launch, when the app comes to the foreground (if the last fetch is older than 15 minutes), on a timer while it's open (every 15 minutes by default; Settings → Data), and on ⌘R or pull to refresh. On iOS a background refresh task runs when the system allows. Unsaved items older than 14 days are pruned.

**Sidebar**
- Views: All, Saved, Articles, Posts, Video and Podcasts, with counts.
- Folders with drag and drop: move sources between folders, reorder sources and folders. Sources in no folder list flat below the folders.
- Pin sources to a Pinned group at the top, hide sources into a collapsed Hidden group, rename, remove. ⌘K filters the source list.

**Reading**
- Selecting an article fetches the page and runs Mozilla Readability (bundled, in a hidden WKWebView with page scripts off), then cleans, sanitizes and caches the text. If the page blocks it, the feed's own full text or a Jina Reader render is used.
- YouTube videos play in an embedded youtube-nocookie player, full width above the title by default. Podcasts play in a native audio player that remembers your position and has playback speeds from 0.8× to 2×.
- Mac: reader tabs, shown like a browser's even when there's one (⌘-click a row, or + / ⌘T for a new tab, ⇧⌘T to reopen a closed one; right-click a tab to pin it) and split view (⌥-click a row, or ⌥⌘S), each pane with its own tabs; a full-screen reader (⇧⌘F).
- Search across titles, summaries, authors and article text (/ or ⌘F).
- Save, Open original, Share and Send to from the reader.

**Copy as Markdown**
- Copy an item as Markdown to paste into whatever AI you use (or anywhere else): title, source, date, link and the full article text. Videos get their description and YouTube's captions; podcasts get their show notes and the episode's transcript when the feed has one (`<podcast:transcript>`). It's in the reader's Share menu, a row's right-click menu and Edit → Copy as Markdown (⇧⌘C); on iPhone, in the share sheet.
- Right-click a view, folder or source in the sidebar (or use the filter menu on iPhone) for Copy Last 24 Hours / Copy Last 7 Days: each item's title, source, time, link and a short summary, ready to paste with "brief me on this".
- Settings → Integrations can add a line above everything you copy, such as "Summarize this in 5 bullets". The app itself has no AI. YouTube captions come from unofficial endpoints and may stop working when YouTube changes them.

**Send to**
- Readwise Reader (paste an access token from readwise.io/access_token) and/or a webhook of your own, set up in Settings → Integrations. With one target the send button sends straight away; with both it asks which.
- The webhook gets a JSON POST with `id`, `url`, `title`, `author`, `published_at`, `summary` and `source { title, host }`. Each target has a test button: the webhook gets a sample payload marked `"test": true`, and the Readwise token is only checked.

**Sync**
- iCloud sync is on by default and needs no sign-up: it uses the device's iCloud account and your private CloudKit database. It carries sources (with their folder, order, pin and hidden state), folders, saved items, appearance and playback settings, the webhook URL and the Readwise token (as an end-to-end encrypted field). Feed items are not synced; each device fetches its own.
- A new device takes the library already in iCloud: if it still only has the starter sources it was seeded with, the ones iCloud doesn't have are dropped. A device that was already in use merges its library with iCloud's instead, so nothing on it is lost.
- Turn it off per device in Settings → Data. Turning it off keeps the local library; turning it back on picks up what changed on both sides.

**Settings**
- On the Mac, Settings (⌘,) opens as a panel over the main window: Sources, Appearance (theme, reader font Sans or Serif, text size, reader width Narrow / Medium / Wide or fill the window), Playback (autoplay, theater layout for videos), Integrations, Data (iCloud sync, refresh interval, database location and size, clear cached article text) and About.
- iPhone uses Liquid Glass system bars and a Feed / Sources / Saved / Settings tab bar.

**Links**
- `opendispatch://add?url=<url>` opens Add source prefilled with that URL.
- `opendispatch://settings?tab=<sources|appearance|playback|integrations|data|about>` opens Settings on that pane.

## Keyboard shortcuts

Mac, and iPad with a hardware keyboard. `?` or ⌘/ shows this list in the app.

| Keys | Action |
| --- | --- |
| j or ↓ / k or ↑ | Next / previous item |
| o or Enter | Open the original in the browser |
| s | Save or unsave |
| ⇧⌘R | Reload the article (extract it again) |
| ⇧⌘C | Copy the item as Markdown |
| g then a / s / v / p | All / Saved / Video / Podcasts |
| ⌘-click | Open in a new tab |
| ⌥-click | Open in split view |
| ⇧⌘] / ⇧⌘[ | Next / previous tab |
| ⌘T | New tab |
| ⌘W | Close the tab |
| ⇧⌘T | Reopen the last closed tab |
| ⌥⌘S | Split view on or off |
| / or ⌘F | Search |
| ⌘K | Filter sources in the sidebar |
| r or ⌘R | Refresh feeds |
| ⌘N | Add a source |
| ⌘\ | Show or hide the sidebar |
| ⇧⌘F | Full-screen reader |
| Esc | Clear the source filter or search, or leave full screen |
| ⌘, | Settings |
| ? or ⌘/ | Show the shortcuts |

## Build from source

Needs Xcode 26 or later (the iOS 26 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Swift packages (GRDB.swift, SwiftSoup, Sparkle) are fetched on the first build.

```bash
cd App
xcodegen generate             # creates OpenDispatch.xcodeproj and Info.plist from project.yml (both gitignored)
open OpenDispatch.xcodeproj   # pick the OpenDispatch scheme, then a Mac or iPhone destination, and Run
```

From the command line:

```bash
cd App
xcodebuild -project OpenDispatch.xcodeproj -scheme OpenDispatch -destination 'platform=macOS' build
xcodebuild -project OpenDispatch.xcodeproj -scheme OpenDispatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Run `xcodegen generate` again after adding or removing files under `App/OpenDispatch/`. Signing is automatic with team `26TVJ92MLZ` (`DEVELOPMENT_TEAM` in `project.yml`); change it to your own team to build on your machine. For a real iPhone, sign in to the team in Xcode → Settings → Accounts and run on the device, or `xcodebuild -project OpenDispatch.xcodeproj -scheme OpenDispatch -destination 'generic/platform=iOS' -allowProvisioningUpdates build`.

Core tests (feed parsing, detection, OPML, scraping, extraction, refresh, integrations, database):

```bash
cd Core
swift test                    # OPENDISPATCH_SKIP_WEBKIT_TESTS=1 skips the WebKit Readability tests
```

To keep `/Applications/OpenDispatch.app` current while developing, run `scripts/install-hooks.sh` once per clone. Every commit, merge or pull on `main` that touches `App/` or `Core/` then builds Release in the background and replaces and relaunches the installed app (log in `App/build/install.log`). `scripts/install-mac.sh` does the same by hand. The hooks also keep AI co-author trailers out of commit messages.

The app icon and in-app logo are rendered from `design/app-icon.svg` with `scripts/render-icons.sh` (needs Google Chrome and ImageMagick). The toolbar and sidebar icons are custom SF Symbols generated by `scripts/make-icons.swift`.

## Releasing

**Mac.** Bump `CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION` when it changes) in `App/project.yml`, commit, then run `scripts/release-mac.sh`. It builds from a clean worktree of the commit, archives, signs with Developer ID, notarizes and staples the app and a DMG, and writes a Sparkle `appcast.xml` signed with the EdDSA key in the login keychain (keep a backup with `generate_keys -x`; without it existing installs can't verify updates). It needs `~/.appstoreconnect/opendispatch.env` with an App Store Connect API key for notarization. Output is in `App/build/release/`; publish with the `gh release create v<version> …` command the script prints. Installed copies read `appcast.xml` from the latest release.

**iCloud.** The app uses the CloudKit container `iCloud.com.gauthamv.openfeed`, and every build, local or released, uses its Production environment (`com.apple.developer.icloud-container-environment` in the entitlements), so a Mac built from this checkout and a TestFlight iPhone share one library. Production only has the record types deployed to it. After changing what syncs (`Core/Sources/OpenDispatchCore/Sync/SyncRecord.swift`), update `App/CloudKit/schema.ckdb` to match, import it into Development (CloudKit Console → Import Schema…, or `xcrun cktool import-schema --team-id 26TVJ92MLZ --container-id iCloud.com.gauthamv.openfeed --environment development --file App/CloudKit/schema.ckdb` with a management token from `xcrun cktool save-token`), then use Deploy Schema Changes… before running the new build. Production record types and fields can be added but never removed.

**iOS.** `scripts/release-ios.sh` archives the app from a clean worktree of the commit, uploads it to App Store Connect, waits for processing and adds the build to the TestFlight Internal group (`scripts/asc-distribute.swift`), which doesn't pick up new builds on its own. Bump `CURRENT_PROJECT_VERSION` first; App Store Connect rejects a build number it has seen.

## Where data lives

- Database: one SQLite file (WAL mode), `openfeed.sqlite`, in Application Support/OpenDispatch. On macOS that's `~/Library/Containers/com.gauthamv.openfeed/Data/Library/Application Support/OpenDispatch/`. Settings → Data shows the path and size.
- Appearance and playback settings, sidebar state and podcast positions are in UserDefaults. The Readwise token is in the Keychain; the webhook URL is in the database.
- iCloud sync: records in a zone named `OpenDispatch` in your private CloudKit database. The database's `sync_records` table remembers what was last synced per record, and `sync_meta` holds the sync engine's state.
- The first launch creates the database, seeds a starter set of sources and folders (`Core/Sources/OpenDispatchCore/Database/Seed.swift`) and refreshes.

The app was called Openfeed before it was renamed. The bundle id `com.gauthamv.openfeed`, the background task id, UserDefaults keys, the Keychain item, the database file name and the `openfeed:kind` attribute in OPML exports keep that name so existing installs, settings, data and TestFlight builds carry over.

## Project layout

- `App/` — the SwiftUI app, one multiplatform target for macOS and iOS. `project.yml` (XcodeGen); `OpenDispatch/Model` (AppModel, settings, background refresh), `OpenDispatch/Design` (colors, type, icons), `OpenDispatch/Views` (sidebar, item list, reader, sources, settings), `OpenDispatch/Resources` (assets, reader stylesheet).
- `Core/` — Swift package `OpenDispatchCore` with all the logic: models, SQLite schema and queries (GRDB), feed parsing, feed detection and OPML, page scraping, article extraction (Readability.js in WebKit plus SwiftSoup), the refresh pipeline, the Readwise/webhook integrations and iCloud sync (`Sync/`). Tests in `Core/Tests`.
- `scripts/` — release, local install, git hooks and icon generation.
- `design/` — the app icon source.
- `SPEC.md` — product spec: design, data model, behavior.
- `PORT.md` — the module contract written for the port from the original Next.js web app to Swift.
