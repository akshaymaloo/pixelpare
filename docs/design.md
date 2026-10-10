# PixelPare: less dashboard, more delightful object

The v0.2 mocks have reassuring mechanics but generic furniture: sidebar, category cards, storage ring, green checkmark. Don’t add confetti to that dashboard. Change the organizing metaphor.

**Design thesis:** make *considering and keeping memories* satisfying—not deleting more. Retain the icon’s teal→blue, white photo card and inward arrows as a recognizable visual vocabulary.

## Non-negotiable foundation

Every direction inherits the same safety spine:

- Start with zero approved removals. Distinguish suggestions, reviewed groups and approved items. Swipes only mark; labeled buttons offer every gesture. Require group approval and a separate removal-plan confirmation.
- Keep at least one photo per group; favorites are never suggested for removal, including video originals. Provide large, undimmed comparisons and **Keep group**.
- Show **Estimate → Preview ready (sample-based estimate) → Final size**. Unknown sizes stay unknown. Report net library reduction, not measured iCloud quota gains; downloads need disclosure.
- Video flow: choose settings → review plan → create and verify smaller copies → separately review originals for removal. Keeping both copies is a valid result, not “space saved.”
- **Undo mark** changes a selection, not a deletion. Recovery belongs to Photos: normally 30 days, but may be unavailable when iCloud is over its limit. Explain cross-device removal; never encourage emptying Recently Deleted.[8]
- Gentle defaults to least compression; Gentle/Balanced retain dimensions and frame rate, with possible detail changes. Smaller resolution caps at 1080p without upscaling, retaining frame rate; disable it when not distinct. No “identical quality” promise.

### Gestures

Optional, tactile shortcuts; each has a labeled button and VoiceOver actions (Mark, Undo mark, Make keeper, Next/Previous group).

- **Light table card:** swipe up marks, swipe down undoes (60 pt threshold, rubber-band follow).
- **Light table surface:** swipe left/right for next/previous group; the tray strip follows.
- **Long-press (0.35 s) on a photo:** full-screen peek; release or tap to dismiss.
- **Double-tap a non-keeper:** Make keeper.
- **Video press dial:** drag between Gentle / Balanced / Smaller resolution detents; selection haptic per detent; never starts an encode.
- **A/B compare:** drag the divider handle.
- **Workbench:** pull to refresh rescans.
- **Receipt sheet:** swipe down to dismiss, disabled while a removal or run is in progress.

Rules: gestures only mark or move, never delete, and call the same AppModel actions as the buttons. Favorites can't be marked (shake + "Protected"); the keeper resists. Calm mode and Reduce Motion turn off swipe-to-mark, animation and haptics; buttons remain.

Old screenshots are a later, explicitly reviewed paper pile—not automatically worthless.

## Six genuinely different directions

### 1. Pocket Workshop — a tiny machine for lighter memories

**Metaphor/pitch:** a tactile desktop instrument, borrowing Teenage Engineering’s compact hardware character and object-like utility.[1]

**Home:** two chunky modules on a warm workbench: photo sorting tray and video press. No storage donut. White cards and teal-blue knobs echo the icon.

**Photo review:** lift a contact sheet into a full-size light table; place labeled selection tabs beside candidates. A fixed keeper stays visible. On Mac, pointer/keyboard selection replaces dragging; iPhone offers thumb-sized buttons.

**Video:** three detented settings—**Gentle / Balanced / Smaller resolution**—with factual setting labels underneath. A press creates a *second* reel; the original visibly remains.

**Recap:** an itemized workshop receipt, separating copies created, originals kept, removals and net reduction.

**Signature:** preset detents plus the icon’s inward arrows settling around the replacement card. No mascot.

**Copy:** warm maker-language: “Let’s make some room.” / “These shots belong together.” / “Smaller copy ready. Original still here.”

**Sound/haptics:** optional wooden clicks; one light iPhone tick per settled setting.

**Risk:** a press can imply crushing memories. Never animate originals being squeezed or shredded; literal controls must remain visible.

### 2. Pip, the Memory Porter — a companion who carries, never judges

**Metaphor/pitch:** a friendly helper for an emotionally loaded chore; borrow Finch’s companion bond and Gentler Streak’s nonjudgmental encouragement.[2][3]

**Home:** Pip, a little folded white photo-card creature, waits beside two tasks.

**Photo review:** Pip holds the suggested keeper *outside* the large comparison; users decide. The character steps away during sensitive review.

**Video:** Pip presents three labeled packing sleeves, with real settings—not “good/better/best.”

**Recap:** Pip rests beside an honest result summary, equally happy when everything was kept.

**Signature:** Pip’s arms form the icon’s shrink arrows around a verified new copy.

**Copy:** reassuring: “I found some lookalikes.” / “Keeping them all is fine.” / “We can stop here.”

**Sound/haptics:** soft paper shuffle, no spoken chatter; subtle approval tick.

**Risk:** childishness, grief triggers, parasocial pressure. No pet hunger, sadness, streaks or growth tied to deleted bytes.

### 3. Contact Sheet Arcade — a puzzle you can finish without deleting

**Metaphor/pitch:** a short-session sorting puzzle, not a shooting gallery. Borrow swipe fluency from Slidebox, but not its trash gesture semantics.[4]

**Home:** choose a suggested five-group session, freely extendable; no countdown.

**Photo review:** a large keeper/candidate pair with a group strip; swipes slot *marks* into a pending tray. **Keep group** completes the puzzle equally.

**Video:** three clearly labeled preset cartridges; compare synchronized motion before applying.

**Recap:** “5 groups reviewed,” then actual outcomes—not a deletion score.

**Signature:** a pending-selection tray snaps into alignment after group approval. No mascot; abstract tiles.

**Copy:** upbeat: “Five groups. Your call.” / “Mark, don’t remove.” / “Session complete—even the keepers count.”

**Sound/haptics:** muted tile clicks; one completion chord, never deletion coin sounds.

**Risk:** compulsive speed, reward-driven mistakes, swipe-cleaner resemblance. No combos, leaderboards, deletion XP or automatic next sessions.

### 4. The Memory Edit — your library as a small independent magazine

**Metaphor/pitch:** curate an issue, not clear a bin. Oversized typography, quiet captions, white margins and teal-blue editorial marks.

**Home:** a cover with two stories: “The lookalikes” and “The long films.”

**Photo review:** generous contact sheets open into facing-page comparisons; suggested keepers are marginal annotations, not verdicts.

**Video:** three treatment cards beside a cinema-style preview, retaining exact preset names.

**Recap:** a locally generated, Wrapped-like “This edit” spread; statistics only by default, with optional user-chosen imagery.

**Signature:** a cover-to-contact-sheet transition; no mascot.

**Copy:** observant: “A little room for what’s next.” / “Which frame tells the story?” / “Your edit: 12 groups considered.”

**Sound/haptics:** quiet page flick; light chapter-boundary tick.

**Risk:** style overwhelms utility; intimate imagery leaks into sharing. Never auto-share, infer meaningful life events, or autoplay personal slideshows.

### 5. Breathing Garden — review creates room, not a quota to fill

**Metaphor/pitch:** a tiny abstract garden grows through attention. Borrow (Not Boring)’s forest-art sensibility, not an environmental-impact claim.[5]

**Home:** two paths through a small illustrated clearing, labeled Photos and Videos.

**Photo review:** a neutral comparison surface; plants live only in the margins.

**Video:** three labeled tools with factual presets; verified replacements receive a new leaf while originals stay visible in the ledger.

**Recap:** one new sprout per completed session, whether users removed anything or not; numeric results remain separate.

**Signature:** opening space between leaves as a group is reviewed. Character: a silent optional firefly.

**Copy:** gentle: “A little breathing room.” / “Keep what you love.” / “Enough for today.”

**Sound/haptics:** optional brief leaf rustle, no ambient loop.

**Risk:** misleading eco claims, visual clutter, guilt through wilting. No CO₂ equivalences, dead gardens or unattended decay.

### 6. Sunday Shelf — a satisfying tidying ritual

**Metaphor/pitch:** a calm physical shelf inspired by KonMari’s mindful keeping, without judging photographs by productivity.[6]

**Home:** choose a small pile; stop whenever ready. Later screenshots become clearly dated paper bundles.

**Photo review:** lay out one group on a linen-colored mat, compare closely, then approve selected marks. Nothing flies into a wastebasket.

**Video:** three labeled folding guides for a smaller *copy*, with original/replacement comparison.

**Recap:** a ribbon around the reviewed session and a factual ledger.

**Signature:** “Close the shelf”—save pending decisions and leave without deleting. No mascot.

**Copy:** unhurried: “One small pile?” / “Keep the whole moment.” / “Decisions saved. Nothing removed.”

**Sound/haptics:** optional fabric-like hush; soft settling tick.

**Risk:** compulsory ceremony and “spark joy” prompts that trivialize records or grief. Ritual is skippable; no compulsory gratitude.

## Ranking and recommendation

Relative concept judgments, not research findings. **5 = strongest**; cost ranks **1 = cheapest**, assuming standard SwiftUI, lightweight 2D assets and no custom 3D engine.

| Direction | Delight | Simplicity | Safety fit | Cost rank | Differentiation |
|---|---:|---:|---:|---:|---:|
| Pocket Workshop | 5 | 4 | 4 | 4 | 5 |
| Pip | 5 | 4 | 4 | 5 | 4 |
| Arcade | 4 | 4 | 2 | 3 | 2 |
| Memory Edit | 3 | 5 | 5 | 1 | 4 |
| Garden | 4 | 3 | 4 | 6 | 4 |
| Sunday Shelf | 3 | 5 | 5 | 2 | 3 |

**Primary: Pocket Workshop.** It makes both sorting and encoding feel like one distinctive product, and extends the existing icon instead of replacing the identity. Borrow **Memory Edit’s receipt**, **Sunday Shelf’s permission to stop**, and **Pip’s kindness without shipping a mascot initially**. Prototype one tray and preset selector first; custom physics, animated characters and gardens are later costs.

**Liquid Glass is chrome, not the concept.** On iOS/macOS 26, use native glass for floating navigation and controls, with opaque white media surfaces. Avoid glass-on-glass and lensing across inspection images. Apple’s guidance explicitly separates navigation from content.[7] On Mac preserve keyboard commands and resizable comparisons; on iPhone keep gestures optional.

## Eighteen small delight moments

1. First scan: a white card peeks from the tray once; real scan progress stays textual.
2. Enter review: cards fan out in 180 ms, then become stationary.
3. Pick keeper: a teal corner tab appears; image brightness never changes.
4. Mark candidate: paper-tab snap plus optional light haptic; label “Marked.”
5. Undo mark: tab slides back in 120 ms; no recovery claim.
6. Keep group: cards stack neatly; same acknowledgment as approval.
7. Favorite: fixed heart shield and “Protected”; no tempting drag target.
8. Linked zoom: both images share one crisp magnification readout.
9. Approve group: pending-plan count updates once with a small tick.
10. Preset change: one detent tick; settings text updates before preview work.
11. Download needed: cloud badge unfolds into explicit size/network disclosure.
12. Preview unavailable: empty frame says “Original still safe”; show retry.
13. Encode complete: replacement reel appears *beside* original, never over it.
14. Verification: checkmark draws only after checks succeed.
15. Already efficient: “This one travels light”; factual skip reason below.
16. Nothing found: empty tidy tray, “Nothing needs your attention.”
17. Recap: receipt unfolds once; kept originals and failures stay visible.
18. Optional About easter egg: tap the icon for a tiny arrow dance; no photo access.

Sounds off by default; respect silent mode. Haptics are optional on supported iPhones, never required feedback.

## Avoid annoyance; offer Calm mode

No nagging mascot, forced quips, streak loss, autoplay sound, repeated celebrations, daily chores or savings leaderboards. Keep jokes out of consent, failures and recovery.

**Calm mode**, available immediately: stationary cards, neutral copy, no character/easter eggs, sound or haptics; identical functionality and safety disclosures. Independently honor Reduce Motion, Reduce Transparency, Increase Contrast, Dynamic Type and VoiceOver. State changes need text and symbols, not color alone. Delight should take milliseconds, never hold the next action hostage.

## Web sources

1. [Teenage Engineering Pocket Operators](https://teenage.engineering/products/po) — compact instrument metaphor.
2. [Finch](https://finchcare.com/) — companion-based encouragement.
3. [Gentler Streak](https://gentlerstories.com/gentlerstreak) — personal progress without guilt.
4. [Slidebox](https://slidebox.co/) — swipe-first organization; deliberately different deletion semantics here.
5. [(Not Boring)](https://notbor.ing/) — Cedar forest artist collaboration.
6. [KonMari method](https://konmari.com/about-the-konmari-method/) — mindful category-based tidying.
7. [Apple: Meet Liquid Glass, WWDC25](https://developer.apple.com/videos/play/wwdc2025/219/) — adaptive controls, hierarchy and material restraint.
8. [Apple: Manage iCloud storage](https://support.apple.com/en-us/108922) — Recently Deleted accounting and over-quota recovery caveat.
9. [CARROT Weather](https://www.meetcarrot.com/weather/) — adjustable personality; inspiration for optional, not compulsory, humor.
