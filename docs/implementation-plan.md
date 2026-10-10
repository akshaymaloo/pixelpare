# PixelPare — Implementation Plan (v1)

Decisions (2026-10-07, user unavailable, defaults taken): **macOS 26 / iOS 26**, App Store sandboxed,
bundle id prefix `com.akshaymaloo.pixelpare`, v1 scope = **similar & duplicate photos, video compression
(3 presets), old screenshots**. The real Photos library is never touched by automated tests.

## Toolchain
- Xcode 27 at `/Applications/Xcode.app` (active dev dir is Command Line Tools) → prefix every command with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Package tests: `DEVELOPER_DIR=… swift test` (Swift Testing, `import Testing`).
- Apps: `xcodegen generate` then
  `xcodebuild -project PixelPare.xcodeproj -scheme PixelPare-macOS -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO` and
  `… -scheme PixelPare-iOS -destination 'generic/platform=iOS Simulator' build`.
- Signing: team `LDC68P74EM` in `project.yml` (automatic). The Mac app runs ad-hoc (`CODE_SIGN_IDENTITY=-`); iPhone builds need a
  registered device (see README, "Testing on iPhone").
- `ffmpeg` is available for generating test video fixtures (tests must not require it at runtime: commit small fixtures or synthesize with AVAssetWriter).

## Layout
```
Package.swift                 swift-tools 6.2 (`.macOS(.v26)` needs ≥6.2), platforms .macOS(.v26) .iOS(.v26), Swift 6 language mode
Sources/PareCore/             Foundation only. Models, grouping, ranking, savings plan, presets, journal
Sources/PareVision/           Vision/CoreImage: feature prints, dHash, sharpness, aesthetics → PareCore.ImageSignals
Sources/PareLibrary/          PhotoKit adapter (PhotoLibrary) + FolderLibrary (fixture/dev) implementing MediaLibrary
Sources/PareTranscode/        AVFoundation HEVC transcoder, size estimator, verifier
Sources/PareUI/               Shared SwiftUI views + AppModel (@Observable, @MainActor)
Tests/PareCoreTests/ PareVisionTests/ PareTranscodeTests/ PareLibraryTests/   (FolderLibrary only)
Apps/macOS/  Apps/iOS/        App entry points, Info.plist, entitlements, Assets.xcassets (AppIcon from design/icon/build)
project.yml                   XcodeGen: PixelPare-macOS, PixelPare-iOS targets depending on PareUI
```
Dependency direction: `PareUI → PareLibrary, PareVision, PareTranscode → PareCore`. Nothing depends on PareUI.

## Contracts (PareCore) — all `Sendable`
```swift
public struct MediaID: Hashable, Codable, Sendable { public let raw: String }
public enum MediaKind: String, Codable, Sendable { case photo, video, screenshot, livePhoto }
public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
  public let id: MediaID; kind; creationDate: Date?; pixelWidth, pixelHeight: Int
  public var byteSize: Int64?          // nil = unknown (iCloud-only, no public size)
  public var isFavorite, isEdited, isLocal: Bool
  public var burstID: String?
  public var duration: TimeInterval?   // video
  public var videoCodec: String?, frameRate: Double?, isHDR: Bool, isSlowMo: Bool  // video
}
public struct ImageSignals: Codable, Sendable {   // produced by PareVision
  public let id: MediaID; dHash: UInt64; featurePrint: [Float]   // L2-normalisable vector
  public let featurePrintRevision: Int; sharpness: Double; aesthetics: Double?; faceQuality: Double?
}
public enum Strictness { case conservative }      // single, not user-tunable in v1
public struct SimilarGroup: Identifiable, Codable, Sendable {
  public let id: UUID; members: [MediaID]; suggestedKeeper: MediaID
  public let reasons: [MediaID: [String]]          // e.g. "Sharper", "Less sharp face"
  public let kind: GroupKind                        // .exact | .nearIdentical | .similar
  public var favorites: Set<MediaID>                // favorites at grouping time; never removable (added in Stage 1)
  public var approval: Approval                     // .suggested | .approved(keep: Set<MediaID>) | .skipped
}
public enum Grouper {
  /// Representative clustering (NOT union-find): every member within threshold of the keeper.
  /// Near-identical = dHash Hamming ≤ 4 (library-wide). Similar = feature distance ≤ t within ±90 s or same burst.
  /// Favorites are never suggested for removal. Groups of size 1 are dropped.
  static func group(items: [MediaItem], signals: [MediaID: ImageSignals], exactHashes: [MediaID: String]) -> [SimilarGroup]
}
public enum KeeperRanker { static func rank(_ ids: [MediaID], items:…, signals:…) -> (keeper: MediaID, reasons: [MediaID:[String]]) }
public enum VideoPreset: String, CaseIterable, Codable, Sendable { case gentle, balanced, smallerResolution }
public struct EncodeSettings: Codable, Sendable { codec "hvc1", width, height, frameRate, quality: Double?, bitsPerPixel: Double, keepAudio: Bool }
public enum PresetPolicy {
  static func settings(for: MediaItem, preset: VideoPreset) -> EncodeSettings?   // nil = not offered (e.g. smallerResolution on ≤1080p)
  static func eligibility(_ item: MediaItem) -> Eligibility   // .eligible | .skipped(reason) : HDR, slo-mo, edited, already efficient, too small
  static func estimate(_ item: MediaItem, preset:) -> SizeEstimate   // range, state .estimate
}
public struct SizeEstimate: Codable, Sendable { state: .estimate|.previewReady|.final; low, high: Int64 }
public struct CleanupPlan: Sendable {   // unique-asset, de-duplicated across categories
  public var removals: Set<MediaID>; public var videoJobs: [MediaID: VideoPreset]
  public func estimatedSavings(items: [MediaID: MediaItem]) -> ClosedRange<Int64>   // each original counted once
}
public enum ScreenshotRule { static func candidates(_ items: [MediaItem], olderThan days: Int = 30, now: Date) -> [MediaID] } // never favorites
public actor OperationJournal {   // JSON file, idempotent, crash-safe (write temp + rename)
  public enum State   // journal v2 — see docs/resilience.md §3 (planned … awaitingRemovalApproval, removing, removed, skipped, failed)
  init(url: URL)   // corrupt file → moved to <name>.corrupt, starts empty
  func record(original: MediaID, state: State, newID: MediaID? = nil, error: String? = nil) throws  // one entry per original; same state = no-op; .removed is final
  func entries() -> [Entry]; func pending() -> [Entry]; func entry(for:) -> Entry?
  func canRemoveOriginal(_ id: MediaID) -> Bool   // importVerified | awaitingRemovalApproval, and newID set
}
// Stage 1 additions: CleanupPlan.init(groups:approvedScreenshots:videoJobs:); SafetyCheck.validate(plan:groups:items:) throws SafetyViolation;
// Eligibility.skipped(SkipReason); Grouper constants: nearIdenticalMaxHamming=4, similarMaxDistance=0.35 (L2 of normalised prints), similarTimeWindow=90.
// KeeperRanker.rank(_:items:signals:exactDuplicates:) takes [MediaID: MediaItem]. Tests use Swift Testing (works with DEVELOPER_DIR=Xcode).
```

## Contracts (adapters)
```swift
// PareLibrary
public protocol MediaLibrary: Sendable {
  func authorization() async -> LibraryAccess                 // .full | .limited | .denied | .notDetermined
  func requestAccess() async -> LibraryAccess
  func items() async throws -> [MediaItem]                    // photos, videos, screenshots (PHAssetMediaSubtype.photoScreenshot)
  func thumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> CGImage
  func exportVideo(_ id: MediaID, to dir: URL, allowNetwork: Bool, progress: @Sendable (Double) -> Void) async throws -> URL
  func exactHash(_ id: MediaID) async throws -> String?       // SHA-256 of original resource if local, else nil
  func importVideo(_ file: URL, preserving original: MediaItem) async throws -> MediaID  // sets creationDate, location, favorite, hidden, user-album membership
  func delete(_ ids: [MediaID]) async throws                  // → Recently Deleted (system confirm)
}
public final class PhotoLibrary: MediaLibrary   // PhotoKit
public final class FolderLibrary: MediaLibrary  // reads a directory (jpg/heic/png/mov/mp4); "import" copies into folder, "delete" moves to .trash/

// PareVision
public enum SignalExtractor { static func signals(for image: CGImage, id: MediaID) async throws -> ImageSignals }  // pins VNGenerateImageFeaturePrintRequest revision
// PareTranscode
public struct Transcoder { func transcode(input: URL, output: URL, settings: EncodeSettings, progress: @Sendable (Double)->Void) async throws }
                         // AVAssetReader/AVAssetWriter, HEVC, audio passthrough, copy metadata + orientation transform, cancellable
public enum Verifier { static func verify(original: URL, encoded: URL, minSavings: Double = 0.15, expectedDisplaySize: CGSize? = nil) async throws -> VerificationReport }
                         // decodes fully, duration ±0.1 s, audio track count, dimensions/orientation, size saving; report.passed
public enum PreviewEncoder { static func sampleEstimate(input: URL, settings:, seconds: Double = 5) async throws -> SizeEstimate  // .previewReady, ±10%
                             static func extractFrame(from: URL, at: CMTime, maxPixel: Int) async throws -> CGImage }
// EncodeSettings width/height = track natural (unrotated) size; swapped automatically if given in display orientation of a 90° track; never upscaled.
```

## UI (PareUI) — "Pocket Workshop" (see `docs/design.md`)
`AppModel` (@Observable): access state, scan progress, trays (lookalikes, videos, screenshots, blurry), CleanupPlan,
job queue driven by PareEngine's `VideoPipeline`. Surfaces: **Workbench** (home: trays of found items on a bench,
"about X worth a look"), **Light table** (lookalike groups; keeper is lit, extras slide off; approve per group),
**Video press** (preset dial with three detents — Gentle / Balanced / Smaller resolution — A/B compare on a preview encode),
**Receipt** (plan review before confirm, and the honest recap after), **Calm mode** (no animation / sound).
Mac and iOS share the views; iOS uses a single stack with the bench as root.
Sandbox entitlements: Photos (`com.apple.security.personal-information.photos-library`), user-selected read-only files.
Info.plist: `NSPhotoLibraryUsageDescription`. Dev mode: `--folder <path>` launch arg / Settings toggle uses FolderLibrary.

## Stages (all done as of 2026-10-09)
1. **Scaffold + PareCore** (+ tests) → `swift test` green.
2. **PareVision + PareLibrary** and **PareTranscode** in parallel (+ tests with fixtures in `Tests/Fixtures`).
3. **PareUI + app shells + project.yml** → both apps build; iOS screenshot from Simulator.
4. Review, fix, README update.
5. Resilient `PareEngine` pipeline (docs/resilience.md), Pocket Workshop UI rebuild, iOS gestures, UI tests,
   real-clip compression tests.

## Trays added after v1

- `TrayRules.swift` (PareCore): `ScreenRecordingRule`, `BiggestRule`, `BurstRule`, `LivePhotoRule`. `MediaItem` gained
  `isScreenRecording`, `burstPick`, `pairedVideoBytes` (decoded with `decodeIfPresent`).
- `CleanupPlan.stillJobs`; `SafetyCheck.validate(approvedVideoRemovals:)` allows a video removal only when it is
  also explicitly approved; favorites stay protected.
- `StillConverter` (PareEngine) with its own journal, `MediaLibrary.convertLivePhotoToStill` / `findStillCopy`.
- `ScanEngine` drops burst leftovers (`burstPick == false`) before grouping and blur analysis.
- Destinations `recordings|biggest|bursts|livePhotos`; launch `--screen recordings|biggest|bursts|live`.

## Safety invariants (tests must cover)
- No removal without `Approval.approved`; favorites never in removals; every group keeps ≥ 1.
- Original video deleted only when journal state is `importVerified` and user approved removal.
- Savings count each original once across categories.
- Transcoder output rejected if verification fails or saving < 15%.

## Stage 2a notes (PareVision + PareLibrary, implemented)
- `SignalExtractor.featurePrintRevision` = `VNGenerateImageFeaturePrintRequestRevision2` (pinned; legacy VN API). Also exposes `SignalExtractorError`.
- `LibraryAccess` is `String`-backed; `LibraryError` (notFound, accessDenied, exportFailed, importFailed, thumbnailFailed). `PhotoLibrary` is `@unchecked Sendable` (lock-guarded PHAsset cache).
- `PhotoLibrary.items()`: `videoCodec`/`frameRate` are nil and `isHDR` false (no cheap public source; no network); `isEdited` = adjustment/fullSize resources present; `byteSize`/`isLocal` via PHAssetResource KVC (`fileSize`, `locallyAvailable`), nil/true if absent. PresetPolicy must tolerate nil codec/frameRate.
- `FolderLibrary`: PNG without EXIF DateTimeOriginal or filename containing "screenshot" → `.screenshot`; MediaID = relative path; import → `<name>-pare.<ext>` (`-pare-N` on collision) next to the original.
- Orchestrator (library + vision) lives in PareUI, not PareLibrary.
