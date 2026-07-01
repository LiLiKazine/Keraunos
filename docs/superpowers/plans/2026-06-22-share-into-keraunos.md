# Share / deep-link a URL into Keraunos

> ✅ **DONE — verified on-device (2026-07-01).** Sharing a YouTube link → tapping Keraunos
> now foregrounds the app and auto-starts the download. Everything below is kept as the
> record of how it was built and the one gotcha that bit us.
>
> **iOS 18+ gotcha (cost a debug cycle):** a share extension must open the host app via
> the responder chain calling `open(_:options:completionHandler:)` — the deprecated
> `openURL:` selector is blocked ("BUG IN CLIENT OF UIKIT …") and silently fails — and
> must defer `completeRequest` into that completion handler or the open is cancelled.
> See `KeraunosShareExtension/ShareViewController.swift` and commit 7009d1e.

## What already works (in code, tested / built)
- `IncomingURL.target(from:)` resolves a direct `http(s)` link or a
  `keraunos://download?url=<encoded>` deep link to a normalized media URL (else nil).
- `KeraunosDeepLink` (in `KeraunosCore`) is the single source of truth for the scheme/
  host/param and the percent-encoding. `IncomingURL` parses via it, and a **round-trip
  test** (`KeraunosDeepLinkTests`) proves anything the builder produces, `IncomingURL`
  recovers unchanged — including URLs with `&`/`=` (the classic dropped-`&t=…` trap).
- `openIncoming(_:)` fills the field and starts the download; garbage is ignored.
- `.onOpenURL { model.openIncoming($0) }` is wired on the main screen.
- ✅ **`keraunos://` scheme is registered** in `app/Keraunos/Info.plist`
  (`CFBundleURLTypes`). Deep links + Shortcuts work now — test from Safari or a one-line
  Shortcut: `keraunos://download?url=https%3A%2F%2Fyoutu.be%2F…`.
- ✅ **Share Extension source is written** at `app/Keraunos/KeraunosShareExtension/`
  (`ShareViewController.swift` + `Info.plist`). It's a no-UI extension that pulls the
  shared URL, builds the deep link via `KeraunosDeepLink`, opens the host app, and
  dismisses. **Not yet compiled** — it has no target, so its first build is on-device.

## Owner step — add the Share Extension target (Xcode, ~5 min)
1. **File ▸ New ▸ Target ▸ Share Extension.** Name it `KeraunosShareExtension`. Let
   Xcode create it; bundle id becomes `io.github.lilikazine.Keraunos.KeraunosShareExtension`.
   Xcode auto-adds it to the app's *Embed Foundation Extensions* phase + a target
   dependency — leave those.
2. **Replace the generated boilerplate with the prepared source:**
   - Overwrite the generated `ShareViewController.swift` with
     `app/Keraunos/KeraunosShareExtension/ShareViewController.swift` (or delete the
     generated file and add this one to the target).
   - Replace the generated `Info.plist`'s `NSExtension` dict with the prepared
     `app/Keraunos/KeraunosShareExtension/Info.plist`.
   - **Delete** the generated `MainInterface.storyboard` and remove any
     `NSExtensionMainStoryboard` key — this extension is programmatic
     (`NSExtensionPrincipalClass`), no UI.
3. **Add the `KeraunosCore` dependency** to the extension target: target ▸ General ▸
   *Frameworks and Libraries* ▸ + ▸ `KeraunosCore`. (The source imports it for
   `KeraunosDeepLink`.)
4. **Set deployment target to iOS 26.5** and sign with your team (both targets).
5. **Verify on a real device:** share a video link from the YouTube app / Safari →
   tap Keraunos → the app opens and the download starts. Also confirm sharing an image
   does *not* offer Keraunos (the activation rule is web-URL/text only).

## Why split this way
Adding a target + signing is one-click in Xcode but risky to hand-edit in `project.pbxproj`
(format 77, embed phases, container proxies), and a share extension is meaningless without
on-device verification. So everything deterministic and testable lives in code now; the
target + device check are yours.

## Note on the open-the-app mechanism
A share extension can't reach `UIApplication.shared`. `extensionContext.open(_:)` is
documented to be unreliable for share extensions, so `ShareViewController` walks the
responder chain to the object that responds to `openURL:` and asks it to open the
`keraunos://` URL. If a future iOS breaks this, the App Group + shared-container handoff
is the fallback (extension writes the URL; app reads it on next launch — but that loses
the one-tap "share → opens and downloads" UX).
