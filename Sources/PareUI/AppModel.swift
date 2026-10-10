import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import Observation
import PareCore
import PareEngine
import PareLibrary
import PareTranscode
import PareVision

public enum Destination: Hashable, Sendable { case home, similar, videos, screenshots, blurry, history, settings }

public enum LibrarySource: Equatable, Sendable {
    case photos
    case folder(URL)
    case sample
}

public enum GroupSort: String, CaseIterable, Sendable { case date = "By date", size = "By size" }

/// One video's live state in the press, fed by `PipelineEvent`s.
public struct JobRow: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case queued, working, waiting, retrying, copyReady, skipped, failed, cancelled }
    public var id: MediaID
    public var phase: Phase = .queued
    public var step: PipelineStep?
    public var fraction: Double?
    public var message = "Waiting in line"
    public var savedBytes: Int64 = 0
}

public struct WorkProgress: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var fraction: Double?
    public var index = 0
    public var total = 0
    public var savedBytes: Int64 = 0
    public var jobs: [JobRow] = []
    public var paused = false
}

public struct RunSummary: Sendable {
    /// Identifies the run so late results from a removal can't land on a different run's recap.
    public let id = UUID()
    public struct Copy: Sendable, Identifiable {
        public var id: MediaID { original }
        public var original: MediaID
        public var copy: MediaID
        public var savedBytes: Int64
        public var originalRemoved = false
    }
    public var removedCount = 0
    public var removedBytes: Int64 = 0
    public var copies: [Copy] = []
    public var skipped: [(id: MediaID, reason: String)] = []
    public var failed: [(id: MediaID, message: String)] = []
    public var notes: [String] = []

    public var pendingOriginals: [MediaID] { copies.filter { !$0.originalRemoved }.map(\.original) }
    public var originalsRemovedCount: Int { copies.filter(\.originalRemoved).count }
    /// Net library reduction so far: removed photos plus videos whose original is gone. A second copy that sits
    /// next to its original saves nothing yet.
    public var estimatedReduction: Int64 {
        removedBytes + copies.filter(\.originalRemoved).reduce(0) { $0 + $1.savedBytes }
    }
    /// What removing every remaining original would add.
    public var pendingReduction: Int64 {
        copies.filter { !$0.originalRemoved }.reduce(0) { $0 + $1.savedBytes }
    }
}

public struct Comparison: @unchecked Sendable {
    public var original: CGImage
    public var preview: CGImage
    public var estimate: SizeEstimate
}

@MainActor @Observable
public final class AppModel {
    public enum ScanState: Equatable { case idle, scanning(ScanProgress), ready, failed(String) }
    public enum Stage { case browsing, working(WorkProgress), done(RunSummary) }

    struct EstimateKey: Hashable { var id: MediaID; var preset: VideoPreset }

    // MARK: State
    public private(set) var source: LibrarySource
    public private(set) var access: LibraryAccess = .notDetermined
    public private(set) var accessChecked = false
    public private(set) var scanState: ScanState = .idle
    public private(set) var lastScan: Date?
    public private(set) var items: [MediaID: MediaItem] = [:]
    public private(set) var groups: [SimilarGroup] = []
    public private(set) var screenshotIDs: [MediaID] = []
    public private(set) var eligibleVideoIDs: [MediaID] = []
    public private(set) var skippedVideos: [(id: MediaID, reason: SkipReason)] = []
    public private(set) var blurryIDs: [MediaID] = []
    public private(set) var unanalyzedCount = 0
    public private(set) var history: [OperationJournal.Entry] = []
    public private(set) var previewing: Set<MediaID> = []
    public private(set) var previewErrors: [MediaID: String] = [:]
    var videoEstimates: [EstimateKey: SizeEstimate] = [:]
    var draftKeep: [UUID: Set<MediaID>] = [:]
    /// The explicit keeper per group; it can never be marked for removal.
    var keepers: [UUID: MediaID] = [:]
    /// Unfinished jobs from an earlier session, held back until the user resumes or discards them.
    public private(set) var recoveredJobs: [OperationJournal.Entry] = []
    public private(set) var acceptedRecovered: Set<MediaID> = []
    /// True while originals are being removed; the buttons that could start another removal are disabled.
    public private(set) var isRemoving = false

    public var selectedScreenshots: Set<MediaID> = []
    public var selectedBlurry: Set<MediaID> = []
    public var selectedVideos: Set<MediaID> = []
    public var preset: VideoPreset = .gentle
    public var groupSort: GroupSort = .date
    public var path: [Destination] = []
    /// Calm mode: no animation, sound or haptics anywhere in the app.
    public var calmMode = false { didSet { defaults.set(calmMode, forKey: Self.calmKey) } }
    /// When off, iCloud originals are only downloaded on Wi‑Fi without Low Data Mode; the run waits otherwise.
    public var allowCellular = true {
        didSet {
            defaults.set(allowCellular, forKey: Self.cellularKey)
            let allow = allowCellular, p = pipeline
            Task { await p.setAllowExpensiveNetwork(allow) }
        }
    }
    /// `--screen lighttable|press|screenshots|blurry|receipt` opens that surface once the first scan finishes.
    public private(set) var launchScreen: String?
    public var showPlan = false
    public var stage: Stage = .browsing
    public var errorMessage: String?

    // MARK: Plumbing
    private var library: any MediaLibrary
    private var journal: OperationJournal
    private var pipeline: VideoPipeline
    private let supportDirectory: URL
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var executionTask: Task<Void, Never>?
    @ObservationIgnored private var scopedFolder: URL?
    private var jobRows: [MediaID: JobRow] = [:]
    private var jobOrder: [MediaID] = []
    private var workPaused = false
    @ObservationIgnored private var continued: ContinuedRun?
    @ObservationIgnored private let thumbnails = ThumbnailCache()
    @ObservationIgnored private let defaults: UserDefaults

    static let folderBookmarkKey = "pixelpare.folderBookmark"
    static let calmKey = "pixelpare.calm"
    static let cellularKey = "pixelpare.cellular"

    /// `--folder <path>` / `PIXELPARE_FOLDER` select a FolderLibrary; `--sample` / `PIXELPARE_SAMPLE=1` the in-memory
    /// SampleLibrary; otherwise the saved Settings choice, otherwise the Photos library.
    public init(arguments: [String] = CommandLine.arguments,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                supportDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.calmMode = defaults.bool(forKey: Self.calmKey)
        self.allowCellular = defaults.object(forKey: Self.cellularKey) as? Bool ?? true
        if let i = arguments.firstIndex(of: "--screen"), arguments.indices.contains(i + 1) { launchScreen = arguments[i + 1] }
        var chosen: LibrarySource = .photos
        if let i = arguments.firstIndex(of: "--folder"), arguments.indices.contains(i + 1) {
            chosen = .folder(URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
        } else if let path = environment["PIXELPARE_FOLDER"], !path.isEmpty {
            chosen = .folder(URL(fileURLWithPath: path, isDirectory: true))
        } else if arguments.contains("--sample") || environment["PIXELPARE_SAMPLE"] == "1" {
            chosen = .sample
        } else if let data = defaults.data(forKey: Self.folderBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: Self.resolveOptions, bookmarkDataIsStale: &stale) {
                chosen = .folder(url)
            }
        }
        let support = supportDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PixelPare", isDirectory: true)
        self.supportDirectory = support
        self.source = chosen
        let lib = Self.makeLibrary(chosen)
        self.library = lib
        let j = OperationJournal(url: Self.journalURL(support, chosen))
        self.journal = j
        self.pipeline = Self.makePipeline(library: lib, journal: j, support: support, source: chosen,
                                      allowCellular: defaults.object(forKey: Self.cellularKey) as? Bool ?? true)
        if case .folder(let url) = chosen { _ = url.startAccessingSecurityScopedResource(); scopedFolder = url }
    }

    /// For previews and tests.
    public init(library: any MediaLibrary, source: LibrarySource = .sample, supportDirectory: URL) {
        self.defaults = UserDefaults(suiteName: "pixelpare.tests") ?? .standard
        self.calmMode = false
        self.supportDirectory = supportDirectory
        self.source = source
        self.library = library
        let j = OperationJournal(url: Self.journalURL(supportDirectory, source))
        self.journal = j
        self.pipeline = Self.makePipeline(library: library, journal: j, support: supportDirectory, source: source,
                                      allowCellular: true)
    }

    #if os(macOS)
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    private static let createOptions: URL.BookmarkCreationOptions = []
    #endif

    private static func makeLibrary(_ s: LibrarySource) -> any MediaLibrary {
        switch s {
        case .photos: PhotoLibrary()
        case .folder(let url): FolderLibrary(root: url)
        case .sample: SampleLibrary()
        }
    }

    private static func makePipeline(library: any MediaLibrary, journal: OperationJournal, support: URL,
                                     source: LibrarySource, allowCellular: Bool) -> VideoPipeline {
        var config = PipelineConfig()
        config.allowExpensiveNetwork = allowCellular
        return VideoPipeline(library: library, journal: journal,
                             workspace: JobWorkspace(root: jobsURL(support, source)), config: config)
    }

    /// A folder's identity is a short hash of its resolved path, so two folders never share a journal, cache or workspace.
    static func folderKey(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func sourceSuffix(_ s: LibrarySource) -> String {
        switch s {
        case .photos: ""
        case .folder(let url): "-folder-\(folderKey(url))"
        case .sample: "-sample"
        }
    }

    private static func journalURL(_ dir: URL, _ s: LibrarySource) -> URL {
        dir.appendingPathComponent("journal\(sourceSuffix(s)).json")
    }

    private static func jobsURL(_ dir: URL, _ s: LibrarySource) -> URL {
        dir.appendingPathComponent("Jobs\(sourceSuffix(s))", isDirectory: true)
    }

    private var detailsCacheURL: URL {
        supportDirectory.appendingPathComponent("videodetails\(Self.sourceSuffix(source)).json")
    }

    private var cacheURL: URL {
        supportDirectory.appendingPathComponent("signals\(Self.sourceSuffix(source)).json")
    }

    public var sourceName: String {
        switch source {
        case .photos: "Photo library"
        case .folder(let url): "Folder · \(url.lastPathComponent)"
        case .sample: "Sample library"
        }
    }

    // MARK: Library selection & access

    public func start() async {
        access = await library.authorization()
        accessChecked = true
        // Settle whatever a previous run left behind; unfinished jobs resume only when the user starts a run.
        try? await pipeline.recover(autoResume: false)
        await refreshHistory()
        let recovered = history.filter { VideoPipeline.isInFlight($0.state) }
        await pipeline.hold(Set(recovered.map(\.original)))
        recoveredJobs = recovered
        acceptedRecovered = []
        if access == .full || access == .limited, scanState == .idle {
            await scan()
            openLaunchScreen()
        }
    }

    private func openLaunchScreen() {
        guard let screen = launchScreen, scanState == .ready else { return }
        launchScreen = nil
        switch screen {
        case "lighttable": path = [.similar]
        case "press": path = [.videos]
        case "screenshots": path = [.screenshots]
        case "blurry": path = [.blurry]
        case "receipt":
            if let g = sortedGroups.first { approveGroup(g.id) }
            for id in screenshotIDs.prefix(3) { selectedScreenshots.insert(id) }
            path = [.similar]
            showPlan = true
        default: break
        }
    }

    public func requestAccess() async {
        access = await library.requestAccess()
        accessChecked = true
        if access == .full || access == .limited { await scan() }
    }

    public func recheckAccess() async {
        access = await library.authorization()
        if (access == .full || access == .limited), scanState == .idle { await scan() }
    }

    public func useSource(_ newSource: LibrarySource) async {
        guard newSource != source else { return }
        scanTask?.cancel()
        scopedFolder?.stopAccessingSecurityScopedResource(); scopedFolder = nil
        if case .folder(let url) = newSource {
            _ = url.startAccessingSecurityScopedResource(); scopedFolder = url
            if let data = try? url.bookmarkData(options: Self.createOptions) {
                defaults.set(data, forKey: Self.folderBookmarkKey)
            }
        } else {
            defaults.removeObject(forKey: Self.folderBookmarkKey)
        }
        await pipeline.shutdown()
        source = newSource
        library = Self.makeLibrary(newSource)
        journal = OperationJournal(url: Self.journalURL(supportDirectory, newSource))
        pipeline = Self.makePipeline(library: library, journal: journal, support: supportDirectory, source: newSource,
                                  allowCellular: allowCellular)
        thumbnails.removeAll()
        resetResults()
        recoveredJobs = []; acceptedRecovered = []
        scanState = .idle
        path = []
        await start()
    }

    // MARK: Scanning

    public func rescan() {
        scanTask?.cancel()
        scanTask = Task { await scan() }
    }

    public func cancelScan() { scanTask?.cancel() }

    func scan() async {
        scanTask?.cancel()
        scanState = .scanning(ScanProgress(phase: .listing, completed: 0, total: 0))
        let engine = ScanEngine(library: library, cacheURL: cacheURL)
        let activity = BackgroundActivity("Scanning library")
        defer { activity.end() }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.scan { p in
                    Task { @MainActor in
                        if case .scanning = self.scanState { self.scanState = .scanning(p) }
                    }
                }
                self.apply(result)
            } catch is CancellationError {
                if case .scanning = self.scanState { self.scanState = .idle }
            } catch {
                self.scanState = .failed(error.localizedDescription)
            }
        }
        scanTask = task
        await task.value
    }

    private func resetResults() {
        detailsTask?.cancel()
        items = [:]; groups = []; screenshotIDs = []; eligibleVideoIDs = []; skippedVideos = []; blurryIDs = []
        selectedScreenshots = []; selectedBlurry = []; selectedVideos = []; draftKeep = [:]; keepers = [:]; videoEstimates = [:]
        previewErrors = [:]; unanalyzedCount = 0
    }

    private func apply(_ r: ScanResult) {
        resetResults()
        items = r.items
        groups = r.groups
        screenshotIDs = r.screenshotCandidates
        blurryIDs = r.blurryCandidates
        eligibleVideoIDs = r.eligibleVideos
            .sorted { (items[$0]?.byteSize ?? 0) > (items[$1]?.byteSize ?? 0) }
        skippedVideos = r.skippedVideos
        unanalyzedCount = r.unanalyzedCount
        lastScan = Date()
        scanState = .ready
        probeVideoDetails()
    }

    /// Background pass after the scan: moves HDR and high-frame-rate videos out of the eligible list.
    private func probeVideoDetails() {
        detailsTask?.cancel()
        let videos = eligibleVideoIDs.compactMap { items[$0] }
        guard !videos.isEmpty else { return }
        let lib = library, url = detailsCacheURL
        detailsTask = Task { [weak self] in
            await VideoDetailsProber.run(items: videos, library: lib, cacheURL: url) { id, details in
                self?.applyDetails(details, to: id)
            }
        }
    }

    func applyDetails(_ details: VideoDetails, to id: MediaID) {
        guard let item = items[id] else { return }
        let updated = item.applying(details)
        guard updated != item else { return }
        items[id] = updated
        let r = PresetPolicy.reclassify(eligible: eligibleVideoIDs, skipped: skippedVideos, items: items)
        guard r.eligible != eligibleVideoIDs else { return }
        eligibleVideoIDs = r.eligible
        skippedVideos = r.skipped
        selectedVideos.remove(id)
    }

    // MARK: Thumbnails

    public func thumbnail(_ id: MediaID, maxPixel: Int) async -> CGImage? {
        let key = "\(id.raw)#\(maxPixel)"
        if let hit = thumbnails.image(for: key) { return hit }
        guard let image = try? await library.thumbnail(id, maxPixel: maxPixel, allowNetwork: false) else { return nil }
        thumbnails.store(image, for: key)
        return image
    }

    // MARK: Text helpers

    public func title(for id: MediaID) -> String {
        if case .folder = source { return (id.raw as NSString).lastPathComponent }
        return Format.date(items[id]?.creationDate)
    }

    public func groupTitle(_ g: SimilarGroup) -> String {
        let date = g.members.compactMap { items[$0]?.creationDate }.min()
        let kind = switch g.kind { case .exact: "exact copies"; case .nearIdentical: "near-identical"; case .similar: "photos" }
        return "\(Format.date(date)) · \(g.members.count) \(kind)"
    }

    // MARK: Groups

    public var sortedGroups: [SimilarGroup] {
        switch groupSort {
        case .date:
            return groups.sorted { (groupDate($0) ?? .distantPast, $0.id.uuidString) > (groupDate($1) ?? .distantPast, $1.id.uuidString) }
        case .size:
            return groups.sorted { (removableBytes($0), $0.id.uuidString) > (removableBytes($1), $1.id.uuidString) }
        }
    }

    private func groupDate(_ g: SimilarGroup) -> Date? { g.members.compactMap { items[$0]?.creationDate }.min() }

    func removableBytes(_ g: SimilarGroup) -> Int64 {
        g.suggestedRemovals.reduce(0) { $0 + (items[$1]?.byteSize ?? 0) }
    }

    public func group(_ id: UUID) -> SimilarGroup? { groups.first { $0.id == id } }

    /// The group's keeper: explicit choice, else the suggestion. Always a member.
    public func keeper(for g: SimilarGroup) -> MediaID {
        if let k = keepers[g.id], g.members.contains(k) { return k }
        return g.suggestedKeeper
    }

    /// Members that will be kept if this group is approved as it currently stands. Always includes the keeper.
    public func keepSet(for g: SimilarGroup) -> Set<MediaID> {
        let base: Set<MediaID>
        if case .approved(let keep) = g.approval { base = keep } else { base = draftKeep[g.id] ?? g.defaultKeep }
        return base.union([keeper(for: g)])
    }

    public func savings(of g: SimilarGroup) -> Int64 {
        Set(g.members).subtracting(keepSet(for: g)).subtracting(g.favorites)
            .reduce(0) { $0 + (items[$1]?.byteSize ?? 0) }
    }

    public var approvedGroupCount: Int { groups.filter { if case .approved = $0.approval { true } else { false } }.count }
    public var skippedGroupCount: Int { groups.filter { $0.approval == .skipped }.count }
    public var pendingGroupCount: Int { groups.count - approvedGroupCount - skippedGroupCount }

    private func update(_ id: UUID, _ change: (inout SimilarGroup) -> Void) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        change(&groups[i])
    }

    public func approveGroup(_ id: UUID) {
        guard let g = group(id) else { return }
        let keep = keepSet(for: g).union(g.favorites)
        guard !keep.isEmpty else { return }
        update(id) { $0.approval = .approved(keep: keep) }
    }

    /// Back to "suggested" so nothing from this group is part of the plan.
    public func unapproveGroup(_ id: UUID) { update(id) { $0.approval = .suggested } }

    /// "Keep all" / skip: nothing in the group is ever removed.
    public func skipGroup(_ id: UUID) { update(id) { $0.approval = .skipped } }

    /// Flips a member between kept and marked. The keeper and favorites can't be marked. Changing an approved
    /// group's removals withdraws its approval so the user approves what they now see.
    public func toggleKeep(group id: UUID, member: MediaID) {
        guard let g = group(id), !g.favorites.contains(member), member != keeper(for: g) else { return }
        var keep = keepSet(for: g)
        if keep.contains(member) { keep.remove(member) } else { keep.insert(member) }
        draftKeep[id] = keep
        if g.approval != .suggested { update(id) { $0.approval = .suggested } }
    }

    /// Makes `member` the keeper. The previous keeper stays kept (unmarked) until the user marks it.
    public func setKeeper(group id: UUID, member: MediaID) {
        guard let g = group(id), g.members.contains(member) else { return }
        let before = keepSet(for: g)
        keepers[id] = member
        let keep = before.union([member])
        draftKeep[id] = keep
        if case .approved = g.approval, keep != before { update(id) { $0.approval = .suggested } }
    }

    // MARK: Screenshots

    public func toggleScreenshot(_ id: MediaID) {
        if selectedScreenshots.contains(id) { selectedScreenshots.remove(id) } else { selectedScreenshots.insert(id) }
    }
    public func selectAllScreenshots() { selectedScreenshots = Set(screenshotIDs) }
    public func clearScreenshots() { selectedScreenshots = [] }

    // MARK: Blurry

    public func toggleBlurry(_ id: MediaID) {
        if selectedBlurry.contains(id) { selectedBlurry.remove(id) } else { selectedBlurry.insert(id) }
    }
    public func selectAllBlurry() { selectedBlurry = Set(blurryIDs) }
    public func clearBlurry() { selectedBlurry = [] }

    public var blurryOpportunity: ClosedRange<Int64> {
        CleanupPlan(removals: Set(blurryIDs)).estimatedSavings(items: items)
    }

    // MARK: Videos

    public func toggleVideo(_ id: MediaID) {
        if selectedVideos.contains(id) { selectedVideos.remove(id) } else { selectedVideos.insert(id) }
    }
    public func selectAllVideos() { selectedVideos = Set(eligibleVideoIDs) }
    public func clearVideos() { selectedVideos = [] }

    public func estimate(for id: MediaID, preset p: VideoPreset? = nil) -> SizeEstimate? {
        let p = p ?? preset
        if let e = videoEstimates[EstimateKey(id: id, preset: p)] { return e }
        guard let item = items[id], PresetPolicy.settings(for: item, preset: p) != nil else { return nil }
        return PresetPolicy.estimate(item, preset: p)
    }

    /// Estimate → Preview ready → Final: a measured size from an earlier press wins over a preview, which wins over the formula.
    public func sizeEstimate(for id: MediaID, preset p: VideoPreset? = nil) -> SizeEstimate? {
        if let e = history.first(where: { $0.original == id && ($0.state == .awaitingRemovalApproval || $0.state == .removed) }),
           let bytes = e.encodedBytes {
            return SizeEstimate(state: .final, low: bytes, high: bytes)
        }
        return estimate(for: id, preset: p)
    }

    /// Videos the preset can actually be applied to (Smaller resolution is not offered for ≤1080p).
    public func isApplicable(_ id: MediaID, preset p: VideoPreset) -> Bool {
        guard let item = items[id] else { return false }
        return PresetPolicy.settings(for: item, preset: p) != nil
    }

    /// Net space saved (original size minus the new copy) for a preset, across the selection, or all eligible
    /// videos when nothing is selected. Same methodology as `opportunity`: `PresetPolicy.estimate` per video,
    /// with a measured preview size taking precedence once the user has one.
    public func videoSavings(preset p: VideoPreset) -> ClosedRange<Int64> {
        let ids = selectedVideos.isEmpty ? eligibleVideoIDs : eligibleVideoIDs.filter(selectedVideos.contains)
        var lo: Int64 = 0, hi: Int64 = 0
        for id in ids {
            guard isApplicable(id, preset: p) else { continue }
            if let size = items[id]?.byteSize, let measured = videoEstimates[EstimateKey(id: id, preset: p)] {
                lo += max(0, size - measured.high); hi += max(0, size - measured.low)
            } else {
                let r = CleanupPlan(videoJobs: [id: p]).estimatedSavings(items: items)
                lo += r.lowerBound; hi += r.upperBound
            }
        }
        return lo...max(lo, hi)
    }

    /// The photo to flip when Space is pressed on the light table: the focused photo, or the first photo that
    /// could be marked. Keepers and favorites never toggle.
    public func spaceToggleTarget(group g: SimilarGroup, focused: MediaID?) -> MediaID? {
        let keeper = keeper(for: g)
        func markable(_ id: MediaID) -> Bool { g.members.contains(id) && id != keeper && !g.favorites.contains(id) }
        if let focused { return markable(focused) ? focused : nil }
        return g.members.first(where: markable)
    }

    /// Favorites that sit in groups whose removals are in the plan. They are never part of it.
    public var protectedFavoriteCount: Int {
        groups.filter { if case .approved = $0.approval { true } else { false } }
            .reduce(0) { $0 + $1.favorites.count }
    }

    public var applicableSelectedVideos: [MediaID] {
        selectedVideos.filter { isApplicable($0, preset: preset) }.sorted()
    }

    /// Sample-encodes a few seconds of a video that is already on this device and refines its estimate.
    public func requestPreview(for id: MediaID) async {
        guard let item = items[id], !previewing.contains(id) else { return }
        let p = preset
        previewing.insert(id); previewErrors[id] = nil
        defer { previewing.remove(id) }
        do {
            let (file, dir) = try await exportOriginal(id)
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let probe = await VideoProbe.load(file),
                  let settings = PresetPolicy.settings(for: probe.refine(item), preset: p) else {
                previewErrors[id] = "This preset doesn't apply to this video."; return
            }
            let est = try await PreviewEncoder.sampleEstimate(input: file, settings: settings)
            videoEstimates[EstimateKey(id: id, preset: p)] = est
        } catch {
            previewErrors[id] = item.isLocal ? error.localizedDescription : "The original is in iCloud. Download it first to preview."
        }
    }

    private func exportOriginal(_ id: MediaID) async throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pixelpare-preview-\(UUID().uuidString)")
        let file = try await library.exportVideo(id, to: dir, allowNetwork: false) { _ in }
        return (file, dir)
    }

    /// Frames from the original and from a short preview encode at the same moment, for the A/B slider.
    public func loadComparison(id: MediaID, preset p: VideoPreset) async throws -> Comparison {
        guard let item = items[id] else { throw LibraryError.notFound(id.raw) }
        let (file, dir) = try await exportOriginal(id)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let probe = await VideoProbe.load(file),
              let settings = PresetPolicy.settings(for: probe.refine(item), preset: p) else {
            throw LibraryError.exportFailed("This preset doesn't apply to this video.")
        }
        let clip = try await PreviewEncoder.previewClip(input: file, settings: settings, seconds: 3)
        defer { clip.cleanup() }
        let t = clip.duration / 2
        let original = try await PreviewEncoder.extractFrame(
            from: file, at: CMTime(seconds: clip.sourceStart + t, preferredTimescale: 600), maxPixel: 1600)
        let preview = try await PreviewEncoder.extractFrame(
            from: clip.url, at: CMTime(seconds: t, preferredTimescale: 600), maxPixel: 1600)
        videoEstimates[EstimateKey(id: id, preset: p)] = clip.estimate
        return Comparison(original: original, preview: preview, estimate: clip.estimate)
    }

    // MARK: Plan

    public var plan: CleanupPlan {
        var jobs: [MediaID: VideoPreset] = [:]
        for id in applicableSelectedVideos { jobs[id] = preset }
        return CleanupPlan(groups: groups, approvedScreenshots: selectedScreenshots.union(selectedBlurry), videoJobs: jobs)
    }

    public var planSavings: ClosedRange<Int64> { plan.estimatedSavings(items: items) }

    /// Everything the app would suggest, before the user has approved anything. Each original counts once.
    public var opportunity: ClosedRange<Int64> {
        let removals = groups.reduce(into: Set<MediaID>()) { $0.formUnion($1.suggestedRemovals) }
            .union(screenshotIDs).union(blurryIDs)
        var jobs: [MediaID: VideoPreset] = [:]
        for id in eligibleVideoIDs where isApplicable(id, preset: preset) { jobs[id] = preset }
        return CleanupPlan(removals: removals, videoJobs: jobs).estimatedSavings(items: items)
    }

    public var similarOpportunity: ClosedRange<Int64> {
        let removals = groups.reduce(into: Set<MediaID>()) { $0.formUnion($1.suggestedRemovals) }
        return CleanupPlan(removals: removals).estimatedSavings(items: items)
    }

    public var similarPhotoCount: Int { groups.reduce(0) { $0 + $1.members.count } }

    public var screenshotOpportunity: ClosedRange<Int64> {
        CleanupPlan(removals: Set(screenshotIDs)).estimatedSavings(items: items)
    }

    public var videoOpportunity: ClosedRange<Int64> {
        var jobs: [MediaID: VideoPreset] = [:]
        for id in eligibleVideoIDs where isApplicable(id, preset: preset) { jobs[id] = preset }
        return CleanupPlan(videoJobs: jobs).estimatedSavings(items: items)
    }

    public var eligibleVideoBytes: Int64 { eligibleVideoIDs.reduce(0) { $0 + (items[$1]?.byteSize ?? 0) } }

    public var librarySummary: String {
        let photos = items.values.filter { $0.kind != .video }.count
        let videos = items.count - photos
        return "\(sourceName) · \(Format.count(photos, "photo")) · \(Format.count(videos, "video"))"
    }

    // MARK: Execution

    /// Validates the plan, removes approved photos (system confirmation), then creates verified smaller copies of
    /// approved videos. Video originals are never removed here.
    public var canExecute: Bool { !plan.isEmpty || !acceptedRecovered.isEmpty }

    /// Includes an unfinished job from last time in the next run; the receipt lists it.
    public func setRecoveredAccepted(_ id: MediaID, _ accepted: Bool) {
        guard recoveredJobs.contains(where: { $0.original == id }) else { return }
        if accepted { acceptedRecovered.insert(id) } else { acceptedRecovered.remove(id) }
    }

    /// Cancels an unfinished job from last time; the original is untouched.
    public func discardRecovered(_ id: MediaID) async {
        recoveredJobs.removeAll { $0.original == id }
        acceptedRecovered.remove(id)
        await pipeline.cancel(id)
        await refreshHistory()
    }

    public func executePlan() {
        guard executionTask == nil, !isRemoving else { return }
        let plan = self.plan
        do {
            try SafetyCheck.validate(plan: plan, groups: groups, items: items, explicitlyApproved: selectedBlurry)
        } catch {
            errorMessage = "The plan didn't pass its safety check (\(error)). Nothing was changed."
            return
        }
        guard canExecute else { return }
        showPlan = false
        stage = .working(WorkProgress(title: "Getting ready", detail: "", fraction: nil))
        executionTask = Task { [weak self] in
            await self?.runPlan(plan)
            self?.executionTask = nil
        }
    }

    public func stopWork() {
        executionTask?.cancel()
        Task { await pipeline.pause() }
    }

    private func runPlan(_ plan: CleanupPlan) async {
        var summary = RunSummary()
        if !plan.removals.isEmpty {
            stage = .working(WorkProgress(
                title: "Removing \(Format.count(plan.removals.count, "photo"))",
                detail: "Confirm in the system dialog. Nothing is removed until you do.", fraction: nil))
            await removePhotos(plan.removals.sorted(), into: &summary)
        }

        let planIDs = plan.videoJobs.keys.filter { items[$0] != nil }.sorted()
        let recoveredIDs = acceptedRecovered.filter { id in recoveredJobs.contains { $0.original == id } }.sorted()
        let ids = planIDs + recoveredIDs.filter { !planIDs.contains($0) }
        if !ids.isEmpty, !Task.isCancelled {
            let activity = BackgroundActivity("Compressing videos")
            defer { activity.end() }
            let p = pipeline
            let run = ContinuedRun(title: "Compressing videos", subtitle: "\(ids.count) to go", total: ids.count) {
                await p.pause()
            }
            continued = run
            defer { continued = nil }
            await pipeline.release(Set(recoveredIDs))
            recoveredJobs.removeAll { recoveredIDs.contains($0.original) }
            acceptedRecovered.subtract(recoveredIDs)
            await pipeline.resume()
            let stream = pipeline.events()
            jobOrder = ids
            jobRows = Dictionary(uniqueKeysWithValues: ids.map { (id: MediaID) in (id, JobRow(id: id)) })
            workPaused = false
            publishWork()
            let watched = Set(ids)
            let listener = Task { @MainActor [weak self] in
                for await event in stream { self?.handle(event, watched: watched) }
            }
            do {
                for preset in VideoPreset.allCases {
                    let group = ids.filter { plan.videoJobs[$0] == preset }.compactMap { items[$0] }
                    if !group.isEmpty { try await pipeline.enqueue(group, preset: preset) }
                }
                await pipeline.waitUntilIdle()
            } catch {
                summary.notes.append("Couldn't start compressing: \(error.localizedDescription)")
            }
            listener.cancel()
            let entries = await journal.entries()
            var unfinished = 0
            for id in ids {
                guard let e = entries.first(where: { $0.original == id }) else { continue }
                switch e.state {
                case .awaitingRemovalApproval, .removing, .removed:
                    if let copy = e.newID {
                        summary.copies.append(.init(original: id, copy: copy,
                                                    savedBytes: max(0, (e.sourceBytes ?? 0) - (e.encodedBytes ?? 0))))
                    }
                case .skipped: summary.skipped.append((id, e.lastError?.message ?? "Skipped"))
                case .failed: summary.failed.append((id, e.lastError?.message ?? "Failed"))
                default: unfinished += 1
                }
            }
            if unfinished > 0 { summary.notes.append("Stopped early; \(unfinished) videos will continue next time.") }
            run.finish(success: unfinished == 0)
        }
        await refreshHistory()
        stage = .done(summary)
    }

    /// Deletes photos after re-checking each one right now (a favorite since the scan is dropped), then reports
    /// only what the library confirms is gone.
    private func removePhotos(_ requested: [MediaID], into summary: inout RunSummary) async {
        var deletable: [MediaID] = []
        var protected = 0, unconfirmed = 0
        for id in requested {
            do {
                guard let fresh = try await library.item(id) else { continue }
                if fresh.isFavorite || fresh.kind == .video { protected += 1 } else { deletable.append(id) }
            } catch { unconfirmed += 1 }
        }
        if protected > 0 {
            summary.notes.append("\(Format.count(protected, "photo")) became a favorite and was left alone.")
        }
        if unconfirmed > 0 {
            summary.notes.append("\(Format.count(unconfirmed, "photo")) couldn't be checked and was left alone.")
        }
        guard !deletable.isEmpty else { return }
        var deleteError: Error?
        do { try await library.delete(deletable) } catch { deleteError = error }
        var removed = 0
        var bytes: Int64 = 0
        for id in deletable {
            // Only a definite "not found" counts as removed; an error means unconfirmed.
            guard await isGone(id) else { continue }
            removed += 1
            bytes += items[id]?.byteSize ?? 0
        }
        summary.removedCount = removed
        summary.removedBytes = bytes
        if removed < deletable.count {
            let rest = deletable.count - removed
            let why = deleteError.map { ": \($0.localizedDescription)" } ?? ""
            summary.notes.append(removed == 0
                ? "Photos weren't removed\(why)"
                : "Removed \(removed) of \(deletable.count) photos; \(Format.count(rest, "photo")) still in your library\(why).")
        }
    }

    private func isGone(_ id: MediaID) async -> Bool {
        do { return try await library.item(id) == nil } catch { return false }
    }

    /// Turns the pipeline's events into per-video rows for the press and the running totals.
    private func handle(_ event: PipelineEvent, watched: Set<MediaID>) {
        func change(_ id: MediaID, _ edit: (inout JobRow) -> Void) {
            guard watched.contains(id) else { return }
            var row = jobRows[id] ?? JobRow(id: id)
            edit(&row)
            jobRows[id] = row
        }
        switch event {
        case .queued(let id): change(id) { $0.phase = .queued; $0.message = "Waiting in line" }
        case .stateChanged(let id, let state):
            change(id) { if $0.phase == .waiting || $0.phase == .retrying { $0.phase = .working }; _ = state }
        case .progress(let id, let step, let f):
            change(id) {
                $0.phase = .working; $0.step = step
                $0.fraction = step == .encode || step == .download ? f : nil
                $0.message = Self.verb(step)
            }
        case .waiting(let id, let reason): change(id) { $0.phase = .waiting; $0.message = reason.message }
        case .resumed(let id): change(id) { $0.phase = .working }
        case .retrying(let id, let step, let attempt, _, _):
            change(id) { $0.phase = .retrying; $0.message = "\(Self.verb(step)) Trying again (attempt \(attempt + 1))" }
        case .finished(let id, let outcome):
            change(id) {
                $0.fraction = nil
                switch outcome {
                case .awaitingRemovalApproval(_, let bytes):
                    $0.phase = .copyReady; $0.savedBytes = bytes
                    $0.message = "Smaller copy ready. Original still here."
                case .skipped(let why): $0.phase = .skipped; $0.message = why
                case .failed(let why, _): $0.phase = .failed; $0.message = why
                case .cancelled: $0.phase = .cancelled; $0.message = "Cancelled"
                case .removed: $0.phase = .copyReady; $0.message = "Original removed"
                }
            }
        case .paused: workPaused = true
        case .resumedAll: workPaused = false
        case .idle: break
        }
        publishWork()
    }

    private static func verb(_ step: PipelineStep) -> String {
        switch step {
        case .preflight, .download: "Getting the original…"
        case .encode: "Making the smaller copy…"
        case .verify: "Checking the new copy…"
        case .importCopy: "Adding the smaller copy…"
        case .verifyImported: "Confirming it's in your library…"
        case .remove: "Removing the original…"
        }
    }

    private func publishWork() {
        guard case .working = stage else { return }
        let rows = jobOrder.compactMap { jobRows[$0] }
        let finished = rows.filter { [.copyReady, .skipped, .failed, .cancelled].contains($0.phase) }.count
        let active = rows.first { $0.phase == .working || $0.phase == .waiting || $0.phase == .retrying }
        continued?.update(completed: finished, total: rows.count,
                          subtitle: "\(min(finished + 1, rows.count)) of \(rows.count)" + (active.map { " · \($0.message)" } ?? ""))
        stage = .working(WorkProgress(
            title: workPaused ? "Paused" : "Pressing \(min(finished + 1, rows.count)) of \(rows.count)",
            detail: active.map { "\(title(for: $0.id)) — \($0.message)" } ?? "",
            fraction: active?.fraction,
            index: finished, total: rows.count,
            savedBytes: rows.reduce(0) { $0 + $1.savedBytes },
            jobs: rows, paused: workPaused))
    }

    /// Explicit user action: remove originals whose smaller copy is verified. The journal has the final say.
    public func removeVideoOriginals() async {
        guard !isRemoving, case .done(let current) = stage else { return }
        isRemoving = true
        defer { isRemoving = false }
        let runID = current.id
        let result = await pipeline.removeOriginals(current.pendingOriginals)
        // Results belong to the run that asked; a different recap on screen now must not be touched.
        if case .done(var summary) = stage, summary.id == runID {
            let removed = Set(result.removed)
            for i in summary.copies.indices where removed.contains(summary.copies[i].original) {
                summary.copies[i].originalRemoved = true
            }
            if !result.declined.isEmpty { summary.notes.append("Nothing was removed; you can approve again any time.") }
            if !result.refused.isEmpty { summary.notes.append("\(result.refused.count) originals were kept (not verified, or a favorite).") }
            if !result.failed.isEmpty { summary.notes.append("\(result.failed.count) originals couldn't be removed and were kept.") }
            stage = .done(summary)
        }
        await refreshHistory()
    }

    /// Originals whose smaller copy was verified in an earlier session and are still waiting for the user's decision.
    public var pendingApprovalCount: Int { history.filter { $0.state == .awaitingRemovalApproval && $0.newID != nil }.count }

    /// Opens the recap for copies that are verified but whose originals are still in the library.
    public func reviewPendingOriginals() {
        var summary = RunSummary()
        for e in history where e.state == .awaitingRemovalApproval {
            guard let copy = e.newID else { continue }
            summary.copies.append(.init(original: e.original, copy: copy,
                                        savedBytes: max(0, (e.sourceBytes ?? 0) - (e.encodedBytes ?? 0))))
        }
        guard !summary.copies.isEmpty else { return }
        stage = .done(summary)
    }

    public func finishRun() {
        guard !isRemoving else { return }
        stage = .browsing
        path = []
        rescan()
    }

    public func refreshHistory() async {
        history = await journal.entries().sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// NSCache is thread-safe; the wrapper only exists to satisfy Sendable checking.
final class ThumbnailCache: @unchecked Sendable {
    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    private let cache = NSCache<NSString, Box>()
    init() { cache.countLimit = 600 }
    func image(for key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }
    func store(_ image: CGImage, for key: String) { cache.setObject(Box(image), forKey: key as NSString) }
    func removeAll() { cache.removeAllObjects() }
}
