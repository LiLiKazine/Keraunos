import Testing

/// Parent suite for tests that share the process-global `StubURLProtocol`
/// handler/lastRequest. `.serialized` is recursive, so it keeps the nested
/// `DownloaderTests` and `MediaAssemblerTests` from running concurrently — they
/// would otherwise race on that shared stub state.
@Suite(.serialized)
struct StubNetworkSuite {}
