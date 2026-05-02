# Remove moolah-server support

**Date:** 2026-04-28
**Status:** Design — pending implementation plan

## Goal

Delete every line of code that exists to talk to `moolah-server` (the historical
REST API at `https://moolah.rocks/api/`). Only iCloud (CloudKit) profiles are
supported going forward. The `Backends/Remote/` subsystem and the
remote-to-iCloud `MigrationCoordinator` are removed wholesale, the
`Profile.backendType` discriminator is dropped, and the
`supportsComplexTransactions` UI gate is folded to its always-true branch.

## Non-goals

- No new functionality. The change is purely subtractive — every code path
  being deleted already had its own coverage; every remaining code path is
  already exercised.
- No CloudKit schema change. `ProfileRecord` in `CloudKit/schema.ckdb` already
  carries only `label / currencyCode / financialYearStartMonth / createdAt`;
  `backendType` and `serverURL` are local-only on the Swift `Profile` and are
  never synced. CloudKit production schemas are append-only in any case.
- No on-launch keychain or `UserDefaults` sweep. Stale `com.moolah.profiles`
  data and `CookieKeychain` cookies on existing installs are silently ignored
  (the new build never reads them).

## Scope decisions

- **Hard cutover for existing remote / moolah profiles.** A device that has
  remote profiles cached in `UserDefaults` simply stops seeing them after
  upgrade — the legacy key (`com.moolah.profiles`) is no longer read. No
  in-app migration prompt, no auto-import.
- **`MigrationCoordinator` deleted with the rest.** It exists solely to copy
  data from a remote profile into a new iCloud profile; with no remote
  profiles, it has no purpose.
- **One PR, one branch, six commits.** Sequencing is described under
  *Implementation order* below; smaller PRs would leave half-states that
  compile but exercise dead code.

## End-state shapes

### `Profile` (`Domain/Models/Profile.swift`)

```swift
struct Profile: Identifiable, Codable, Sendable, Equatable {
  let id: UUID
  var label: String
  var currencyCode: String
  var financialYearStartMonth: Int
  let createdAt: Date

  init(
    id: UUID = UUID(),
    label: String,
    currencyCode: String = "AUD",
    financialYearStartMonth: Int = 7,
    createdAt: Date = Date()
  ) { /* ... */ }

  var instrument: Instrument { .fiat(code: currencyCode) }
}
```

Removed: `BackendType` enum, `backendType`, `serverURL`, `resolvedServerURL`,
`moolahServerURL`, `supportsComplexTransactions`. The `Codable` synthesis
ignores unknown keys, so a stale `ProfileRecord` returning from CloudKit (which
never carried these columns) decodes fine; legacy `UserDefaults`-encoded
remote `Profile`s under `com.moolah.profiles` are simply never read.

### `ProfileStore` (`Features/Profiles/ProfileStore.swift`)

- `remoteProfiles` removed.
- `validator: (any ServerValidator)?` parameter and stored property removed.
- `profilesKey` UserDefaults persistence removed; only `activeProfileKey` and
  the cloud loader remain.
- Every `switch profile.backendType` site collapses to the iCloud branch.
- `validateAndAddProfile` keeps only the iCloud-availability branch and loses
  the server-URL branch.
- `validateAndUpdateProfile` becomes a thin pass-through to `updateProfile`.
- `removeProfile` no longer touches `CookieKeychain`.
- `WelcomePhase` and its `.pickingProfile` case are unchanged — the
  multi-iCloud-profile picker stays.

### `ProfileSession` (`App/ProfileSession+Factories.swift`)

- `makeBackend` collapses to the cloud-only path. The
  `URLSessionConfiguration.ephemeral` plumbing, per-profile `URLSession`, and
  `CookieKeychain` constructor go away.
- `makeRegistryWiring` no longer needs the `as? CloudKitBackend` fallback;
  the parameter type narrows to `CloudKitBackend` (preferred) or the cast
  becomes a forced cast guarded by `fatalError`.

### Welcome / profile-form UI

- `WelcomeView` removes any backend-type chooser and goes straight to the
  "Create iCloud profile" CTA + existing iCloud-availability messaging.
- `ProfileFormView` loses its backend-type segmented control, the server-URL
  `TextField`, and the in-flight server-validation spinner. What remains:
  label, currency, financial-year-start-month.
- `ICloudProfilePickerView` is unaffected.

## Deletion inventory

### Files deleted outright

- `Backends/Remote/` — entire directory: `RemoteBackend.swift`,
  `RemoteCSVImportProfileRepository.swift`, `RemoteImportRuleRepository.swift`,
  `SingleInstrumentGuard.swift`, all of `APIClient/`, `DTOs/`, `Repositories/`,
  `Validation/`, plus `Auth/CookieKeychain.swift` and
  `Auth/RemoteAuthProvider.swift`.
- `Backends/CloudKit/Migration/` — entire directory (`MigrationCoordinator`,
  `CloudKitDataImporter`, `MigrationError`, `MigrationProfileNaming`,
  `MigrationVerifier`).
- `Domain/Repositories/ServerValidator.swift` — protocol becomes orphaned.
- Tests:
  - `MoolahTests/Backends/Remote*RepositoryTests.swift` (six files).
  - `MoolahTests/Backends/RemoteServerValidatorTests.swift`.
  - `MoolahTests/Backends/CookieKeychainTests.swift`.
  - `MoolahTests/Migration/` — entire directory.
  - `MoolahTests/Support/InMemoryServerValidator.swift`.
- API-shaped fixtures under `MoolahTests/Support/Fixtures/`: `accounts.json`,
  `account_balances.json`, `account_create_response.json`,
  `account_update_response.json`, `categories.json`, `earmarks.json`,
  `transactions.json`, `investment_values.json`. (CoinGecko / Yahoo / CSV
  fixtures stay.)

### Files moved (`KeychainStore` is shared)

- `Backends/Remote/Auth/KeychainStore.swift` → `Shared/KeychainStore.swift`.
  Used by `CryptoTokenStore` and `ProfileSession+Factories` for the CoinGecko
  API key.
- `MoolahTests/Backends/KeychainStoreTests.swift` →
  `MoolahTests/Shared/KeychainStoreTests.swift`.

### Files edited (structural)

- `Domain/Models/Profile.swift` — see end-state above.
- `Features/Profiles/ProfileStore.swift` — see end-state above.
- `Features/Profiles/ProfileStore+Cloud.swift` (and any sibling extension) —
  drop `profilesKey` use.
- `App/ProfileSession+Factories.swift` — collapse `makeBackend`; tighten
  `makeRegistryWiring`.
- `App/MoolahApp.swift`, `App/MoolahApp+Setup.swift` — drop the
  `RemoteServerValidator()` injection and tighten the `ProfileStore`
  constructor call.
- `Features/Profiles/Views/WelcomeView.swift`,
  `Features/Profiles/Views/ProfileFormView.swift` — UI changes per
  *End-state shapes*.

### Files edited (mechanical fold of `supportsComplexTransactions`)

`supportsComplexTransactions` appears at **78 locations** across 25-ish
view/store files plus their previews. The fold pattern per call site is:

1. Where the file declares `let supportsComplexTransactions: Bool` and a
   matching init parameter, delete both.
2. Where it does `if supportsComplexTransactions { A } else { B }`, replace
   with `A`.
3. Where it does `supportsComplexTransactions ? X : Y`, replace with `X`.
4. Where the call site is
   `child(supportsComplexTransactions: profile.supportsComplexTransactions)`,
   drop the argument; if the parent only carried the flag in order to pass
   it down, drop the parent's flag too — propagating upward.
5. Update `#Preview` blocks the same way (previews currently pass
   `supportsComplexTransactions: true`, so the change is purely deletion).

Affected directories: `Features/Accounts`, `Features/Earmarks`,
`Features/Transactions`, `Features/Investments`, `Features/Reports`,
`Features/Analysis`, `Features/Settings`, `Features/Navigation`, plus
`Shared/` cross-cutting helpers and `Automation/AppleScript/Commands/`.

### Documentation

- `README.md` — rewrite the "Connecting to moolah-server" / "Authentication"
  sections; the iCloud-sync section already exists and stays.
- Active in-flight plans referencing moolah-server only get touched if
  leaving the copy in place would mislead future readers — likely candidates
  are `plans/2026-04-24-first-run-experience-design.md` and
  `plans/IOS_RELEASE_AUTOMATION_PLAN.md`. Everything in `plans/completed/`
  stays as-is — those documents are historical record.

## Test strategy

- **No new tests.** The change is purely subtractive; every code path being
  deleted had its own coverage and every remaining code path is already
  exercised by the cloud-backend contract tests, store tests, and UI tests.
- **Edited test files** (drop remote / migration cases, keep cloud cases):
  - `MoolahTests/Domain/ProfileTests.swift`.
  - `MoolahTests/Features/ProfileStoreTests.swift`,
    `ProfileStoreTestsMore.swift`,
    `ProfileStoreTestsMoreSecondHalf.swift`,
    `ProfileStoreAvailabilityTests.swift`,
    `ProfileStoreAutoActivateGuardTests.swift`.
  - `MoolahTests/App/ProfileSessionTests.swift` and siblings.
  - `MoolahTests/Automation/AutomationServiceMigrationTests.swift` —
    delete entirely.
  - Other `MoolahTests/Automation/*` — drop any case that constructs a
    remote `Profile`.
  - `MoolahUITests_macOS/Tests/InstrumentPickerUITests.swift` and
    `Helpers/Screens/CreateAccountScreen.swift` — drop the `BackendType`
    references that exist only to seed a profile in a particular shape.

## Verification

- `just format-check` clean.
- `just test` clean on both `MoolahTests_iOS` and `MoolahTests_macOS`.
- Full `MoolahUITests_macOS` pass — most of the fold sites are exercised
  end-to-end.
- `mcp__xcode__XcodeListNavigatorIssues` warning-free.
- A grep sweep that finds zero hits (outside `plans/completed/` and
  `.claude/worktrees/`) for: `RemoteBackend`, `RemoteServerValidator`,
  `RemoteAuthProvider`, `CookieKeychain`, `MigrationCoordinator`,
  `MigrationVerifier`, `BackendType`, `Profile.serverURL`,
  `resolvedServerURL`, `supportsComplexTransactions`, `moolah-server`,
  `moolah\.rocks`. The grep output goes into the PR description as
  evidence.

## Implementation order — five commits, one PR

1. **Move `KeychainStore`.** `Backends/Remote/Auth/KeychainStore.swift` →
   `Shared/KeychainStore.swift`; tests follow. No behavioural change. Update
   the two production import sites (`ProfileSession+Factories.swift`,
   `Features/Settings/CryptoTokenStore.swift`) and the test target's path
   reference if any.
2. **Drop `BackendType` from `Profile` and rewire the construction layer.**
   Strip the discriminator and remote fields from `Profile`; collapse the
   `switch` in `ProfileSession.makeBackend`; drop `remoteProfiles`,
   `validator`, `profilesKey`, and the `ServerValidator` parameter from
   `ProfileStore`; drop the `RemoteServerValidator()` injection in
   `MoolahApp+Setup`; narrow the welcome/profile-form views. After this
   commit `Backends/Remote/` and `Backends/CloudKit/Migration/` are
   unreferenced from production but their test files still compile.
3. **Delete the remote and migration subsystems.** `git rm`
   `Backends/Remote/`, `Backends/CloudKit/Migration/`,
   `Domain/Repositories/ServerValidator.swift`,
   `MoolahTests/Support/InMemoryServerValidator.swift`, all the Remote /
   Migration / `CookieKeychain` test files, and the API-shaped JSON
   fixtures. If `project.yml` references any of those paths explicitly
   (rather than via folder reference), edit it in the same commit. Run
   `just generate` locally after — the regenerated `Moolah.xcodeproj` is
   gitignored, so there is nothing further to commit unless `project.yml`
   itself changed.
4. **Fold `supportsComplexTransactions` call sites.** ~25 view/store files
   plus their previews; update any surviving `ProfileTests`,
   `ProfileStoreTests`, and Automation tests in the same commit. Run
   `just test` clean on both targets at this point.
5. **Documentation.** README rewrite; only-if-still-active entries in
   `plans/*.md` updated. `plans/completed/*.md` left alone.

Each commit lands as its own merge-queue entry per the standing rule. The
branch ships as a single PR with all five commits.
