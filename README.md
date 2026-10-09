# PixelPare

Mac + iOS app to shrink a Photos / iCloud Photos library: review similar & duplicate photos, and re-encode
large videos to HEVC with three user-chosen levels. On-device, review-first, never auto-deletes.

**Status:** investigation & UX mocks — no app code yet.

| File | What |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Shared Swift Package core + SwiftUI Mac/iOS shells, PhotoKit/Vision/AVFoundation pipeline, risks, milestones |
| [docs/research.md](docs/research.md) | Competitors, Apple API constraints, realistic savings (cited) |
| [docs/brainstorm-sol.md](docs/brainstorm-sol.md) | Feature ranking, UX concept, monetization, names (GPT-6.1 Sol) |
| [docs/mock-review-sol.md](docs/mock-review-sol.md) | Sol's critique of mocks v0.1 + architecture — most items applied in v0.2 |
| [mocks/index.html](mocks/index.html) | Clickable-looking HTML mocks: Mac home, similar photos, videos, compare, progress/done, iPhone (open in a browser) |
| [mocks/preview.png](mocks/preview.png) | Full-page render of the mocks |
| [mocks/playful.html](mocks/playful.html) | v0.3 playful direction "Pocket Workshop" (workbench, light table, video press, receipt, iPhone, Calm mode) + alternates Pip and The Memory Edit |
| [mocks/playful-preview.png](mocks/playful-preview.png) | Full-page render of the playful mocks |
| [docs/playful-ux-sol.md](docs/playful-ux-sol.md) | Six creative directions, rankings, delight moments, Calm mode (Sol 6.1) |
| [docs/feature-ideas.md](docs/feature-ideas.md) | Ranked cleanup modules: blurry, screen recordings, Live → still, bursts, RAW, etc. (v1 / v1.1 / later) |
| [design/icon/](design/icon/) | App icon: `pixelpare-icon.svg` (master, edit this), `./make-icons.sh` → `build/` iOS + macOS `AppIcon` sets and `PixelPare.icns`; `icon-preview.png` |

Next step: **M0 spike** — CLI over a folder: feature-print grouping + HEVC transcode at 3 presets, measured on ~50 real videos.
