# PixelPare — Video pipeline resilience spec (v1)

Goal: a video job **never loses data, never duplicates, never deletes early, and always converges**
(finishes, waits for a condition with a visible reason, or stops with an honest reason) — across network
loss, iCloud download stalls, disk full, thermal throttling, app suspension/termination, crashes at any
instruction, PhotoKit errors and user cancellation of the system delete prompt.

## 1. Invariants (enforced in code and by tests)
1. **I1 Original safety** — an original is deleted only if journal state is `awaitingRemovalApproval`,
   the new asset still exists *and* re-verifies (exists, duration ±0.2 s, size > 0), and the user approved removal.
2. **I2 Exactly one copy** — at most one imported copy per original, even if the app dies between
   PhotoKit commit and journal write (reconciliation, §5).
3. **I3 Durable progress** — every step transition is written to the journal (atomic file replace) before the
   next step starts; every step is idempotent given the journal state + workspace files.
4. **I4 Convergence** — each job ends in `awaitingRemovalApproval`, `removed`, `skipped(reason)`, or
   `failed(reason)` after bounded retries; *waiting* states (network/disk/thermal/paused) are not failures.
5. **I5 No leaks** — workspace files are deleted when a job reaches a terminal state or `awaitingRemovalApproval`;
   orphaned workspaces are garbage-collected on launch.
6. **I6 Honest errors** — every non-success outcome has a user-readable reason and a classification.

## 2. Module
`PareEngine` (new library target; depends on PareCore, PareLibrary, PareTranscode). PareUI depends on it.
Replaces `PareUI/VideoJobRunner.swift`.

## 3. Job state machine (journal v2)
```
planned → preflight → downloading → downloaded → encoding → encoded → verified
        → importing(token, startedAt) → imported(newID) → awaitingRemovalApproval → removing → removed
side exits: skipped(reason) | failed(reason, class)  (terminal, retryable by explicit user "Try again")
waiting overlay: waiting(.network | .diskSpace(needed) | .thermal | .lowPower | .paused | .backoff(until))
```
Journal entry v2 fields: `original`, `state`, `preset`, `settings`, `newID?`, `importToken?`, `importStartedAt?`,
`attempts: [Step: Int]`, `lastError: {class, message}?`, `nextRetryAt?`, `sourceBytes?`, `encodedBytes?`,
`originalModificationDate?`, `updatedAt`. File format `version: 2`; v1 files migrate on load
(v1 states map 1:1; unknown → `planned`). `canRemoveOriginal` keeps v1 semantics.

## 4. Steps
| Step | Work | Retries / fallbacks | Waits on |
|---|---|---|---|
| preflight | original still exists & `modificationDate` unchanged; eligibility; free space ≥ source + 1.3×estimate + 1 GB | — (skip if gone/changed/ineligible) | disk space |
| download | `exportVideo` to `Jobs/<id>/source.<ext>.partial` → atomic rename; validate size>0 and AVURLAsset loads duration+video track; re-probe eligibility (HDR/slo-mo/codec/fps) | 6 attempts, exp. backoff 2 s→5 min, full jitter; stall watchdog 120 s without progress | network (NWPathMonitor), expensive/constrained network per setting, disk |
| encode | `Transcoder` to `encoded.mov.partial` → rename | ladder: ① preset w/ quality hint ② bitrate only ③ bitrate + AAC audio; each rung ≤ 2 attempts for transient errors; stall watchdog 60 s; partial file removed before each try | thermal ≥ .serious, low power (setting), disk |
| verify | `Verifier.verify` | correctness failure → next ladder rung; savings < 15 % → **skipped("already efficient")** | — |
| import | write `importing(token, startedAt)` **before** `performChanges`; then `imported(newID)` | 4 attempts; before each retry run reconciliation (§5) | disk |
| post-import verify | new asset exists, duration ±0.2 s, resource size ≈ encoded bytes | 3 attempts (PhotoKit can be eventually consistent) | — |
| remove (user-initiated) | re-verify new asset (I1); delete originals in batches ≤ 50 | userCancelled → stays `awaitingRemovalApproval` (declined, not error); partial failure → re-check each original: gone ⇒ `removed`, present ⇒ unchanged; already-missing ⇒ `removed`; new copy missing ⇒ back to `verified` & re-import | — |

## 5. Import reconciliation (I2)
On recovery or retry of a job in `importing` without `newID`: `library.findImportedCopy(fingerprint:addedAfter:)`
with fingerprint = original creationDate, duration ±0.2 s, encoded pixel size, excluding the original's id and
any id already in the journal. Found ⇒ adopt as `newID` (`imported`). Not found ⇒ safe to import again.

## 6. Error classification
`ErrorClassifier.classify(Error) -> ErrorClass`:
`.transient` (URLError timedOut/networkConnectionLost/notConnected*, PHPhotosError operationInterrupted,
AVError mediaServicesWereReset/operationInterrupted/sessionWasInterrupted, stall, NSCocoa file coordination)
· `.waitNetwork` (notConnectedToInternet, PHPhotosError networkAccessRequired/networkError)
· `.waitDisk` (ENOSPC, NSFileWriteOutOfSpaceError, AVError diskFull, PHPhotosError notEnoughSpace)
· `.userDeclined` (PHPhotosError userCancelled)
· `.needsUser` (access denied/limited, library unavailable)
· `.permanent` (invalid/missing resource, unsupported asset, decode failure after all ladder rungs)
· `.cancelled` (CancellationError).
Unknown errors are treated as `.transient` up to the retry cap, then `.permanent`.

## 7. Runtime
- One `VideoPipeline` actor per process; inter-process guard with `flock` on `Jobs/.lock`.
- Serial jobs; download of job N+1 may prefetch while job N encodes (bounded by disk check).
- `pause()`, `resume()`, `cancel(job)`, `retry(job)`; events via `AsyncStream<PipelineEvent>`.
- `recover()` on launch: GC orphan workspaces, reset in-flight steps to their last durable state, reconcile imports.
- Injectable `Clock/Sleeper`, `NetworkMonitoring`, `DiskSpaceProviding`, `DeviceConditions` (thermal/low power),
  and `VideoEncoding` (transcode + verify) for deterministic tests.
- Workspace: Application Support/PixelPare/Jobs (excluded from backup), not tmp — survives relaunch.
- Mac: `ProcessInfo.beginActivity(.userInitiated + idleSystemSleepDisabled)` while running.
  iOS: `BGContinuedProcessingTask`; on expiration cancel the current step — the journal resumes it later.

## 8. Tests (fault injection)
Scriptable `FakeLibrary` + `FakeEncoder` + fake conditions:
crash after every state transition (new pipeline instance, same journal/workspace) ⇒ completes exactly once;
crash between PhotoKit commit and journal write ⇒ reconciliation adopts, no duplicate; network off → waits →
resumes; disk full → waits; stall → retry; encoder ladder fallback; savings < 15 % ⇒ skipped; delete declined,
partial delete, already-deleted original, new copy vanished before delete; original edited mid-job ⇒ skipped;
**seeded randomized fault schedule ×300 runs** asserting I1–I5. Plus one end-to-end test with FolderLibrary +
real Transcoder on a generated clip.

## 9. Hardware encoder safety (incident 2026-10-09)
Four kernel panics on the dev Mac (macOS 27.0.1 / 26A434, M3 Pro/Max T6031):
`dart-ave0 … DART(CPUDART) error: PTE invalid exception on write` in `AppleT8110DART`, which is the IOMMU of the
hardware video encoder (AVE). Unified logs show `swiftpm-testing-helper` (`swift test`) as the VTEncoderXPCService
client right before the 14:36 and 14:45 panics. It was running parallel 1280×720 H.264 fixture encodes, HEVC
transcodes and a mid-encode cancel, and the encoder logged `fail to stop AVC` first. This is an OS/driver bug, but we
must not trigger it:
- **Tests**: fixtures are written as Motion-JPEG (software). Suites that use the real HEVC encoder
  (`TranscoderTests`, `Pipeline end to end`) are **opt-in** and serialized:
  `PIXELPARE_HW_ENCODE_TESTS=1 swift test --no-parallel --filter 'TranscoderTests|end to end'`.
  Run them only when you're prepared for a possible restart until Apple ships a fix.
- **App**: `EncoderGate` (PareTranscode) allows one hardware encode session per process, FIFO and
  cancellation-aware. Full transcodes and preview clips never overlap.
- Follow-up: file Feedback with `/Library/Logs/DiagnosticReports/panic-full-2026-10-09-144519.0002.panic`. If
  panics recur in the app, add a hardware-free fallback rung (software HEVC with
  `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder = false`) behind a setting.
