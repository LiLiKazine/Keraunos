import Foundation
import KeraunosCore

/// Runs yt-dlp extraction inside the embedded interpreter. A custom serial
/// executor backed by a dedicated DispatchSerialQueue means this actor's work
/// runs on its own thread — NOT the Swift cooperative pool — so the blocking
/// Python C call is safe to make, and actor isolation serializes access to the
/// single (GIL-bound) interpreter and protects `initialized`. Actors are
/// Sendable, so no @unchecked / nonisolated(unsafe) / continuation needed.
actor PythonExtractor: MediaExtracting {
    private let queue = DispatchSerialQueue(label: "io.github.lilikazine.Keraunos.python")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var initialized = false   // ordinary actor-isolated state

    private let cookieProvider: (any CookieProviding)?
    private let timeout: Duration

    init(cookieProvider: (any CookieProviding)? = nil, timeout: Duration = .seconds(45)) {
        self.cookieProvider = cookieProvider
        self.timeout = timeout
    }

    func listFormats(_ url: URL) async throws -> FormatListing {
        try ensureInitialized()
        let cookieURL = await cookieProvider?.cookieFile()
        defer { if let cookieURL { try? FileManager.default.removeItem(at: cookieURL) } }
        let cookiePath = cookieURL?.path
        return try await withTimeout(timeout) { [self] in
            try await blockingList(url, cookiePath: cookiePath)
        }
    }

    // Only the extraction call is bounded: ensureInitialized() (first-call
    // Python init) and the cookieProvider hop above run before the timeout
    // window. The blocking C call runs on this actor's serial executor (via the
    // actor-isolated blockingExtract); the timeout's timer runs on the
    // cooperative pool. On timeout the C call is orphaned on the serial
    // executor until it returns — the next resolve queues behind it.
    func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia {
        try ensureInitialized()
        let cookieURL = await cookieProvider?.cookieFile()
        defer { if let cookieURL { try? FileManager.default.removeItem(at: cookieURL) } }
        let cookiePath = cookieURL?.path
        return try await withTimeout(timeout) { [self] in
            try await blockingExtract(url, cookiePath: cookiePath, option: option)
        }
    }

    private func blockingList(_ url: URL, cookiePath: String?) throws -> FormatListing {
        guard let cString = keraunos_python_list_formats(url.absoluteString, cookiePath) else {
            throw KeraunosError.runtime(detail: "null extraction result")
        }
        defer { free(cString) }
        return try ExtractionDecoder.decodeListing(Data(String(cString: cString).utf8))
    }

    private func blockingExtract(_ url: URL, cookiePath: String?, option: FormatOption?) throws -> ResolvedMedia {
        guard let cString = keraunos_python_extract(url.absoluteString, cookiePath,
                                                    option?.formatID, (option?.isAdaptive ?? false) ? 1 : 0) else {
            throw KeraunosError.runtime(detail: "null extraction result")
        }
        defer { free(cString) }
        return try ExtractionDecoder.decode(Data(String(cString: cString).utf8))
    }

    private func ensureInitialized() throws {
        guard !initialized else { return }
        guard let resources = Bundle.main.resourceURL else {
            throw KeraunosError.runtime(detail: "no resource bundle")
        }
        // b14 layout: stdlib at <resources>/python (PYTHONHOME, populated by the
        // install_python build phase), our module at <resources>/app, vendored
        // packages at <resources>/app_packages, CA bundle at <resources>/app.
        let caCert = resources.appendingPathComponent("app/cacert.pem")
        let status = keraunos_python_init(resources.path, caCert.path)
        guard status == 0 else { throw KeraunosError.runtime(detail: "python init failed (\(status))") }
        initialized = true
    }
}
