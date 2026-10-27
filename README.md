# OpenDispatch

A native RSS and news reader for macOS and iOS, written in SwiftUI. It pulls RSS/Atom feeds, YouTube channels, podcasts, social posts and feedless news pages into one chronological feed, extracts the full text of articles, plays videos and podcasts inline, and sends items to Readwise Reader or a webhook.

Single user, no accounts, no server. Everything is fetched and stored on the device, and iCloud sync keeps your sources, folders, saved items and settings the same on your Macs, iPhones and iPads through the iCloud account they are already signed in to. MIT licensed.

**Download for Mac:** the latest notarized DMG is on the [releases page](https://github.com/gautham-v/opendispatch/releases/latest). The app updates itself through Sparkle (OpenDispatch → Check for Updates…). Requires macOS 15 or later. The iPhone and iPad app (iOS/iPadOS 26 or later) builds from this repo; see [Build from source](#build-from-source).

## Features

**Sources**
- Add a site URL, a feed URL, a YouTube channel (`youtube.com/@handle`) or an Apple Podcasts link, and the app finds the feed (⌘N, the sidebar's add button, or the Sources tab on iPhone).
- Pages with no feed, like `anthropic.com/news`, are added as scraped sources: the app reads the article links off the listing page and each article's Open Graph / JSON-LD metadata.
- Hacker News items link to their comment threads from the reader (and show points and comment counts on iPhone). X, Bluesky, Threads and Mastodon sources collect in the Posts view, and posts from X, Bluesky and Mastodon render with avatars, media, link cards and quoted posts.
- OPML import and export in Settings → Sources. Imported folders become sidebar folders; feeds you already have are skipped.
- Feeds refresh on launch, when the app comes to the foreground (if the last fetch is older than 15 minutes), on a timer while it's open (every 15 minutes by default; Settings → Data), and on ⌘R or pull to refresh. On iOS a background refresh task runs when the system allows. Unsaved items older than 14 days are pruned.

**Sidebar**
- Views: All, Saved, Articles, Posts, Video and Podcasts, with counts, and Highlights under Saved (see below).
- Folders with drag and drop: move sources between folders, reorder sources and folders. Sources in no folder list flat below the folders.
- Pin sources to a Pinned group at the top, hide sources into a collapsed Hidden group, rename, remove. ⌘K filters the source list.

**Reading**
- Selecting an article fetches the page and runs Mozilla Readability (bundled, in a hidden WKWebView with page scripts off), then cleans, sanitizes and caches the text. If the page blocks it, the feed's own full text or a Jina Reader render is used.
- YouTube videos play in an embedded youtube-nocookie player, full width above the title by default. Podcasts play in a native audio player that remembers your position and has playback speeds from 0.8× to 2×.
- Mac: reader tabs, shown like a browser's even when there's one (⌘-click a row, or + / ⌘T for a new tab, ⇧⌘T to reopen a closed one; right-click a tab to pin it) and split view (⌥-click a row, or ⌥⌘S), each pane with its own tabs; a full-screen reader (⇧⌘F).
- Open any link: type or paste it into a new tab's address field (⌘L) and it opens in the reader like an article from a feed, with highlights, read aloud and Copy as Markdown; a YouTube link plays in the video player, and an Apple Podcasts episode link or a direct audio link (.mp3, .m4a, ...) opens as an episode with the audio player (an Apple Podcasts episode also gets the show's notes and, for Copy as Markdown, its transcript when the show's feed has one). A post on X, Bluesky, Mastodon (any server) or LinkedIn (including lnkd.in short links) opens as a post, with its author, text and links, photos or video, quoted post and link card, and its first line as the title; Threads and Instagram posts show their author, text and picture when they will give them without a login, otherwise they say so and link to the original. Opened links stay out of the feed and the source list; save one to keep it (it syncs like other saved items), otherwise it's pruned 14 days after you opened it.
- Read aloud: the headphones button (⇧⌘L on the Mac) speaks the headline and then the article, a sentence at a time, with the system voices, highlighting the sentence being read and scrolling to keep it in view. A player bar steps sentences, pauses, changes speed (0.8× to 2×) and shows elapsed and estimated time; click or tap a sentence to jump there, or select text and choose Read Aloud from Here. On iPhone it keeps going in the background with lock-screen controls. Pick the voice and starting speed in Settings → Playback; better voices download in System Settings → Accessibility → Spoken Content.
- Search across titles, summaries, authors and article text (/ or ⌘F).
- Save, Open original, Share and Send to from the reader.

**Copy as Markdown**
- Copy an item as Markdown to paste into whatever AI you use (or anywhere else): title, source, date, link and the full article text. Videos get their description and YouTube's captions; podcasts get their show notes and the episode's transcript when the feed has one (`<podcast:transcript>`). It's in the reader's Share menu, a row's right-click menu and Edit → Copy as Markdown (⇧⌘C); on iPhone, in the share sheet.
- Right-click a view, folder or source in the sidebar (or use the filter menu on iPhone) for Copy Last 24 Hours / Copy Last 7 Days: each item's title, source, time, link and a short summary, ready to paste with "brief me on this".
- Settings → Integrations can add a line above everything you copy, such as "Summarize this in 5 bullets". The app itself has no AI. YouTube captions come from unofficial endpoints and may stop working when YouTube changes them.

**Highlights and notes**
- Select text in an article and highlight it in yellow, green, blue, pink or purple, or underline it. On the Mac, Control-click (right-click) the selection: the colors and Add Note… come first in the menu, like Apple Books. Click a highlight for a small popover under it: its colors and Underline, a note button, a remove button and the note itself (click it to edit). Control-click a highlight to change its color, edit its note or remove it. On iPhone the edit menu of a selection has Highlight and Add Note, and tapping a highlight opens the same popover. Add Note… and Edit Note… open a note sheet with the quote and a text editor. A highlight with a note has a small marker in the margin beside its first line; nothing sits beside the article, so its width never changes.
- The highlighter button in the reader bar opens Highlights & Notes, a popover with this article's highlights in reading order (the quote, three lines at most, and its note); picking one closes it and scrolls the article to that highlight with a brief flash. It also has Copy as Markdown and the Readwise status. On iPhone it is a sheet.
- The Highlights view (sidebar, under Saved with a count; on iPhone the Saved / Highlights control at the top of the Saved tab) lists every article you highlighted, newest activity first, even ones the app no longer has: opening one brings the article back from its source, or opens the original page when the source is gone. Highlights keep their article from being pruned.
- Highlights are drawn with the CSS Custom Highlight API and found again by their text and the words around it, so they survive a re-extracted article; one that no longer matches stays in the list, marked as not found.

**Send to**
- Readwise Reader (paste an access token from readwise.io/access_token) and/or a webhook of your own, set up in Settings → Integrations. With one target the send button sends straight away; with both it asks which.
- With a Readwise token set, "Send highlights to Readwise" (on by default) sends highlights and notes you make on this device to Readwise through its highlights API, and updates or deletes them there when you edit or remove them. A failure never blocks anything; what is still unsent goes out on the next change or launch.
- The webhook gets a JSON POST with `id`, `url`, `title`, `author`, `published_at`, `summary` and `source { title, host }`. Each target has a test button: the webhook gets a sample payload marked `"test": true`, and the Readwise token is only checked.

**Sync**
- iCloud sync is on by default and needs no sign-up: it uses the device's iCloud account and your private CloudKit database. It carries sources (with their folder, order, pin and hidden state), folders, saved items, highlights and notes, appearance and playback settings, the webhook URL and the Readwise token (as an end-to-end encrypted field). Feed items are not synced; each device fetches its own.
- A new device takes the library already in iCloud: if it still only has the starter sources it was seeded with, the ones iCloud doesn't have are dropped. A device that was already in use merges its library with iCloud's instead, so nothing on it is lost.
- Turn it off per device in Settings → Data. Turning it off keeps the local library; turning it back on picks up what changed on both sides.

**Settings**
- On the Mac, Settings (⌘,) opens as a panel over the main window: Sources, Appearance (theme, reader font Sans or Serif, text size, reader width Narrow / Medium / Wide or fill the window), Playback (autoplay and theater layout for videos, Read aloud voice and speed), Integrations, Data (iCloud sync, refresh interval, database location and size, clear cached article text) and About.
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
| ⇧⌘L | Listen to the article (read aloud), pause or resume |
| g then a / s / v / p | All / Saved / Video / Podcasts |
| ⌘-click | Open in a new tab |
| ⌥-click | Open in split view |
| ⇧⌘] / ⇧⌘[ | Next / previous tab |
| ⌘T | New tab |
| ⌘L | Open a link in a new tab |
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

**iCloud.** The app uses the CloudKit container `iCloud.com.gauthamv.openfeed`, and every build, local or released, uses its Production environment (`com.apple.developer.icloud-container-environment` in the entitlements), so a Mac built from this checkout and a TestFlight iPhone share one library. Production only has the record types deployed to it. Highlights sync as a `Highlight` record type: until it is deployed, highlights stay on the device that made them (they are retried after a relaunch and every 30 minutes) and nothing else is held up. After changing what syncs (`Core/Sources/OpenDispatchCore/Sync/SyncRecord.swift`), update `App/CloudKit/schema.ckdb` to match, import it into Development (CloudKit Console → Import Schema…, or `xcrun cktool import-schema --team-id 26TVJ92MLZ --container-id iCloud.com.gauthamv.openfeed --environment development --file App/CloudKit/schema.ckdb` with a management token from `xcrun cktool save-token`), then use Deploy Schema Changes… before running the new build. Production record types and fields can be added but never removed.

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
