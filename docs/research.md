> **Correction (verified 2026-10-06):** Apple's [iCloud storage doc](https://support.apple.com/en-us/108922) says items in Recently Deleted *don't count toward iCloud storage*, and that over-quota accounts delete immediately with no recovery. Where this report implies storage only drops after a purge, Apple's doc takes precedence.

# PhotoSlim — Market & Technical Research

*Research date: 2026-10-06. Compiled for planning a macOS + iOS app that frees iCloud Photos space via duplicate/similar-photo cleanup and user-controlled video re-compression.*

---

## 1. Competitive Landscape

### Mobile "swipe cleaner" apps (freemium/subscription)

| App | Features | Pricing | UX | Common complaints |
|---|---|---|---|---|
| **Gemini Photos → rebranded CleanMy®Phone (MacPaw)** | Similar/burst/blurry/screenshot detection, card-stack review, "best shot" auto-pick, AI photo categorization (Travel/Pets/Docs), video compression, Live Photo→still, on-device processing | Pre-rebrand ~$1.99/mo–$14.99 one-time; post-rebrand **$4.99/mo, $19.99/yr, $34.99 lifetime**, 3-day trial | Tinder-style swipe/card review, "Best Shot" auto-highlight, AI folders | Forced migration from one-time → subscription angered legacy users; perceived as bloated/slower; pricey vs. free rivals; inaccurate selection on huge libraries ([macstories.net](https://www.macstories.net/reviews/gemini-photos-declutters-your-photo-library/), [luminaclean.app](https://luminaclean.app/blog/is-cleanmyphone-worth-it.html)) |
| **Clever Cleaner (CleverFiles/Disk Drill)** | AI duplicate/similar detection + "Best Shot", largest-video finder, screenshot cleanup, Live Photo compression, unlimited swipe mode, on-device | **Free, no subscription, no ads** (daily caps on some auto features) | Unlimited swipe cleanup mode, one-tap "Smart Cleanup" | Remarkably few — mainly speculation the free model won't last ([cleverfiles.com](https://www.cleverfiles.com/clever-cleaner/), [luminaclean.app](https://luminaclean.app/blog/is-clever-cleaner-really-free.html)) |
| **Slidebox** | Swipe-up delete / swipe-down favorite / tap-to-file albums, compare similar shots, undo stack | Free w/ ads; premium ~$4.99/mo or ~$49.99/yr or one-time unlock | Swipe-centric sorting rather than auto-grouping | Ad-heaviness in free tier, crashes, limited Live Photo support ([appagg.com](https://appagg.com/ios/photo-video/slidebox-photo-cleaner-app-15217970.html)) |
| **Cleanup: Phone Storage Cleaner** | Duplicates, similar screenshots/videos, video compression, email cleaner, contacts merge, secret vault, widgets | Free + IAP/subscription tiers | Explicit-approval-before-delete flow praised for trust | Privacy worries about full-library access despite on-device claims ([cleanmymac.com](https://cleanmymac.com/blog/clean-up-iphone-storage-cleaner-review)) |
| **Cleaner Kit (BPMobile)** | AI dup/similar photo+video grouping, blurry detection, contacts/calendar/email cleanup, swipe sort, video compression, Face-ID vault | Free w/ ads; **$4.99–$6.99/week**, ~$24.97 lifetime occasionally | Swipe archive/retain | Heavy ads, false-positive groupings, slow scans on huge libraries ([macpaw.com review](https://macpaw.com/how-to/cleaner-kit-clean-up-storage-review)) |
| **Swipewipe** | Swipe-to-keep/delete, "On This Day" gamified memory prompts | Free + ads/IAP | Gamified swipe | Crashes, slow loads, pricey subscription ([favvyapp.com](https://www.favvyapp.com/en/blog/swipewipe-review)) |
| **Duplicate Photos Fixer / Remo Duplicate Photos Remover** | Exact + similar duplicate detection, auto-best-pick | Fixer: $4.99 one-time, no trial; Remo: fully free, no ads | Manual compare UI (Fixer) vs. simple auto-pick (Remo) | Fixer: flags "similar" not exact dupes (false positives), nag popups ([appsmenow.com](https://appsmenow.com/reviews/146022-duplicate-photos-fixer)) |

### Desktop / power-user tools

- **PowerPhotos (Mac, Fat Cat Software)** — the strongest technical competitor for Mac: cross-*library* duplicate detection (vs. Apple's single-library-only native tool), full library merge preserving albums/keywords, batch metadata editing, smart search by size/dimensions/duration. **One-time $39.95** (no subscription) — a notable outlier in a subscription-heavy market. Desktop, window-based UX, not swipe-based. ([macstories.net](https://www.macstories.net/sponsored/powerphotos-the-ultimate-toolbox-for-photos-on-the-mac-sponsor-3/), [sixcolors.com](https://sixcolors.com/sponsor/2025/01/powerphotos-the-ultimate-toolbox-for-photos-on-the-mac-merge-or-split-photos-libraries-and-eliminate-duplicate-photos/))
- **Gemini 2 (Mac)** — general duplicate-file finder (not photo-specific), one-time license (~£29.95) or subscription from $1.95/mo, also bundled in Setapp. Well-regarded; main complaint is pricing-model confusion across purchase paths. ([macpaw.com/gemini](https://macpaw.com/gemini))

### Apple's built-in "Duplicates" album (iOS 16+ / macOS Ventura+)

- ML-based content + metadata comparison auto-populates a Duplicates utility only when matches exist; detects exact and near-identical/re-encoded copies. "Merge" keeps the highest-quality/most-complete-metadata copy, preserves album memberships, sends losers to **Recently Deleted** (30-day window, not instant purge). ([support.apple.com/iPhone](https://support.apple.com/guide/iphone/merge-duplicate-photos-and-videos-iph1978d9c23/ios), [support.apple.com/Mac](https://support.apple.com/guide/photos/remove-duplicates-pht5a3157c1d/mac))
- **Limitations:** single-library only (no cross-device/cross-library dedup — PowerPhotos' core differentiator); can take hours/days to populate on large libraries; may miss heavily edited/cropped duplicates; merge logic is an undocumented black box. ([discussions.apple.com](https://discussions.apple.com/thread/254784519), [macworld.com](https://www.macworld.com/article/1366211/how-to-use-duplicate-detection-apple-photos.html))
- **Market implication:** Apple's native tool has eroded the low end (simple exact-duplicate finders); third parties now differentiate via cross-library merge, broader device-wide cleanup (contacts/email/calendar), AI categorization, and **video compression** — which Apple does not offer at all.

### Video compression apps

Generic "Video Compress" apps offer slider/preset bitrate-resolution controls with before/after preview. Complaints concentrate on aggressive settings causing visible pixelation (especially after re-upload to social media) and on ads/paywalls rather than quality per se. ([fixthephoto.com](https://fixthephoto.com/best-video-compressor-apps.html))

### Common bonus features across the market

| Feature | Notes | Example apps |
|---|---|---|
| Screenshot cleanup | Deterministic — iOS flags screenshots via `PHAssetMediaSubtype.photoScreenshot`, no ML needed | CleanMy®Phone, Gemini Photos, Cleanup |
| Blurry/dark photo detection | On-device sharpness/exposure classifier (Laplacian-variance-style), bucketed for review | Gemini Photos, "AI Cleaning – Photo Cleaner" |
| Live Photo → still conversion | Strips ~3s video+audio component; **saves ~2–3x per-photo size** (still ~2–3MB vs. Live ~5–9MB, i.e., 3-6GB/1000 photos) | CleanMy®Phone (dedicated module) ([tidy.gallery](https://tidy.gallery/blog/live-photos-storage/)) |
| Burst cleanup / best-shot picking | Uses `PHAsset.burstIdentifier` + sharpness/eyes/smile scoring to auto-star one keeper | Photoscope, PickBurst, Picker AI (dedicated single-purpose apps) |
| Large-file/video sorting | Storage dashboard ranking biggest space consumers | CleanMy®Phone "Health" module |
| Similar video clustering | Frame-sampling + perceptual hash/embedding, harder than photo-only dedup | "Duplicate Photo & Video Finder", Sanary, Roomy |
| Contacts dedupe/merge | Fuzzy name/phone/email matching; **no "Recently Deleted" safety net** for contacts (asymmetric risk vs. photos) | CleanMy®Phone, Cleanup, Sanary |
| Other extras | Spam-email cleanup, secure PIN vault, device health/security dashboards, breach-checking (HaveIBeenPwned), storage widgets | Cleanup, Sanary |

**Suites vs. focused tools:** All-in-one suites (CleanMy®Phone, Cleanup, Cleaner Kit, Sanary) bundle 4+ features above; narrowly-focused tools (Remo, Photoscope, PickBurst) do one thing well with simpler, trust-building UX.

### Synthesis — cross-cutting market patterns

1. **Subscription fatigue is real and a genuine differentiator.** Apps that are "free forever, no subscription" (Clever Cleaner, Remo) get disproportionately positive reviews specifically because of pricing, versus the dominant $4-7/week or $20-35/year cohort that draws recurring complaints about forced trials and one-time→subscription bait-and-switch migrations.
2. **Swipe/card-stack review is the near-universal mobile UX pattern**, always paired with an auto-highlighted "best shot" and an undo/review step before final deletion — users want AI suggestions but insist on confirming before anything is removed.
3. **"On-device processing, no cloud upload" is the standard trust message** combating skepticism around full Photos-library access permission.
4. **False positives in similarity/duplicate detection are the most consistent functional complaint** industry-wide — plan for conservative thresholds, clear diff/comparison UI, and easy review/undo.
5. **The Recently-Deleted/iCloud-purge confusion is a platform-level, not app-level, problem** — users frequently (and incorrectly) blame third-party apps for "not freeing space" when the 30-day Apple retention window is the real cause. **Onboarding must proactively explain this.**
6. **Video quality complaints are secondary to ads/paywall complaints**, but before/after preview sliders are the standard mitigation UX.

---

## 2. Apple APIs & Technical Constraints

### PhotoKit fundamentals
- `PHAsset`, `PHAssetResource` (fetched via `PHAssetResource.assetResources(for:)`), `PHPhotoLibrary.shared()` singleton with mutations wrapped in `performChanges`/`performChangesAndWait`. ([developer.apple.com/documentation/photos](https://developer.apple.com/documentation/photos))
- `PHAuthorizationStatus`: `.notDetermined/.restricted/.denied/.authorized/.limited` — `.limited` (iOS 14+) requires `PHAccessLevel` (`.readWrite`/`.addOnly`) and proactive re-prompting via `presentLimitedLibraryPicker(from:)`; the system only auto-prompts once per session. ([developer.apple.com — Delivering an Enhanced Privacy Experience](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app))

### Can you replace a video in place? **No.**
- `PHAssetChangeRequest` only supports: (a) creating new assets via `PHAssetCreationRequest`, (b) `deleteAssets(_:)`, (c) modifying an *existing* asset's metadata/favorite flag — **not** arbitrary resource replacement. ([developer.apple.com/documentation/photos/phassetchangerequest](https://developer.apple.com/documentation/photos/phassetchangerequest))
- `PHContentEditingOutput`/`PHAdjustmentData` supports **non-destructive, revertible** edits (filters/crops) where the original master is always retained underneath — **this does not reduce storage** and is unsuitable for a space-saving recompression feature.
- **Required pattern for recompression:** create a brand-new asset (`PHAssetCreationRequest.forAsset()` + `addResource(with:.video, fileURL:options:)`), then `PHAssetChangeRequest.deleteAssets(_:)` the old one. Confirmed via PhotoKit docs' structural separation and corroborated on Stack Overflow. ([stackoverflow.com/q/63764116](https://stackoverflow.com/questions/63764116/how-to-delete-phasset-permanently-from-devicephotos-in-ios-sdk))
- **`deleteAssets` only soft-deletes to Recently Deleted (~30 days)** — there is no public API to force immediate/permanent deletion. This is a crucial UX point: deleting duplicates does **not** immediately free iCloud storage.

### What must be manually re-applied when creating the replacement asset
- `PHAssetCreationRequest` exposes `creationDate`, `location`, `isFavorite` directly — set these explicitly from the original asset.
- **NOT automatic:** album memberships (must re-add via `PHAssetCollectionChangeRequest.addAssets(_:)` per album), favorite status, Live Photo pairing (must reconstruct `.photo` + `.pairedVideo` resources with matching content identifiers), and embedded Exif/XMP metadata (must be merged into file bytes *before* `addResource` — `PHAssetResourceCreationOptions` does not inject Exif). ([developer.apple.com/documentation/photos/phassetcreationrequest](https://developer.apple.com/documentation/photos/phassetcreationrequest), community pitfalls on [discussions.apple.com/thread/256185035](https://discussions.apple.com/thread/256185035))

### Downloading iCloud-only originals
- `PHAssetResourceManager` (`requestData`/`writeData`) and `PHAssetResourceRequestOptions.isNetworkAccessAllowed` (must be `true` to fetch non-resident/"Optimize Storage" assets from iCloud), plus a progress handler. ([developer.apple.com/documentation/photos/phassetresourcemanager](https://developer.apple.com/documentation/photos/phassetresourcemanager))
- Practical design: use cheap thumbnail/local data for first-pass hashing/similarity scoring (`isNetworkAccessAllowed=false`), and only trigger full-resolution iCloud downloads for assets actually selected for recompression — gate behind Wi-Fi and show progress.

### Vision framework for similarity
- `VNGenerateImageFeaturePrintRequest` → `VNFeaturePrintObservation.computeDistance(_:to:)` for perceptual similarity. ([developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest))
- **Critical gotcha:** vector length/distance scale changed between OS revisions — iOS 16 revision: 2048-float unnormalized (distances 0–40+); iOS 17+ revision: 768-float normalized (distances <~2.0). **Must pin the request revision and calibrate thresholds per revision**, not documented prominently by Apple. ([Stack Overflow 77185128](https://stackoverflow.com/questions/77185128/))
- Classic perceptual hashing (pHash/aHash/dHash) has no native Apple framework — cheap/fast, good for exact recompression/resize duplicates, fails on crop/rotation. **Recommended hybrid**: pre-filter with cheap hashes, confirm ambiguous pairs with Vision feature-print distance.

### AVFoundation video re-compression
- `AVAssetExportSession` presets (`HEVCHighestQuality`, `HEVC1920x1080`/`3840x2160`, MV-HEVC spatial presets, ProRes presets for archival — **not for space-saving**) offer **no custom bitrate control**. ([developer.apple.com/documentation/avfoundation/export-presets](https://developer.apple.com/documentation/avfoundation/export-presets))
- For custom bitrate/quality, use `AVAssetWriter` + `AVAssetWriterInput` with `AVVideoCodecKey: .hevc` and `AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey, AVVideoProfileLevelKey, ...]`, mapping onto VideoToolbox's `kVTCompressionPropertyKey_*` constants (HDR metadata insertion mode, output bit depth, profile level) — **hardware encoder support varies by device/chip generation.** ([developer.apple.com/documentation/videotoolbox/compression-properties](https://developer.apple.com/documentation/videotoolbox/compression-properties))
- **HDR/Dolby Vision risk:** Dolby Vision Profile 8.4 capture (iPhone 12+) uses proprietary per-frame dynamic metadata on top of a 10-bit HLG base layer. AVFoundation/VideoToolbox APIs robustly handle the HLG base layer via `AVVideoColorPropertiesKey`, but **full DV dynamic-metadata re-authoring through a pixel-level re-encode is thinly documented and may silently downgrade DV clips to plain HLG HDR.** **Recommendation: exclude or warn on Dolby Vision assets by default** until tested.
- **Metadata/creation-date gap:** `AVAssetExportSession.metadata` lets you attach `AVMutableMetadataItem`s, but **re-encoding always stamps new internal QuickTime atom timestamps** — there is no API to force internal container timestamps to the original value. **Reliable fix: set `PHAssetCreationRequest.creationDate` at the PhotoKit layer** from the original `PHAsset.creationDate` rather than trusting the file's embedded timestamp. ([Apple Developer Forums thread 109144](https://developer.apple.com/forums/thread/109144), [Stack Overflow 52483264](https://stackoverflow.com/questions/52483264/))

### Background processing
- **`BGProcessingTask`** (iOS 13+): deferred, system-scheduled, no execution guarantee — appropriate for automatic/background-triggered maintenance (e.g., scheduled scans).
- **`BGContinuedProcessingTask`** (new in iOS/iPadOS 26, WWDC25 session 227): for continuing **user-initiated** long-running work (e.g., a tapped "Optimize Library Now" button) after backgrounding, with a system Live-Activity-style progress UI the user can cancel, and **can request background GPU access** for continued hardware-accelerated transcoding. **Apple explicitly says not to use it for automatic/background work like photo syncing** — only for explicit, user-initiated, progress-reportable actions. This maps directly onto PhotoSlim's architecture: automatic nightly dedupe scans → `BGProcessingTask`; user-tapped batch recompression → `BGContinuedProcessingTask`. ([developer.apple.com/videos/play/wwdc2025/227/](https://developer.apple.com/videos/play/wwdc2025/227/))

### App architecture
- Apple's SwiftUI multiplatform app template (one target, `#if os(macOS)` conditionals) is the recommended modern path for a fresh iOS+Mac app; Mac Catalyst remains best reserved for porting an existing heavy UIKit/iPad codebase rather than as a default for new projects. ([developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target))
- Best practice (general SPM convention, not one canonical Apple doc): isolate non-UI logic — PhotoKit scanning, Vision-based dedupe/clustering, AVFoundation/VideoToolbox compression pipeline — into a local **Swift Package** shared by both iOS and macOS targets, keeping platform UI separate.

---

## 3. What Space Actually Gets Saved

- **Deleting does NOT free iCloud storage immediately.** Deleted items move to **Recently Deleted** and still count against quota for up to **30 days** (or until manually emptied: Albums → Recently Deleted → Select → Delete All). ([support.apple.com/en-us/104967](https://support.apple.com/en-us/104967)) — this applies to Shared Photo Library deletions too (only the original uploader can permanently delete during the window).
- **iCloud always counts the full-resolution original**, regardless of "Optimize Storage" which only affects the local/on-device cached copy. ([support.apple.com/en-us/105061](https://support.apple.com/en-us/105061)) — meaning any re-processing of an "optimized" (cloud-only) asset first requires downloading the full original over the network.
- **Live Photos cost ~2–3x a plain photo** (still ~2–3MB + paired HEVC video ~3–6MB vs. a plain photo's 2–3MB) because both components are stored and counted as originals. ([tidy.gallery](https://tidy.gallery/blog/live-photos-storage/))
- **Storage counters can lag independently of the 30-day window** — users report counters stuck/not refreshing for hours to days even after emptying Recently Deleted; a widely reported, unresolved sync quirk. ([forums.macrumors.com](https://forums.macrumors.com/threads/icloud-storage-size-not-refreshing-after-deleting-files.2100765/), [discussions.apple.com/thread/256240612](https://discussions.apple.com/thread/256240612)) → **product implication: show users an explicit "empty Recently Deleted now" action and set expectations that iCloud's displayed usage may take time to update.**

### Compression ratios
- Theoretical/lab ceiling for H.264→HEVC: **~50% smaller at equal quality** (original HEVC design goal). ([getstream.io/blog/avc-vs-hevc](https://getstream.io/blog/avc-vs-hevc/))
- **Real-world production figures are lower**: Warner Bros. Discovery reports **25–40%** savings at HD/4K, **15–20%** at lower resolutions. ([streamingmedia.com](https://www.streamingmedia.com/Producer/Articles/Editorial/Featured-Articles/HEVC-vs.-H.264-Bandwidth-and-Cost-Savings-161358.aspx))
- Bitmovin's 2026 VOD benchmark at matched VMAF: **~15.5%** average with per-title encoding, up to **~24%** on cinematic content. ([bitmovin.com](https://bitmovin.com/blog/hevc-vod-encoding-efficiency-benchmark/))
- **Realistic planning range: 15–40%** file-size reduction for equal perceived quality when transcoding H.264→HEVC; treat "~50%" as a marketing/theoretical ceiling, not a guaranteed field result.
- **Re-encoding already-HEVC at a lower bitrate has diminishing returns and compounds generational loss** — each further bitrate cut removes proportionally more needed information (rate-distortion curve), and no hard benchmark was found quantifying this precisely; qualitative engineering consensus only. **Recommendation: warn users when choosing to re-compress already-HEVC content**, and prioritize true H.264→HEVC transcodes as the primary value proposition.

### Quality measurement (VMAF/SSIM) on-device
- **VMAF** (Video Multimethod Assessment Fusion), created by Netflix, fuses multiple quality features via an ML regression model into a 0–100 perceptual quality score; open-sourced at [github.com/Netflix/vmaf](https://github.com/Netflix/vmaf), which also bundles PSNR/SSIM/MS-SSIM implementations.
- **Apple provides no native VMAF/quality-scoring API** — VideoToolbox is encode/decode only, no exposed quality metric. ([developer.apple.com/documentation/videotoolbox](https://developer.apple.com/documentation/videotoolbox))
- To compute VMAF on iOS/Mac you must bundle a compiled FFmpeg with `--enable-libvmaf` (e.g., via FFmpegKit or FFmpeg-iOS) and invoke the standard `ffmpeg -lavfi libvmaf` filter — no pure-Swift native implementation exists.
- **Lighter alternative for on-device validation:** SSIM/PSNR (also in libvmaf/FFmpeg) are far cheaper computationally (no ML step) though less perceptually accurate — a reasonable pragmatic choice for a fast "did this recompression visibly hurt quality" sanity check before committing to delete the original.

---

## 4. Recommendations for PhotoSlim's Feature Set

Based on the competitive gaps and technical constraints above:
1. **Lead with "no subscription, or a fair one-time/lifetime option"** — this is the single clearest market differentiator (Clever Cleaner, Remo, PowerPhotos all prove this works).
2. **Default to swipe/card review with auto-highlighted "keep this one"** but make false-positive recovery trivial (the #1 complaint across the market).
3. **Proactively educate users about the 30-day Recently Deleted window** and provide a one-tap "empty now" flow — don't let users blame the app for iCloud storage not updating.
4. **Offer Live Photo→still conversion and screenshot/burst cleanup** as easy, near-zero-risk wins alongside the harder duplicate/video-recompression work — these are cheap to implement (deterministic flags/metadata) and deliver clearly understood savings (~2-3x per Live Photo).
5. **Be conservative with Dolby Vision/HDR content** — exclude by default or clearly warn, given documented re-encode risk.
6. **Architect compression UX around `BGContinuedProcessingTask`** (iOS 26+) for user-initiated batch jobs with visible, cancelable progress, falling back to `BGProcessingTask` for opportunistic background scans on older OS versions.
7. **Set realistic compression-savings expectations in UI**: 15-40% size reduction for H.264→HEVC, much less for re-compressing existing HEVC — don't oversell "50% smaller."

---

## 10-Bullet Summary

- **Subscription fatigue is the biggest market opportunity**: apps that are genuinely free or one-time-priced (Clever Cleaner, Remo, PowerPhotos) earn disproportionately positive reviews versus the dominant $4-7/week subscription cohort (CleanMy®Phone, Cleaner Kit) that draws recurring backlash.
- **Apple's native Duplicates album (iOS16+/Ventura+) only works within a single library**, can take hours/days to populate, and uses an undocumented merge algorithm — third parties differentiate via cross-library merge (PowerPhotos), video compression (which Apple doesn't offer), and broader device-wide cleanup.
- **False positives in similarity detection are the #1 functional complaint industry-wide** — plan for conservative thresholds, clear before/after comparison, and easy undo.
- **You cannot replace a video's underlying resource in-place with PhotoKit** — the only path is create-new-asset via `PHAssetCreationRequest` + `PHAssetChangeRequest.deleteAssets()` on the old one, manually carrying over album memberships, favorite flag, and creation date (none of which are automatic).
- **`deleteAssets` only soft-deletes to "Recently Deleted" for ~30 days** — no public API forces immediate purge, and this is the root cause of the near-universal "why didn't my iCloud storage go down" user confusion; must be addressed head-on in onboarding/UX.
- **`VNGenerateImageFeaturePrintRequest` distance scale changed between iOS 16 and 17+ revisions** (unnormalized 2048-float vs. normalized 768-float) — you must pin the revision and calibrate similarity thresholds per OS version, an undocumented gotcha.
- **Re-encoding always resets internal QuickTime container timestamps** even if you set `AVMutableMetadataItem`s — the reliable fix is setting `PHAssetCreationRequest.creationDate` at the PhotoKit layer from the original asset, not trusting the exported file's embedded metadata.
- **Dolby Vision dynamic metadata is at real risk of silent downgrade to plain HLG HDR during any pixel-level re-encode** — Apple's public APIs don't fully document DV-preserving re-authoring; default to excluding/warning on DV assets.
- **Realistic H.264→HEVC savings are 15–40% at equal perceived quality** in production benchmarks (not the oft-quoted ~50% theoretical ceiling), with diminishing/compounding-loss returns when re-encoding video that's already HEVC.
- **Easy, low-risk wins exist alongside the hard dedup/compression work**: Live Photo→still conversion saves ~2-3x per photo via a deterministic flag, screenshot/burst cleanup use native iOS metadata (no ML needed), and `BGContinuedProcessingTask` (iOS 26) is purpose-built for exactly this app's "user taps Optimize, sees live progress, can cancel" compression workflow.

*Full file written to: `/Users/akshaymaloo/Documents/Projects/photoslim/docs/research.md`*
