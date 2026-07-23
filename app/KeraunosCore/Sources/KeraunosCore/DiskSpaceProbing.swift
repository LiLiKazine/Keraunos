import Foundation

/// Probes free space so the finalizer can refuse a merge that would run the volume out of
/// space mid-write (ENOSPC) instead of failing opaquely. Seamed so tests are deterministic.
public protocol DiskSpaceProbing: Sendable {
    /// Bytes available for "important" usage on `url`'s volume, or nil if unknown.
    func availableCapacity(at url: URL) -> Int64?
}

/// The real probe: asks the volume how much space is available for important usage.
public struct VolumeDiskSpace: DiskSpaceProbing {
    public init() {}
    public func availableCapacity(at url: URL) -> Int64? {
        // Unknown capacity (query failed) → nil, which the caller treats as "don't block".
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            return nil
        }
    }
}
