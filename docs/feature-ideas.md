# PixelPare — Cleanup feature ideas (v0.1)

Each idea becomes a **module on the Workbench** (Pocket Workshop direction). Shared safety rules apply:
suggestions only, nothing marked by default, favorites protected, explicit approval, honest estimates,
originals go to Recently Deleted (recovery not guaranteed when iCloud is over quota).

Savings figures are rough, per typical library; validate against real libraries before showing numbers.

## Ranked

| # | Module | Detection | Action | Typical saving | Effort | Release |
|---|---|---|---|---|---|---|
| 1 | **Lookalike tray** (exact / near / similar) | SHA-256, dHash, Vision feature print *(built)* | Review & remove | High | Done (core) | **v1** |
| 2 | **Video press** (HEVC copies) | PresetPolicy eligibility *(built)* | New smaller copy → review original | Very high | Done (core) | **v1** |
| 3 | **Old screenshots** | `PHAssetMediaSubtype.photoScreenshot` *(built)* + age | Review & remove | Medium | Low | **v1** |
| 4 | **Blurry shots** | Laplacian sharpness *(built)*, face capture quality, aesthetics `overallScore`/`isUtility`; exclude bursts, long exposure, motion-blur-intended (Live Photo long exposure effect) | Review & remove ("Probably blurry") | Low–medium | Low | **v1** |
| 5 | **Screen recordings** | Video with `PHAssetMediaSubtype.videoScreenRecording` | Review & remove, or press | High per item | Low | **v1** |
| 6 | **Biggest items** | Sort by resource size (`fileSize` when known) | Open in press / review | High | Low | **v1** |
| 7 | **Live Photo → still** | `photoLive` subtype | New still asset (HEIC photo resource, preserve date/location/favorite/hidden/albums) → review original. Turning "Live" off in Photos saves nothing. | ~1–3 MB each | Medium (reuses video replace flow + journal) | v1.1 |
| 8 | **Burst leftovers** | `burstIdentifier` + `representsBurst`/`burstSelectionTypes` | Keep user/auto picks, suggest the rest | Medium | Low | v1.1 |
| 9 | **Accidental shots** | Near-black/near-uniform histogram, very low aesthetics, pocket/floor (low saliency) | Review & remove | Low | Low | v1.1 |
| 10 | **ProRAW / RAW+JPEG** | `PHAssetResource` types (`.alternatePhoto`, RAW UTIs), size | Keep a HEIC copy, review RAW original | Very high per item | Medium | v1.1 |
| 11 | **ProRes / 4K60 heavy video** | Codec probe after export | Press (exists) with explicit “pro footage” warning | Very high | Low | v1.1 |
| 12 | **Saved-from-chat media** | No camera EXIF, low res, known messaging sizes, memes (text-heavy) | Review & remove | Low–medium | Medium | Later |
| 13 | **Documents & receipts** | `VNDetectDocumentSegmentationRequest`, text recognition | Export to PDF/Files, then review | Low | Medium | Later |
| 14 | **Old JPEG/PNG → HEIC** | UTI + size | New HEIC copy → review original | ~40–50% per item | Medium | Later (metadata risk) |
| 15 | **Photos of screens / QR codes** | Moiré/rect detection, barcode request | Review | Low | Medium | Later |

## Replace-style modules (7, 10, 11, 14)
All reuse the existing **replace pipeline**: export → transform → verify → import new asset with preserved
metadata → journal `importVerified` → user reviews originals separately. Never replace in place.
Edited assets (`hasAdjustments`) are excluded in v1 because PhotoKit re-import would bake or lose edits.

## Notes
- Live Photo → still loses the motion and any Live effect (loop/bounce/long exposure); copy must say so.
- Blur heuristics have false positives (night, intentional bokeh, artistic motion): never pre-mark; show the
  reason and a zoomed crop.
- All detection stays on device; nothing leaves the Mac/iPhone.
