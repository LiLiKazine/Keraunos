# Share / deep-link a URL into Keraunos

> The app-side **receiving** logic is built and tested (`IncomingURL`,
> `DownloadViewModel.openIncoming`, `.onOpenURL`). What remains are two Xcode/device
> steps that this loop can't safely do (project-file + signing + on-device verification).

## What already works (in-app, tested)
- `IncomingURL.target(from:)` resolves either a direct `http(s)` link or a
  `keraunos://download?url=<encoded>` deep link to a normalized media URL (else nil).
- `openIncoming(_:)` fills the field and starts the download; garbage is ignored.
- `.onOpenURL { model.openIncoming($0) }` is wired on the main screen, so the moment a
  scheme or extension delivers a URL, it just works. Verified by unit tests + app build.

## Owner step 1 — register the URL scheme (enables Shortcuts / deep links now)
In the Keraunos target's Info settings, add a URL Type:
- **Identifier:** `io.github.lilikazine.Keraunos`
- **URL Schemes:** `keraunos`

Then `keraunos://download?url=https%3A%2F%2Fyoutu.be%2F…` opens the app and auto-downloads.
Test from Safari or a one-line Shortcut. (If the target uses a generated Info.plist,
add `CFBundleURLTypes` via a custom Info.plist or the target's Info tab.)

## Owner step 2 — add the Share Extension target (the headline entry point)
1. File ▸ New ▸ Target ▸ **Share Extension** (e.g. `KeraunosShareExtension`).
2. Restrict its `NSExtensionActivationRule` to URLs (and optionally web pages) so it
   appears when sharing a link from YouTube/Safari/etc.
3. In the extension, read the shared URL from the `NSExtensionItem` attachments and
   forward it to the app via the scheme:
   `keraunos://download?url=<percent-encoded>` using `openURL`/`extensionContext`.
4. The app's existing `.onOpenURL` → `openIncoming` path takes it from there — no further
   app-side code needed.
5. Sign both targets with your team; verify on a real device (share a video link from
   the YouTube app → Keraunos opens and downloads).

## Why split this way
Adding a target + entitlements + signing is one-click in Xcode but risky to hand-edit in
`project.pbxproj`, and a share extension is meaningless without on-device verification.
So the deterministic, testable half lives in code now; the device half is yours.
