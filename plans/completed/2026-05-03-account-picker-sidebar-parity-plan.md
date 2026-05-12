# Account Picker Sidebar Parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every account-selection `Picker` in `TransactionDetail*`
render with a type-based icon and the same group/sort order as the
sidebar; fix every "first valid account" smart-default to use that
order.

**Architecture:** Two pure helpers on the `Accounts` domain collection
(`sidebarGrouped`, `sidebarOrdered`) become the single source of truth.
A new `AccountPickerOptions` SwiftUI view emits the
`Section`/`Label`/`Tag` content for any `Picker`. Existing pickers and
default-pick sites are migrated to use them.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test` / `#expect`),
`just` for build/format/test.

**Spec:** [`plans/2026-05-03-account-picker-sidebar-parity-design.md`](2026-05-03-account-picker-sidebar-parity-design.md).

**Worktree:** `.worktrees/account-picker-sidebar-parity` on
`feat/account-picker-sidebar-parity`.

**Layer-path correction (since spec was written):**
- `TransactionDraft+SimpleMode.swift` lives in `Shared/Models/`, not
  `Domain/Models/`.
- `TransactionDetailView+Helpers.swift` lives in
  `Features/Transactions/Views/`, not
  `Features/Transactions/Views/Detail/`.
- TransactionDraft tests live in `MoolahTests/Shared/`. The new
  `Accounts` ordering tests live in `MoolahTests/Domain/`.
- The hidden flag is `Account.isHidden`, not `hidden`.
- A fourth picker call site was found: `TransactionDetailAddLegSection`.
  A second smart-default site was found: `TransactionDraft+TradeMode.applyTransferLegs`.

---

## File Map

**Create:**
- `Features/Accounts/Views/Account+Icon.swift` — moved `sidebarIcon` extension.
- `Features/Accounts/Views/AccountPickerOptions.swift` — shared picker content view + `#Preview`.
- `Domain/Models/Accounts+SidebarOrdering.swift` — pure helpers on `Accounts`.
- `MoolahTests/Domain/AccountsSidebarOrderingTests.swift` — Swift Testing suite.
- `MoolahTests/Shared/TransactionDraftSetTypeDefaultAccountTests.swift` — regression suite for the smart-default fix.

**Modify:**
- `Features/Accounts/Views/AccountSidebarRow.swift` — remove the `sidebarIcon` extension (moved).
- `Features/Transactions/Views/Detail/TransactionDetailAccountSection.swift` — drop `sortedAccounts` param, drop `eligibleTransferAccounts` helper, use `AccountPickerOptions`.
- `Features/Transactions/Views/Detail/TransactionDetailTradeSection.swift` — drop `sortedAccounts` param, use `AccountPickerOptions`.
- `Features/Transactions/Views/Detail/TransactionDetailLegRow.swift` — drop `sortedAccounts` param, use `AccountPickerOptions`.
- `Features/Transactions/Views/Detail/TransactionDetailAddLegSection.swift` — drop `sortedAccounts` param, take `accounts: Accounts`, use `accounts.sidebarOrdered().first`.
- `Features/Transactions/Views/TransactionDetailView.swift` — drop `sortedAccounts:` arguments at the four call sites; pass `accounts:` to `AddLegSection`.
- `Features/Transactions/Views/TransactionDetailView+Helpers.swift` — delete the `sortedAccounts` computed property.
- `Shared/Models/TransactionDraft+SimpleMode.swift` — `setType` uses `accounts.sidebarOrdered(excluding:)`.
- `Shared/Models/TransactionDraft+TradeMode.swift` — `applyTransferLegs` uses `accounts.sidebarOrdered(excluding:)`.
- `project.yml` — register the four new source files (run `just generate` to regenerate `Moolah.xcodeproj`).

**Out of scope (left as-is, may be raised by reviewers):**
- `accounts.ordered.first` fallbacks in `AnalysisView`, `UpcomingView`, `TransactionListView`, `RuleEditorView`, `RuleEditorActionRow`. These are display-instrument fallbacks and rule-editor defaults, not transaction-detail account pickers. If reviewers ask for them to be migrated for consistency, fix them then.

---

### Task 1: Extract `sidebarIcon` to its own file (no behaviour change)

**Files:**
- Create: `Features/Accounts/Views/Account+Icon.swift`
- Modify: `Features/Accounts/Views/AccountSidebarRow.swift` (lines 57-66 removed)
- Modify: `project.yml` (add the new source file under the relevant target sources)

- [ ] **Step 1: Create `Account+Icon.swift`**

```swift
import Foundation

/// SF Symbol used for an account in the sidebar and in account-selection
/// pickers. Keep this mapping in one place so the sidebar and the pickers
/// stay in sync.
extension Account {
  var sidebarIcon: String {
    switch type {
    case .bank: return "building.columns"
    case .asset: return "house.fill"
    case .creditCard: return "creditcard"
    case .investment: return "chart.line.uptrend.xyaxis"
    }
  }
}
```

- [ ] **Step 2: Remove the duplicated extension from `AccountSidebarRow.swift`**

Delete lines 57-66 (the `extension Account { var sidebarIcon: String { ... } }` block). Leave the rest of the file untouched.

- [ ] **Step 3: Register the new file in `project.yml`**

`project.yml` lists each Swift file per target via xcodegen sources. Locate the section that declares `Features/Accounts/Views/AccountSidebarRow.swift` (or, if sources are globbed, no edit needed). If listed explicitly, add `Features/Accounts/Views/Account+Icon.swift` next to it. If globbed, skip this step.

- [ ] **Step 4: Regenerate the Xcode project**

Run: `just generate`
Expected: project regenerates without errors; new file is picked up.

- [ ] **Step 5: Build to verify nothing broke**

Run: `just build-mac 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`. If the build complains about a duplicate `sidebarIcon`, you missed deleting the old one.

- [ ] **Step 6: Format**

Run: `just format`

- [ ] **Step 7: Commit**

```bash
git -C .worktrees/account-picker-sidebar-parity add \
  Features/Accounts/Views/Account+Icon.swift \
  Features/Accounts/Views/AccountSidebarRow.swift \
  project.yml
git -C .worktrees/account-picker-sidebar-parity commit -m "refactor(accounts): extract sidebarIcon to shared file

Move the Account.sidebarIcon extension out of AccountSidebarRow so the
upcoming AccountPickerOptions view can share the same mapping. Pure
move, no behaviour change."
```

---

### Task 2: `Accounts.sidebarGrouped` and `sidebarOrdered` (TDD)

**Files:**
- Create: `MoolahTests/Domain/AccountsSidebarOrderingTests.swift`
- Create: `Domain/Models/Accounts+SidebarOrdering.swift`
- Modify: `project.yml` (register both files if sources are listed explicitly)

- [ ] **Step 1: Write the failing test suite**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Accounts sidebar ordering")
struct AccountsSidebarOrderingTests {
  private func bank(_ name: String, position: Int, isHidden: Bool = false) -> Account {
    Account(
      id: UUID(), name: name, type: .bank, instrument: .AUD,
      positions: [], position: position, isHidden: isHidden)
  }
  private func investment(_ name: String, position: Int, isHidden: Bool = false) -> Account {
    Account(
      id: UUID(), name: name, type: .investment, instrument: .AUD,
      positions: [], position: position, isHidden: isHidden)
  }

  @Test("Partitions current vs investment by type")
  func partitionsByType() {
    let chequing = bank("Chequing", position: 0)
    let house = Account(
      id: UUID(), name: "House", type: .asset, instrument: .AUD,
      positions: [], position: 1, isHidden: false)
    let card = Account(
      id: UUID(), name: "Card", type: .creditCard, instrument: .AUD,
      positions: [], position: 2, isHidden: false)
    let brokerage = investment("Brokerage", position: 0)
    let accounts = Accounts(from: [brokerage, card, chequing, house])

    let groups = accounts.sidebarGrouped()

    #expect(groups.current.map(\.name) == ["Chequing", "House", "Card"])
    #expect(groups.investment.map(\.name) == ["Brokerage"])
  }

  @Test("Sorts within each group by position ascending")
  func sortsByPosition() {
    let a = bank("A", position: 2)
    let b = bank("B", position: 0)
    let c = bank("C", position: 1)
    let accounts = Accounts(from: [a, b, c])

    let groups = accounts.sidebarGrouped()

    #expect(groups.current.map(\.name) == ["B", "C", "A"])
  }

  @Test("Excluding drops the matching account from both helpers")
  func excludingDrops() {
    let a = bank("A", position: 0)
    let b = bank("B", position: 1)
    let accounts = Accounts(from: [a, b])

    let groups = accounts.sidebarGrouped(excluding: a.id)
    let flat = accounts.sidebarOrdered(excluding: a.id)

    #expect(groups.current.map(\.name) == ["B"])
    #expect(flat.map(\.name) == ["B"])
  }

  @Test("Hidden accounts are filtered out by default")
  func hiddenFiltered() {
    let visible = bank("Visible", position: 0)
    let hidden = bank("Hidden", position: 1, isHidden: true)
    let accounts = Accounts(from: [visible, hidden])

    let groups = accounts.sidebarGrouped()

    #expect(groups.current.map(\.name) == ["Visible"])
  }

  @Test("alwaysInclude retains a hidden account")
  func alwaysIncludeRetainsHidden() {
    let visible = bank("Visible", position: 0)
    let hidden = bank("Hidden", position: 1, isHidden: true)
    let accounts = Accounts(from: [visible, hidden])

    let groups = accounts.sidebarGrouped(alwaysInclude: hidden.id)

    #expect(groups.current.map(\.name) == ["Visible", "Hidden"])
  }

  @Test("alwaysInclude on a non-existent id is a no-op")
  func alwaysIncludeNonExistent() {
    let visible = bank("Visible", position: 0)
    let accounts = Accounts(from: [visible])

    let groups = accounts.sidebarGrouped(alwaysInclude: UUID())

    #expect(groups.current.map(\.name) == ["Visible"])
  }

  @Test("excluding wins over alwaysInclude when they collide")
  func excludingWinsOverAlwaysInclude() {
    // Defensive contract: callers can pass the picker's own from-account
    // as `excluding` and the same id as `alwaysInclude` (the current
    // selection). Exclusion must win so a transfer's from-account never
    // reappears as a counterpart option.
    let a = bank("A", position: 0)
    let accounts = Accounts(from: [a])

    let groups = accounts.sidebarGrouped(excluding: a.id, alwaysInclude: a.id)

    #expect(groups.current.isEmpty)
  }

  @Test("sidebarOrdered concatenates current then investment")
  func flatOrder() {
    let chequing = bank("Chequing", position: 0)
    let brokerage = investment("Brokerage", position: 0)
    let accounts = Accounts(from: [brokerage, chequing])

    #expect(accounts.sidebarOrdered().map(\.name) == ["Chequing", "Brokerage"])
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `just test-mac AccountsSidebarOrderingTests 2>&1 | tee .agent-tmp/sidebar-ordering-tests.txt | tail -20`
Expected: compile errors — `sidebarGrouped` / `sidebarOrdered` undefined.

- [ ] **Step 3: Add the implementation**

Create `Domain/Models/Accounts+SidebarOrdering.swift`:

```swift
import Foundation

extension Accounts {
  struct SidebarGroups: Equatable {
    var current: [Account]
    var investment: [Account]
  }

  /// Accounts grouped and sorted the way the sidebar shows them.
  ///
  /// - Parameters:
  ///   - excluding: Account id to drop entirely. Used by the transfer
  ///     counterpart picker to remove the from-account from the
  ///     candidate list.
  ///   - alwaysInclude: Account id to keep visible even when hidden.
  ///     Used by pickers so a previously-selected account that has
  ///     since been hidden stays in the dropdown.
  /// - Returns: Two arrays — `current` (bank, asset, credit card) and
  ///   `investment` — each sorted ascending by `Account.position`.
  /// - Note: When `excluding` and `alwaysInclude` reference the same
  ///   id, exclusion wins.
  func sidebarGrouped(
    excluding: UUID? = nil,
    alwaysInclude: UUID? = nil
  ) -> SidebarGroups {
    let visible = ordered.filter { account in
      if account.id == excluding { return false }
      if account.isHidden && account.id != alwaysInclude { return false }
      return true
    }
    let sorted = visible.sorted { $0.position < $1.position }
    var current: [Account] = []
    var investment: [Account] = []
    for account in sorted {
      if account.type.isCurrent {
        current.append(account)
      } else {
        investment.append(account)
      }
    }
    return SidebarGroups(current: current, investment: investment)
  }

  /// Flat sidebar-ordered list (current first, then investment) with
  /// the same hidden / exclusion rules as ``sidebarGrouped(excluding:alwaysInclude:)``.
  func sidebarOrdered(
    excluding: UUID? = nil,
    alwaysInclude: UUID? = nil
  ) -> [Account] {
    let groups = sidebarGrouped(excluding: excluding, alwaysInclude: alwaysInclude)
    return groups.current + groups.investment
  }
}
```

- [ ] **Step 4: Register the source file in `project.yml` if needed**

Same check as Task 1 step 3. If file globs cover `Domain/Models/`, no edit needed.

- [ ] **Step 5: Regenerate, run tests**

```bash
just generate
just test-mac AccountsSidebarOrderingTests 2>&1 | tee .agent-tmp/sidebar-ordering-tests.txt | tail -30
```
Expected: all 8 tests pass.

- [ ] **Step 6: Format and commit**

```bash
just format
git -C .worktrees/account-picker-sidebar-parity add \
  Domain/Models/Accounts+SidebarOrdering.swift \
  MoolahTests/Domain/AccountsSidebarOrderingTests.swift \
  project.yml
git -C .worktrees/account-picker-sidebar-parity commit -m "feat(accounts): add sidebarGrouped/sidebarOrdered helpers

Pure functions on the Accounts domain collection that return accounts
grouped (current vs investment) or flat in the same order as the
sidebar. Hidden accounts filtered by default; alwaysInclude retains a
hidden account when it is the picker's current selection. Used by
upcoming changes to the transaction detail account pickers and the
type-switch smart default."
```

- [ ] **Step 7: Cleanup**

```bash
rm .agent-tmp/sidebar-ordering-tests.txt
```

---

### Task 3: `AccountPickerOptions` view + `#Preview`

**Files:**
- Create: `Features/Accounts/Views/AccountPickerOptions.swift`
- Modify: `project.yml` (register if needed)

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// Picker content for selecting an account. Drop into any `Picker`
/// content closure to render the sidebar's grouping and icon set.
///
/// ```swift
/// Picker("Account", selection: $accountId) {
///   Text("None").tag(UUID?.none)
///   AccountPickerOptions(
///     accounts: accounts,
///     exclude: nil,
///     currentSelection: accountId
///   )
/// }
/// ```
///
/// Sentinel rows like `Text("None").tag(UUID?.none)` stay at the call
/// site so each picker can label its empty state appropriately
/// ("None", "Select…", etc.).
struct AccountPickerOptions: View {
  let accounts: Accounts
  let exclude: UUID?
  let currentSelection: UUID?

  var body: some View {
    let groups = accounts.sidebarGrouped(
      excluding: exclude,
      alwaysInclude: currentSelection
    )
    if !groups.current.isEmpty {
      Section("Current Accounts") {
        ForEach(groups.current) { account in
          Label(account.name, systemImage: account.sidebarIcon)
            .tag(UUID?.some(account.id))
        }
      }
    }
    if !groups.investment.isEmpty {
      Section("Investments") {
        ForEach(groups.investment) { account in
          Label(account.name, systemImage: account.sidebarIcon)
            .tag(UUID?.some(account.id))
        }
      }
    }
  }
}

#Preview("Account picker — both groups") {
  @Previewable @State var selection: UUID? = nil
  let chequing = Account(
    id: UUID(), name: "Chequing", type: .bank, instrument: .AUD,
    positions: [], position: 0, isHidden: false)
  let card = Account(
    id: UUID(), name: "Card", type: .creditCard, instrument: .AUD,
    positions: [], position: 1, isHidden: false)
  let brokerage = Account(
    id: UUID(), name: "Brokerage", type: .investment, instrument: .AUD,
    positions: [], position: 0, isHidden: false)
  let accounts = Accounts(from: [chequing, card, brokerage])

  return Form {
    Picker("Account", selection: $selection) {
      Text("None").tag(UUID?.none)
      AccountPickerOptions(
        accounts: accounts,
        exclude: nil,
        currentSelection: selection
      )
    }
  }
}
```

- [ ] **Step 2: Register in `project.yml` if needed; regenerate**

```bash
just generate
```

- [ ] **Step 3: Build to confirm it compiles**

```bash
just build-mac 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Format and commit**

```bash
just format
git -C .worktrees/account-picker-sidebar-parity add \
  Features/Accounts/Views/AccountPickerOptions.swift \
  project.yml
git -C .worktrees/account-picker-sidebar-parity commit -m "feat(accounts): AccountPickerOptions view

Shared Picker content that emits sidebar-grouped Sections with the
type-based icon and Account.id tag. Empty sections are omitted.
Sentinel rows (None / Select...) stay at the call site so each picker
can label its empty state."
```

---

### Task 4: Migrate `TransactionDetailAccountSection`

**Files:**
- Modify: `Features/Transactions/Views/Detail/TransactionDetailAccountSection.swift`

- [ ] **Step 1: Replace the file content**

```swift
import SwiftUI

/// Account picker for the relevant leg, plus — when the draft is a
/// transfer — the counterpart-account picker. When the resulting transfer
/// is cross-currency the section also embeds
/// `TransactionDetailCrossCurrencyRow` for the counterpart amount and the
/// derived exchange-rate caption.
struct TransactionDetailAccountSection: View {
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  let relevantInstrument: Instrument?
  let counterpartInstrument: Instrument?
  let counterpartAmountBinding: Binding<String>
  let isCrossCurrency: Bool
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  var body: some View {
    Section {
      Picker("Account", selection: $draft.legDrafts[draft.relevantLegIndex].accountId) {
        Text("None").tag(UUID?.none)
        AccountPickerOptions(
          accounts: accounts,
          exclude: nil,
          currentSelection: draft.legDrafts[draft.relevantLegIndex].accountId
        )
      }
      // Snap the relevant leg's instrument to the newly chosen account's
      // instrument so the inline picker on the Amount row tracks the
      // account. Mirrors the multi-leg row in `TransactionDetailLegRow`.
      .onChange(of: draft.legDrafts[draft.relevantLegIndex].accountId) { _, newAccountId in
        if let newAccountId, let account = accounts.by(id: newAccountId) {
          draft.legDrafts[draft.relevantLegIndex].instrument = account.instrument
        }
      }

      if draft.type == .transfer {
        transferRows
      }
    }
  }

  @ViewBuilder private var transferRows: some View {
    let counterpartIndex = draft.relevantLegIndex == 0 ? 1 : 0
    let toAccountLabel = draft.showFromAccount ? "From Account" : "To Account"
    let currentAccountId = draft.legDrafts[draft.relevantLegIndex].accountId
    let counterpartId = draft.legDrafts[counterpartIndex].accountId

    Picker(toAccountLabel, selection: $draft.legDrafts[counterpartIndex].accountId) {
      Text("Select...").tag(UUID?.none)
      AccountPickerOptions(
        accounts: accounts,
        exclude: currentAccountId,
        currentSelection: counterpartId
      )
    }
    .accessibilityIdentifier(UITestIdentifiers.Detail.toAccountPicker)
    .onChange(of: draft.legDrafts[counterpartIndex].accountId) { _, newAccountId in
      // Snap the counterpart leg's instrument to the new account before
      // mirroring amounts — the cross-currency picker reads the leg's
      // instrument first.
      if let newAccountId, let account = accounts.by(id: newAccountId) {
        draft.legDrafts[counterpartIndex].instrument = account.instrument
      }
      draft.snapToSameCurrencyIfNeeded(accounts: accounts)
    }

    if isCrossCurrency {
      TransactionDetailCrossCurrencyRow(
        draft: $draft,
        relevantInstrument: relevantInstrument,
        counterpartInstrument: counterpartInstrument,
        counterpartAmountBinding: counterpartAmountBinding,
        focusedField: $focusedField
      )
    }
  }
}
```

Note: the `sortedAccounts` parameter is gone, and so is the
`eligibleTransferAccounts` helper — `AccountPickerOptions` does both
(grouping and hidden-filter, with `exclude` for the from-account).

- [ ] **Step 2: Update the call site in `TransactionDetailView.swift`**

Locate the call around line 265:

```swift
TransactionDetailAccountSection(
  draft: $draft,
  accounts: accounts,
  sortedAccounts: sortedAccounts,
  ...
)
```

Remove the `sortedAccounts: sortedAccounts,` line. The `accounts: accounts` argument stays.

- [ ] **Step 3: Build (will still succeed because `sortedAccounts` is still used elsewhere)**

```bash
just build-mac 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Format and commit**

```bash
just format
git -C .worktrees/account-picker-sidebar-parity add \
  Features/Transactions/Views/Detail/TransactionDetailAccountSection.swift \
  Features/Transactions/Views/TransactionDetailView.swift
git -C .worktrees/account-picker-sidebar-parity commit -m "feat(transactions): icon + grouping in TransactionDetailAccountSection

Both the primary and the transfer-counterpart account pickers now use
AccountPickerOptions. The eligibleTransferAccounts helper is dropped
— exclusion and hidden-filter now happen inside the shared view."
```

---

### Task 5: Migrate `TransactionDetailTradeSection`

**Files:**
- Modify: `Features/Transactions/Views/Detail/TransactionDetailTradeSection.swift`

- [ ] **Step 1: Drop the `sortedAccounts` field and rewrite the picker**

Change the type's stored properties from:

```swift
let accounts: Accounts
let sortedAccounts: [Account]
```

to:

```swift
let accounts: Accounts
```

Replace the `accountPicker` property body's `ForEach(sortedAccounts) { ... }` with `AccountPickerOptions`:

```swift
private var accountPicker: some View {
  Picker("Account", selection: accountBinding) {
    Text("None").tag(UUID?.none)
    AccountPickerOptions(
      accounts: accounts,
      exclude: nil,
      currentSelection: accountBinding.wrappedValue
    )
  }
  .accessibilityIdentifier(UITestIdentifiers.Detail.tradeAccount)
}
```

- [ ] **Step 2: Update the call site in `TransactionDetailView.swift`**

Around line 210:

```swift
TransactionDetailTradeSection(
  draft: $draft,
  accounts: accounts,
  sortedAccounts: sortedAccounts,
  ...
)
```

Remove the `sortedAccounts: sortedAccounts,` line.

- [ ] **Step 3: Build, format, commit**

```bash
just build-mac 2>&1 | tail -5
just format
git -C .worktrees/account-picker-sidebar-parity add \
  Features/Transactions/Views/Detail/TransactionDetailTradeSection.swift \
  Features/Transactions/Views/TransactionDetailView.swift
git -C .worktrees/account-picker-sidebar-parity commit -m "feat(transactions): icon + grouping in trade-section account picker"
```

---

### Task 6: Migrate `TransactionDetailLegRow`

**Files:**
- Modify: `Features/Transactions/Views/Detail/TransactionDetailLegRow.swift`

- [ ] **Step 1: Drop `sortedAccounts` field and rewrite the picker**

Remove the `let sortedAccounts: [Account]` field. Replace the `accountPicker` body with:

```swift
private var accountPicker: some View {
  Picker("Account", selection: $draft.legDrafts[index].accountId) {
    Text("None").tag(UUID?.none)
    AccountPickerOptions(
      accounts: accounts,
      exclude: nil,
      currentSelection: draft.legDrafts[index].accountId
    )
  }
  .onChange(of: draft.legDrafts[index].accountId) { _, newAccountId in
    draft.enforceEarmarkOnlyInvariants(at: index)
    if let newAccountId, let account = accounts.by(id: newAccountId) {
      draft.legDrafts[index].instrument = account.instrument
    } else if let emId = draft.legDrafts[index].earmarkId,
      let earmark = earmarks.by(id: emId)
    {
      draft.legDrafts[index].instrument = earmark.instrument
    }
  }
}
```

- [ ] **Step 2: Update the call site in `TransactionDetailView.swift`**

Around line 297:

```swift
TransactionDetailLegRow(
  ...
  accounts: accounts,
  ...
  sortedAccounts: sortedAccounts,
  ...
)
```

Remove the `sortedAccounts: sortedAccounts,` line.

- [ ] **Step 3: Build, format, commit**

```bash
just build-mac 2>&1 | tail -5
just format
git -C .worktrees/account-picker-sidebar-parity add \
  Features/Transactions/Views/Detail/TransactionDetailLegRow.swift \
  Features/Transactions/Views/TransactionDetailView.swift
git -C .worktrees/account-picker-sidebar-parity commit -m "feat(transactions): icon + grouping in leg-row account picker"
```

---

### Task 7: Migrate `TransactionDetailAddLegSection`

The "Add Sub-transaction" button computes its default account via
`sortedAccounts.first`. Switch to `accounts.sidebarOrdered().first` so
the default mirrors the sidebar's first-visible account.

**Files:**
- Modify: `Features/Transactions/Views/Detail/TransactionDetailAddLegSection.swift`

- [ ] **Step 1: Rewrite**

```swift
import SwiftUI

/// "Add Sub-transaction" section in custom-mode editing. The new leg
/// inherits its default account and instrument from the first
/// sidebar-ordered account so the user has a sensible starting point
/// to edit from.
struct TransactionDetailAddLegSection: View {
  @Binding var draft: TransactionDraft
  let accounts: Accounts

  var body: some View {
    Section {
      Button("Add Sub-transaction") {
        let defaultAccount = accounts.sidebarOrdered().first
        draft.addLeg(
          defaultAccountId: defaultAccount?.id,
          instrument: defaultAccount?.instrument
        )
      }
      .accessibilityLabel("Add Sub-transaction")
    }
  }
}
```

- [ ] **Step 2: Update the call site in `TransactionDetailView.swift`**

Around line 310:

```swift
TransactionDetailAddLegSection(draft: $draft, sortedAccounts: sortedAccounts)
```

becomes:

```swift
TransactionDetailAddLegSection(draft: $draft, accounts: accounts)
```

- [ ] **Step 3: Build, format, commit**

```bash
just build-mac 2>&1 | tail -5
just format
git -C .worktrees/account-picker-sidebar-parity add \
  Features/Transactions/Views/Detail/TransactionDetailAddLegSection.swift \
  Features/Transactions/Views/TransactionDetailView.swift
git -C .worktrees/account-picker-sidebar-parity commit -m "feat(transactions): use sidebar order for Add Sub-transaction default"
```

---

### Task 8: Delete the now-unused `sortedAccounts` helper

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView+Helpers.swift` (delete the `sortedAccounts` property at lines 6-13)
- Modify: `Features/Transactions/Views/TransactionDetailView.swift` (the `// Computed helpers (sortedAccounts, …` comment at line 348 — drop the `sortedAccounts` mention)

- [ ] **Step 1: Delete the property**

In `TransactionDetailView+Helpers.swift`, remove lines 6-13:

```swift
  var sortedAccounts: [Account] {
    accounts.ordered.sorted { lhs, rhs in
      if lhs.type.isCurrent != rhs.type.isCurrent {
        return lhs.type.isCurrent
      }
      return lhs.position < rhs.position
    }
  }
```

- [ ] **Step 2: Update the comment**

In `TransactionDetailView.swift` line 348, change:

```swift
// Computed helpers (sortedAccounts, isEditable, isSimpleEarmarkOnly, instruments,
```

to drop `sortedAccounts,` from the list.

- [ ] **Step 3: Build to verify nothing references it any more**

```bash
just build-mac 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`. If any reference remains, fix the call site.

- [ ] **Step 4: Format and commit**

```bash
just format
git -C .worktrees/account-picker-sidebar-parity add \
  Features/Transactions/Views/TransactionDetailView+Helpers.swift \
  Features/Transactions/Views/TransactionDetailView.swift
git -C .worktrees/account-picker-sidebar-parity commit -m "refactor(transactions): drop the sortedAccounts helper

Superseded by Accounts.sidebarGrouped/sidebarOrdered, which are now
used directly by every account picker and the type-switch smart default."
```

---

### Task 9: Fix smart-default in `TransactionDraft.setType` (TDD)

**Files:**
- Create: `MoolahTests/Shared/TransactionDraftSetTypeDefaultAccountTests.swift`
- Modify: `Shared/Models/TransactionDraft+SimpleMode.swift` (line 176 only)

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft.setType counterpart-account default")
struct TransactionDraftSetTypeDefaultAccountTests {
  private let aud = Instrument.AUD

  private func acct(
    name: String, position: Int, type: AccountType = .bank, isHidden: Bool = false
  ) -> Account {
    Account(
      id: UUID(), name: name, type: type, instrument: aud,
      positions: [], position: position, isHidden: isHidden)
  }

  @Test("Switching to .transfer picks first sidebar-ordered non-from account")
  func picksSidebarFirstNonFromAccount() throws {
    // Insertion order is unsorted; sidebar order is by `position`.
    let chequing = acct(name: "Chequing", position: 0)
    let savings = acct(name: "Savings", position: 1)
    let brokerage = acct(name: "Brokerage", position: 0, type: .investment)
    let accounts = Accounts(from: [brokerage, savings, chequing])

    var draft = TransactionDraft(accountId: chequing.id, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: chequing.id, amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]

    draft.setType(.transfer, accounts: accounts)

    let counterpart = try #require(draft.counterpartLeg)
    #expect(counterpart.accountId == savings.id)
  }

  @Test("From-account being first sidebar account: default falls to second")
  func fromAccountIsFirstSidebarAccount() throws {
    let chequing = acct(name: "Chequing", position: 0)
    let savings = acct(name: "Savings", position: 1)
    let accounts = Accounts(from: [chequing, savings])

    var draft = TransactionDraft(accountId: chequing.id, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: chequing.id, amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]

    draft.setType(.transfer, accounts: accounts)

    let counterpart = try #require(draft.counterpartLeg)
    #expect(counterpart.accountId == savings.id)
  }

  @Test("Hidden accounts are never picked as the default counterpart")
  func skipsHiddenAccounts() throws {
    let chequing = acct(name: "Chequing", position: 0)
    let hiddenSavings = acct(name: "Old Savings", position: 1, isHidden: true)
    let visibleSavings = acct(name: "Savings", position: 2)
    let accounts = Accounts(from: [chequing, hiddenSavings, visibleSavings])

    var draft = TransactionDraft(accountId: chequing.id, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: chequing.id, amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]

    draft.setType(.transfer, accounts: accounts)

    let counterpart = try #require(draft.counterpartLeg)
    #expect(counterpart.accountId == visibleSavings.id)
  }
}
```

- [ ] **Step 2: Run; expect first test to fail**

```bash
just test-mac TransactionDraftSetTypeDefaultAccountTests 2>&1 | tee .agent-tmp/setType-tests.txt | tail -40
```

Expected: `picksSidebarFirstNonFromAccount` fails — current behaviour picks `brokerage` (first by insertion). The hidden-skipping test may also fail.

- [ ] **Step 3: Fix `setType`**

In `Shared/Models/TransactionDraft+SimpleMode.swift`, line 176:

```swift
let defaultAccount = accounts.ordered.first { $0.id != currentAccountId }
```

Replace with:

```swift
let defaultAccount = accounts.sidebarOrdered(excluding: currentAccountId).first
```

`alwaysInclude:` is deliberately omitted (defaults to `nil`): we are
choosing a *new* default and must never auto-pick a hidden account.

- [ ] **Step 4: Re-run tests**

```bash
just test-mac TransactionDraftSetTypeDefaultAccountTests 2>&1 | tee .agent-tmp/setType-tests.txt | tail -10
```

Expected: all 3 tests pass.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C .worktrees/account-picker-sidebar-parity add \
  Shared/Models/TransactionDraft+SimpleMode.swift \
  MoolahTests/Shared/TransactionDraftSetTypeDefaultAccountTests.swift \
  project.yml
git -C .worktrees/account-picker-sidebar-parity commit -m "fix(transactions): smart-default counterpart honours sidebar order

setType used accounts.ordered (insertion order) to pick the default
counterpart account. That meant switching to Transfer often pre-filled
an Investment account ahead of a Current account purely because of the
order accounts were created. Use Accounts.sidebarOrdered(excluding:)
instead, which matches the picker order and skips hidden accounts."
```

- [ ] **Step 6: Cleanup**

```bash
rm .agent-tmp/setType-tests.txt
```

---

### Task 10: Fix smart-default in `TransactionDraft+TradeMode.applyTransferLegs`

The `Trade → Transfer` reverse-switch path uses the same broken pattern.
Apply the same fix.

**Files:**
- Modify: `Shared/Models/TransactionDraft+TradeMode.swift` (line 189)

- [ ] **Step 1: Look at the existing `TransactionDraftReverseSwitchTests.swift` (if present)**

```bash
ls /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-picker-sidebar-parity/MoolahTests/Shared/TransactionDraftReverseSwitchTests.swift && \
grep -n 'applyTransferLegs\|switch.*[Tt]ransfer\|toTransfer' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/account-picker-sidebar-parity/MoolahTests/Shared/TransactionDraftReverseSwitchTests.swift
```

If a test for `Trade → Transfer` exists there, add the regression case to that suite (same pattern as Task 9 step 1: insertion-order Investment-first vs Current-second; assert counterpart resolves to the Current account). If no such test exists, add a new `@Test` to the existing file under a clear name like `tradeToTransferPicksSidebarFirstNonPaidAccount`.

- [ ] **Step 2: Write the failing test**

```swift
@Test("Trade → Transfer: counterpart picks first sidebar-ordered non-paid account")
func tradeToTransferPicksSidebarFirstNonPaidAccount() throws {
  let aud = Instrument.AUD
  let brokerage = Account(
    id: UUID(), name: "Brokerage", type: .investment, instrument: aud,
    positions: [], position: 0, isHidden: false)
  let chequing = Account(
    id: UUID(), name: "Chequing", type: .bank, instrument: aud,
    positions: [], position: 0, isHidden: false)
  let accounts = Accounts(from: [brokerage, chequing])
  // Construct a trade-shaped draft on the brokerage account, then
  // reverse-switch to .transfer. The counterpart should be Chequing
  // (sidebar order), not the next ordered() account.
  // ... build draft according to the existing test patterns in the file ...
}
```

Use the surrounding tests in `TransactionDraftReverseSwitchTests.swift` for the exact draft-construction idiom — every test in this suite shows it.

- [ ] **Step 3: Run; expect failure**

```bash
just test-mac TransactionDraftReverseSwitchTests 2>&1 | tee .agent-tmp/reverse-switch-tests.txt | tail -40
```

- [ ] **Step 4: Fix `applyTransferLegs`**

In `Shared/Models/TransactionDraft+TradeMode.swift` line 189:

```swift
let other = accounts.ordered.first { $0.id != paidLeg.accountId }
```

Replace with:

```swift
let other = accounts.sidebarOrdered(excluding: paidLeg.accountId).first
```

- [ ] **Step 5: Re-run, format, commit**

```bash
just test-mac TransactionDraftReverseSwitchTests 2>&1 | tee .agent-tmp/reverse-switch-tests.txt | tail -10
just format
git -C .worktrees/account-picker-sidebar-parity add \
  Shared/Models/TransactionDraft+TradeMode.swift \
  MoolahTests/Shared/TransactionDraftReverseSwitchTests.swift
git -C .worktrees/account-picker-sidebar-parity commit -m "fix(transactions): trade→transfer counterpart honours sidebar order

Same fix as the simple-mode setType path: applyTransferLegs picked the
first accounts.ordered (insertion order) account that wasn't the paid
leg's account. Use sidebarOrdered(excluding:) instead so the
counterpart matches what the picker would offer first."
rm .agent-tmp/reverse-switch-tests.txt
```

---

### Task 11: Final sweep — full test run + format-check

- [ ] **Step 1: Format**

```bash
just format
```

- [ ] **Step 2: Format-check (must be clean)**

```bash
just format-check 2>&1 | tail -20
```

Expected: exit 0, no diffs.

- [ ] **Step 3: Full test run on macOS**

```bash
mkdir -p .agent-tmp
just test-mac 2>&1 | tee .agent-tmp/full-test-mac.txt | tail -30
grep -iE 'failed|error:' .agent-tmp/full-test-mac.txt | head
```

Expected: zero failures. If anything fails, fix root cause and re-run.

- [ ] **Step 4: Full test run on iOS**

```bash
just test-ios 2>&1 | tee .agent-tmp/full-test-ios.txt | tail -30
grep -iE 'failed|error:' .agent-tmp/full-test-ios.txt | head
```

Expected: zero failures.

- [ ] **Step 5: Cleanup**

```bash
rm .agent-tmp/full-test-mac.txt .agent-tmp/full-test-ios.txt
```

- [ ] **Step 6: Visual sanity check via Xcode preview**

Open `AccountPickerOptions.swift` in Xcode, expand the `#Preview`. Verify:
- "Current Accounts" section contains Chequing and Card (with bank / credit-card icons).
- "Investments" section contains Brokerage (with trending-line icon).
- Native section divider sits between the two groups.
- Selecting an item updates the preview's `selection` state.

If a render artefact is wrong, fix it before moving on.

---

## Plan Self-Review

- **Spec coverage**:
  - §1 helper → Task 2 ✓
  - §2 view → Task 3 ✓
  - §3 icon move → Task 1 ✓
  - §4 migration of three call sites → Tasks 4, 5, 6 ✓ (plus Task 7 for the fourth one discovered during exploration)
  - §5 smart-default fix → Tasks 9 + 10 (two sites: simple-mode setType and trade-mode applyTransferLegs)
  - §6 hidden rule → Task 2 tests (alwaysIncludeRetainsHidden, hiddenFiltered, excludingWinsOverAlwaysInclude); Task 9 test (skipsHiddenAccounts)
  - Acceptance #1-#5 → Tasks 1-10
  - Acceptance #6 (clean reviewers, format, tests) → Task 11 + the post-implementation reviewer pass that follows this plan
- **Placeholder scan**: no TBDs; every step shows the actual code. Task 10 step 2 leaves the test-body details to the executing agent only because the file's existing test patterns are non-trivial to inline accurately — the instruction explicitly tells the agent to copy the surrounding pattern.
- **Type consistency**: `sidebarGrouped` returns `SidebarGroups { current, investment }` in Task 2 and is consumed identically in Task 3 (`groups.current`, `groups.investment`). `sidebarOrdered` is consumed in Tasks 7, 9, 10 with the same signature.
- **Hidden interaction with `excluding`**: Task 2 test `excludingWinsOverAlwaysInclude` pins the contract; Task 3 view uses both params consistently.
