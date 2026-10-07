# PixelPare — Technical Investigation & Architecture (draft v0.2)

> v0.2 folds in `mock-review-sol.md` (Sol 6.1 review) and `research.md`. Corrections are marked **[v0.2]**.

> Goal: free iCloud Photos space by (1) removing duplicate/similar photos and
> (2) re-encoding videos at user-chosen quality levels — on-device, private, and safe.

## 1. Can we do Mac + iOS from one codebase? — Yes

Recommended: **native SwiftUI multiplatform app + a shared Swift Package**, *not* Mac Catalyst.
PhotoKit, Vision, AVFoundation and VideoToolbox are available on both platforms with nearly identical
APIs, so 85–90% of the code can be shared. Only the shell (window/navigation, background-task
handling, a few gestures) differs.

```
pixelpare/
├── Package.swift                 # shared core, built & tested with SwiftPM
├── Sources/
│   ├── PareCore/                 # pure Swift: models, clustering, scoring, presets, savings math
│   ├── PareLibrary/              # PhotoKit adapter: scan, fetch, download-from-iCloud, delete, re-import
│   ├── PareVision/               # feature prints, hashes, sharpness / aesthetics / face-quality scoring
│   ├── PareTranscode/            # AVAssetReader/Writer + VideoToolbox HEVC pipeline, verification (SSIM)
│   └── PareUI/                   # shared SwiftUI views (cards, group grid, compare slider, savings ring)
├── Apps/
│   ├── macOS/                    # App entry, window/sidebar layout, menu commands
│   └── iOS/                      # App entry, tab/stack layout, BGContinuedProcessingTask, swipe review
├── Tools/pare-validate/          # executable validation suite (works under Command Line Tools)
└── project.yml                   # XcodeGen spec for the two app targets (as in ../filament)
```

`PareCore` has no Apple-framework dependency beyond Foundation (images cross the boundary as core-owned values; `CGImage` lives only in the adapter targets) **[v0.2]**, so the expensive logic (grouping,
best-shot ranking, savings estimation) is unit-testable on any machine and with fixtures.

Protocol seams keep the core testable and platform-neutral:

```swift
protocol MediaLibrary {           // PhotoKit in prod, fixture folder in tests / CLI
    func assets(_ kind: MediaKind) -> AsyncStream<MediaItem>
    func loadThumbnail(_ id: MediaID, maxPixel: Int, allowNetwork: Bool) async throws -> ImageRef
    func exportVideo(_ id: MediaID, version: Version, allowNetwork: Bool) async throws -> StagedFile
    func importVideo(_ file: StagedFile, copying: PreservationPlan) async throws -> MediaID  // step 1: add copy
    func verifyImported(_ id: MediaID, against: MediaID) async throws -> VerificationReport // step 2
    func delete(_ ids: [MediaID]) async throws   // step 3, only after user approves -> Recently Deleted
}
```

Create / verify / delete are deliberately separate calls, driven by a persisted, idempotent **operation journal** (original id, new id, state) so a crash never causes a duplicate import or a blind delete. **[v0.2]**

## 2. Feature 1 — Similar & duplicate photos

Pipeline (incremental, resumable, cached in a local SQLite/SwiftData store keyed by `localIdentifier` +
`modificationDate`):

1. **Enumerate** `PHAsset` images, sorted by `creationDate`. Request thumbnails (~512 px) with
   `PHImageManager` — thumbnails are available even for iCloud-only originals, so scanning
   does not require downloading the full library. (Thumbnails are usually cached, but a request can still hit iCloud — model "unavailable" results.) **[v0.2]**
2. **Exact duplicates** = byte-identical original resource (hash of the resource when local). **Near-identical candidates** = 64-bit dHash/pHash Hamming ≤ 4 — searched library-wide, not only by date, so later imports/copies are caught. **[v0.2]**
3. **Similar shots**: `VNGenerateImageFeaturePrintRequest` → `computeDistance`. **Pin the request revision** — the distance scale changed between revisions, so thresholds must be calibrated per revision. **[v0.2]**
   Only compare within a sliding **time window** (e.g. ±90 s, or same burst ID) to keep it
   O(n·k) instead of O(n²) and to avoid grouping unrelated photos of the same landmark.
   Cluster around a representative (every member must be within threshold of the keeper) — **not** union-find, which chains A≈B≈C into false groups. Thresholds are conservative and not user-tunable. **[v0.2]**
4. **Pick the best shot** per group (auto-selected "Keep"):
   - `VNCalculateImageAestheticsScoresRequest` (macOS 15 / iOS 18+) → `overallScore`, `isUtility`
   - `VNDetectFaceCaptureQualityRequest` (composite face quality — **not** an eyes-closed detector; UI says "less sharp face", not "eyes closed") **[v0.2]**
   - Sharpness = variance of Laplacian (Core Image / vImage)
   - Tie-breakers: favorite, edited, higher resolution (file size / location are weak signals only).
5. **Review**: suggestions are *not* approvals. Only groups the user explicitly approves are deleted, via `PHAssetChangeRequest.deleteAssets` → goes to *Recently
   Deleted* (see §5 caveat). The system shows its own confirmation dialog — we batch into one call.

Notes / risks
- False positives are the #1 trust killer → default to conservative thresholds, always show the group
  side-by-side, never auto-delete, never delete favorites without explicit opt-in.
- Bursts (`representsBurst`, `burstIdentifier`) and Live Photos need special handling.
- Performance target: ~2–4k photos/min on Apple Silicon for feature prints at 512 px; cache results.

## 3. Feature 2 — Video compression without visible quality loss

### The PhotoKit constraint
PhotoKit **cannot overwrite an original resource**. Editing via `PHContentEditingOutput` keeps the
original (and *adds* a rendered version → uses *more* space). So "compress" =

1. Download (`isNetworkAccessAllowed = true`, progress shown). **[v0.2]** Edited videos: exporting the *original* resource discards the user's edits — either export the current rendered version or skip edited videos in MVP.
2. Transcode to a temp file.
3. **Verify** (duration matches, frame count, audio present, quality metric ≥ threshold, size savings ≥ 15%).
4. `PHAssetCreationRequest` the new file, explicitly setting `creationDate` (re-encoding resets container timestamps), `location`, `isFavorite`,
   `isHidden`, and membership in writable user albums; copy QuickTime metadata (make/model, GPS, orientation) separately.
   Captions/titles, People, Memories and shared-album links are **not** transferable via public API. **[v0.2]**
5. **User reviews originals for removal**, then delete (Recently Deleted — see §5 caveat).

Things that are **lost or need care**: edit history (adjustments) of the original, shared-album
membership, People/face tags & memories linkage (re-derived by Photos later), Slo-mo time ramps
(`AVComposition` assets — skip or flatten with warning), Cinematic-mode depth (skip), Spatial videos (skip).

### Encoding
- Codec: **HEVC (H.265)** via `AVAssetWriter` + VideoToolbox hardware encoder; 10-bit Main10 for HDR.
- **HDR / Dolby Vision: excluded from MVP [v0.2].** Re-encoding can silently drop DV dynamic metadata to plain HLG or flatten highlights. v1.1 supports only a tested device/codec matrix.
- Rate control: prefer quality-targeted (`kVTCompressionPropertyKey_Quality`) where the encoder supports it — **probe at runtime** and fall back to a calibrated bits-per-pixel bitrate. **[v0.2]**
- Audio: pass-through (no re-encode) when AAC; otherwise AAC 192 kbps.
- Skip files already efficient (HEVC with bits-per-pixel below threshold) — show "already optimized".

### User-facing compression levels (proposal)

| Preset | What it does | Typical saving* | Visible change |
|---|---|---|---|
| **Gentle** (default) | HEVC, least compression; keep resolution & fps | ~15–40% on H.264; little on HEVC | Least change |
| **Balanced** | HEVC, more compression; keep resolution & fps | ~30–55% | Fine detail may change |
| **Smaller resolution** | HEVC, cap at 1080p (never upscale); keep fps | ~50–75% on 4K | Visible on big screens |

No custom sliders and no 60→30 fps in v1. Hide "Smaller resolution" for ≤1080p sources. Ship two presets if testing shows Gentle/Balanced are indistinguishable. **[v0.2]**

\*Production benchmarks put H.264→HEVC at 15–40% at equal perceived quality (`research.md`); measure on our own corpus. Sizes move through **Estimate → Preview ready (sample encode) → Final size**, always labelled. **[v0.2]**

Verification (gate before import): decodes fully, duration/timestamps, audio tracks, orientation, dimensions, color tags, net saving ≥ 15%. Sampled SSIM is an internal diagnostic only — never shown as a quality promise. VMAF used offline to calibrate presets. **[v0.2]**

## 4. Background work & platform differences

| | macOS | iOS |
|---|---|---|
| Long scans / encodes | Scoped `ProcessInfo.beginActivity`; resumable queue (in-flight item restarts) | `BGContinuedProcessingTask` (iOS 26) with system progress UI; fallback: foreground + `BGProcessingTask` on charger |
| Thermal | less critical | throttle on `ProcessInfo.thermalState` ≥ .serious |
| Downloads from iCloud | fine | Wi-Fi only by default; respect Low Data Mode |
| Review UX | grid + keyboard (←/→, space, ⌫) | grid + swipe cards |

## 5. Privacy & safety principles
- 100% on-device; no network except iCloud downloads by PhotoKit. No analytics by default.
- Nothing is permanently deleted by us — always Recently Deleted. Per Apple ([108922](https://support.apple.com/en-us/108922), verified): items there **don't count toward iCloud storage**, and are normally recoverable 30 days — **except** when the account is over its iCloud limit, where deletes are immediate. UI must say so; never nudge users to purge. **[v0.2]**
- Originals deleted only *after* the new video is verified, imported, re-verified, and the user approves.
- Clear "before/after" savings report.

## 6. Build & test notes (this Mac)
- `swift test` fails under Command Line Tools (swift-testing macro plugin missing) → ship a
  `pare-validate` executable target (`swift run pare-validate`), or build with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for XCTest/xcodebuild.
- App targets via XcodeGen (`project.yml`), matching the `filament` project setup.
- Test fixtures: a folder-backed `MediaLibrary` implementation so clustering/transcoding can be tested
  without touching the real Photos library.

## 7. Suggested milestones
1. **M0 – Spike (1 wk)**: CLI on a folder: feature-print grouping + HEVC transcode with 3 presets; measure
   savings & SSIM on 50 real videos (incl. HDR, slo-mo, 4K60).
2. **M1 – Mac MVP**: PhotoKit scan, Similar Photos review, Video compression queue, Recently-Deleted safety.
3. **M2 – iOS app**: same core, swipe review, background continued processing.
4. **M3 – Extras**: screenshots, blurry, large videos, Live Photo → still, widgets/Shortcuts.

## 8. Open questions
- Minimum OS: macOS 15 / iOS 18 (aesthetics scoring) or macOS 26 / iOS 26 (BGContinuedProcessingTask, Liquid Glass)?
- Distribution: Mac App Store (sandbox + Photos entitlement) vs direct download.
- Business model: one-time purchase vs free scan + paid cleanup.
