import Foundation

/// Sink for non-fatal transfer failures that arise in delegate-driven, non-throwing paths
/// (a persist that fails, a temp file that won't delete). Such an error can't be propagated
/// to a caller, but it must not vanish: recording it here makes it observable and diagnosable,
/// while the crash-consistent state machine provides the actual recovery (retry on next launch,
/// orphan GC). The app target adapts the existing `FailureLog` to this seam.
public protocol TransferDiagnostics: Sendable {
    /// Records a failure. `kind` is a stable slug for grouping; `detail` is free text
    /// (redaction of any embedded secrets is the sink's responsibility).
    func record(kind: String, detail: String)
}
