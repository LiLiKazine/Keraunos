import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import KeraunosCore
import os

/// Launch-argument hooks that let UI tests start from a known state.
///
/// `PlayerRotationUITests` needs at least one file in the Library, but CI simulators are
/// always factory-fresh — the test used to time out waiting for a row that could never
/// appear. Launching with `-KeraunosSeedLibrary` makes the app plant one short, genuinely
/// playable clip in the download store before the Library first renders.
///
/// DEBUG-only: the seeding path is compiled out of Release builds, so a shipped app has no
/// way to be talked into writing into the user's library by a launch argument.
enum UITestSupport {
    /// Add this to `XCUIApplication.launchArguments` to request a seeded Library.
    static let seedLibraryArgument = "-KeraunosSeedLibrary"

    /// Name of the planted clip — distinct enough that a developer who runs with the flag
    /// against a real library can tell it apart from their own downloads.
    private static let seedFilename = "UITest Sample.mp4"

    private static let log = Logger(subsystem: "io.github.lilikazine.Keraunos",
                                    category: "UITestSupport")

    static var isSeedingRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(seedLibraryArgument)
    }

    /// Plants the sample clip if the launch argument asked for it, returning whether the
    /// store changed (so the caller knows to re-read it).
    ///
    /// Additive and idempotent: an existing seed is left in place and no other file is ever
    /// touched, so running with the flag against a populated library is non-destructive.
    @discardableResult
    static func seedLibraryIfRequested(in store: DownloadStore) async -> Bool {
        #if DEBUG
        guard isSeedingRequested else { return false }

        let destination = store.directory.appendingPathComponent(seedFilename)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            log.info("UI-test seed already present — leaving it in place.")
            return false
        }

        do {
            try await writeSampleClip(to: destination)
            log.info("Planted UI-test seed clip at \(destination.path, privacy: .public).")
            return true
        } catch {
            // A failed seed must not take the app down. The test that depends on it will
            // still fail, with its own "is the Library empty?" message; this log is what
            // explains why it was empty.
            log.error("Failed to plant UI-test seed clip: \(error, privacy: .public)")
            return false
        }
        #else
        return false
        #endif
    }

    #if DEBUG

    /// Writes a one-second solid-colour H.264 clip.
    ///
    /// Generated rather than committed as a binary fixture: the repo stays source-only, and
    /// the clip is guaranteed decodable by whatever SDK is building it rather than by
    /// whatever encoder produced a checked-in file years earlier.
    ///
    /// `nonisolated` on purpose — the app target defaults to `MainActor` isolation, and
    /// encoding has no business blocking the main actor during launch.
    private nonisolated static func writeSampleClip(to url: URL) async throws {
        let width = 320
        let height = 240
        let frameRate: Int32 = 30
        let frameCount = 30

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        guard writer.canAdd(input) else { throw SeedError.writerRejectedInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? SeedError.writerFailedToStart
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            let buffer = try makePixelBuffer(width: width, height: height,
                                             frame: frame, of: frameCount)
            let time = CMTime(value: CMTimeValue(frame), timescale: frameRate)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? SeedError.frameAppendFailed
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? SeedError.writerDidNotComplete
        }
    }

    /// One frame: a flat colour that drifts red-ward across the clip, so a seeded video that
    /// is actually playing looks different from one stuck on its first frame.
    private nonisolated static func makePixelBuffer(
        width: Int, height: Int, frame: Int, of total: Int
    ) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32ARGB, nil, &created)
        guard status == kCVReturnSuccess, let buffer = created else {
            throw SeedError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else {
            throw SeedError.pixelBufferContextFailed
        }

        let progress = CGFloat(frame) / CGFloat(max(total - 1, 1))
        context.setFillColor(red: progress, green: 0.2, blue: 1 - progress, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private enum SeedError: Error {
        case writerRejectedInput
        case writerFailedToStart
        case frameAppendFailed
        case writerDidNotComplete
        case pixelBufferCreationFailed(CVReturn)
        case pixelBufferContextFailed
    }

    #endif
}
