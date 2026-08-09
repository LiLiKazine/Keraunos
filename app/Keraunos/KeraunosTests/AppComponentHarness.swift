import Foundation
import WebKit
import KeraunosCore
@testable import Keraunos

// MARK: - Download flow

/// Behavior-level driver for the extraction -> selection -> durable enqueue boundary.
@MainActor
final class DownloadViewModelHarness {
    let model: DownloadViewModel
    private let enqueuer: RecordingJobEnqueuer
    private let scriptedExtractor: ScriptedMediaExtractor?
    private let storage: AppHarnessStorage

    init(
        listings: [Result<FormatListing, KeraunosError>],
        resolutions: [Result<ResolvedMedia, KeraunosError>] = [],
        quality: DefaultQuality = .ask,
        autoSaveToPhotos: Bool = false,
        photoSaver: (any PhotoSaving)? = nil
    ) {
        let extractor = ScriptedMediaExtractor(listings: listings, resolutions: resolutions)
        let enqueuer = RecordingJobEnqueuer()
        let storage = AppHarnessStorage()
        let preferences = Preferences(defaults: storage.defaults)
        preferences.defaultQuality = quality
        preferences.autoSaveToPhotos = autoSaveToPhotos

        self.enqueuer = enqueuer
        self.scriptedExtractor = extractor
        self.storage = storage
        model = DownloadViewModel(
            extractor: extractor,
            store: DownloadStore(directory: storage.directory),
            photoSaver: photoSaver,
            preferences: preferences,
            enqueuer: enqueuer)
    }

    init(extractor: any MediaExtracting) {
        let enqueuer = RecordingJobEnqueuer()
        let storage = AppHarnessStorage()
        self.enqueuer = enqueuer
        self.scriptedExtractor = nil
        self.storage = storage
        model = DownloadViewModel(
            extractor: extractor,
            store: DownloadStore(directory: storage.directory),
            preferences: Preferences(defaults: storage.defaults),
            enqueuer: enqueuer)
    }

    static func ready(
        _ media: ResolvedMedia,
        autoSaveToPhotos: Bool = false,
        photoSaver: (any PhotoSaving)? = nil
    ) -> DownloadViewModelHarness {
        DownloadViewModelHarness(
            listings: [.success(.ready(media))],
            autoSaveToPhotos: autoSaveToPhotos,
            photoSaver: photoSaver)
    }

    static func choices(
        _ options: [FormatOption],
        resolvingTo media: ResolvedMedia,
        quality: DefaultQuality = .ask
    ) -> DownloadViewModelHarness {
        DownloadViewModelHarness(
            listings: [.success(.choices(options))],
            resolutions: [.success(media)],
            quality: quality)
    }

    static func failing(_ error: KeraunosError) -> DownloadViewModelHarness {
        DownloadViewModelHarness(listings: [.failure(error)])
    }

    func start(_ input: String) async {
        model.urlText = input
        await model.startDownload()
    }

    func select(_ option: FormatOption) async {
        model.selectFormat(option)
        await model.currentTask?.value
    }

    var enqueuedJobs: [TransferJob] { enqueuer.jobs }
    var enqueuedJob: TransferJob? { enqueuer.jobs.count == 1 ? enqueuer.jobs[0] : nil }
    var storageDirectory: URL { storage.directory }
    var defaultsSuiteIdentifier: String { storage.defaultsSuiteName }
    var listedURLs: [URL] {
        get async {
            guard let scriptedExtractor else { return [] }
            return await scriptedExtractor.listedURLs
        }
    }
    var resolveCommands: [MediaResolveCommand] {
        get async {
            guard let scriptedExtractor else { return [] }
            return await scriptedExtractor.resolveCommands
        }
    }
}

/// Owns the filesystem and UserDefaults side effects of one app-component harness.
/// Retaining it beside the model keeps both alive for the scenario; deinit tears both down.
private final class AppHarnessStorage {
    let directory: URL
    let defaults: UserDefaults
    let defaultsSuiteName: String

    init() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeraunosAppHarness-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
        } catch {
            fatalError("Could not create app harness directory: \(error)")
        }

        let suiteName = "KeraunosAppHarness.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create app harness defaults suite \(suiteName)")
        }

        self.directory = directory
        self.defaultsSuiteName = suiteName
        self.defaults = defaults
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            assertionFailure("Could not remove app harness directory: \(error)")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

actor ScriptedMediaExtractor: MediaExtracting {
    private var listings: [Result<FormatListing, KeraunosError>]
    private var resolutions: [Result<ResolvedMedia, KeraunosError>]
    private(set) var listedURLs: [URL] = []
    private(set) var resolveCommands: [MediaResolveCommand] = []

    init(
        listings: [Result<FormatListing, KeraunosError>],
        resolutions: [Result<ResolvedMedia, KeraunosError>]
    ) {
        self.listings = listings
        self.resolutions = resolutions
    }

    func listFormats(_ url: URL) throws -> FormatListing {
        listedURLs.append(url)
        return try next(&listings, phase: "listing").get()
    }

    func resolve(_ url: URL, option: FormatOption?) throws -> ResolvedMedia {
        resolveCommands.append(MediaResolveCommand(url: url, option: option))
        return try next(&resolutions, phase: "resolution").get()
    }

    private func next<T>(
        _ results: inout [Result<T, KeraunosError>],
        phase: String
    ) -> Result<T, KeraunosError> {
        guard !results.isEmpty else {
            return .failure(.runtime(detail: "No scripted \(phase) result remains"))
        }
        return results.removeFirst()
    }
}

struct MediaResolveCommand: Sendable, Equatable {
    let url: URL
    let option: FormatOption?
}

@MainActor
private final class RecordingJobEnqueuer: JobEnqueuing {
    private(set) var jobs: [TransferJob] = []
    func enqueue(_ job: TransferJob) async { jobs.append(job) }
}

enum AppTestMedia {
    static func progressive(
        filename: String = "clip.mp4",
        title: String = "Test clip",
        remoteURL: URL = URL(string: "https://cdn.x.test/video.mp4")!,
        headers: [String: String] = [:]
    ) -> ResolvedMedia {
        ResolvedMedia(
            kind: .progressive(MediaTrack(
                url: remoteURL,
                httpHeaders: headers,
                codec: "avc1",
                fileExtension: "mp4")),
            title: title,
            suggestedFilename: filename)
    }

    static func option(
        height: Int = 720,
        formatID: String = "22",
        isAdaptive: Bool = false
    ) -> FormatOption {
        FormatOption(
            height: height,
            codecLabel: "H.264",
            approxBytes: nil,
            formatID: formatID,
            isAdaptive: isAdaptive)
    }
}

extension ResolvedMedia {
    static func progressive(filename: String) -> ResolvedMedia {
        AppTestMedia.progressive(filename: filename)
    }
}

// MARK: - Queue projection

@MainActor
struct QueueProjectionHarness {
    let rows: [QueueItem]

    init(jobs: [TransferJob], snapshots: [UUID: ProgressSnapshot] = [:]) {
        rows = DownloadsViewModel.rows(jobs: jobs, snapshots: snapshots)
    }

    var onlyRow: QueueItem? { rows.count == 1 ? rows[0] : nil }
}

enum AppTestTransfer {
    static func track(
        _ part: String = "video.part",
        bytesWritten: Int64 = 0,
        totalBytes: Int64? = nil,
        taskIdentifier: Int? = nil
    ) -> TrackJob {
        TrackJob(
            remoteURL: URL(string: "https://cdn.x.test/\(part)")!,
            urlExpiresAt: nil,
            chunkSize: nil,
            partFileName: part,
            bytesWritten: bytesWritten,
            totalBytes: totalBytes,
            resumeData: nil,
            taskIdentifier: taskIdentifier)
    }

    static func job(
        id: UUID = UUID(),
        state: JobState,
        createdAt: TimeInterval = 1,
        kind: TransferJob.Kind? = nil,
        filename: String = "clip.mp4",
        page: String = "https://vimeo.com/1234",
        height: Int? = 720,
        isAdaptive: Bool? = nil,
        credentialRef: String? = nil
    ) -> TransferJob {
        let effectiveKind = kind ?? .progressive(track())
        let kindIsAdaptive: Bool
        switch effectiveKind {
        case .progressive: kindIsAdaptive = false
        case .adaptive: kindIsAdaptive = true
        }
        return TransferJob(
            id: id,
            sourcePageURL: URL(string: page)!,
            formatSelection: FormatSelection(
                formatID: "x", height: height, isAdaptive: isAdaptive ?? kindIsAdaptive),
            credentialRef: credentialRef,
            createdAt: Date(timeIntervalSince1970: createdAt),
            state: state,
            kind: effectiveKind,
            suggestedFilename: filename,
            savedFilename: nil,
            autoSaveToPhotos: false)
    }

    static func snapshot(
        _ state: JobState,
        receivedBytes: Int64,
        totalBytes: Int64?,
        isEstimated: Bool = false
    ) -> ProgressSnapshot {
        ProgressSnapshot(
            state: state,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            isEstimated: isEstimated)
    }
}

// MARK: - Cookie behavior

@MainActor
final class CookieStoreHarness {
    private let dataStore: WKWebsiteDataStore
    private let store: CookieStore

    init() {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        self.dataStore = dataStore
        store = CookieStore(dataStore: dataStore)
    }

    func givenCookie(
        _ name: String,
        value: String = "v",
        domain: String,
        path: String = "/"
    ) async {
        let cookie = HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
            .expires: Date(timeIntervalSinceNow: 3_600),
        ])!
        await dataStore.httpCookieStore.setCookie(cookie)
    }

    func exportedText() async throws -> String? {
        guard let url = await store.cookieFile() else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func signedInHosts() async -> [String] { await store.signedInHosts() }
    func signOut(host: String) async { await store.signOut(host: host) }
    func signOutAll() async { await store.signOutAll() }
}
