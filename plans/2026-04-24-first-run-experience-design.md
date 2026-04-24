# First-Run Experience Redesign — Design Spec

**Status:** Draft — pending user review
**Date:** 2026-04-24
**Related code:** `Features/Profiles/Views/ProfileSetupView.swift`, `App/ProfileWindowView.swift`, `App/ProfileRootView.swift`, `Features/Profiles/ProfileStore.swift`, `Features/Profiles/ProfileStore+Cloud.swift`

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
- Extend `ProfileStore` with an observable `iCloudAvailability` property driven by `CKAccountChanged` notifications and an initial `CKContainer.default().accountStatus()` probe.
- Expose a way for `WelcomeView` to know whether the initial sync fetch has completed at least once (so the "Checking iCloud…" status can transition to "No profiles in iCloud" rather than spin forever).
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

1. App launches. `ProfileStore` has no local profiles, `iCloudAvailability == .available`, `SyncCoordinator` reports `isFirstLaunch == true`.
2. `WelcomeView` renders the **branded hero** (state 1): hero title, brand subhead, "Get started" button, quiet "Checking iCloud for your profiles…" status line with spinner.
3. In the background, `SyncCoordinator` performs its first fetch for the `profile-index` zone.
4. One of three things happens, in order:
   - **(a)** Exactly one profile arrives from iCloud → auto-activate it, the window transitions to `SessionRootView`. No user action needed.
   - **(b)** Two or more profiles arrive → swap the hero for the **picker** (state 5): "Welcome back. You have profiles in iCloud. Pick one to open." Rows for each profile plus a "+ Create a new profile" row at the bottom.
   - **(c)** The first fetch completes with zero profiles → the status line text changes from "Checking iCloud for your profiles…" to "No profiles in iCloud yet." The spinner fades. The "Get started" button is unchanged.
5. At any point during (3), the user can tap "Get started" and proceed into the **create-profile form** (state 2). Background iCloud fetching continues; see §3.3 for the mid-form arrival case.

### 3.2 First launch — iCloud unavailable

1. App launches. `iCloudAvailability == .unavailable(...)` (not signed in, entitlements missing, restricted, etc.).
2. `WelcomeView` renders the **branded hero with off-chip** (state 4): same hero as 3.1 but with an inline chip under the CTA: "iCloud sync is off. Your profile will be saved on this device." with an "Open System Settings" link (macOS: opens System Settings → Apple ID → iCloud; iOS: opens the iCloud pane of Settings).
3. User taps "Get started" → create-profile form (state 2). No background spinner (no iCloud check to run).
4. Profile is created locally (CloudKit backend with an in-memory-unsyncable store? — see §6.3 for the implementation note).
5. If `iCloudAvailability` flips to `.available` while the user is on the welcome hero or in the form, the off-chip / spinner updates live, and subsequent cloud-profile arrivals follow the §3.3 path.

### 3.3 Mid-form iCloud profile arrival

1. User tapped "Get started" and is typing into the **create-profile form** (state 2). Spinner line under the form reads "Still checking iCloud…"
2. iCloud returns one or more profiles.
3. The form sprouts a non-blocking **yellow banner** above it (state 3): "Found '<label>' in iCloud. You can open it instead of creating a new one." Actions: **Open**, **Dismiss**.
   - **Open** → switch to that profile's session (abandoning any input typed into the form). For multi-profile arrivals, the banner reads "Found N profiles in iCloud. — **View**" and tapping View swaps the form for the picker (state 5) with the typed name passed as a draft (user's input is **not** discarded in this case — if they pick "+ Create a new profile" from the picker, they land back in the form with their input intact).
   - **Dismiss** → banner disappears for the rest of this session. User stays in the form. Further profile arrivals during this session do **not** re-surface the banner — the user has explicitly said "I'm creating a new one." Any additional profiles that synced down remain available from the profile menu after setup completes.
4. If the user taps "Create Profile" before tapping Open/Dismiss, the profile is created and the iCloud profile becomes visible from the profile menu afterward.

### 3.4 Subsequent launches

Unchanged — existing routing. `profileStore.hasProfiles == true` lands in `SessionRootView` immediately. `WelcomeView` is never shown once any profile exists.

---

## 4. Visual Design

### 4.1 Hybrid brand/system split

- **Branded hero** (Brand Space navy, `#07102E`; Poppins / SF fallback; Income Blue primary button; Balance Gold label accent) for states **1** (welcome + checking) and **4** (iCloud unavailable).
- **System materials** (`.formStyle(.grouped)`, `.background(.regularMaterial)` / default window background, system blue `.borderedProminent` buttons) for states **2** (create form), **3** (form + banner), and **5** (picker).

Rationale: the hero moment gets brand weight precisely because it's a one-time, pass-through marketing beat. Interactive screens use native chrome so the transition from setup → main app is seamless.

### 4.2 Typography & layout

All hero text must scale with Dynamic Type. Avoid hardcoded point sizes; use SwiftUI text styles with `.bold()` / `.font(.largeTitle.bold())` / etc. Pad for comfortable reading at the largest accessibility sizes.

Fixed max-width on hero subhead (~320pt) so lines don't sprawl on wide macOS windows.

### 4.3 Accessibility

- **Colour contrast:** all brand-on-Space pairings verified ≥ WCAG AA (spot-checked during brainstorming: min 5.5:1 for the Income Blue button text, 8:1+ for every other pair).
- **VoiceOver:** hero title + subhead get `.accessibilityAddTraits(.isHeader)`; status line has `.accessibilityLabel("Checking iCloud for your profiles")`; banner is announced as `.accessibilityLiveRegion(.polite)` when it appears; spinner marked `.accessibilityAddTraits(.updatesFrequently)`.
- **Reduce Motion:** spinner uses system `ProgressView()` (iOS / macOS handle motion reduction). No bespoke animations on transitions — use `withAnimation(reduceMotion ? nil : .default)` pattern already used in `ProfileSetupView`.
- **Increase Contrast / Reduce Transparency:** brand states (1, 4) use solid Brand Space — no translucency to strip. System states (2, 3, 5) use `.regularMaterial`, which adapts automatically.
- **Light Mode:** the hero is always dark. That is intentional — it's a splash / welcome moment — but the form and picker respect system appearance. A Light-Mode user will see dark → light transition at the Get Started tap. Acceptable, because the dark state is brief by design.
- **Keyboard navigation (macOS):** Tab order = primary CTA first, then secondary affordances (Open System Settings link, banner actions). Return activates primary CTA.

### 4.4 Approved copy

| Slot | Copy |
|---|---|
| Hero eyebrow label | `Moolah` |
| Hero title | `Your money,<br/>rock solid.` (second line in Balance Gold) |
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
| Banner (multi) | `Found <N> profiles in iCloud.` / action `View` `Dismiss` |
| Picker title | `Welcome back.` |
| Picker subtitle | `You have profiles in iCloud. Pick one to open.` |
| Picker row meta | `<currency code> · <account count> account(s)` (account count read from synced ProfileRecord if known, else omitted) |
| Picker footer CTA | `+ Create a new profile` |

All copy is `String(localized:)`-wrapped.

---

## 5. State Machine

`WelcomeView` owns a small `@State` enum for the *interaction phase*, and observes `ProfileStore` for *data state*. The combination yields which of the five layouts to show.

```swift
enum InteractionPhase {
  case landing         // User hasn't tapped Get Started yet
  case creating        // User is filling out the create-profile form
  case pickingProfile  // User is choosing between multiple iCloud profiles
}
```

State resolution (pseudocode):

```
if profileStore.cloudProfiles.count == 1 && phase == .landing:
  → auto-activate that profile; this view unmounts
else if phase == .pickingProfile || (profileStore.cloudProfiles.count >= 2 && phase == .landing):
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

**First-fetch-complete flag.** The "Checking iCloud…" status line needs to transition to "No profiles in iCloud yet." once the initial `profile-index` fetch has completed empty-handed. Source of truth: `SyncCoordinator` already has `isFirstLaunch` and emits a fetch-session-end via the `CKSyncEngine` delegate path (`endFetchingChanges()`). We'll expose a new observable `profileIndexFetchedAtLeastOnce: Bool` on `SyncCoordinator`, set to `true` the first time `endFetchingChanges()` fires after start. `WelcomeView` reads this to swap the status-line text.

---

## 6. Data Model Changes

### 6.1 `ProfileStore.iCloudAvailability`

New observable property:

```swift
enum ICloudAvailability: Equatable {
  case unknown        // initial, before first accountStatus probe
  case available
  case unavailable(reason: UnavailableReason)

  enum UnavailableReason: Equatable {
    case notSignedIn
    case restricted
    case temporarilyUnavailable
    case entitlementsMissing
    case unknown
  }
}

@Observable @MainActor final class ProfileStore {
  var iCloudAvailability: ICloudAvailability = .unknown
  ...
}
```

Lifecycle:

- On `init`, schedule an async probe via `CKContainer.default().accountStatus()` and map to the enum.
- Register for `CKAccountChangedNotification` (NotificationCenter). On fire, re-probe and update.
- If entitlements are missing (`CloudKitAuthProvider.isCloudKitAvailable == false`), set `.unavailable(.entitlementsMissing)` synchronously and don't register the observer.

Existing `validateiCloudAvailability()` on the store remains — it is only used from the validation path of `validateAndAddProfile` and continues to set `validationError`. The new `iCloudAvailability` property is the observable one the view binds to.

### 6.2 `SyncCoordinator.profileIndexFetchedAtLeastOnce`

```swift
@Observable @MainActor final class SyncCoordinator {
  ...
  var profileIndexFetchedAtLeastOnce: Bool = false
}
```

Set to `true` inside `endFetchingChanges()` after `flushFetchSessionChanges()` returns. Persisted in-memory only — fine to reset on relaunch because by then the user either has profiles (welcome never shown) or genuinely is on a fresh slate.

### 6.3 Local-only profiles (when iCloud unavailable)

When the user creates a profile while `iCloudAvailability == .unavailable(...)`, we still use `BackendType.cloudKit` and the `CloudKitBackend` — the record just won't sync until iCloud comes back online. This matches existing behaviour (`validateiCloudAvailability` already returns `true` when entitlements are missing, and `addProfile` still writes to the `ProfileRecord` store). No new backend type is introduced.

When iCloud later becomes available, `CKSyncEngine` picks up the pending records and uploads them on its next fetch. Profile is de facto local until then.

---

## 7. Components

### 7.1 New

- **`Features/Profiles/Views/WelcomeView.swift`** — the top-level first-run state machine view. Renders one of: hero-welcome, hero-welcome-with-off-chip, create-form, create-form-with-banner, picker.
- **`Features/Profiles/Views/WelcomeHero.swift`** — the branded hero block, reused across states 1 and 4. Takes a trailing content slot so the caller can inject either the checking-status line or the off-chip.
- **`Features/Profiles/Views/CreateProfileFormView.swift`** — the system-styled form (states 2 and 3). Uses `Form`, `.formStyle(.grouped)`, and a `DisclosureGroup` for Advanced. Exposes an async `save` closure and an `iCloudBannerState` binding.
- **`Features/Profiles/Views/ICloudProfilePickerView.swift`** — the list of iCloud profiles (state 5) with the "+ Create a new profile" footer row.
- **`Features/Profiles/Views/ICloudArrivalBanner.swift`** — the yellow banner used in state 3, parameterised for single vs multi arrival.

### 7.2 Modified

- **`App/ProfileWindowView.swift`** — replace `ProfileSetupView()` with `WelcomeView()`. Drop the bare `ProgressView()` branch (its use case is subsumed by WelcomeView state 1).
- **`App/ProfileRootView.swift`** — replace `ProfileSetupView()` with `WelcomeView()`. The existing `cloudProfiles` change handler for session creation is unchanged.
- **`Features/Profiles/ProfileStore.swift` / `+Cloud.swift`** — add `iCloudAvailability`, the account-status probe, and the `CKAccountChanged` observer.
- **`Backends/CloudKit/Sync/SyncCoordinator.swift` / `+Lifecycle.swift`** — add `profileIndexFetchedAtLeastOnce` and set it in `endFetchingChanges()`.

### 7.3 Removed / renamed

- **`Features/Profiles/Views/ProfileSetupView.swift`** — deleted. Not used anywhere else.
- **`Features/Auth/WelcomeView.swift`** — renamed to `SignedOutView.swift` (it's shown post-setup when a Moolah-server session has lost its auth, not a welcome). Its type name `WelcomeView` → `SignedOutView`. All call sites updated.

### 7.4 Tests

- **Store tests** (in `MoolahTests/Features/`):
  - `ProfileStoreICloudAvailabilityTests` — probe returns `.available` when account is fine; `.unavailable(.notSignedIn)` on `.noAccount`; reacts to `CKAccountChangedNotification`; `.unavailable(.entitlementsMissing)` when `CloudKitAuthProvider.isCloudKitAvailable == false`.
  - `SyncCoordinatorProfileIndexFetchTests` — `profileIndexFetchedAtLeastOnce` is `false` at start, flips `true` after the first `endFetchingChanges()` call, remains `true`.
- **UI tests** (in `MoolahUITests_macOS/`, per `guides/UI_TEST_GUIDE.md`):
  - `WelcomeViewTests.testFirstLaunchNoCloudProfiles_showsHeroAndSetsUpProfile` — seed a blank container (`UI_TESTING_SEED = .emptyNoProfiles`), verify hero text visible, tap "Get started", fill in name, tap "Create Profile", verify `SessionRootView` appears.
  - `WelcomeViewTests.testFirstLaunchWithOneCloudProfile_autoOpens` — seed with a single cloud profile, verify `SessionRootView` appears without intermediate hero.
  - `WelcomeViewTests.testFirstLaunchWithMultipleCloudProfiles_showsPicker` — seed two cloud profiles, verify picker with both rows + "+ Create a new profile".
  - `WelcomeViewTests.testICloudUnavailable_showsOffChipAndDeepLink` — seed with unavailable-iCloud flag, verify chip + "Open System Settings" visible.
  - `WelcomeViewTests.testMidFormCloudProfileArrives_showsBanner` — start in the form, simulate a profile arriving, verify banner with Open / Dismiss; tap Dismiss, verify banner goes away and subsequent arrivals don't re-trigger it.

New UI-test seeds needed in `UITestSupport/UITestSeeds.swift`:
- `emptyNoProfiles` (blank index container)
- `singleCloudProfile` (one `ProfileRecord` in the index)
- `multipleCloudProfiles` (two)
- `iCloudUnavailable` (blank container + env flag that forces `iCloudAvailability == .unavailable(.notSignedIn)`)
- `midFormCloudProfileTrigger` (starts blank; a hidden UI-test-only button in the form injects a `ProfileRecord` to simulate arrival — see `guides/UI_TEST_GUIDE.md` §4 on test-only affordances)

### 7.5 Accessibility test

- Add an XCTest check that scans `WelcomeView` descendants and asserts every interactive element has a non-empty accessibility label (pattern already in `MoolahUITests_macOS/` — reuse existing helper).

---

## 8. Edge Cases

- **Profile arrives while on picker (state 5):** list updates live. Acceptable — the user hasn't committed yet. New row appears with a subtle insertion animation (respecting Reduce Motion).
- **Profile arrives, then the same profile is removed from another device before we got here:** `loadCloudProfiles` already handles deletions on non-initial loads. Picker / banner updates live.
- **User taps "Open System Settings" while on macOS:** open `x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?aaaiCloud`. Fall back to `System Settings.app` if the URL scheme fails.
- **User taps "Get started" while the spinner is still running, then iCloud returns exactly 1 profile:** banner appears (state 3), *not* auto-open, because the user has already expressed intent to create.
- **User is mid-form, taps Open on the banner, then immediately wants to create a separate profile:** they have to use Settings → Add Profile. Their typed input was discarded when they tapped Open. We could preserve it via a draft, but the added state machine isn't worth the rare case. Call it out in the Open confirmation if we find this is a common regret.
- **iCloud account changes mid-session:** banner is not re-triggered. `cloudProfiles` list updates naturally.
- **First fetch fails with network error:** `profileIndexFetchedAtLeastOnce` stays `false`. Status line keeps saying "Checking iCloud for your profiles…" indefinitely. Acceptable — retry will happen automatically. If we want a failure UX later, add a timeout variant; out of scope here.
- **User launches, immediately quits, relaunches:** on second launch if still no profiles and no cloud profiles, same welcome screen shows. Nothing persists between launches related to this view.

---

## 9. Implementation Order

Phased so each step is independently testable and revert-safe:

1. **Add `ICloudAvailability` to `ProfileStore`** (with tests). No UI changes yet.
2. **Add `profileIndexFetchedAtLeastOnce` to `SyncCoordinator`** (with tests).
3. **Build `WelcomeHero`, `CreateProfileFormView`, `ICloudProfilePickerView`, `ICloudArrivalBanner` as isolated views** with `#Preview`s.
4. **Build `WelcomeView` state machine** composing the above, with unit-testable phase/state logic lifted into a `@MainActor` helper if it gets complex.
5. **Wire into `ProfileWindowView` / `ProfileRootView`** by swapping `ProfileSetupView()` → `WelcomeView()`.
6. **Delete `ProfileSetupView.swift`** and rename `Auth/WelcomeView.swift` → `SignedOutView.swift`.
7. **Add UI-test seeds** and the six UI tests listed in §7.4.
8. **Brand QA pass:** side-by-side on macOS Light + Dark + iOS Light + Dark. Verify Dynamic Type at `.accessibility5`. Verify VoiceOver traversal.

Each step lands as a separate PR through the merge queue.

---

## 10. Open Questions

None — all raised during brainstorming are resolved. Parked for future consideration:

- Whether to offer a timeout variant on the "Checking iCloud…" status line (after N seconds, show "Taking longer than usual — you can continue anyway"). Defer until we see telemetry / user reports of long waits.
- Whether the "+ Create a new profile" from the picker should preserve a typed name from the mid-form state if the user was bounced there via the multi-arrival banner. See §3.3 — spec says yes; flag if it proves fiddly in implementation.

---
