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
        if let shared = await firstSharedURL(),
           let deepLink = KeraunosDeepLink.url(forMediaURL: shared.absoluteString) {
            openHostApp(deepLink)
        }
        // Always complete, even on a miss, so the share sheet doesn't hang.
        extensionContext?.completeRequest(returningItems: nil)
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

    /// A share extension can't reach `UIApplication.shared`, so walk the responder chain
    /// to find the object that responds to `openURL:` (the application) and ask it to open
    /// our scheme. `extensionContext.open(_:)` is documented to be unreliable for share
    /// extensions, so this is the dependable path.
    private func openHostApp(_ url: URL) {
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }
}
