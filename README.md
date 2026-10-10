# PixelPare

Mac + iOS app to shrink a Photos / iCloud Photos library: review lookalike photos, old screenshots and blurry
shots, and make smaller HEVC copies of large videos at three user-chosen levels (Gentle / Balanced / Smaller
resolution). On-device, review-first, never auto-deletes — an original video is only removed after its smaller
copy is imported, verified and you approve.

**Status:** early development. Shared Swift package core + resilient video pipeline are in place; the SwiftUI
apps (Pocket Workshop design) are being built.

## Layout

| Path | What |
|---|---|
| `Sources/PareCore` | Models, grouping, cleanup plan, operation journal |
| `Sources/PareVision` | Feature prints, blur / screenshot signals |
| `Sources/PareLibrary` | `PhotoLibrary` (PhotoKit) and `FolderLibrary` (dev / tests) |
| `Sources/PareTranscode` | HEVC transcoder, verifier, preview encoder, `EncoderGate` |
| `Sources/PareEngine` | Resilient, resumable video pipeline (export → encode → verify → import → approve → remove) |
| `Sources/PareUI` | Shared SwiftUI views and `AppModel` |
| `Apps/iOS`, `Apps/macOS` | Thin app shells; `project.yml` (XcodeGen) |
| `design/icon/` | App icon master `pixelpare-icon.svg`; `./make-icons.sh` builds the iOS/macOS icon sets |

## Docs

| File | What |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Shared core + SwiftUI shells, PhotoKit / Vision / AVFoundation pipeline, risks |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Module contracts |
| [docs/resilience.md](docs/resilience.md) | Video pipeline invariants, journal state machine, retries, recovery, fault-injection tests |
| [docs/design.md](docs/design.md) | "Pocket Workshop" design direction, delight moments, Calm mode |
| [docs/feature-ideas.md](docs/feature-ideas.md) | Ranked cleanup modules (v1 / v1.1 / later) |
| [docs/research.md](docs/research.md) | Competitors, Apple API constraints, realistic savings |
| [mocks/playful.html](mocks/playful.html) | Visual spec (open in a browser); `playful-*.png` renders |

## Build

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build && swift test
xcodegen generate   # then open PixelPare.xcodeproj
```

Set your `DEVELOPMENT_TEAM` in `project.yml` (or Xcode → Signing) to run on a device.

> **Real encode tests are opt-in.** Hardware VideoToolbox encodes from `swift test` have caused kernel panics on
> macOS 27.0.1 (see `docs/resilience.md` §9). Fixtures use Motion-JPEG, and the real HEVC suites run on Apple's
> *software* HEVC encoder:
>
> ```sh
> PIXELPARE_SOFTWARE_ENCODE=1 swift test --no-parallel --filter 'TranscoderTests|folderLibraryWithRealTranscoder'
> ```
>
> Compression on phone-like clips (every preset, with savings and an SSIM quality score):
>
> ```sh
> scripts/make-test-videos.sh          # ffmpeg (software x264/x265) → .scratch/videos
> PIXELPARE_SOFTWARE_ENCODE=1 PIXELPARE_TEST_VIDEOS=.scratch/videos PIXELPARE_TEST_OUTPUT=.scratch/video-output \
>   swift test --no-parallel --filter pipelineCompressesPhoneLikeClips
> scripts/score-test-videos.sh         # SSIM of each copy against its original
> ```
