# Sync Progress Indicator — Design

**Date:** 2026-04-25

## 1. Motivation

Two end-user scenarios surface the same gap: the app gives no signal that iCloud is actively transferring data.

1. **First launch on a new device.** Welcome shows "Checking iCloud for profiles" and stays there until the entire fetch session settles. On a profile with many transactions, that wait can be minutes long. The user has no signal that anything is happening — only a static "checking" message that never changes.
2. **Returning to the app on another device.** ContentView shows stale data while CloudKit pulls in changes from the other device. The user has no way to tell whether they're looking at fresh data or a snapshot that's about to update.

The fix is a passive sync-status indicator modelled on Photos' iCloud sync status: subtle but discoverable, telling users "data is flowing" without disrupting their workflow.

## 2. Goals & Non-goals

**Goals**

- Surface "iCloud is fetching data right now" with a record count where possible.
- Surface "iCloud is uploading changes" with an exact pending-upload count.
- Surface "last synced X ago" so users can see how fresh the local view is.
- Replace the opaque "Checking iCloud" wait on Welcome with a richer "found data, downloading" experience that keeps the create-profile escape hatch available.

**Non-goals**

- Determinate download progress bar with "X of Y records." CloudKit doesn't expose total record counts ahead of time; we surface "received so far" plus a `moreComing` indeterminate signal.
- Per-record-type visibility ("downloading transactions", "downloading accounts"). One bucket — "data."
- New error UI for sync failures. Existing `SyncStatusBanner` (quota) and Welcome hero-off paths (account unavailable) are unchanged; the new footer is a complementary surface, not a replacement.
- A pause/resume button. Photos has one; we don't need it.

## 3. Architecture

A new `@Observable @MainActor` value `SyncProgress` lives alongside `SyncCoordinator` and is exposed as `syncCoordinator.progress`. It owns all the new state — phase, counters, timestamps. `SyncCoordinator`'s existing event hooks (`beginFetchingChanges`, `fetchedRecordZoneChanges`, `endFetchingChanges`, `sentRecordZoneChanges`, `accountChange`, quota errors, retry chain) feed it. Views observe `progress` directly.

This mirrors the existing extension-per-concern split inside `Backends/CloudKit/Sync/` (`+Lifecycle`, `+Zones`, `+RecordChanges`, `+Delegate`). `SyncProgress` is its own focused, unit-testable unit.

Two render targets consume `SyncProgress`:

- **`SyncProgressFooter`** — sidebar footer in `SidebarView` via `.safeAreaInset(edge: .bottom)`. macOS gets a two-line always-visible row; iOS gets a one-line compact row visible only when the sidebar drawer is open.
- **`WelcomeView` / `WelcomeStateResolver`** — the new `.heroDownloading(received:)` state reads `progress.recordsReceivedThisSession` to render the "found data on iCloud" upgrade.

## 4. State Model

```swift
@Observable @MainActor
final class SyncProgress {
  enum Phase: Equatable {
    case idle              // engine not yet started, or stopped
    case connecting        // engine started, no events flowed yet
    case receiving         // active fetch session, records arriving
    case sending           // active send, no fetch
    case syncing           // both fetch + send active
    case upToDate          // last session settled cleanly
    case degraded(Reason)  // quota / account / persistent fetch failure
  }

  enum Reason: Equatable {
    case quotaExceeded
    case iCloudUnavailable(ICloudAvailability.UnavailableReason)
    case retrying
  }

  private(set) var phase: Phase
  private(set) var recordsReceivedThisSession: Int
  private(set) var pendingUploads: Int
  private(set) var lastSettledAt: Date?
  private(set) var moreComing: Bool
}
```

Field semantics:

- `pendingUploads` is a mirror of `syncEngine.state.pendingRecordZoneChanges.count`, updated explicitly on `sentRecordZoneChanges` and after `state.add(...)` calls. The mirror exists so SwiftUI Observation tracks updates reliably; CKSyncEngine state remains authoritative.
- `recordsReceivedThisSession` accumulates modifications + deletions across all profiles for the current fetch session. Resets to zero on settle.
- `lastSettledAt` persists in `UserDefaults` (key `com.moolah.sync.lastSettledAt`). Hydrated on `SyncCoordinator.init`, written on settle, cleared on `stop()` / sign-out / profile deletion.
- `moreComing` mirrors the most recent `FetchedRecordZoneChanges.moreComing` flag. Used to hold `.receiving` across multi-batch sessions instead of flickering through `.upToDate`.

## 5. State Machine

| Trigger | Effect |
|---|---|
| `start()` completes | `.connecting` if `iCloudAvailability == .available`, else `.idle` |
| `willFetchChanges` | `.receiving` if `pendingUploads == 0`, else `.syncing` |
| `fetchedRecordZoneChanges(changes)` | `recordsReceivedThisSession += changes.modifications.count + changes.deletions.count`; capture `moreComing` |
| `sentRecordZoneChanges` | Recompute `pendingUploads`; if drops to 0 with no fetch active, evaluate settle |
| `didFetchChanges` | Evaluate settle (see below) |
| `accountChange` → unavailable | `.degraded(.iCloudUnavailable(reason))` |
| Quota error in send | `.degraded(.quotaExceeded)` |
| `refetchAttempts > 0` | `.degraded(.retrying)` |
| `stop()` | `.idle` |

**Settle condition.** Flip to `.upToDate` when:

```
didFetchChanges fires
  AND moreComing == false on the last batch (or no records arrived)
  AND pendingUploads == 0
  AND no degraded reason active
```

On settle: `lastSettledAt = Date()` (persisted), `recordsReceivedThisSession = 0`, `phase = .upToDate`.

If `moreComing == true` at session end, stay in `.receiving` — CKSyncEngine will start another fetch immediately and we don't want footer flicker. If `pendingUploads > 0` at session end with no fetch active, transition to `.sending`.

Empty fetch sessions (zero records) still settle. That's how `lastSettledAt` advances during quiet idle use.

## 6. Rendering

### macOS sidebar footer

Two-line row, ~44pt tall, with a separator above, in `SidebarView` via `.safeAreaInset(edge: .bottom)`.

Layouts by phase:

- `.upToDate` → `checkmark.icloud` · "Up to date" · "Updated 2 minutes ago"
- `.receiving` → `icloud.and.arrow.down` · "Receiving from iCloud" · "1,234 records"
- `.sending` → `icloud.and.arrow.up` · "Sending to iCloud" · "3 of 12"
- `.syncing` → `arrow.up.arrow.down.circle` · "Syncing with iCloud" · "1,234 received · 47 to send"
- `.degraded(.quotaExceeded)` → `exclamationmark.icloud` · "iCloud storage full"
- `.degraded(.iCloudUnavailable)` → `xmark.icloud` · "iCloud unavailable"
- `.degraded(.retrying)` → `arrow.clockwise.icloud` · "Retrying" · "last error 30s ago"
- `.idle` / `.connecting` → `icloud` · "Connecting…"

Top line is `.subheadline`; bottom line is `.caption` `.secondary`. "Updated X ago" uses `RelativeDateTimeFormatter` re-rendered via a `TimelineView(.periodic(every: 60))` so the relative time advances. Numeric counts use `.monospacedDigit()`.

### iOS sidebar-drawer footer

Single-line, `.caption`, only visible when the sidebar drawer is open (regular width) — parallel to Photos-iOS's "scroll to the bottom of Library to see it." Layouts:

- `.upToDate` → `checkmark.icloud` · "Up to date"
- `.receiving` → `icloud.and.arrow.down` · "Receiving · 1,234"
- `.sending` → `icloud.and.arrow.up` · "Sending · 3 of 12"
- `.syncing` → `arrow.up.arrow.down.circle` · "Syncing"
- Degraded variants use the same icons and short labels (no relative-time line).

No relative timestamp on iOS — that's the macOS-only flourish.

### Banner / footer interplay

- **Quota exceeded** stays in the existing top `SyncStatusBanner` *and* shows in the footer. Two surfaces is fine — the banner is dismissable and actionable; the footer is ambient.
- **iCloud unavailable** shows in the footer only. Welcome / hero-off already handles the user-facing remediation path.
- **Retrying** shows in the footer only.

## 7. Welcome Integration

### New state: `.heroDownloading(received: Int)`

`WelcomeStateResolver` adds a new arm between `.heroChecking` and `.picker` / `.autoActivateSingle`:

```
.heroChecking
  ↓  (progress.recordsReceivedThisSession > 0)
.heroDownloading(received: N)
  ↓  (full session settles; resolver falls through to existing arms)
.picker  /  .autoActivateSingle
```

If records never start flowing (truly empty iCloud), the path is `.heroChecking` → `.heroNoneFound` as today. The picker/auto-activate transition trigger (full session settled) is **unchanged** — we are not flipping into ContentView early.

### One-way stickiness

The `.heroChecking` → `.heroDownloading` transition is one-way for the lifetime of the Welcome view session. Stored as `@State` on `WelcomeView`; reset when the view appears. So if `recordsReceivedThisSession` dips back to 0 (e.g. counter reset between sessions), the resolver does not flip back to `.heroChecking` mid-Welcome.

The resolver itself does not enforce stickiness — it computes purely from inputs. Stickiness lives on the view, which passes a `wasDownloading: Bool` flag into the resolver to keep the state if it has ever entered `.heroDownloading` since the view appeared.

### Layout: single hero, animated transition

`WelcomeHero` renders both `.heroChecking` and `.heroDownloading`. The transition is animated in-place via `matchedGeometryEffect` on the brand and the action button, plus opacity/scale on the new download-status block.

| Element | `.heroChecking` | `.heroDownloading` |
|---|---|---|
| Logo / brand | full size, centred | shrinks slightly, moves up |
| Status line | "Checking iCloud…" small/secondary | "Found data on iCloud · 1,234 records downloaded" prominent, with download icon and progress animation |
| Action button | full prominence: "Get started", primary | de-emphasized: "Create a new profile", secondary, smaller |
| Footnote | none | "Download from iCloud will continue in the background." |

The button stays fully functional throughout `.heroDownloading`. A user who creates a fresh local profile triggers the existing create-profile flow; the in-flight CloudKit download continues and surfaces through the sidebar footer once they're past the hero.

### Welcome-view session boundary

A "session" for Welcome stickiness purposes = one mount of `WelcomeView`. `@State var hasEverDownloaded = false` lives on the view; flips true the first time the resolver returns `.heroDownloading` and never flips back. The view passes that flag into the resolver. On `.onAppear` the flag stays whatever it was; on a fresh navigation back to Welcome (e.g. after sign-out) the view is freshly mounted and the flag starts false again.

## 8. Error Handling & Edge Cases

- **Quota exceeded mid-Welcome.** Top banner appears. Welcome stays on whichever phase it was in — receive-side records continue arriving, the banner is purely about uploads.
- **iCloud goes unavailable mid-Welcome.** `accountChange` flips `iCloudAvailability` to unavailable; resolver routes to `.heroOff(reason)`. Any in-flight `.heroDownloading` is abandoned cleanly.
- **Records-flowing then session fails.** Short-retry chain kicks in (`refetchAttempts > 0`). Footer shows `.degraded(.retrying)`; Welcome stays in `.heroDownloading` (no flicker back to `.heroChecking`). If retries exhaust, long-retry timer takes over — Welcome holds `.heroDownloading` indefinitely; user can fall back to "Create a new profile."
- **App backgrounded / scene-phase changes.** No special handling. `SyncProgress` lives on `SyncCoordinator` which is app-level. On foreground, fresh sync sessions resume from current phase.
- **Test/preview backends.** `TestBackend` and `PreviewBackend` don't have a real `CKSyncEngine`. `SyncProgress` exposes internal-visibility setters for tests/previews to drive arbitrary states; production path goes through `SyncCoordinator`'s event handlers exclusively.

## 9. Persistence

`lastSettledAt` is the only persisted field. UserDefaults key `com.moolah.sync.lastSettledAt`.

- Hydrated on `SyncCoordinator.init` so the macOS footer reads "Updated 3h ago" the moment the app opens, before any sync has run.
- Written on every settle (atomic, no debounce — settles are infrequent enough).
- Cleared on `stop()` and on profile deletion / sign-out.

`recordsReceivedThisSession`, `pendingUploads`, `phase`, and `moreComing` are not persisted — they're session-scoped.

## 10. Testing

### Unit — `SyncProgress` state machine

`MoolahTests/Sync/SyncProgressTests.swift` (new):

- Each phase transition fires from the right event (matrix in §5).
- `fetchedRecordZoneChanges` increments counter by mods + dels.
- `didFetchChanges` with `moreComing == true` stays `.receiving`; with `moreComing == false` and no pending uploads, settles.
- `sentRecordZoneChanges` drops `pendingUploads` to 0 → settle if no fetch active.
- Empty fetch sessions still settle.
- `lastSettledAt` round-trips through UserDefaults (init hydrates, settle persists, stop clears).
- Degraded-reason transitions for quota / account / retry.

### Unit — `WelcomeStateResolver`

Extend `MoolahTests/Profiles/WelcomeStateResolverTests.swift`:

- New input `progress.recordsReceivedThisSession`. Index unfetched + records > 0 + `wasDownloading == false` → `.heroDownloading(received:)`. Records == 0 + `wasDownloading == false` → `.heroChecking`. Index fetched + session settled → existing arms.
- Stickiness: `wasDownloading == true` keeps `.heroDownloading` even if records drop to 0.
- Account-unavailable inputs override `.heroDownloading` → `.heroOff(reason)`.

### Integration — `SyncCoordinator` event wiring

Extend existing `SyncCoordinatorTests*` files. After firing each `CKSyncEngine.Event` through the coordinator's test harness, assert `coordinator.progress` reaches the expected phase. Catches wiring regressions where future refactors forget to feed `SyncProgress`.

### View — `SyncProgressFooter`

`MoolahTests/Features/SyncProgressFooterTests.swift` (new):

- Render with each phase, assert visible text and SF Symbol.
- `RelativeDateTimeFormatter` output handles `nil` `lastSettledAt` without throwing.
- macOS and iOS render bodies tested under their own targets.

### UI — `MoolahUITests_macOS`

Extend `WelcomeUITests`:

- New seed in `UITestSeeds` that injects a `SyncProgress` snapshot with `recordsReceivedThisSession = 1234` and `iCloudAvailability = .available`, with index not yet fetched. Test asserts:
  - `.heroDownloading` headline renders ("Found data on iCloud · 1,234 records downloaded")
  - "Create a new profile" button is present and tappable
  - Download indicator has correct accessibility label
- Separate seed per sidebar-footer state (`upToDate`, `receiving`, `sending`, degraded variants) so footer rendering is exercised end-to-end.

### Out of scope for tests

- `matchedGeometryEffect` animation timing — covered by manual visual review.
- `RelativeDateTimeFormatter` localisation — system-provided.
- Real CKSyncEngine state — we drive the coordinator's event handlers directly.

## 11. Out of Scope / Future Work

- **Pause/resume sync.** Photos has it; we don't need it now. Could be added later as a footer affordance.
- **Tap-to-detail popover.** Both platforms could grow a tap-target on the footer that surfaces last-error details, retry timer state, etc. Useful for debugging but not load-bearing for either of the original two scenarios.
- **Per-zone progress.** "Receiving Profile Foo · Profile Bar — 1,234 records." Adds noise without much benefit; one bucket is enough.
- **Show the picker as soon as index is fetched, with a per-profile "downloading" overlay.** Would let multi-profile users pick before all data is downloaded. Considered and rejected for now: increases UX complexity for a corner case (multi-profile + slow connection). Easy follow-up if it turns out to matter.
