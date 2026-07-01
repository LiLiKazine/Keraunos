import UIKit
import UniformTypeIdentifiers
import KeraunosCore

/// A no-UI share extension. When the user shares a link to Keraunos, it pulls the URL out
/// of the shared item, forwards it to the app as `keraunos://download?url=…`, and
/// dismisses immediately. The app's `.onOpenURL` → `IncomingURL` path does the actual
/// download — the extension itself downloads nothing.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await forwardSharedURL() }
    }

    private func forwardSharedURL() async {
        guard let shared = await firstSharedURL(),
              let deepLink = KeraunosDeepLink.url(forMediaURL: shared.absoluteString) else {
            // Nothing usable was shared — just dismiss so the sheet doesn't hang.
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        openHostApp(deepLink)   // completes the request inside its completion handler
    }

    /// The first usable URL among the shared attachments: a `public.url` item (a link
    /// shared from Safari / the YouTube app) if present, else a URL found inside shared
    /// plain text (some apps share "caption https://… " as text).
    private func firstSharedURL() async -> URL? {
        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
            .flatMap { $0.attachments ?? [] }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            if let url = item as? URL { return url }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            if let text = item as? String, let url = Self.firstURL(in: text) { return url }
        }
        return nil
    }

    private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url
    }

    /// Opens the host app with our `keraunos://` URL by walking the responder chain to the
    /// `UIApplication` and calling the non-deprecated `open(_:options:completionHandler:)`.
    ///
    /// Two iOS 18+ gotchas this avoids:
    /// - A share extension can't touch `UIApplication.shared`, and the old `openURL:`
    ///   selector is now blocked outright — UIKit logs "BUG IN CLIENT OF UIKIT … migrate
    ///   to open(_:options:completionHandler:)" and returns false without opening.
    /// - `completeRequest` is deferred into the completion handler: tearing the extension
    ///   down before the open dispatches cancels it (the app never comes forward).
    private func openHostApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:]) { [weak self] _ in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
                return
            }
            responder = current.next
        }
        // No UIApplication in the responder chain — nothing to open; dismiss.
        extensionContext?.completeRequest(returningItems: nil)
    }
}
