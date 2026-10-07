# PhotoSlim mock review — round 2

Reviewed `mocks/index.html`, the supplied `mocks/preview.png`, and `docs/architecture.md`. This is a design/architecture review, not a functional accessibility audit. Neither source document was modified.

## Overall verdict

The visual hierarchy is strong: native-feeling windows, approachable category cards, a sensible video list, and useful original/replacement disclosure. The Mac “worth reviewing” headline, protected favorites, deferred HDR support, and selection-only swipes are good decisions. Preserve them.

The main weakness is **the gap between reassurance and actual guarantees**. The interface looks conservative but can remove hundreds of unreviewed suggestions, presents sample-based predictions as measurements, and makes an incorrect claim about when iCloud space returns. Fix those before polishing the visual style.

An important correction to my earlier brainstorm: Recently Deleted is **not an unconditional 30-day safety net**. Apple documents an over-quota exception, and explicitly says its contents do not count toward iCloud storage. The review below supersedes any implication that permanent purging is required to reclaim iCloud space.

## 1. Top issues, ranked

Severity: **P0 = safety/recovery blocker; P1 = misleading primary behavior or essential usability; P2 = simplification/polish.**

| Rank | Severity | Screen | Problem | Concrete fix |
|---|---|---|---|---|
| 1 | P0 | Home, Videos, Compare, Done | “For 30 days” is unconditional. Apple says deleted assets may be removed immediately when the account exceeds its iCloud storage limit—the exact audience this product targets. | Say “Normally recoverable in Photos for 30 days; recovery may be unavailable if iCloud storage is over its limit.” Before removal, offer **Keep originals** and optional verified external export. Ask users to check iCloud storage; do not invent an automatic quota check through PhotoKit. |
| 2 | P0 | Similar Photos | “167 groups · 412 to remove” plus a global removal button can authorize removal of suggestions the user has never inspected. Three visible groups do not constitute review of 167. | Track **suggested / reviewed / approved** separately. Start with zero approved removals. Require **Approve this group**, then enable **Review removal plan** for approved groups only. Favorites remain protected; always keep at least one item per group. |
| 3 | P1 | Done | “Space returns when Photos empties Recently Deleted (5 Nov)—or empty it yourself now” is wrong for iCloud accounting and encourages destroying the recovery window. | Remove the date and purge nudge. Use “Estimated photo-library reduction: 41 GB. iCloud storage reporting may take time to update.” Explain recovery separately. Never claim a measured quota increase. |
| 4 | P1 | Home → Videos → Compare | Thumbnail-only discovery becomes “measured” savings from sample encodes without showing when originals were downloaded or how much work occurred. A five-second sample measures that segment, not the full file. | Show **Estimated**, **Preview ready**, and **Final size** as distinct states. Perform previews on demand for selected videos, disclose downloads first, and label extrapolated savings “Sample-based estimate.” Use ranges until full encodes complete. |
| 5 | P1 | Videos / Compare | **Compress 84 videos** appears to bypass an optional Compare screen containing the most important deletion/metadata disclosure. “Use Gentle” does not say whether it selects settings or starts a destructive batch. | Make the CTA **Review plan**, then **Create smaller copies**. After verified import, offer **Review originals for removal** in the foreground. “Use Gentle” becomes **Apply Gentle to selected videos**, with an explicit scope. |
| 6 | P1 | All savings surfaces | The headline can add overlapping screenshots, blurry images, similar groups, exact duplicates, and Live Photos. Selecting a favorite or keeping another image also changes savings. | Calculate a unique-asset removal plan and mutually exclusive operation choices. Count each original once; subtract replacement bytes. Recompute after each decision and show “If you approve these suggestions.” |
| 7 | P1 | Video presets / Compare | “Looks identical,” “no visible change,” quality bars, and “99.1 / 100” imply a universal quality guarantee. Twelve-frame SSIM cannot establish that. “Fine for memories” dismisses the value of the user’s memories. | Replace with factual settings and modest language: “Least compression; keeps resolution and frame rate.” Remove quality bars and the public numeric score. Explain differences through synchronized motion previews. |
| 8 | P1 | Similar Photos | Five small, dimmed thumbnails per row hide the details needed to judge faces, focus, documents, and expression. The supplied render makes labels particularly small. | Keep the grid as an overview; opening a group shows a large keeper/candidate pair with linked zoom. Do not dim candidates while judging them. Show “Suggested keeper — sharper” rather than an unexplained green KEEP stamp. |
| 9 | P1 | Compare | The checklist promises Albums, Favorite, untouched audio, and full 4K/60 without conditioning on the asset or preset. “Removed from shared albums” conflates separate library relationships. | Generate disclosure from a per-asset preservation report. Distinguish supported writable albums from unsupported relationships. Update resolution, frame rate, audio, and edit warnings when presets change. Exclude shared-library operations from MVP. |
| 10 | P1 | iPhone Home / Review | Mac says “worth reviewing”; iPhone reverts to **Free up 48.6 GB** and **Review all**. Icon-only ✕ / ↺ / ♥ conflates keeping with favoriting, and there is no visible “keep whole group” button despite the note. | Use the same qualified headline and **Review biggest opportunities**. Label controls **Mark**, **Undo mark**, **Keep**, and **Keep group**. Add **Compare with keeper** and a review-summary destination. Undoing a selection is legitimate; it is not deletion recovery. |
| 11 | P1 | Working / recovery | Pause is the only visible control; partial failure, storage exhaustion, permission revocation, and quit behavior are absent. “Open Recently Deleted” assumes an available deep link. | Add **Stop after current item**, persistent per-item states, and a retryable failure summary. Say “Resume queue after reopening”; do not imply an unfinished encode continues through quit. Validate navigation into Photos or use **Show recovery instructions**. |
| 12 | P2 | Home / sidebar | Six categories, repeated sidebar entries, a ring, and a composition bar compete with the “one number, one button” principle. “Safe to remove · 1 click” weakens the safety story. | Ship two cards: **Similar & duplicate photos** and **Large videos**. Use Home/History navigation. Remove the ring/bar and the one-click claim; defer extras rather than leaving distracting disabled cards. |
| 13 | P2 | Home / Videos | The ring claims “212 GB iCloud Photos”; the listed components total 165 GB. The home advertises compressing 86 videos while the action processes 84. | Omit unverified account totals. If keeping library estimates, show coverage and uncertainty. Say “84 eligible; 2 skipped” and let users inspect reasons. Keep counts consistent across surfaces. |

### Render and interaction specifics

The supplied preview cuts off the bottom portion of the iPhone section, so it cannot establish that the sheet CTA and lower controls fit on-screen. Regenerate an uncropped render for visual sign-off, then test actual small-phone layouts.

The source also uses fixed heights and `overflow:hidden` for content areas. Fine for a static poster, but not a production behavior: lists must scroll, footers must not cover items, and the comparison toolbar must survive narrow windows and larger text.

A full-frame 4K video cannot simultaneously fit this comparison viewport and display at 100% source-pixel zoom. Provide explicit **Fit / 100%**, synchronized panning, time scrubbing, and a few representative motion segments. Show preview generation/loading rather than promising instant preset switching.

Use real checked states, text labels, keyboard focus, and accessible names in implementation. Green KEEP and faint blue circles are insufficient state communication by themselves. Do not mistake missing JavaScript in a static mock for an application defect.

## 2. What I would remove

1. **Library composition ring and bar.** They duplicate each other, consume the prime area, and require size/account knowledge the app does not reliably have.
2. **Four MVP category cards.** Screenshots and blur can follow later; Live Photo flattening is destructive format conversion, not a first-launch recommendation. Merge exact duplicates into photo review.
3. **Strict / Normal / Loose.** Users should not tune a classifier’s safety. Use conservative defaults and a later “Show more possible matches” action, with separate unapproved suggestions.
4. **Custom compression controls.** Three presets are enough. Resolution/fps/quality sliders create support burden and contradictory promises.
5. **Quality meters and SSIM badges.** Keep diagnostics internally. A calibrated perceptual comparison is more useful than pseudo-objective green bars.
6. **Oldest sorting and extra Settings tab.** Start largest-first; put occasional preferences in a menu/sheet.
7. **Unnecessary recovery CTAs.** One **How to recover in Photos** action is enough unless reliable deep navigation has been proven.

The simplified journey is: **Home → focused category review → approved plan → create/verify copies → review original removal → results/history**. Comparison is an optional detail before encoding; safety disclosure is mandatory regardless.

## 3. Presets: your version is better for this product

I prefer **your resolution-preserving Gentle/Balanced pair** over my earlier automatic 1080p Balanced and 720p Smallest proposal. This is an archival utility, not a messaging attachment compressor. A user with 4K footage should not discover that the recommended setting silently changed what they captured.

Use:

| Preset | Promise | Presentation |
|---|---|---|
| **Gentle — default** | Highest-quality supported encode; retain source dimensions and frame rate. | “Least compression · keeps 4K/60 fps” for that specific source; estimated net savings. |
| **Balanced** | More aggressive compression; retain dimensions and frame rate. | “Smaller file · some detail may change”; same source-specific settings disclosure. |
| **Smaller resolution** | Cap resolution at 1080p without upscaling; retain frame rate by default. | “4K → 1080p · more detail loss on large screens.” |

Rename “Max savings”: it is neither mathematically maximal nor a clear description for a 1080p source. Disable **Smaller resolution** when it offers no distinct setting; never manufacture a third option. Do not bundle 60→30 fps into this preset: motion changes are a separate decision, deferred from MVP.

The disadvantage is that Gentle/Balanced differences may be hard to understand and savings may overlap. Solve that with source-specific preview results, not louder claims. If validation finds no meaningful distinction, ship two choices rather than three fake tiers. My earlier presets fit a space-first, sharing-oriented product better; yours fit preservation and trust better.

## 4. Architecture: errors and implementation risks

### Must correct before implementation

- **Section 1: “pure Foundation” contradicts `CGImage`.** The example `MediaLibrary` protocol depends on Core Graphics. Put it in an Apple-platform adapter target, or define a core-owned representation. Vision-based aesthetics/features are also not pure-Swift ranking inputs unless computed by adapters.
- **Section 1: `replace` combines creation and deletion.** This hides the most important safety boundary and implies atomicity that does not exist. Separate create, validate imported copy, approve removal, and delete; persist an idempotent journal. Cancellation/deletion refusal must leave both copies intact.
- **Section 2: thumbnails are not guaranteed available offline.** Cached thumbnails often avoid original downloads, but requests can still need iCloud access. Model unavailable/degraded results and explicit network policy. Correct the mock’s “no iCloud downloads” promise.
- **Section 2: Hamming ≤4 does not identify exact duplicates.** Perceptual hashes indicate visual similarity, can collide, and ignore metadata/resource differences. Call this “near-identical candidates”; use resource hashing for byte-identical classification when resources are accessible. Capture-date restrictions miss imported copies.
- **Section 2: time windows plus union-find create blind spots and false clusters.** Time-window-only similarity misses later copies; union-find can chain A≈B and B≈C even when A≉C. Use broader candidate retrieval for duplicates and enforce group coherence against a representative or pairwise bounds.
- **Section 2: face-quality scores are not an eyes-open detector.** `VNDetectFaceCaptureQualityRequest` gives a composite capture-quality assessment, not a guaranteed “eyes closed” classification. Add a validated classifier or remove the categorical label. Larger files and location availability are weak keeper tie-breakers, not quality guarantees.
- **Section 3: original download versus flattened edits is inconsistent.** Downloading the original resource can discard the user’s visible edits; the UI promises flattening them. Define original versus current-version export explicitly, support edited assets only with tested current-render semantics, and skip specialized compositions when unsupported.
- **Section 3: metadata copying is not automatic.** Container metadata and PhotoKit properties require separate work. Restrict album restoration to supported writable collections; titles/captions are not generally editable through a public PhotoKit asset-change API. Do not promise People tags, memories linkage, or shared-album relationship transfer.
- **Section 3: HDR/Dolby Vision is not just Main10 + HLG + metadata passthrough.** HDR formats differ; arbitrary re-encoding may invalidate or lose dynamic metadata. Align architecture with the mock’s deferred support. Even v1.1 should promise only tested combinations, not blanket preservation.
- **Section 3: constant-quality support is an assumption.** A VideoToolbox quality key is not a portable AVAssetWriter HEVC recipe or a guaranteed CRF equivalent. Probe encoder/property support and test each supported device/OS; provide a calibrated bitrate fallback. Hardware acceleration also needs capability checks.
- **Section 3: quality targets are unimplemented aspirations.** Sampled SSIM/PSNR cannot certify VMAF 95+, “no visible loss,” or full-file integrity. Validate decoding, presentation timestamps, orientation, color, audio tracks, dimensions, duration, and net size. Variable-frame-rate material makes naive frame-count equality problematic. Test perceptual quality separately on a representative corpus.
- **Section 5: 30-day recovery is not unconditional.** Apply the Apple over-quota warning above. Verification and successful local import do not prove completed iCloud upload or an independent backup. Let users retain originals; never silently trade recovery for space.

### Qualify rather than delete

- **Background work (§4):** iOS 26 continued processing is a good fit for user-started encoding, but needs progress reporting, cancellation/expiration handlers, and runtime resource checks. Background GPU availability varies. Scheduled charging work belongs to discretionary processing, not an automatic continued-processing launch. Background deletion requiring user consent should wait for foreground review.
- **Mac runtime (§4):** thermal pressure still matters. Prefer scoped process activity/power management rather than blanket “App Nap disabled.” Pausing a queue is easy; resuming a half-written encode requires explicit support or restarting that item.
- **Size/URL contract (§1/3):** PhotoKit does not expose reliable public resource byte counts for every cloud-only asset. Avoid undocumented KVC. Not every video request yields a simple persistent file URL; composition and export lifetimes belong in the adapter contract. Budget staging space and clean up only app-owned files.
- **85–90% sharing, throughput, and one-week spike (§1/2/7):** plausible hypotheses, not engineering guarantees. Benchmark download, feature extraction, validation, and encoding separately across Intel/Apple Silicon and iPhone hardware.
- **CLT test workaround (§6):** record the actual toolchain error; do not generalize one installation failure into “swift test is unavailable.” A validation executable is useful, but not a replacement for unit/integration tests under a supported toolchain.

## References

- [Apple: Manage your iCloud storage](https://support.apple.com/en-us/108922). Explicitly states that Recently Deleted does not count toward iCloud storage and documents the over-quota recovery exception.
- [Apple: Delete photos](https://support.apple.com/en-us/104967). Cross-device deletion and normal recovery behavior.
- [Apple WWDC25: Finish tasks in the background](https://developer.apple.com/videos/play/wwdc2025/227/). User initiation, progress, expiration, scheduling, and supported-resource checks.
- [Apple: Face capture quality request](https://developer.apple.com/documentation/vision/vndetectfacecapturequalityrequest).
- [Apple: PhotoKit](https://developer.apple.com/documentation/photokit). Validate detailed adapter behavior against the chosen deployment SDK.

**Acceptance bar for the next mock:** no unconditional recovery promise, zero unreviewed approved deletions, honest size states, mandatory plan confirmation, factual preset descriptions, and one large comparison surface per photo group.
