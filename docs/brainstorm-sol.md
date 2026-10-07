# PixelPare: fewer files, same memories

**Product thesis:** help people reclaim meaningful photo-library space without making them become storage experts—or fear losing a memory. Start with a native Mac app that excels at reviewing near-duplicates and shrinking large, ordinary videos. Reuse its decision-making core on iPhone, not its desktop interface.

Apple Photos already handles some duplicates. Differentiate through near-duplicate review, understandable video tradeoffs, and trustworthy savings. PhotoKit exposes a photo library, not the user’s complete iCloud storage account.

## 1. Feature priorities

Value means likely space saved or confidence gained; effort includes platform edge cases and support burden.

| Feature | Value | Effort | Release | Notes |
|---|---|---|---|---|
| Exact duplicates and near-duplicate groups | High | High | MVP | Separate “identical” from “similar”; never delete automatically. |
| Large-video leaderboard | Very high | Low–medium | MVP | Biggest opportunities first; show duration, size confidence, and compatibility. |
| Three video compression presets | Very high | High | MVP | Ordinary SDR videos first; estimate before downloading, measure afterward. |
| What-if savings preview | High | Medium | MVP | Update as users choose items; distinguish estimates from verified savings. |
| Best-shot recommendation | High | High | MVP | Consider sharpness, resolution, favorites, and capture timing; explain the suggestion. |
| Safety history and Recently Deleted guidance | Very high | Medium | MVP | Local operation journal; recovery belongs to Photos, not a fictional app backup. |
| Favorite/album/date preservation | Very high | High | MVP | Preserve supported fields; disclose exceptions before proceeding. |
| Screenshots and screen recordings | High | Low–medium | v1.1 | Group old captures; recordings often offer unusually good compression savings. |
| Blurry or accidental shots | Medium | Medium | v1.1 | Suggestions only; artistic blur and low-light memories are not garbage. |
| Burst review | Medium | Medium | v1.1 | Show a sequence and suggested keepers; respect burst representation. |
| Storage forecast | Medium | Medium | v1.1 | Project photo-library growth from recent captures, not a promised iCloud bill reduction. |
| Scheduled incremental scans | Medium | Medium | v1.1 | Opt-in reminders and opportunistic indexing; no unattended deletion. |
| Shortcuts / App Intents | Medium | Medium | v1.1 | “Scan library” and “Show largest videos”; no silent destructive action. |
| RAW + JPEG pair review | High for enthusiasts | High | Later | A paired asset is not necessarily two independent deletable photos. |
| Live Photo slimming | Medium | High | Later | Converting to a still loses motion/audio; explicit per-item opt-in. |
| Slo-mo optimization | Medium | High | Later | Frame rate and slow-motion adjustments must survive, or exclude the asset. |
| WhatsApp / forwarded-media suggestions | Medium | Medium–high | Later | Origin is often unavailable; use transparent heuristics, never a certainty label. |
| Widgets | Low | Medium | Later | A quiet review reminder; no private thumbnails or exaggerated savings counters. |
| External original archive | High for cautious users | High | Later | Verified export and restore manifest; never market untested archives as backups. |

**Scope boundary:** MVP supports personal-library review and supported SDR video conversion. Exclude shared-library mutations, specialized video, RAW conversion, and Live Photo flattening. Unsupported items stay visible with an explanation, not silently omitted. Do not add still-photo recompression initially: video offers larger wins with fewer format surprises.

## 2. Opinionated UX: one job, seven screens

### 1. Welcome and permission

One sentence: “Keep your memories. Reduce what they occupy.” Show the three promises: processing on-device, review before removal, and no original removed before its replacement is checked.

Ask for Photos access only after “Find savings.” Explain read/write needs plainly. With limited access, scan the selected subset and say “Selected photos only”; never report it as the entire library. On Mac, offer a persistent “How safety works” link. On iPhone, use one short onboarding sheet, not a carousel.

### 2. Free up space: the home screen

Lead with **“About 18 GB worth reviewing”**, not “18 GB freed.” Below: Similar photos, Large videos, and—later—Screenshots. Each card has one sentence, a count, and estimated savings. Keep one primary button: **Review biggest opportunities**.

Show scan progress and usable partial results. Explain that iCloud-only originals may need downloading. Avoid red gauges and fake urgency. Mac gets a Home/History sidebar; iPhone gets tabs.

### 3. Similar-photo review

Mac uses a large keeper beside a filmstrip of alternatives. Mark one **Suggested keeper**, with reasons such as “Sharper; higher resolution.” Favorites are protected by default. Users can keep multiple images, change the keeper, or skip the entire group.

Separate exact matches from near-matches. A holiday burst with different expressions is not a duplicate. Include accessible keyboard actions: keep, mark for removal, next group, undo selection.

iPhone presents the same group full-screen with pinch-to-zoom and a keeper strip. Optional swipe review changes a reversible selection only: swipe to keep or mark, never immediately delete. Keep labeled buttons available; gestures must not be required.

### 4. Video selection

Order supported videos by potential net savings, then size. Each row shows thumbnail, duration, resolution, original size or estimate, and “On device” / “Download needed.” Include filters for supported videos and large recordings.

An “Unsupported” disclosure explains HDR, slow-motion, or other restrictions. Mac supports range selection; iPhone uses obvious checkboxes. Before starting a cloud download, show estimated transfer size and allow cancellation. Do not download the whole library just to populate this screen.

### 5. Choose quality and compare

Present three plain-language presets, not bitrate sliders:

- **Gentle:** same resolution where practical; modest savings; least visible change.
- **Balanced — recommended:** preserve up to 1080p; a practical size/quality compromise.
- **Smallest:** preserve up to 720p; bigger savings, visible detail loss on large screens.

Never upscale smaller sources. Show “Estimated 1.2 GB → 540 MB” for the selected file, with a range until an encode is measured. Codec and resolution live under Details. These presets are targets, not universal savings percentages or promises of indistinguishable quality.

Offer a synchronized Original / Smaller comparison at matching timestamps, including motion and low-light scenes. Mac can show side-by-side playback; iPhone uses an A/B toggle and zoomable still frames. Preview compression must use the intended export settings, although final savings remain uncertain until the full encode. State explicitly when compression changes resolution; do not hide it behind “smart optimization.”

### 6. Review plan and run

Summarize “Keep 42 photos; remove 68; create 5 smaller videos.” Separate duplicate removals from video-original removals. Show temporary disk requirements and estimated download volume.

Default workflow: download → encode → validate → import smaller copy → verify the imported asset → offer original removal. Retaining originals remains an option, with the explicit warning that it saves no library space yet.

Final confirmation says: **“Removing items from iCloud Photos removes them on your other devices too.”** Keep the system authorization/confirmation flow. On Mac, run a resumable queue; on iPhone, show foreground progress and pause safely when background execution expires.

### 7. Results and safety history

Report “Estimated library reduction after originals are removed,” plus measured original/replacement sizes where available. Keep pending removals and retained originals separate. Do not claim an exact increase in available iCloud storage or guarantee when accounting updates.

History records what happened, not an “Undo forever” promise. Provide instructions to recover originals in Photos’ Recently Deleted, normally available for 30 days; warn that permanent deletion ends that safety net. Never offer one-click permanent purging. Explain that new compressed copies and restored originals may coexist, and let users inspect both before cleaning up.

## 3. Technical risks and mitigations

**Replacement is not in-place compression.** PhotoKit does not expose arbitrary rewriting of an existing original. Create a new asset, verify it, then request deletion separately. This changes asset identity and can disrupt links, edit history, ordering, and relationships. Persist an operation journal with original/new identifiers and states so interruptions never turn into blind retries or duplicate imports.

**iCloud-only assets and temporary storage.** Optimized libraries often lack local originals. Use authorized network-enabled resource requests, cancellation, and bounded download/encode concurrency. Preflight enough headroom for source, output, and import staging; pause if it disappears. Label size uncertainty: avoid private APIs or resource-size hacks. Cache measured sizes and invalidate them when assets change.

**Metadata is a product feature.** Preserve capture date, location when authorized, favorite status, and membership in writable user albums using supported APIs. Include container-level metadata in export testing; validate orientation, audio, duration, and color properties. Smart albums recalculate, and people recognition, edit history, captions, burst links, or specialized resource relationships may not transfer. Show a preservation checklist and block conversion when a required guarantee cannot be met.

**HDR and Dolby Vision need their own pipeline.** A playable export can still flatten highlights, alter color, or lose dynamic metadata. MVP rejects unsupported HDR rather than silently tone-mapping it. Later, build an explicit supported-device/codec matrix and test actual playback on Mac, iPhone, Photos, and exported files. Apply the same caution to cinematic, spatial, and slow-motion assets.

**Smaller is not always better.** Already-efficient video can grow or lose quality. Skip outputs that fail a minimum net-savings threshold. Validate the full file structurally, check decode completion and representative visual/audio samples, then verify imported availability. Automated validation reduces corruption risk; it does not prove perceptual equivalence or completed iCloud upload. Never claim either.

**Similarity can destroy meaningful differences.** Use perceptual hashes or Vision features to find candidates, then stricter comparisons to classify them. Temporal context helps but should not exclude genuine duplicates copied later. Avoid connected-component clustering that chains unrelated photos through borderline matches. Calibrate against faces, documents, edits, and screenshots; protect favorites and require review.

**iOS energy and lifecycle constraints.** Hardware-assisted encoding where supported, thermal-aware throttling, small batches, and resumable checkpoints matter more than background speed. Offer Wi-Fi/charging preferences. Treat background execution as opportunistic, not a guaranteed overnight service. Mac gets the same queue semantics with more permissive concurrency.

**Shared core, native edges.** A Swift Package should own grouping, ranking, savings models, preset policies, job state, and testable preservation rules. Protocol-based adapters handle PhotoKit, AVFoundation, persistence, and scheduling. Platform-specific SwiftUI presentation and lifecycle integration stay outside the core. Start with fixture-based tests and interrupted-job tests, then device integration tests against a disposable test library.

## 4. Monetization, privacy, and trust

Recommend a free useful scan and unrestricted photo-review experience, with a **one-time unlock for batch video compression**. Let users complete a small free conversion before paying. Prefer a universal Mac/iPhone purchase when the iPhone app ships; price-test roughly $20–30 rather than inventing a weekly subscription. Explain any future paid major upgrade openly.

Position it as **“Your library stays yours.”** No account, advertising, cloud AI, or thumbnail uploads. Be precise: on-device analysis can still require downloads from the user’s existing iCloud Photos account. Keep diagnostic logs free of filenames, locations, and images; diagnostics sharing is explicit and optional.

Trust means conservative defaults, honest estimates, preservation disclosures, and recoverability limits. Never guarantee subscription savings or describe Recently Deleted as an independent backup. Publish compatibility and Apple’s deletion guidance.

## 5. Ten naming directions

1. **PhotoSlim** (original working name) — clear utility; “slim” may undersell safety.
2. **MemoryRoom** — strongest emotional promise: space without losing memories.
3. **KeepBest** — excellent for review; less obviously about video.
4. **PhotoLight** — approachable and category-relevant.
5. **LibraryLift** — broader, premium utility positioning.
6. **Spacekeeper** — combines reclamation and protection.
7. **FrameWise** — thoughtful selection, less storage-specific.
8. **Reclaim Photos** — direct, action-oriented.
9. **Lighter Library** — plain-language benefit.
10. **RoomForMore** — positive, memorable, but needs a descriptive subtitle.

**Decision (2026-10-07): the app is named PixelPare.** It was clear on the App Store, pixelpare.app / pixelpare.com and a quick trademark web search; a formal USPTO/WIPO search is still to do. Keepsake, Sift, Featherweight and others were rejected over existing apps, trademarks or domains.

### Platform references

- [Apple: deleting photos, cross-device effects, duplicates, and Recently Deleted](https://support.apple.com/en-us/104967)
- [Apple: PHAssetCreationRequest](https://developer.apple.com/documentation/photos/phassetcreationrequest)
- [Apple: PhotoKit](https://developer.apple.com/documentation/photokit)
