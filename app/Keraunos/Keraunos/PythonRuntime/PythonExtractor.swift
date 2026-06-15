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

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        try ensureInitialized()
        guard let cString = keraunos_python_extract(url.absoluteString) else {
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
