# Remove moolah-server Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete every line that exists to talk to `moolah-server` (the legacy
REST API at `https://moolah.rocks/api/`) and the `MigrationCoordinator` whose
sole job was importing remote profiles into iCloud. Only iCloud (CloudKit)
profiles are supported afterwards.

**Architecture:** Subtractive refactor. The `Backends/Remote/` and
`Backends/CloudKit/Migration/` subsystems are deleted in one PR, the
`Profile.backendType` discriminator (`.remote` / `.moolah` / `.cloudKit`) is
removed, and the `Profile.supportsComplexTransactions` UI gate is folded to
its always-true branch across ~22 view/store files. No new tests; no CloudKit
schema change.

**Tech Stack:** Swift 6 / SwiftUI / SwiftData / CloudKit, `just` task runner,
`xcodegen`, `swift-format` + SwiftLint, Swift Testing (`@Suite`/`@Test`),
XCUITest.

**Companion spec:** `plans/2026-04-28-remove-moolah-server-design.md`. Read it
first if you want context on the scope decisions (hard cutover for legacy
profiles, no schema change, KeychainStore is shared).

---

## How to use this plan

- **Worktree:** This plan lives on the branch `spec/remove-moolah-server` in
  the worktree `.worktrees/remove-moolah-server`. Implement in a sibling
  worktree branched from `main` (e.g. `feature/remove-moolah-server`) so the
  spec branch stays untouched. The `superpowers:using-git-worktrees` skill
  handles directory selection. Once Task 0 has created the worktree, every
  subsequent command in the plan runs from inside that new worktree
  (`.worktrees/remove-moolah-server-impl`).
- **Five commits, one PR.** Each commit corresponds to a numbered section
  below; commit boundaries are explicit "Run tests + commit" steps. Land the
  branch as one PR with all five commits.
- **Tests run at commit boundaries**, not after every step. Swift compile +
  full-suite runs are slow; run them when a commit is ready, not between
  individual file edits.
- **Capture test output to `.agent-tmp/`** per the project rule:
  `mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-<step>.txt`.
  Delete temp files when done.
- **Never edit `.swiftlint-baseline.yml`** without explicit permission. If
  `just format-check` flags a new violation in a file you touched, fix the
  underlying code instead.
- **Merge-queue rule:** every commit goes through the merge-queue skill, not
  manual merge.

---

## Setup

### Task 0: Create the implementation worktree and verify a clean baseline

**Files:** none modified; only worktree creation.

- [ ] **Step 1: Create the worktree off `main`.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
  .worktrees/remove-moolah-server-impl -b feature/remove-moolah-server
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/remove-moolah-server-impl
```

- [ ] **Step 2: Confirm `.worktrees/` is gitignored.**

Run: `git check-ignore -q .worktrees && echo OK`
Expected: `OK`

- [ ] **Step 3: Run baseline tests (macOS only — fast loop).**

```bash
mkdir -p .agent-tmp
just test-mac 2>&1 | tee .agent-tmp/test-baseline.txt
```

Expected: all tests pass. If anything fails, stop and report — every later
commit's "verify + commit" step depends on a clean baseline.

- [ ] **Step 4: Confirm `just format-check` is clean.**

```bash
just format-check
```

Expected: exits 0. If it fails, run `just format` first to land the
formatting fix as a separate prep commit.

---

## Commit 1: Move `KeychainStore` to `Shared/`

**Why first:** `KeychainStore` is shared (used for the CoinGecko API key in
`CryptoTokenStore` and `ProfileSession+Factories`), so it must escape
`Backends/Remote/Auth/` before the directory can be deleted in commit 3.
Doing the move in its own commit keeps the diff trivially reviewable as a
pure rename.

### Task 1: Move `KeychainStore.swift` to `Shared/`

**Files:**
- Move: `Backends/Remote/Auth/KeychainStore.swift` → `Shared/KeychainStore.swift`
- Test move: `MoolahTests/Backends/KeychainStoreTests.swift` → `MoolahTests/Shared/KeychainStoreTests.swift`

- [ ] **Step 1: Create the destination directory if it doesn't exist.**

```bash
mkdir -p MoolahTests/Shared
```

- [ ] **Step 2: Move the production file.**

```bash
git mv Backends/Remote/Auth/KeychainStore.swift Shared/KeychainStore.swift
```

- [ ] **Step 3: Move the test file.**

```bash
git mv MoolahTests/Backends/KeychainStoreTests.swift MoolahTests/Shared/KeychainStoreTests.swift
```

- [ ] **Step 4: Regenerate the Xcode project.**

`project.yml` uses folder references, so just run:

```bash
just generate
```

Verify it succeeds. The regenerated `Moolah.xcodeproj` is gitignored, so this
produces no diff to commit unless `project.yml` changed (it won't for a pure
move under existing folder refs).

- [ ] **Step 5: Run macOS tests.**

```bash
just test-mac 2>&1 | tee .agent-tmp/test-commit1.txt
grep -i 'failed\|error:' .agent-tmp/test-commit1.txt
```

Expected: no failures. `KeychainStore` and `KeychainStoreTests` should still
work — only their paths moved.

- [ ] **Step 6: Format and commit.**

```bash
just format
git status
git add Shared/KeychainStore.swift MoolahTests/Shared/KeychainStoreTests.swift
# git mv has already staged the deletes; confirm:
git diff --cached --stat
```

Commit with:

```bash
git commit -m "$(cat <<'EOF'
refactor: move KeychainStore out of Backends/Remote/Auth into Shared/

KeychainStore is shared infrastructure (used by CryptoTokenStore and
ProfileSession+Factories for the CoinGecko API key), not remote-only. Moving
it to Shared/ unblocks the wholesale deletion of Backends/Remote/ in the
follow-up commit on this branch.

No behaviour change.
EOF
)"
```

- [ ] **Step 7: Clean up temp.**

```bash
rm .agent-tmp/test-commit1.txt
```

---

## Commit 2: Drop `BackendType` and rewire the construction layer

**End state after this commit:** `Profile` has no backend discriminator;
`ProfileSession.makeBackend` only builds the CloudKit path; `ProfileStore`
only manages cloud profiles; `MoolahApp+Setup` no longer injects a
`ServerValidator`. `Backends/Remote/` and `Backends/CloudKit/Migration/` are
unreferenced from production code but their test files (which import the
deleted-but-still-present types) still compile — those go in commit 3.

### Task 2: Strip remote fields from `Profile`

**Files:**
- Modify: `Domain/Models/Profile.swift`

- [ ] **Step 1: Replace the file contents with the end-state shape.**

```swift
import Foundation

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
  ) {
    self.id = id
    self.label = label
    self.currencyCode = currencyCode
    self.financialYearStartMonth = financialYearStartMonth
    self.createdAt = createdAt
  }

  var instrument: Instrument {
    Instrument.fiat(code: currencyCode)
  }
}
```

Removed: `BackendType` enum, `backendType`, `serverURL`, `resolvedServerURL`,
`moolahServerURL`, `supportsComplexTransactions`. Codable synthesis ignores
unknown keys, so a stale CloudKit `ProfileRecord` decodes fine; legacy
`com.moolah.profiles` UserDefaults entries are simply never read after
Task 4.

- [ ] **Step 2: Don't build yet** — every consumer of `backendType`,
  `serverURL`, `resolvedServerURL`, and `supportsComplexTransactions` is
  about to break, and we'll fix them in the next tasks. Move on.

### Task 3: Collapse `ProfileSession.makeBackend` to the cloud path

**Files:**
- Modify: `App/ProfileSession+Factories.swift`

- [ ] **Step 1: Replace the `makeBackend` switch with the cloud path only.**

In `App/ProfileSession+Factories.swift`, replace the entire `makeBackend(...)`
function body with:

```swift
guard let containerManager else {
  fatalError("ProfileContainerManager is required for CloudKit profiles")
}
return makeCloudKitBackend(
  profile: profile,
  containerManager: containerManager,
  syncCoordinator: syncCoordinator,
  marketData: CloudKitMarketDataServices(
    exchangeRates: exchangeRates,
    stockPrices: stockPrices,
    cryptoPrices: cryptoPrices))
```

The `switch profile.backendType` and the `URLSessionConfiguration.ephemeral`
/ `CookieKeychain` plumbing go away.

- [ ] **Step 2: Update the doc comment on `makeBackend(...)`.**

The current comment reads "iCloud profiles get the full conversion service
(stock + crypto + fiat); remote profiles use their own internal fiat-only
conversion." Replace with a one-liner: "Builds the CloudKit `BackendProvider`
for the profile."

- [ ] **Step 3: Update the doc comment on the `RegistryWiring` struct.**

The current comment says "Remote/moolah profiles are single-instrument by
server design and leave all five nil." Drop that sentence; the bundle is
always populated for CloudKit profiles, and CloudKit is now the only kind.

- [ ] **Step 4: Tighten `makeRegistryWiring` if you can.**

The function currently does `guard let cloudBackend = backend as? CloudKitBackend`.
After this commit `backend` is statically a `CloudKitBackend`, so the cast is
unnecessary. Two options:

- Easy: keep the `guard` but replace its `else` branch with `fatalError("makeBackend only constructs CloudKitBackend")` — minimum diff.
- Cleaner: change the `backend: BackendProvider` parameter to `backend: CloudKitBackend`. Search call sites; if there are none, do this.

Pick the cleaner option if the call site is just `ProfileSession.init` —
otherwise take the easy one and revisit later.

### Task 4: Strip `ProfileStore` to cloud-only

**Files:**
- Modify: `Features/Profiles/ProfileStore.swift`
- Modify: `Features/Profiles/ProfileStore+Cloud.swift`

- [ ] **Step 1: Edit `ProfileStore.swift`.**

Make the following edits:

1. Delete the `var remoteProfiles: [Profile] = []` stored property.
2. Delete the `let validator: (any ServerValidator)?` stored property.
3. Delete the `validator` parameter from `init(...)` and the
   `self.validator = validator` line.
4. Replace `var profiles: [Profile] { remoteProfiles + cloudProfiles }`
   with `var profiles: [Profile] { cloudProfiles }`.
5. Replace `addProfile(_:)` body's `switch profile.backendType` with the
   contents of the `case .cloudKit:` branch (drop the `case .remote, .moolah:`
   branch and the wrapping `switch`).
6. Replace `removeProfile(_:)` so that the `if let index = remoteProfiles
   .firstIndex(...)` branch is deleted entirely; only the `cloudProfiles`
   removal path remains. The `CookieKeychain(account: id.uuidString).clear()`
   call disappears with that branch.
7. Replace `updateProfile(_:)` body's `switch` with the contents of the
   `case .cloudKit:` branch.
8. Replace `validateAndAddProfile(_:)` body with:
   ```swift
   guard await validateiCloudAvailability() else { return false }
   addProfile(profile)
   return true
   ```
9. Replace `validateAndUpdateProfile(_:)` body with:
   ```swift
   updateProfile(profile)
   return true
   ```
   No iCloud-availability check on update — that matches the existing
   `case .cloudKit` branch, which had `// No validation needed for updating
   an existing CloudKit profile`.

Also drop any `import` lines that become unused (likely none — keep
`CloudKit`, `Foundation`, `OSLog`, `Observation`, `SwiftData`).

`WelcomePhase` and its `.pickingProfile` case are unchanged.

- [ ] **Step 2: Edit `ProfileStore+Cloud.swift`.**

1. Delete the `validateServer(url:)` method entirely (it was the only caller
   of `self.validator`).
2. Find the `loadFromDefaults` / persistence helpers and delete the code
   path that reads/writes `Self.profilesKey` (the legacy
   `com.moolah.profiles` key). Only `Self.activeProfileKey` persistence
   should remain. If the file does not contain that code path, it's likely
   inline in `ProfileStore.swift` — apply the same edit there. (Search:
   `grep -n "profilesKey" Features/Profiles/`.)
3. Delete the `static let profilesKey = "com.moolah.profiles"` declaration
   wherever it lives — there should be only one.

- [ ] **Step 3: Update doc comment at the top of `ProfileStore.swift`.**

The current header says "Remote profiles persist in UserDefaults; iCloud
profiles persist in SwiftData (ProfileRecord). Active profile ID is
per-device via UserDefaults." Replace with: "Profiles persist as CloudKit
`ProfileRecord` rows in SwiftData; the active profile ID is per-device
via UserDefaults."

### Task 5: Drop the `RemoteServerValidator` injection

**Files:**
- Modify: `App/MoolahApp.swift`

- [ ] **Step 1: Remove the `RemoteServerValidator()` injection.**

Find the `ProfileStore(...)` construction call (around line 82). It currently
passes `validator: RemoteServerValidator()`. Drop that argument entirely.
Also drop any `import`s that become unused.

- [ ] **Step 2: Search for other `ServerValidator` injection sites.**

Run: `grep -rn "validator:" App/ MoolahApp+Setup.swift 2>/dev/null`.
Expected: only test files and the `App/MoolahApp.swift` you just edited
should mention the parameter — and that one mention should now be gone.

### Task 6: Strip welcome / profile-form server-URL UI

**Files:**
- Modify: `Features/Profiles/Views/WelcomeView.swift`
- Modify: `Features/Profiles/Views/ProfileFormView.swift`
- Modify: `Features/Profiles/Views/CreateProfileFormView.swift`
- Modify (if affected): `Features/Profiles/Views/WelcomeStateResolver.swift`,
  `Features/Profiles/Views/WelcomeHero.swift`,
  `Features/Profiles/Views/ProfileMenuItems.swift`

- [ ] **Step 1: Audit the views.**

```bash
grep -n "BackendType\|backendType\|serverURL\|resolvedServerURL\|RemoteServer" \
  Features/Profiles/Views/*.swift
```

This lists every line that needs editing. Each one falls into one of:

- A `Picker` / `Menu` / segmented control between `.remote` / `.moolah` /
  `.cloudKit` — delete it; the Profile is always `.cloudKit` now.
- A `TextField` or read of `profile.serverURL` / `profile.resolvedServerURL`
  — delete it.
- A read of `profile.backendType` for branching — keep only the
  `.cloudKit` branch.
- A `Profile(...)` constructor call passing `backendType:` or `serverURL:` —
  drop those argument labels.

The `ICloudProfilePickerView`, `ICloudArrivalBanner`, `ICloudOffChip`,
`ICloudStatusLine` views deal exclusively with iCloud and should not appear
in the audit grep — they're untouched.

- [ ] **Step 2: After each file edit, save.**

You'll get compile errors at every call site that still references
`BackendType`. That's expected; the `ProfileTests` and `ProfileStoreTests`
edits below will close out the rest.

### Task 7: Clean up surviving production references

**Files:** various — discovered by grep.

- [ ] **Step 1: Grep for surviving call sites.**

```bash
grep -rn "BackendType\|backendType\|\.resolvedServerURL\|moolahServerURL" \
  App/ Features/ Shared/ Domain/ Automation/ 2>/dev/null
```

Expected hits include:

- `App/ContentView.swift`, `App/ProfileSession.swift`, `App/UITestSeedHydrator.swift`
- `Automation/AppleScript/Commands/*.swift`,
  `Automation/AutomationService.swift`,
  `Automation/AutomationService+ProfileMigration.swift` (the migration
  extension goes entirely — see Task 17 in commit 3)
- `Features/Profiles/ProfileStore+Cloud.swift` (already touched)
- `Shared/InstrumentSearchService.swift` (a doc comment — see below)

- [ ] **Step 2: For each hit, apply the appropriate fold.**

- `BackendType.cloudKit` literal in a `Profile(...)` constructor — drop the
  `backendType:` argument label.
- `if profile.backendType == .cloudKit { ... }` — keep the body; drop the
  `if`.
- `switch profile.backendType { ... }` — keep only the `.cloudKit` branch.
- `profile.resolvedServerURL` / `profile.moolahServerURL` — these are dead
  code paths; delete the whole containing block.
- Doc comments that say "Remote/moolah profiles ..." — rewrite or delete.

- [ ] **Step 3: Update `Shared/InstrumentSearchService.swift` comment.**

The comment at line ~125 mentions "When `catalog` is `nil` (e.g. a
`RemoteBackend` profile), this returns ...". Replace `RemoteBackend profile`
with a generic phrasing (e.g. "When `catalog` is `nil` (e.g. catalog init
failed)").

- [ ] **Step 4: Update `Domain/Models/BackendError.swift` comment on
  `unsupportedInstrument`.**

The current case-doc reads:

```swift
/// Thrown by single-instrument backends (Remote, moolah) when a write carries
/// an instrument other than the profile's currency. Indicates a programmer
/// error — the UI should have gated the write on `Profile.supportsComplexTransactions`.
case unsupportedInstrument(String)
```

`unsupportedInstrument` is still thrown — `CloudKitEarmarkRepository` uses it
(see `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift:150`).
Update the comment to reference the surviving thrower:

```swift
/// Thrown when a write carries an instrument that isn't allowed for the
/// target entity (e.g. an earmark whose instrument doesn't match the
/// containing entity). Indicates a programmer error — the UI should have
/// rejected the write before reaching the backend.
case unsupportedInstrument(String)
```

### Task 8: Strip remote cases from surviving tests

**Files:**
- Modify: `MoolahTests/Domain/ProfileTests.swift`
- Modify: `MoolahTests/Features/ProfileStoreTests.swift`
- Modify: `MoolahTests/Features/ProfileStoreTestsMore.swift`
- Modify: `MoolahTests/Features/ProfileStoreTestsMoreSecondHalf.swift`
- Modify: `MoolahTests/Features/ProfileStoreAvailabilityTests.swift`
- Modify: `MoolahTests/Features/ProfileStoreAutoActivateGuardTests.swift`
- Modify: `MoolahTests/App/ProfileSessionTests.swift` (and any sibling
  `ProfileSession*Tests.swift` files — check with `ls MoolahTests/App/`)
- Modify: `MoolahTests/Automation/*` (audit each — Task 21 in commit 3
  deletes `AutomationServiceMigrationTests.swift` outright, but the others
  may have remote-profile cases that need stripping)
- Modify: `MoolahTests/Domain/AuthContractTests.swift` — comment update only

- [ ] **Step 1: Edit each test file.**

For each file in the list above:

1. Find every `Profile(...)` constructor call. If it passes
   `backendType: .remote` or `backendType: .moolah` *or* `serverURL: ...`,
   either delete the whole test (if its purpose is exclusively to exercise
   the remote/moolah path) or strip the offending arguments.
2. Find every `InMemoryServerValidator(...)` construction — delete the test;
   the validator type goes in commit 3.
3. Find every `validator:` argument on `ProfileStore(...)` — drop it.

- [ ] **Step 2: Update `AuthContractTests.swift` header comment.**

The file header currently reads "Both InMemoryAuthProvider and
RemoteAuthProvider must pass these tests". Update to: "InMemoryAuthProvider
must pass these tests" (RemoteAuthProvider goes in commit 3, but the comment
update can happen here in commit 2 — the file content is unchanged, just
honest copy).

- [ ] **Step 3: Don't touch the `MoolahTests/Backends/Remote*` files.**

Those go away wholesale in commit 3, Task 17. Editing them now is wasted
work.

### Task 9: Verify and commit

- [ ] **Step 1: `just format`.**

```bash
just format
```

- [ ] **Step 2: Run `just test-mac` to verify the rewire compiles and existing tests still pass.**

```bash
just test-mac 2>&1 | tee .agent-tmp/test-commit2.txt
grep -i 'failed\|error:' .agent-tmp/test-commit2.txt
```

Expected: clean. If there are compile errors, they'll be at call sites you
missed in Tasks 6/7 — fix them.

Note that `MoolahTests/Backends/Remote*` test files still compile and run at
this point because their target types (`RemoteAccountRepository` etc.) still
exist on disk under `Backends/Remote/`. They just no longer have any
production caller.

- [ ] **Step 3: Run `just format-check`.**

```bash
just format-check
```

Expected: exits 0.

- [ ] **Step 4: Run `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`.**

Expected: no warnings in user code (preview macros may emit warnings —
ignore those).

- [ ] **Step 5: Stage and commit.**

```bash
git status
git add -A
git diff --cached --stat
git commit -m "$(cat <<'EOF'
refactor: drop BackendType discriminator and rewire construction layer to CloudKit-only

Strips Profile.backendType / serverURL / resolvedServerURL /
moolahServerURL / supportsComplexTransactions; collapses
ProfileSession.makeBackend to the CloudKit path; removes ProfileStore's
remoteProfiles, profilesKey persistence, and ServerValidator injection;
narrows the welcome/profile-form views.

After this commit Backends/Remote/ and Backends/CloudKit/Migration/ are
unreferenced from production. Their files (and tests) get deleted in the
next commit on this branch.
EOF
)"
```

- [ ] **Step 6: Clean up.**

```bash
rm .agent-tmp/test-commit2.txt
```

---

## Commit 3: Delete the Remote and Migration subsystems

**End state after this commit:** `Backends/Remote/`,
`Backends/CloudKit/Migration/`, `Domain/Repositories/ServerValidator.swift`,
the Remote test files, `MoolahTests/Migration/`,
`MoolahTests/Support/InMemoryServerValidator.swift`, and the API-shaped JSON
fixtures are gone. The build still compiles; tests still pass; the file
count is much smaller.

### Task 10: Delete `Backends/Remote/`

**Files:** the entire directory.

- [ ] **Step 1: Delete the directory.**

```bash
git rm -rf Backends/Remote
```

Expected: 28 files removed (`RemoteBackend.swift`,
`RemoteCSVImportProfileRepository.swift`,
`RemoteImportRuleRepository.swift`, `SingleInstrumentGuard.swift`, all of
`APIClient/`, `DTOs/`, `Repositories/`, `Validation/`, plus `Auth/`'s two
remaining files — `KeychainStore.swift` already left in commit 1).

### Task 11: Delete `Backends/CloudKit/Migration/`

**Files:** the entire directory.

- [ ] **Step 1: Delete the directory.**

```bash
git rm -rf Backends/CloudKit/Migration
```

Expected: 5 files removed (`CloudKitDataImporter.swift`,
`MigrationCoordinator.swift`, `MigrationError.swift`,
`MigrationProfileNaming.swift`, `MigrationVerifier.swift`).

### Task 12: Delete `Domain/Repositories/ServerValidator.swift`

**Files:**
- Delete: `Domain/Repositories/ServerValidator.swift`

- [ ] **Step 1: Confirm no surviving references.**

```bash
grep -rn "ServerValidator" --include="*.swift" \
  App/ Features/ Shared/ Domain/ Backends/ MoolahTests/ MoolahUITests_macOS/
```

Expected output: only `Domain/Repositories/ServerValidator.swift` itself,
`MoolahTests/Support/InMemoryServerValidator.swift`, and possibly a comment.
Any other production hit means a Task 7 fold was missed — go fix it.

- [ ] **Step 2: Delete.**

```bash
git rm Domain/Repositories/ServerValidator.swift
```

### Task 13: Delete the Remote test files

**Files:**

- Delete: `MoolahTests/Backends/RemoteAccountRepositoryTests.swift`
- Delete: `MoolahTests/Backends/RemoteCategoryRepositoryTests.swift`
- Delete: `MoolahTests/Backends/RemoteEarmarkRepositoryTests.swift`
- Delete: `MoolahTests/Backends/RemoteInvestmentRepositoryTests.swift`
- Delete: `MoolahTests/Backends/RemoteTransactionRepositoryTests.swift`
- Delete: `MoolahTests/Backends/RemoteTransactionRepositoryTestsMore.swift`
- Delete: `MoolahTests/Backends/RemoteServerValidatorTests.swift`
- Delete: `MoolahTests/Backends/CookieKeychainTests.swift`
- Delete: `MoolahTests/Backends/Remote/` directory (contains
  `ServerUUIDTests.swift`)

- [ ] **Step 1: Delete.**

```bash
git rm MoolahTests/Backends/RemoteAccountRepositoryTests.swift \
       MoolahTests/Backends/RemoteCategoryRepositoryTests.swift \
       MoolahTests/Backends/RemoteEarmarkRepositoryTests.swift \
       MoolahTests/Backends/RemoteInvestmentRepositoryTests.swift \
       MoolahTests/Backends/RemoteTransactionRepositoryTests.swift \
       MoolahTests/Backends/RemoteTransactionRepositoryTestsMore.swift \
       MoolahTests/Backends/RemoteServerValidatorTests.swift \
       MoolahTests/Backends/CookieKeychainTests.swift
git rm -rf MoolahTests/Backends/Remote
```

### Task 14: Delete `MoolahTests/Migration/`

**Files:** the entire directory.

- [ ] **Step 1: Delete.**

```bash
git rm -rf MoolahTests/Migration
```

Expected: 5 files removed (`CloudKitDataImporterTests.swift`,
`DataExporterTests.swift`, `MigrationIntegrationTests.swift`,
`MigrationProfileNamingTests.swift`, `MigrationVerifierTests.swift`).

If `DataExporterTests.swift` looks suspicious — confirm:

```bash
grep -l "Migration\|Remote" .agent-tmp/scratch-DataExporterTests.swift 2>/dev/null \
  || git -C . show HEAD:MoolahTests/Migration/DataExporterTests.swift | grep -i "migration\|remote"
```

If it's *only* about migration (it should be — it lives in the Migration
folder), the delete is correct. If the file actually exercises non-migration
data export, restore it from HEAD into a non-migration location instead. (In
practice this is rhetorical — `DataExporter` is the migration importer's
inverse and goes with it.)

### Task 15: Delete `MoolahTests/Support/InMemoryServerValidator.swift`

- [ ] **Step 1: Delete.**

```bash
git rm MoolahTests/Support/InMemoryServerValidator.swift
```

### Task 16: Delete API-shaped fixtures

**Files:**

- Delete: `MoolahTests/Support/Fixtures/accounts.json`
- Delete: `MoolahTests/Support/Fixtures/account_balances.json`
- Delete: `MoolahTests/Support/Fixtures/account_create_response.json`
- Delete: `MoolahTests/Support/Fixtures/account_update_response.json`
- Delete: `MoolahTests/Support/Fixtures/categories.json`
- Delete: `MoolahTests/Support/Fixtures/earmarks.json`
- Delete: `MoolahTests/Support/Fixtures/transactions.json`
- Delete: `MoolahTests/Support/Fixtures/investment_values.json`

CoinGecko, Yahoo, and CSV fixtures stay.

- [ ] **Step 1: Delete.**

```bash
git rm MoolahTests/Support/Fixtures/accounts.json \
       MoolahTests/Support/Fixtures/account_balances.json \
       MoolahTests/Support/Fixtures/account_create_response.json \
       MoolahTests/Support/Fixtures/account_update_response.json \
       MoolahTests/Support/Fixtures/categories.json \
       MoolahTests/Support/Fixtures/earmarks.json \
       MoolahTests/Support/Fixtures/transactions.json \
       MoolahTests/Support/Fixtures/investment_values.json
```

### Task 17: Drop the AppleScript `+ProfileMigration` extension

**Files:**
- Possibly delete: `Automation/AutomationService+ProfileMigration.swift`

- [ ] **Step 1: Inspect the file.**

```bash
grep -n "Migration\|Remote\|backendType" Automation/AutomationService+ProfileMigration.swift
```

If the file is exclusively about migrating remote profiles to iCloud, delete
it:

```bash
git rm Automation/AutomationService+ProfileMigration.swift
```

If it has any non-migration responsibility, fold the migration parts out and
keep the rest. (Most likely: it's purely migration → delete.)

- [ ] **Step 2: Drop the matching test if there is one.**

```bash
ls MoolahTests/Automation/AutomationServiceMigrationTests.swift && \
  git rm MoolahTests/Automation/AutomationServiceMigrationTests.swift
```

### Task 18: Verify and commit

- [ ] **Step 1: Regenerate the project (folder refs may need a refresh).**

```bash
just generate
```

- [ ] **Step 2: `just format`.**

```bash
just format
```

- [ ] **Step 3: Run tests.**

```bash
just test-mac 2>&1 | tee .agent-tmp/test-commit3.txt
grep -i 'failed\|error:' .agent-tmp/test-commit3.txt
```

Expected: clean. If there are compile errors, the most likely cause is a
test file that imports `RemoteAccountRepository` / `MigrationCoordinator` /
`InMemoryServerValidator` that wasn't deleted. Re-run the grep:

```bash
grep -rln "RemoteBackend\|RemoteAuthProvider\|RemoteServerValidator\|CookieKeychain\|MigrationCoordinator\|InMemoryServerValidator" \
  --include="*.swift" .
```

Expected: zero hits outside `plans/completed/` and `.worktrees/`.

- [ ] **Step 4: Run `just format-check`.**

Expected: exits 0.

- [ ] **Step 5: Run the iOS suite as well — first time on this branch.**

```bash
just test 2>&1 | tee .agent-tmp/test-commit3-full.txt
grep -i 'failed\|error:' .agent-tmp/test-commit3-full.txt
```

Expected: clean across both `MoolahTests_iOS` and `MoolahTests_macOS`.

- [ ] **Step 6: Commit.**

```bash
git status
git add -A
git diff --cached --stat
git commit -m "$(cat <<'EOF'
refactor: delete moolah-server (Remote) backend and migration coordinator

Backends/Remote/: 28 files (APIClient, Auth/CookieKeychain +
RemoteAuthProvider, DTOs, Repositories, Validation, plus the wrappers
RemoteBackend / RemoteCSVImportProfileRepository /
RemoteImportRuleRepository / SingleInstrumentGuard).

Backends/CloudKit/Migration/: 5 files (MigrationCoordinator,
CloudKitDataImporter, MigrationError, MigrationProfileNaming,
MigrationVerifier) — purely remote→iCloud migration.

Domain/Repositories/ServerValidator.swift: orphaned protocol.

Tests: MoolahTests/Backends/Remote*, MoolahTests/Migration/,
MoolahTests/Support/InMemoryServerValidator.swift,
MoolahTests/Backends/CookieKeychainTests.swift, and the API-shaped JSON
fixtures under MoolahTests/Support/Fixtures/. AppleScript migration
extension and its tests also gone.

After this commit `supportsComplexTransactions` is the last vestige of the
remote/moolah world; it's folded in the next commit on this branch.
EOF
)"
```

- [ ] **Step 7: Clean up.**

```bash
rm .agent-tmp/test-commit3*.txt
```

---

## Commit 4: Fold `Profile.supportsComplexTransactions`

**End state after this commit:** every view that currently takes a
`supportsComplexTransactions: Bool` parameter loses it; every conditional
branch that depended on it collapses to the always-true path.

**Important boundary:** `Profile.supportsComplexTransactions` was already
deleted in commit 2 (Task 2). For commit 2 to compile, every *read* of
`profile.supportsComplexTransactions` had to be folded in commit 2 itself
(Task 7) — replaced with `true`, or with the surrounding `if`/`switch`
collapsing to its true branch. What survived into commit 4 is the views'
own stored `let supportsComplexTransactions: Bool` properties and their
init parameters, which are independent of `Profile` and still compile.

Commit 4 pushes the fold one level deeper: each child view drops its own
parameter → the parent stops passing it → the parent drops its parameter
→ repeat upward until the fold reaches a leaf. The change is mechanical.

### Task 19: Confirm scope

- [ ] **Step 1: Re-grep for surviving sites.**

```bash
grep -rn "supportsComplexTransactions" --include="*.swift" \
  App/ Features/ Shared/ MoolahTests/ MoolahUITests_macOS/
```

Expected: 70+ hits across ~22 files. Each one is either:

- A stored `let supportsComplexTransactions: Bool` and matching init
  parameter on a view → delete both.
- A `supportsComplexTransactions ? X : Y` ternary → replace with `X`.
- An `if supportsComplexTransactions { A } else { B }` → replace with `A`.
- A call-site argument `child(supportsComplexTransactions: ...)` → drop the
  argument label and value.
- A `#Preview` literal `supportsComplexTransactions: true` → drop the
  argument.

### Task 20: Fold `App/ContentView.swift`

**Files:**
- Modify: `App/ContentView.swift`

- [ ] **Step 1: Find the three sites.**

`App/ContentView.swift` has three `supportsComplexTransactions:
session.profile.supportsComplexTransactions` argument-passing call sites
(approximately lines 85, 168, 290). After commit 2 these still compile
because `session.profile.supportsComplexTransactions` was either replaced
with `true` or already wrong; verify by grep.

- [ ] **Step 2: At each call site, drop the entire argument.**

The child view's init in commit 4 will no longer take that parameter.

### Task 21: Fold the Accounts feature

**Files:**
- Modify: `Features/Accounts/Views/CreateAccountView.swift`
- Modify: `Features/Accounts/Views/EditAccountView.swift`

- [ ] **Step 1: In `CreateAccountView.swift`, delete the property and init parameter.**

Lines to remove:
- `let supportsComplexTransactions: Bool` (around line 19)
- `supportsComplexTransactions: Bool = false` from the init signature
  (around line 29)
- `self.supportsComplexTransactions = supportsComplexTransactions` (around
  line 33)

Lines to replace:
- `if supportsComplexTransactions { InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency) }`
  → keep just `InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)`
  (drop the `if`)
- Any `#Preview` line with `supportsComplexTransactions: true` → drop the
  argument.

- [ ] **Step 2: Repeat the same pattern for `EditAccountView.swift`.**

- [ ] **Step 3: Fix any call site that constructs these views.**

Search:

```bash
grep -rn "CreateAccountView(\|EditAccountView(" App/ Features/ MoolahUITests_macOS/
```

For each call site, drop the `supportsComplexTransactions:` argument.

### Task 22: Fold the Earmarks feature

**Files:**
- Modify: `Features/Earmarks/Views/CreateEarmarkSheet.swift`
- Modify: `Features/Earmarks/Views/EditEarmarkSheet.swift`
- Modify: `Features/Earmarks/Views/EarmarksView.swift`
- Modify: `Features/Earmarks/Views/EarmarkDetailView.swift`

- [ ] **Step 1: For each file, apply the same fold as Task 21.**

`CreateEarmarkSheet.swift` has a `supportsComplexTransactions ? currency :
instrument` ternary — replace with `currency`. Other sites are conditional
sections to keep unconditionally.

- [ ] **Step 2: Fix the call sites.**

```bash
grep -rn "CreateEarmarkSheet(\|EditEarmarkSheet(\|EarmarksView(\|EarmarkDetailView(" \
  App/ Features/ MoolahUITests_macOS/
```

Drop the argument from each.

### Task 23: Fold the Transactions feature

**Files:**
- Modify: `Features/Transactions/Views/Detail/TransactionDetailModeSection.swift`
- Modify: `Features/Transactions/Views/Detail/TransactionDetailView+Previews.swift`
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`
- Modify: `Features/Transactions/Views/TransactionInspectorModifier.swift`
- Modify: `Features/Transactions/Views/TransactionListView.swift`
- Modify: `Features/Transactions/Views/UpcomingView.swift`

- [ ] **Step 1: Apply the fold per file.**

`TransactionDetailModeSection.swift` has the substantive change: the
"custom-mode toggle is hidden when `supportsComplexTransactions` is `false`"
behaviour is the load-bearing one. After this commit the toggle is always
shown — verify the `body` retains the toggle UI when the flag is removed.

- [ ] **Step 2: Fix call sites.**

```bash
grep -rn "TransactionDetailModeSection(\|TransactionDetailView(\|TransactionInspectorModifier(\|TransactionListView(\|UpcomingView(" \
  App/ Features/ MoolahUITests_macOS/
```

### Task 24: Fold Investments / Reports / Analysis / Sidebar

**Files:**
- Modify: `Features/Investments/Views/InvestmentAccountView.swift`
- Modify: `Features/Reports/Views/ReportsView.swift`
- Modify: `Features/Analysis/Views/AnalysisView.swift`
- Modify: `Features/Navigation/SidebarView.swift`

- [ ] **Step 1: Apply the fold per file and fix call sites.**

These are typically the "warning banner shown to single-instrument profiles"
sites — the warning copy disappears entirely now that all profiles are
multi-instrument-capable.

### Task 25: Fold UI tests

**Files:**
- Modify: `MoolahUITests_macOS/Helpers/Screens/CreateAccountScreen.swift`
- Modify: `MoolahUITests_macOS/Tests/InstrumentPickerUITests.swift`

- [ ] **Step 1: Audit each file.**

```bash
grep -n "supportsComplexTransactions\|backendType\|BackendType" \
  MoolahUITests_macOS/Helpers/Screens/CreateAccountScreen.swift \
  MoolahUITests_macOS/Tests/InstrumentPickerUITests.swift
```

These references exist only to seed a profile in a particular shape. Drop
them; the seeded profile now has no backend-type discriminator.

If `InstrumentPickerUITests.swift` has a test whose entire purpose is to
verify the picker is *hidden* on remote profiles, delete the test — that
behaviour no longer exists.

### Task 26: Fold ProfileTests

**Files:**
- Modify: `MoolahTests/Domain/ProfileTests.swift`

- [ ] **Step 1: Delete cases that test `supportsComplexTransactions`.**

Most likely there's a test asserting `Profile(backendType: .cloudKit).supportsComplexTransactions == true`
and a counterpart for `.remote == false`. Both go — the property is gone.

Surviving cases: instrument computation from currencyCode, equality, encode/
decode round-trip.

### Task 27: Verify and commit

- [ ] **Step 1: `just format`.**

```bash
just format
```

- [ ] **Step 2: Run `just test`.**

```bash
just test 2>&1 | tee .agent-tmp/test-commit4.txt
grep -i 'failed\|error:' .agent-tmp/test-commit4.txt
```

Expected: clean, both targets.

- [ ] **Step 3: Run `MoolahUITests_macOS`.**

```bash
just test-mac MoolahUITests_macOS 2>&1 | tee .agent-tmp/uitest-commit4.txt
grep -i 'failed\|error:' .agent-tmp/uitest-commit4.txt
```

Expected: clean. The fold sites are exercised end-to-end here, so this is
the highest-signal verification step in the whole plan.

- [ ] **Step 4: `just format-check`.**

Expected: exits 0.

- [ ] **Step 5: `mcp__xcode__XcodeListNavigatorIssues` warning-free.**

- [ ] **Step 6: Confirm the grep sweep is empty.**

```bash
grep -rn "supportsComplexTransactions" --include="*.swift" \
  App/ Features/ Shared/ Domain/ Backends/ MoolahTests/ MoolahUITests_macOS/
```

Expected: zero hits.

- [ ] **Step 7: Commit.**

```bash
git status
git add -A
git diff --cached --stat
git commit -m "$(cat <<'EOF'
refactor: fold Profile.supportsComplexTransactions across feature views

Every site that previously gated multi-instrument UI behind the
single-instrument backend now unconditionally takes the multi-instrument
path. ~22 view/store/test files; the property and the parameter
disappear from the API surface.
EOF
)"
```

- [ ] **Step 8: Clean up.**

```bash
rm .agent-tmp/*commit4*.txt
```

---

## Commit 5: Documentation

**End state after this commit:** README, CLAUDE.md, and the `guides/` files
match the new reality (CloudKit-only, no moolah-server, no remote tests).
Active in-flight plans get updated only where stale copy would mislead future
readers; `plans/completed/*.md` is left as historical record.

### Task 28: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Edit the four moolah-server-stained lines.**

Find and replace these passages:

1. Line ~78: "No feature file may import `Backends/` or reference `Remote*`
   types directly." → "No feature file may import `Backends/`."
2. Line ~81: "`RemoteBackend` for production, `CloudKitBackend` with
   in-memory SwiftData for tests (`TestBackend`) and previews
   (`PreviewBackend`)." → "`CloudKitBackend` for production, and the same
   `CloudKitBackend` with in-memory SwiftData for tests (`TestBackend`) and
   previews (`PreviewBackend`)."
3. Line ~121: "Tests run against `CloudKitBackend` with in-memory SwiftData.
   `RemoteBackend` tests use fixture JSON stubs." → "Tests run against
   `CloudKitBackend` with in-memory SwiftData."
4. Line ~124-125: Delete the "Verification: Every `CloudKitBackend`
   repository method must be verified against `moolah-server` source..."
   bullet entirely; delete the "Fixtures: Remote backend tests use
   `URLProtocol` stubs..." bullet entirely.

### Task 29: Update `guides/TEST_GUIDE.md`

**Files:**
- Modify: `guides/TEST_GUIDE.md`

- [ ] **Step 1: Edit line ~105.**

`(`TestBackend` vs `RemoteBackend` via `BackendProvider`)` → `(`TestBackend`
via `BackendProvider`)`. Also scan the file for any other moolah-server /
RemoteBackend / fiat-only / single-instrument references and update them.

### Task 30: Update `guides/INSTRUMENT_CONVERSION_GUIDE.md`

**Files:**
- Modify: `guides/INSTRUMENT_CONVERSION_GUIDE.md`

- [ ] **Step 1: Find the §Rule 11a or `requireMatchesProfileInstrument` /
  `SingleInstrumentGuard` references.**

```bash
grep -n "SingleInstrumentGuard\|requireMatchesProfileInstrument\|supportsComplexTransactions\|Remote" \
  guides/INSTRUMENT_CONVERSION_GUIDE.md
```

The single-instrument guard no longer exists. Either delete the rule
entirely, or rewrite it to reflect the multi-instrument-everywhere reality.
Pick deletion if the rule has no remaining force.

### Task 31: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find moolah-server / `moolah.rocks` references.**

```bash
grep -n "moolah-server\|moolah\.rocks\|moolah\.rocks/api" README.md
```

The README currently has at least three sections that describe the legacy
backend (around lines 6-7, 71, 81). Rewrite the project intro to describe
moolah-native as a CloudKit-backed Universal SwiftUI app for macOS and iOS
(no server component). The existing "iCloud sync" section stays.

### Task 32: Update active in-flight plan docs

**Files (audit each — only edit if stale copy would mislead):**

- `plans/2026-04-11-australian-tax-reporting-design.md`
- `plans/2026-04-20-ui-testing-strategy-design.md`
- `plans/2026-04-21-transaction-detail-focus-design.md`
- `plans/2026-04-24-first-run-experience-design.md`
- `plans/2026-04-24-first-run-experience-implementation.md`
- `plans/IOS_RELEASE_AUTOMATION_PLAN.md`

- [ ] **Step 1: For each file, grep and decide.**

```bash
grep -n "moolah-server\|RemoteBackend\|backendType" plans/<file>.md
```

If the reference is in a "background context" section that's purely
historical → leave it alone.

If the reference is in a step that an engineer might *act on* (e.g.
"validate against moolah-server") → rewrite or strike that step.

Most likely the first-run experience and iOS release automation plans need
small updates; the others can stay.

- [ ] **Step 2: Don't touch `plans/completed/*.md`.**

Those are historical record.

### Task 33: Final verification and commit

- [ ] **Step 1: `just format` (no-op for markdown but runs cleanly).**

```bash
just format
```

- [ ] **Step 2: Run the final-evidence grep for the PR description.**

```bash
grep -rn "RemoteBackend\|RemoteServerValidator\|RemoteAuthProvider\|CookieKeychain\|MigrationCoordinator\|MigrationVerifier\|BackendType\|Profile\.serverURL\|resolvedServerURL\|supportsComplexTransactions\|moolah-server\|moolah\.rocks" \
  --include="*.swift" --include="*.md" --include="*.yml" \
  --exclude-dir=.worktrees --exclude-dir=completed --exclude-dir=build .
```

Expected: zero hits. `--exclude-dir` takes a basename in BSD grep, so
`completed` (the only such directory in the project) excludes
`plans/completed/`; `.worktrees` excludes both this spec worktree and any
other branches you have checked out.

If anything surfaces, fix it before commit.

- [ ] **Step 3: Run the full test suite one last time.**

```bash
just test 2>&1 | tee .agent-tmp/test-final.txt
grep -i 'failed\|error:' .agent-tmp/test-final.txt
```

Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git status
git add -A
git diff --cached --stat
git commit -m "$(cat <<'EOF'
docs: update README, CLAUDE.md, and guides for CloudKit-only world

README no longer describes moolah-server. CLAUDE.md, TEST_GUIDE.md, and
INSTRUMENT_CONVERSION_GUIDE.md drop their references to RemoteBackend,
fixture JSON stubs, the SingleInstrumentGuard rule, and the cross-repo
moolah-server verification step. In-flight plans tightened where stale
copy would mislead future readers; plans/completed/ untouched.
EOF
)"
```

- [ ] **Step 5: Clean up.**

```bash
rm -f .agent-tmp/*.txt
```

---

## Open the PR

### Task 34: Push and create the PR

- [ ] **Step 1: Push the branch.**

```bash
git push -u origin feature/remove-moolah-server
```

- [ ] **Step 2: Create the PR.**

Use the standard format. Body skeleton:

```markdown
## Summary
- Deletes `Backends/Remote/` (moolah-server REST client) and
  `Backends/CloudKit/Migration/` (remote→iCloud migration coordinator)
- Drops `Profile.backendType` discriminator and `supportsComplexTransactions`
  gate; CloudKit is now the only backend
- Companion design: `plans/2026-04-28-remove-moolah-server-design.md`

## Verification
- `just test` clean (iOS + macOS)
- `MoolahUITests_macOS` clean
- Grep sweep: zero hits outside `plans/completed/` for `RemoteBackend`,
  `RemoteServerValidator`, `RemoteAuthProvider`, `CookieKeychain`,
  `MigrationCoordinator`, `MigrationVerifier`, `BackendType`,
  `Profile.serverURL`, `resolvedServerURL`,
  `supportsComplexTransactions`, `moolah-server`, `moolah.rocks`

## Migration story for existing installs
Hard cutover. Devices with cached `.remote` / `.moolah` profiles in
`com.moolah.profiles` UserDefaults silently stop seeing them after upgrade
— the new build never reads that key. Stale `CookieKeychain` cookies and
the legacy UserDefaults entry are not actively cleaned up; they hang
around as orphan keychain rows / dictionary entries on the device.

## Test plan
- [x] `just test` — both targets green
- [x] `just test-mac MoolahUITests_macOS` green
- [x] `just format-check` green
- [x] `mcp__xcode__XcodeListNavigatorIssues` warning-free
```

- [ ] **Step 3: Add the PR to the merge queue.**

Per the standing rule, every PR goes through the `merge-queue` skill, not
manual merge.

---

## Self-review checklist (for the implementer, before opening the PR)

- [ ] Five commits, each landing in a green state.
- [ ] No edits to `.swiftlint-baseline.yml`.
- [ ] No `RemoteBackend` / `MigrationCoordinator` / `BackendType` /
  `supportsComplexTransactions` / `moolah-server` references outside
  `plans/completed/`.
- [ ] `WelcomePhase.pickingProfile` still exists (it's the multi-iCloud
  picker, not a server-validation thing).
- [ ] `BackendError.unsupportedInstrument` is still in `BackendError.swift`
  (it's still thrown by `CloudKitEarmarkRepository`); only its doc comment
  changed.
- [ ] `KeychainStore` and `InMemoryAuthProvider` survive — both are
  shared, not remote-only.
- [ ] `AuthProvider` protocol survives; `AuthContractTests` header comment
  no longer mentions `RemoteAuthProvider`.
