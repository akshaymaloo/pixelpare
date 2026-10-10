import CoreGraphics
import CoreMedia
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

    public var selectedScreenshots: Set<MediaID> = []
    public var selectedBlurry: Set<MediaID> = []
    public var selectedVideos: Set<MediaID> = []
    public var preset: VideoPreset = .gentle
    public var groupSort: GroupSort = .date
    public var path: [Destination] = []
    /// Calm mode: no animation, sound or haptics anywhere in the app.
    public var calmMode = false { didSet { defaults.set(calmMode, forKey: Self.calmKey) } }
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
    @ObservationIgnored private var executionTask: Task<Void, Never>?
    @ObservationIgnored private var scopedFolder: URL?
    private var jobRows: [MediaID: JobRow] = [:]
    private var jobOrder: [MediaID] = []
    private var workPaused = false
    @ObservationIgnored private let thumbnails = ThumbnailCache()
    @ObservationIgnored private let defaults: UserDefaults

    static let folderBookmarkKey = "pixelpare.folderBookmark"
    static let calmKey = "pixelpare.calm"

    /// `--folder <path>` / `PIXELPARE_FOLDER` select a FolderLibrary; `--sample` / `PIXELPARE_SAMPLE=1` the in-memory
    /// SampleLibrary; otherwise the saved Settings choice, otherwise the Photos library.
    public init(arguments: [String] = CommandLine.arguments,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                supportDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.calmMode = defaults.bool(forKey: Self.calmKey)
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
        self.pipeline = Self.makePipeline(library: lib, journal: j, support: support)
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
        self.pipeline = Self.makePipeline(library: library, journal: j, support: supportDirectory)
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

    private static func makePipeline(library: any MediaLibrary, journal: OperationJournal, support: URL) -> VideoPipeline {
        VideoPipeline(library: library, journal: journal,
                      workspace: JobWorkspace(root: support.appendingPathComponent("Jobs", isDirectory: true)))
    }

    private static func journalURL(_ dir: URL, _ s: LibrarySource) -> URL {
        switch s {
        case .photos: dir.appendingPathComponent("journal.json")
        case .folder: dir.appendingPathComponent("journal-folder.json")
        case .sample: dir.appendingPathComponent("journal-sample.json")
        }
    }

    private var cacheURL: URL {
        switch source {
        case .photos: supportDirectory.appendingPathComponent("signals.json")
        case .folder: supportDirectory.appendingPathComponent("signals-folder.json")
        case .sample: supportDirectory.appendingPathComponent("signals-sample.json")
        }
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
        pipeline = Self.makePipeline(library: library, journal: journal, support: supportDirectory)
        thumbnails.removeAll()
        resetResults()
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
        items = [:]; groups = []; screenshotIDs = []; eligibleVideoIDs = []; skippedVideos = []; blurryIDs = []
        selectedScreenshots = []; selectedBlurry = []; selectedVideos = []; draftKeep = [:]; videoEstimates = [:]
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

    /// Members that will be kept if this group is approved as it currently stands.
    public func keepSet(for g: SimilarGroup) -> Set<MediaID> {
        if case .approved(let keep) = g.approval { return keep }
        return draftKeep[g.id] ?? g.defaultKeep
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
        let keep = keepSet(for: g)
        guard !keep.isEmpty else { return }
        update(id) { $0.approval = .approved(keep: keep.union($0.favorites)) }
    }

    /// Back to "suggested" so nothing from this group is part of the plan.
    public func unapproveGroup(_ id: UUID) { update(id) { $0.approval = .suggested } }

    /// "Keep all" / skip: nothing in the group is ever removed.
    public func skipGroup(_ id: UUID) { update(id) { $0.approval = .skipped } }

    /// Flips a member between keep and remove. Favorites can't be removed and the last kept member can't be unkept.
    public func toggleKeep(group id: UUID, member: MediaID) {
        guard let g = group(id), !g.favorites.contains(member) else { return }
        var keep = keepSet(for: g)
        if keep.contains(member) {
            guard keep.count > 1 else { return }
            keep.remove(member)
        } else {
            keep.insert(member)
        }
        draftKeep[id] = keep
        if case .approved = g.approval { update(id) { $0.approval = .approved(keep: keep) } }
        else if g.approval == .skipped { update(id) { $0.approval = .suggested } }
    }

    /// Keeps only `member` (plus favorites) and marks every other member for removal.
    public func setKeeper(group id: UUID, member: MediaID) {
        guard let g = group(id) else { return }
        let keep = Set([member]).union(g.favorites)
        draftKeep[id] = keep
        update(id) { $0.approval = .suggested }
        if case .approved = g.approval { update(id) { $0.approval = .approved(keep: keep) } }
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

    /// Expected total saving for a preset across the selection, or all eligible videos when nothing is selected.
    public func videoSavings(preset p: VideoPreset) -> ClosedRange<Int64> {
        let ids = selectedVideos.isEmpty ? eligibleVideoIDs : eligibleVideoIDs.filter(selectedVideos.contains)
        var lo: Int64 = 0, hi: Int64 = 0
        for id in ids {
            guard let item = items[id], let est = estimate(for: id, preset: p) else { continue }
            let size = item.byteSize ?? PresetPolicy.estimate(item, preset: .gentle).high * 3
            lo += max(0, size - est.high); hi += max(0, size - est.low)
        }
        return lo...max(lo, hi)
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
    public func executePlan() {
        guard executionTask == nil else { return }
        let plan = self.plan
        do {
            try SafetyCheck.validate(plan: plan, groups: groups, items: items, explicitlyApproved: selectedBlurry)
        } catch {
            errorMessage = "The plan didn't pass its safety check (\(error)). Nothing was changed."
            return
        }
        guard !plan.isEmpty else { return }
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
            let ids = plan.removals.sorted()
            do {
                try await library.delete(ids)
                summary.removedCount = ids.count
                summary.removedBytes = ids.reduce(0) { $0 + (items[$1]?.byteSize ?? 0) }
            } catch {
                summary.notes.append("Photos weren't removed: \(error.localizedDescription)")
            }
        }

        let ids = plan.videoJobs.keys.filter { items[$0] != nil }.sorted()
        if !ids.isEmpty, !Task.isCancelled {
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
        }
        await refreshHistory()
        stage = .done(summary)
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
        guard case .done(var summary) = stage else { return }
        let ids = summary.pendingOriginals
        let result = await pipeline.removeOriginals(ids)
        let removed = Set(result.removed)
        for i in summary.copies.indices where removed.contains(summary.copies[i].original) {
            summary.copies[i].originalRemoved = true
        }
        if !result.declined.isEmpty { summary.notes.append("Nothing was removed; you can approve again any time.") }
        if !result.refused.isEmpty { summary.notes.append("\(result.refused.count) originals were kept (not verified).") }
        if !result.failed.isEmpty { summary.notes.append("\(result.failed.count) originals couldn't be removed and were kept.") }
        stage = .done(summary)
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
