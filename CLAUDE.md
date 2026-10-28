# OpenDispatch

Native SwiftUI RSS/news reader for macOS and iOS. `SPEC.md` is the build spec and `PORT.md` the module-level contract; read them before changing behavior. The app was previously named Openfeed, so the bundle id is still `com.gauthamv.openfeed`.

## Typography

No monospace font in the app UI. Use the system sans (SF) for UI and metadata lines and a serif (New York, `.design(.serif)`) for article text. Monospace is allowed only for `<pre>`/`<code>` inside articles (`reader.css`); `.monospacedDigit()` on counters is fine. Don't bundle font files or reintroduce a mono metadata style. See `SPEC.md` and `App/OpenDispatch/Design/Typography.swift`.

## Testing on iPhone

Push a TestFlight build with `scripts/release-ios.sh` instead of installing over a cable from Xcode. Bump `CURRENT_PROJECT_VERSION` in `App/project.yml` first; App Store Connect rejects a build number it has seen. The script archives from a clean worktree, uploads, waits for processing, and adds the build to the Internal TestFlight group through `scripts/asc-distribute.swift`.

- It needs `~/.appstoreconnect/opendispatch.env` (`ASC_KEY_ID`, `ASC_ISSUER`, `ASC_KEY` path to the `.p8`). Those credentials live only on the maintainer's Mac; never commit them or paste them into docs.
- App Store Connect app records can't be created through the API; they are made in the web UI.
- Export compliance is automatic (`ITSAppUsesNonExemptEncryption` is false).
- Builds in an external TestFlight group need Beta App Review; the Internal group does not, so use it for device testing.
- Mac releases are a separate flow (`scripts/release-mac.sh`: Developer ID, notarization, Sparkle appcast).
