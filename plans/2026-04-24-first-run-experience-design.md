# First-Run Experience Redesign — Design Spec

**Status:** Draft — pending user review
**Date:** 2026-04-24
**Related code:** `Features/Profiles/Views/ProfileSetupView.swift`, `App/ProfileWindowView.swift`, `App/ProfileRootView.swift`, `Features/Profiles/ProfileStore.swift`, `Features/Profiles/ProfileStore+Cloud.swift`, `Backends/CloudKit/Sync/SyncCoordinator.swift`, `Backends/CloudKit/Sync/SyncCoordinator+Zones.swift` (`handleAccountChange`), `Backends/CloudKit/Sync/SyncCoordinator+Lifecycle.swift` (`completeStart`, `endFetchingChanges`)

---

## 1. Context & Goals

Moolah's current first-run screen (`ProfileSetupView`) gives equal prominence to three backends: iCloud, Moolah server, and Custom Server. It also fails to tell a user on a fresh device that iCloud might already hold their profile — so a user reinstalling on a new Mac could easily create a new profile before iCloud finishes catching up, ending with two profiles they didn't want.

This redesign aligns the first-run path with where the product is going:

1. **Default to iCloud.** Moolah-server connections become a power-user affordance set up later from Settings. (Custom-server and Moolah-server entries remain available in Settings → Add Profile unchanged — see §2.)
2. **Acknowledge the "new device, existing iCloud data" case.** Show a progress cue while iCloud fetches, and let the user create a new profile anyway if they choose.
3. **Treat no-profiles-from-iCloud as a setup workflow.** A first-time user sees a proper welcome moment and a single-field create-a-profile form — not a three-way backend picker.
4. **Speak with the brand voice** ("Your money, rock solid.", "Solid money. Chill vibes.") rather than the generic "Personal finance, your way." currently shown.

### Non-goals

- No redesign of `SessionRootView`, profile switching, or any post-sign-in UX.
- No change to `ProfileFormView` (Settings → Add Profile sheet).
- No deletion or deprecation of the `.moolah` / `.remote` backend types at this step — `RemoteBackend` continues to exist and work, we only change its discoverability.

---

## 2. Scope

**In scope:**

- Replace `ProfileSetupView` with a new `WelcomeView` state-machine view.
- Extend `SyncCoordinator` with an observable `iCloudAvailability` property driven by the existing `handleAccountChange` event and an initial `CKContainer.default().accountStatus()` probe in `completeStart`. Surface the property to view code via `ProfileStore` (a pass-through, so the view contract is unchanged).
- Expose a way for `WelcomeView` to know whether the initial sync fetch of the `profile-index` zone has completed at least once (so the "Checking iCloud…" status can transition to "No profiles in iCloud" rather than spin forever).
- Update routing in `App/ProfileWindowView.swift` (macOS) and `App/ProfileRootView.swift` (iOS) to present `WelcomeView` instead of `ProfileSetupView` / bare `ProgressView`.
- Copy changes aligned with `guides/BRAND_GUIDE.md`.

**Out of scope:**

- **`ProfileFormView` (Settings → Add Profile) is explicitly unchanged.** Moolah-server and Custom-Server remain reachable there.
- Merging / migrating existing local profiles into iCloud.
- Any redesign of `SessionRootView`, `WelcomeView.swift` in `Features/Auth/` (which is the *sign-in* welcome, not first-run — will need renaming; see §7).
- Removing `BackendType.moolah` or `.remote` enum cases.

---

## 3. User Flows

### 3.1 First launch — iCloud available, no profiles yet

1. App launches. `ProfileStore` has no local profiles, `SyncCoordinator.iCloudAvailability == .available`, `SyncCoordinator.isFirstLaunch == true`.
2. `WelcomeView` renders the **branded hero** (state 1): hero title, brand subhead, "Get started" button, quiet "Checking iCloud for your profiles…" status line with spinner.
3. In the background, `SyncCoordinator` performs its first fetch for the `profile-index` zone.
4. One of three things happens, in order:
   - **(a)** Exactly one profile arrives from iCloud → auto-activate it, the window transitions to `SessionRootView`. No user action needed. *Guard:* auto-activation is suppressed when `WelcomeView.phase == .creating` — see §3.3 and §8.
   - **(b)** Two or more profiles arrive → swap the hero for the **picker** (state 5): "Welcome back. You have profiles in iCloud. Pick one to open." Rows for each profile plus a "+ Create a new profile" row at the bottom.
   - **(c)** The `profile-index` zone fetch completes with zero profiles → the status line text changes from "Checking iCloud for your profiles…" to "No profiles in iCloud yet." The spinner fades. The "Get started" button is unchanged.
5. At any point during (3), the user can tap "Get started" and proceed into the **create-profile form** (state 2). Background iCloud fetching continues; see §3.3 for the mid-form arrival case.

### 3.2 First launch — iCloud unavailable

1. App launches. `iCloudAvailability == .unavailable(...)` (not signed in, entitlements missing, restricted, etc.).
2. `WelcomeView` renders the **branded hero with off-chip** (state 4): same hero as 3.1 but with an inline chip under the CTA: "iCloud sync is off. Your profile will be saved on this device." with an "Open System Settings" link (macOS: opens System Settings → Apple ID → iCloud; iOS: opens the iCloud pane of Settings).
3. User taps "Get started" → create-profile form (state 2). No background spinner (no iCloud check to run).
4. Profile is created as a `BackendType.cloudKit` profile (see §6.3 — pending records sit in the `CKSyncEngine` / SwiftData store until iCloud becomes available, at which point backfill picks them up).
5. If `iCloudAvailability` flips to `.available` while the user is on the welcome hero or in the form, the off-chip / spinner updates live, and subsequent cloud-profile arrivals follow the §3.3 path.

### 3.3 Mid-form iCloud profile arrival

1. User tapped "Get started" and is typing into the **create-profile form** (state 2). Spinner line under the form reads "Still checking iCloud…"
2. iCloud returns one or more profiles.
3. The form sprouts a non-blocking **brand-gold advisory banner** above it (state 3): "Found '<label>' in iCloud. You can open it instead of creating a new one." Actions: **Open**, **Dismiss**.
   - **Open** → switch to that profile's session (abandoning any input typed into the form). For multi-profile arrivals, the banner reads "Found N profiles in iCloud. — **View**" and tapping View swaps the form for the picker (state 5) with the typed name passed as a draft (user's input is **not** discarded in this case — if they pick "+ Create a new profile" from the picker, they land back in the form with their input intact).
   - **Dismiss** → banner disappears for the rest of this session. User stays in the form. Further profile arrivals during this session do **not** re-surface the banner — the user has explicitly said "I'm creating a new one." Any additional profiles that synced down remain available from the profile menu after setup completes.
4. If the user taps "Create Profile" before tapping Open/Dismiss, the profile is created and the iCloud profile becomes visible from the profile menu afterward. The "Create Profile" action must check `phase == .creating` and skip any auto-activation that `ProfileStore.loadCloudProfiles` would otherwise trigger (see §8 race-condition note).

### 3.4 Subsequent launches

Unchanged — existing routing. `profileStore.hasProfiles == true` lands in `SessionRootView` immediately. `WelcomeView` is never shown once any profile exists.

---

## 4. Visual Design

### 4.1 Hybrid brand/system split

- **Branded hero** (Brand Space navy `#07102E`, SF Pro Display system font via `.font(.largeTitle.bold())` and similar; Income Blue primary button; Balance Gold eyebrow-label accent) for states **1** (welcome + checking) and **4** (iCloud unavailable).
- **System materials** (`.formStyle(.grouped)`, default window background, `.borderedProminent` buttons with system tint) for states **2** (create form), **3** (form + banner), and **5** (picker).

**Colour-token discipline.** Brand hex values are allowed inside `WelcomeHero.swift` (and its subviews `ICloudStatusLine.swift` and `ICloudOffChip.swift`, which ride on the dark hero), and inside `ICloudArrivalBanner.swift`. They are expressed as private `Color(red:green:blue:)` constants scoped to those files — **never** as project-wide `Color` extensions. `CreateProfileFormView` and `ICloudProfilePickerView` use system semantic colours exclusively per `guides/UI_GUIDE.md` §5. The arrival banner is drawn with brand Balance Gold `#FFD56B` on a translucent fill, with dark brand text on top; this is a deliberate brand-moment appearance that persists through Dark Mode. We keep it brand because it's the one system-screen element that sits alongside the hero narratively (iCloud has something for you) — the rest of the form / picker chrome is system-themed.

**macOS window chrome for the hero.** States 1 and 4 extend the brand surface edge-to-edge. The hosting window uses `.windowStyle(.hiddenTitleBar)` and the hero lays out into the full window rect (traffic-light buttons float over the navy surface). Without this, macOS renders a default grey titlebar band that breaks the hero. On transition into states 2/3/5, the window reverts to standard chrome via a container-level `.toolbar { }` with an empty principal placement, so the system titlebar + blur material returns. (Implementation hint: the simplest way is to use one window for WelcomeView and reinstall standard chrome at the same time as the phase transition — see §7 for component boundaries.)

### 4.2 Typography & layout

All hero text must scale with Dynamic Type. Avoid hardcoded point sizes; use SwiftUI text styles with `.bold()` / `.font(.largeTitle.bold())` / etc. Pad for comfortable reading at the largest accessibility sizes.

Fixed max-width on hero subhead (~320pt) so lines don't sprawl on wide macOS windows.

### 4.3 Accessibility

- **Colour contrast:** all brand-on-Space pairings verified ≥ WCAG AA (spot-checked during brainstorming: min 5.5:1 for the Income Blue button text, 8:1+ for every other pair).
- **VoiceOver:** hero title + subhead get `.accessibilityAddTraits(.isHeader)`; status line has `.accessibilityLabel("Checking iCloud for your profiles")`; the arrival banner is announced as `.accessibilityLiveRegion(.polite)` when it appears; spinner marked `.accessibilityAddTraits(.updatesFrequently)`. The banner `.accessibilityLabel` combines the title, body, and the two actions so a VoiceOver user hears "Found Household in iCloud. You can open it instead of creating a new one. Open. Dismiss."
- **Reduce Motion:** spinner uses system `ProgressView()` (iOS / macOS honour motion reduction). No bespoke transition animations — use the `withAnimation(reduceMotion ? nil : .default)` pattern already used in `ProfileSetupView`.
- **Increase Contrast / Reduce Transparency:** brand states (1, 4) use solid Brand Space — no translucency to strip. System states (2, 3, 5) use system materials, which adapt automatically.
- **Keyboard navigation (macOS):** initial focus goes to the primary CTA (`.focused($focus, equals: .primaryCTA)` on the Income Blue button). The button uses `.buttonStyle(.borderedProminent)` on the system-styled screens for automatic focus-ring treatment; on the hero it uses a custom button style and therefore declares `.focusable(true)` + `.onKeyPress(.return) { performPrimaryAction() }` explicitly. Tab order = primary CTA, then "Open System Settings" link (state 4) or banner actions (state 3), then the Advanced disclosure (state 2). Verify in Full Keyboard Access mode on macOS 26.
- **iOS haptics:** on iOS, `UIImpactFeedbackGenerator(style: .medium)` fires on the "Get started" tap; `UINotificationFeedbackGenerator().notificationOccurred(.success)` fires when `Create Profile` completes successfully. Reasoning: the brand voice is "permission-giving" and the satisfying physical confirmation matches "Set it up. Then go live your life." No haptics on macOS.
- **Light Mode:** the hero is always dark. That is intentional — it's a splash / welcome moment. A Light-Mode user will see a dark → light transition at the Get Started tap. Acceptable, because the dark state is brief by design and the brand surface is the first impression we want.

### 4.4 Approved copy

| Slot | Copy |
|---|---|
| Hero eyebrow label | `Moolah` (rendered with `.textCase(.uppercase)`, tracking +0.15em, Balance Gold) |
| Hero title | `Your money,\nrock solid.` (second line in Balance Gold) |
| Hero subhead | `Money stuff should be boring. Locked down, sorted out, taken care of — so the rest of your life doesn't have to be.` |
| Primary CTA (welcome) | `Get started` |
| Checking status | `Checking iCloud for your profiles…` |
| No profiles found | `No profiles in iCloud yet.` |
| iCloud off chip | Title `iCloud sync is off.` / body `Your profile will be saved on this device.` / link `Open System Settings` |
| Form title | `Create a profile` |
| Form subtitle | `Just give it a name. You can tweak the rest later.` |
| Form name label | `Name` |
| Form Advanced disclosure | `Advanced` |
| Form currency label | `Currency` |
| Form FY month label | `Financial year starts` |
| Primary CTA (form) | `Create Profile` |
| Cancel (form) | `Cancel` |
| Banner (single) | `Found '<label>' in iCloud.` / sub `You can open it instead of creating a new one.` / actions `Open` `Dismiss` |
| Banner (multi) | `Found <N> profiles in iCloud.` / action `View` `Dismiss` — **open question**: reviewer suggested warmer phrasing ("Looks like you've got N profiles in iCloud." or "You've got N profiles waiting."). Defer to user — see §10. |
| Picker title | `Welcome back.` |
| Picker subtitle | `You have profiles in iCloud. Pick one to open.` |
| Picker row meta | `<currency code> · <account count> account(s)` — the count renders inside a `Text(...)` with `.monospacedDigit()` applied (per `guides/UI_GUIDE.md` §4) so incoming changes don't cause row-width jitter |
| Picker footer CTA | `+ Create a new profile` |

All copy is `String(localized:)`-wrapped.

---

## 5. State Machine

`WelcomeView` owns a small `@State` enum for the *interaction phase*, and observes `ProfileStore` + `SyncCoordinator` for *data state*. The combination yields which of the five layouts to show.

```swift
enum InteractionPhase {
  case landing         // User hasn't tapped Get Started yet
  case creating        // User is filling out the create-profile form
  case pickingProfile  // User is choosing between multiple iCloud profiles
}
```

State resolution (pseudocode):

```
if profileStore.cloudProfiles.count == 1
   && phase == .landing
   && !bannerDismissedThisSession:
  → auto-activate that profile; this view unmounts
else if phase == .pickingProfile
     || (profileStore.cloudProfiles.count >= 2 && phase == .landing):
  → state 5 (picker)
else if phase == .creating:
  → state 2 (form), with
     state 3 banner overlay if
       cloudProfilesCount > 0 &&
       !bannerDismissedThisSession &&
       cloudProfilesCount changed while phase == .creating
else if iCloudAvailability == .unavailable(...):
  → state 4 (hero + off chip)
else:
  → state 1 (hero + checking)
```

**First-fetch-complete flag.** The "Checking iCloud…" status line transitions to "No profiles in iCloud yet." once a fetch session that actually interrogated the `profile-index` zone has completed. This is *not* "any fetch session ended" — see §6.2 for the precise hook.

---

## 6. Data Model Changes

### 6.1 `SyncCoordinator.iCloudAvailability`

Per `guides/SYNC_GUIDE.md` Rule 8, all CloudKit account-state handling belongs inside `SyncCoordinator`. The observable property lives on the coordinator; `ProfileStore` exposes a pass-through computed `var iCloudAvailability: ICloudAvailability { syncCoordinator.iCloudAvailability }` so view code remains oriented around `ProfileStore`.

```swift
enum ICloudAvailability: Equatable {
  case unknown        // initial; no probe yet, OR .couldNotDetermine (transient)
  case available
  case unavailable(reason: UnavailableReason)

  enum UnavailableReason: Equatable {
    case notSignedIn              // CKAccountStatus.noAccount
    case restricted               // CKAccountStatus.restricted
    case temporarilyUnavailable   // CKAccountStatus.temporarilyUnavailable
    case entitlementsMissing      // CloudKitAuthProvider.isCloudKitAvailable == false
  }
}

@Observable @MainActor final class SyncCoordinator {
  ...
  var iCloudAvailability: ICloudAvailability = .unknown
}
```

**`CKAccountStatus` → `ICloudAvailability` mapping.** Call out explicitly:

| `CKAccountStatus` | Maps to |
|---|---|
| `.available` | `.available` |
| `.noAccount` | `.unavailable(.notSignedIn)` |
| `.restricted` | `.unavailable(.restricted)` |
| `.temporarilyUnavailable` | `.unavailable(.temporarilyUnavailable)` |
| `.couldNotDetermine` | `.unknown` (**transient** — we keep "Checking iCloud…" behaviour rather than dropping to state 4; retry happens on next `CKAccountChanged` notification) |
| Any thrown error | `.unknown` (same reasoning) |
| `CloudKitAuthProvider.isCloudKitAvailable == false` (entitlements) | `.unavailable(.entitlementsMissing)` — set synchronously at coordinator init, skips the account probe |

**Lifecycle.**

- **Initial probe:** in `SyncCoordinator.completeStart()` (after the engine is installed on the main actor), schedule an async probe via `CKContainer.default().accountStatus()` and update `iCloudAvailability`. Until the probe returns, the value stays `.unknown`, which `WelcomeView` renders as state 1 (spinner + "Checking iCloud…") — correct behaviour.
- **Subsequent changes:** `SyncCoordinator` already receives `CKSyncEngine.Event.accountChange` via `handleAccountChange` (in `SyncCoordinator+Zones.swift`). Extend that method to map the account-change type to `iCloudAvailability` alongside the existing zone / backfill work. **No new `CKAccountChangedNotification` observer is registered** — `CKSyncEngine` already surfaces account changes through its delegate path, and a duplicate observer would violate SYNC_GUIDE Rule 8 (single source of truth for account changes).
- **Synthetic first-launch `.signIn` guard.** SYNC_GUIDE notes that `CKSyncEngine` synthesises a `.signIn` event on every initialisation that lacks saved state. The existing `isFirstLaunch` guard inside `handleAccountChange` is preserved — the new availability update is unconditional, but the zone-reset / re-queue behaviour remains gated by `isFirstLaunch` exactly as today.

Existing `validateiCloudAvailability()` on the store remains — it is only used from the validation path of `validateAndAddProfile` and continues to set `validationError`. The new `iCloudAvailability` property is the observable one the view binds to.

### 6.2 `SyncCoordinator.profileIndexFetchedAtLeastOnce`

```swift
@Observable @MainActor final class SyncCoordinator {
  ...
  private(set) var profileIndexFetchedAtLeastOnce: Bool = false
}
```

**Scope.** The flag must flip `true` only once a fetch session that actually touched the `profile-index` zone has completed — not on *any* fetch-session end. A session that only drained a `profile-data` zone (typical on an already-onboarded device receiving a new transaction) must not flip the flag.

**Hook.** The correct point is inside `endFetchingChanges()` (in `SyncCoordinator+Lifecycle.swift`), gated on a new boolean tracked during the session — `fetchSessionTouchedIndexZone` — that's set to `true` whenever the delegate loop receives any `CKSyncEngine.Event.fetchedRecordZoneChanges` (or equivalent zone-fetch-completion event) for the index zone ID, regardless of whether records were present. The existing `fetchSessionIndexChanged` flag (set in `SyncCoordinator+RecordChanges.swift` when an index-zone record is applied) is insufficient — it only fires on non-empty fetches.

Concretely, add:

```swift
// In SyncCoordinator.swift (alongside fetchSessionIndexChanged)
var fetchSessionTouchedIndexZone = false

// In SyncCoordinator+Delegate.swift, wherever zone-level fetch events
// are handled, set fetchSessionTouchedIndexZone = true whenever the zone
// ID matches profileIndexHandler.zoneID. This fires even if the fetch
// returned zero changes.

// In SyncCoordinator+Lifecycle.swift, inside endFetchingChanges(), after
// flushFetchSessionChanges():
if fetchSessionTouchedIndexZone && !profileIndexFetchedAtLeastOnce {
  profileIndexFetchedAtLeastOnce = true
}
fetchSessionTouchedIndexZone = false
```

**Persistence.** In-memory only. Acceptable trade-off: on a relaunch mid-fetch (app killed during a slow-network first fetch), the flag resets and `WelcomeView` again shows "Checking iCloud…" until the fetch actually completes. That is the honest UX — we genuinely don't know yet. The next completion flips the flag. If the user has profiles in iCloud, they arrive first (via `loadCloudProfiles` / notifications) and the flag becomes irrelevant. The only case where an indefinite spinner could surface is "no iCloud profiles exist AND network is too slow for an empty-handed fetch to complete" — in that case the user can still tap "Get started" and proceed; the flag is only cosmetic.

### 6.3 Local-only profiles (when iCloud unavailable)

When the user creates a profile while `iCloudAvailability == .unavailable(...)`, we still use `BackendType.cloudKit` and the `CloudKitBackend`. No new backend type is introduced. Existing behaviour in `validateiCloudAvailability` already returns `true` when entitlements are missing; `addProfile` writes the `ProfileRecord` to the local SwiftData index container.

**How the record eventually reaches iCloud.** The upload path depends on backfill, not on the `queueSave` call at creation time:

1. At creation time, `ProfileStore.addProfile` (via `onProfileChanged`) calls `SyncCoordinator.queueSave`. If `iCloud` was unavailable at launch, the sync engine may still be installed (its `init` doesn't require an account) but will not be able to upload. `queueSave` appends the record to `CKSyncEngine.state.pendingRecordZoneChanges`, which is an in-memory queue that survives as long as the engine is installed; if the engine was never installed (`syncEngine == nil`), the call is a documented no-op (`SyncCoordinator+Lifecycle.swift` line 141 comment).
2. When the account later becomes available, `CKSyncEngine` fires `.accountChange(.signIn)`. `SyncCoordinator.handleAccountChange` calls `queueAllExistingRecordsForAllZones()` (when `isFirstLaunch == true`) or the backfill picks up the record via `queueUnsyncedRecordsForAllProfiles()` in `completeStart` on the next launch (because the `ProfileRecord` has no `encodedSystemFields` — the mark of an unsynced record).
3. Either way, the record ends up queued and uploaded. This is not automatic from the `queueSave` call alone — it depends on the backfill scan in `SyncCoordinator+Backfill.swift`.

The spec calls this out explicitly so the implementation doesn't rely on `queueSave` alone for the unavailable→available transition.

---

## 7. Components

### 7.1 New

- **`Features/Profiles/Views/WelcomeView.swift`** — the top-level first-run state machine view. Renders one of: hero-welcome, hero-welcome-with-off-chip, create-form, create-form-with-banner, picker. Owns the `InteractionPhase` enum.
- **`Features/Profiles/Views/WelcomeHero.swift`** — the branded hero block, reused across states 1 and 4. Takes a trailing content slot so the caller can inject either the checking-status line (`ICloudStatusLine`) or the off-chip (`ICloudOffChip`). Private `Color(red:green:blue:)` constants for brand hex — no project-wide `Color` extensions.
- **`Features/Profiles/Views/CreateProfileFormView.swift`** — the system-styled form (states 2 and 3). Uses `Form`, `.formStyle(.grouped)`, and a `DisclosureGroup` for Advanced. Exposes an async `save` closure and an `iCloudBannerState` binding. The primary CTA uses `.buttonStyle(.borderedProminent)` for automatic focus-ring treatment.
- **`Features/Profiles/Views/ICloudProfilePickerView.swift`** — the list of iCloud profiles (state 5) with the "+ Create a new profile" footer row. Row meta text uses `.monospacedDigit()` on the account-count.
- **`Features/Profiles/Views/ICloudArrivalBanner.swift`** — the brand-gold advisory banner used in state 3, parameterised for single vs multi arrival. Backed by brand Balance Gold `#FFD56B` on a translucent fill with dark brand text — private `Color(red:green:blue:)` constants scoped to this file, mirroring `WelcomeHero`'s discipline.

### 7.2 Modified

- **`App/ProfileWindowView.swift`** — replace `ProfileSetupView()` with `WelcomeView()`. Drop the bare `ProgressView()` branch (its use case is subsumed by WelcomeView state 1). Apply `.windowStyle(.hiddenTitleBar)` to the window when `WelcomeView` is presented; standard chrome returns when the session opens.
- **`App/ProfileRootView.swift`** — replace `ProfileSetupView()` with `WelcomeView()`. The existing `cloudProfiles` change handler for session creation is unchanged.
- **`Features/Profiles/ProfileStore.swift` / `+Cloud.swift`** — expose a pass-through `iCloudAvailability` computed from `SyncCoordinator`. Add a phase-guard entry point so `loadCloudProfiles` can check whether the welcome view is mid-form before auto-activating a single arriving profile (see §3.3, §8).
- **`Backends/CloudKit/Sync/SyncCoordinator.swift` / `+Zones.swift` (`handleAccountChange`) / `+Lifecycle.swift` (`completeStart`, `endFetchingChanges`) / `+Delegate.swift` (zone-fetch event wiring)** — add `iCloudAvailability`, the initial account probe in `completeStart`, the account-status-to-availability mapping in `handleAccountChange`, `profileIndexFetchedAtLeastOnce`, and the per-session `fetchSessionTouchedIndexZone` flag.

### 7.3 Removed / renamed

- **`Features/Profiles/Views/ProfileSetupView.swift`** — deleted. Not used anywhere else.
- **`Features/Auth/WelcomeView.swift`** — renamed to `SignedOutView.swift` (it's shown post-setup when a Moolah-server session has lost its auth, not a welcome). Its type name `WelcomeView` → `SignedOutView`. All call sites updated.

### 7.4 Tests

- **Store / coordinator tests** (in `MoolahTests/`):
  - `SyncCoordinatorICloudAvailabilityTests` — probe returns `.available` when account is fine; `.unavailable(.notSignedIn)` on `.noAccount`; `.unknown` on `.couldNotDetermine`; reacts to a simulated `CKSyncEngine.Event.accountChange`; `.unavailable(.entitlementsMissing)` when `CloudKitAuthProvider.isCloudKitAvailable == false`; synthetic first-launch `.signIn` does not mis-report availability.
  - `SyncCoordinatorProfileIndexFetchTests` — `profileIndexFetchedAtLeastOnce` is `false` at start; does **not** flip on a fetch session that only touched `profile-data` zones; flips `true` on a fetch session that touched the `profile-index` zone (empty or non-empty); remains `true`; resets to `false` on `start()` after `stop()`.
  - `ProfileStoreICloudAvailabilityPassthroughTests` — `ProfileStore.iCloudAvailability` mirrors `SyncCoordinator.iCloudAvailability`.
  - `ProfileStoreAutoActivateGuardTests` — when `WelcomeView.phase == .creating` is signalled, `loadCloudProfiles` does **not** auto-activate a single arriving profile; when `.landing`, it does.
- **UI tests** (in `MoolahUITests_macOS/`, per `guides/UI_TEST_GUIDE.md`):
  - `WelcomeViewTests.testFirstLaunchNoCloudProfiles_showsHeroAndSetsUpProfile` — seed a blank container (`UI_TESTING_SEED = .emptyNoProfiles`), verify hero text visible, tap "Get started", fill in name, tap "Create Profile", verify `SessionRootView` appears.
  - `WelcomeViewTests.testFirstLaunchWithOneCloudProfile_autoOpens` — seed with a single cloud profile, verify `SessionRootView` appears without intermediate hero.
  - `WelcomeViewTests.testFirstLaunchWithMultipleCloudProfiles_showsPicker` — seed two cloud profiles, verify picker with both rows + "+ Create a new profile".
  - `WelcomeViewTests.testICloudUnavailable_showsOffChipAndDeepLink` — seed with unavailable-iCloud flag, verify chip + "Open System Settings" visible.
  - `WelcomeViewTests.testMidFormCloudProfileArrives_showsBanner` — start in the form, simulate a profile arriving, verify banner with Open / Dismiss; tap Dismiss, verify banner goes away and subsequent arrivals don't re-trigger it.
  - `WelcomeViewTests.testMidFormNoRaceWithAutoActivate` — start in the form, simulate a single profile arriving mid-form, verify the form stays put (no auto-activation) and the banner appears instead.

New UI-test seeds needed in `UITestSupport/UITestSeeds.swift`:
- `emptyNoProfiles` (blank index container)
- `singleCloudProfile` (one `ProfileRecord` in the index)
- `multipleCloudProfiles` (two)
- `iCloudUnavailable` (blank container + env flag that forces `iCloudAvailability == .unavailable(.notSignedIn)`)
- `midFormCloudProfileTrigger` (starts blank; a hidden UI-test-only button in the form injects a `ProfileRecord` to simulate arrival — see `guides/UI_TEST_GUIDE.md` §4 on test-only affordances)

### 7.5 Accessibility test

- Add an XCTest check that scans `WelcomeView` descendants and asserts every interactive element has a non-empty accessibility label (pattern already in `MoolahUITests_macOS/` — reuse existing helper).

### 7.6 Preview coverage

Each new view (`WelcomeView`, `WelcomeHero`, `CreateProfileFormView`, `ICloudProfilePickerView`, `ICloudArrivalBanner`) ships with at minimum three `#Preview`s:

1. Default — light mode, standard Dynamic Type.
2. `.preferredColorScheme(.dark)` — verifies dark-mode adaptation (and that the hero's forced `.colorScheme(.dark)` still looks right).
3. `.dynamicTypeSize(.accessibility5)` — verifies layout at the largest accessibility size.

For `WelcomeView` specifically, include one preview per `InteractionPhase` × data state combination relevant to the default layout so reviewers can eyeball all five states without running the app.

---

## 8. Edge Cases

- **Profile arrives while on picker (state 5):** list updates live. Acceptable — the user hasn't committed yet. New row appears with a subtle insertion animation (respecting Reduce Motion).
- **Profile arrives, then the same profile is removed from another device before we got here:** `loadCloudProfiles` already handles deletions on non-initial loads. Picker / banner updates live.
- **User taps "Open System Settings" while on macOS:** use `NSWorkspace.shared.open` with a well-known System Settings URL for the Apple ID / iCloud pane. The exact URL scheme has shifted across macOS releases (System Preferences → System Settings → Apple ID / Internet Accounts pane restructure) and we target macOS 26+. The implementation must:
  1. Try `x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane` (still works as a compatibility redirect on recent releases).
  2. On failure (open returns `false`), fall back to `NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))`, which opens System Settings to its default root.
  3. Verify the primary URL resolves on the CI runner's target OS (macOS 26) before shipping. If it no longer resolves, update to whatever scheme does, keeping the fallback in place.
  On iOS, open `URL(string: "App-Prefs:")!` via `UIApplication.shared.open`.
- **User taps "Get started" while the spinner is still running, then iCloud returns exactly 1 profile:** banner appears (state 3), *not* auto-open, because the user has already expressed intent to create. This is enforced by the `phase == .creating` guard on auto-activation (see below).
- **Race between auto-activation and mid-form save.** `ProfileStore.loadCloudProfiles` auto-selects when `activeProfileID == nil`. Without mitigation, this can race the user's "Create Profile" tap: both paths set `activeProfileID` and the winner is non-deterministic. Mitigation: add a `var welcomePhase: InteractionPhase?` handle on `ProfileStore` (set by `WelcomeView` on mount / phase changes, cleared on unmount). `loadCloudProfiles` skips the auto-select block when `welcomePhase == .creating`. A test (`ProfileStoreAutoActivateGuardTests`, `WelcomeViewTests.testMidFormNoRaceWithAutoActivate`) covers this.
- **User is mid-form, taps Open on the banner, then immediately wants to create a separate profile:** they have to use Settings → Add Profile. Their typed input was discarded when they tapped Open. We could preserve it via a draft, but the added state machine isn't worth the rare case. Call it out in the Open confirmation if we find this is a common regret.
- **iCloud account changes mid-session:** banner is not re-triggered. `cloudProfiles` list updates naturally.
- **First fetch fails with network error or other transient failure:** retries are automatic on two levels. `CKSyncEngine` itself reschedules fetches after transient errors (network, rate-limit, server-busy) on its own back-off. On top of that, `Backends/CloudKit/Sync/SyncCoordinator+Refetch.swift` implements a short-retry budget and, once exhausted, a periodic long-retry last-resort probe. Foregrounding the app or the network returning will also re-kick fetches. `profileIndexFetchedAtLeastOnce` stays `false` until a fetch actually completes, so the status line honestly keeps saying "Checking iCloud for your profiles…" while work is genuinely ongoing. If the account is fundamentally broken (`.notAuthenticated`, etc.), `CKSyncEngine` fires a `.accountChange(.signOut)` event and `iCloudAvailability` flips to `.unavailable(...)` — view transitions to state 4 (iCloud off).
- **`CKAccountStatus.couldNotDetermine` on initial probe:** treated as transient (`.unknown`), **not** `.unavailable`. The status line keeps saying "Checking iCloud…" and a subsequent `CKAccountChanged` notification resolves it. Prevents the common laptop-just-woke-up / network-still-coming-up case from flashing "iCloud sync is off."
- **Synthetic `.signIn` on first engine init:** `CKSyncEngine` emits a `.signIn` event whenever it's initialised without saved state (i.e. every truly fresh launch). The existing `isFirstLaunch` guard inside `handleAccountChange` already skips the heavyweight zone-reset on this path; the new availability-update code **runs unconditionally** but is a pure assignment and safe to re-fire.
- **User launches, immediately quits, relaunches:** on second launch if still no profiles and no cloud profiles, same welcome screen shows. Nothing persists between launches related to this view — `profileIndexFetchedAtLeastOnce` resets to `false`.

---

## 9. Implementation Order

Phased so each step is independently testable and revert-safe:

1. **Add `iCloudAvailability` to `SyncCoordinator`** (with tests) — the account-status mapping, the initial probe in `completeStart`, the `handleAccountChange` extension, and the `ProfileStore` pass-through computed property. No UI changes yet.
2. **Add `profileIndexFetchedAtLeastOnce` + `fetchSessionTouchedIndexZone` to `SyncCoordinator`** (with tests).
3. **Add the `welcomePhase` auto-activate guard to `ProfileStore`** (with tests).
4. **Build `WelcomeHero`, `CreateProfileFormView`, `ICloudProfilePickerView`, `ICloudArrivalBanner` as isolated views** with three `#Preview`s each (light, dark, accessibility5 — see §7.6).
5. **Build `WelcomeView` state machine** composing the above, with unit-testable phase/state logic lifted into a `@MainActor` helper if it gets complex.
6. **Wire into `ProfileWindowView` / `ProfileRootView`** by swapping `ProfileSetupView()` → `WelcomeView()`. Apply `.windowStyle(.hiddenTitleBar)` on the macOS window while the welcome is presented.
7. **Delete `ProfileSetupView.swift`** and rename `Auth/WelcomeView.swift` → `SignedOutView.swift`.
8. **Add UI-test seeds** and the six UI tests listed in §7.4.
9. **Brand QA pass:** side-by-side on macOS Light + Dark + iOS Light + Dark. Verify Dynamic Type at `.accessibility5`. Verify VoiceOver traversal. Verify the System Settings deep link on a clean macOS 26 install.

Each step lands as a separate PR through the merge queue.

---

## 10. Open Questions

- **Banner (multi) copy.** Current: "Found N profiles in iCloud." Reviewer suggested warmer phrasing ("Looks like you've got N profiles in iCloud." or "You've got N profiles waiting."). To be decided by the user before implementation locks the copy. The single-profile banner retains "Found '<label>' in iCloud." in either case.

Parked for future consideration:

- Whether to offer a timeout variant on the "Checking iCloud…" status line (after N seconds, show "Taking longer than usual — you can continue anyway"). Defer until we see telemetry / user reports of long waits.
- Whether the "+ Create a new profile" from the picker should preserve a typed name from the mid-form state if the user was bounced there via the multi-arrival banner. See §3.3 — spec says yes; flag if it proves fiddly in implementation.

---
