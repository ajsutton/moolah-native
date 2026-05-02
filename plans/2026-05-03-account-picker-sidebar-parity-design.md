# Account Picker Sidebar Parity — Design

**Date:** 2026-05-03
**Status:** Approved (in conversation), proceeding to implementation plan
**Scope:** Make every account-selection `Picker` in the app render with the
same icon and ordering as the sidebar account list, and fix the
"smart-default counterpart" account chosen on transaction-type switch so it
honours that order.

## Motivation

Every account-selection dropdown in `TransactionDetailView` currently
renders only the account name. The sidebar already presents accounts as
icon + name + balance, grouped into Current Accounts and Investments and
sorted by user-defined `position`. The dropdowns are visually
disconnected from the sidebar and harder to scan, and the "first valid
account" default chosen on type-switch uses an unrelated unsorted order.

## Scope

**In scope**

- Add the type-based icon to every account-selection `Picker` row.
- Group dropdown rows into two `Section`s — "Current Accounts" and
  "Investments" — matching the sidebar layout, with native dividers
  between them.
- Sort within each group by `Account.position` (matching the sidebar).
- Hide the same accounts the sidebar hides (`hidden == true`), with one
  exception: if the picker's currently-selected account is hidden, keep
  it in the list so opening an old transaction doesn't silently lose its
  selection.
- Fix the smart-default counterpart account picked on transaction-type
  switch so it follows the same sidebar order.

**Out of scope**

- Account balance is **not** rendered inside picker rows. SwiftUI's
  `Picker` cannot reliably right-align a monospaced amount column inside
  a native `NSMenu` on macOS, and we want to keep the native picker
  control rather than build a custom popover.
- No change to the picker primitive (`Picker` stays). No new custom
  popover or Menu-based control.
- No change to which accounts each call site permits (e.g. transfer
  counterpart still excludes the from-account; trade legs continue to
  accept any account).
- Earmarks are not "accounts" and are not part of these dropdowns; no
  change to earmark UI.

## Affected Call Sites

Three pickers in `Features/Transactions/Views/Detail/`:

- `TransactionDetailAccountSection.swift` — primary account picker, plus
  the transfer-counterpart picker that appears when
  `draft.type == .transfer`.
- `TransactionDetailTradeSection.swift` — single shared trade-account
  picker.
- `TransactionDetailLegRow.swift` — per-leg picker in the multi-leg
  custom trade UI.

One smart-default site in `Domain/Models/`:

- `TransactionDraft+SimpleMode.swift` — `setType(_:accounts:)` chooses
  the counterpart account when the type changes to `.transfer`.

A grep during implementation will catch any other site I've missed (per
the "fix all instances" rule).

## Design

### 1. Domain: shared sidebar ordering on `Accounts`

Add two pure helpers to the `Accounts` collection in `Domain/Models/`.
They are the single source of truth for "sidebar-equivalent" account
ordering, used by both the picker view and the smart-default lookup.

```swift
extension Accounts {
    struct SidebarGroups: Equatable {
        var current: [Account]
        var investment: [Account]
    }

    /// Accounts grouped and sorted the same way the sidebar shows them.
    /// - Parameters:
    ///   - excluding: An account id to drop entirely (e.g. the from-account
    ///     when offering counterparts for a transfer).
    ///   - alwaysInclude: An account id that must remain visible even if
    ///     it is hidden (the picker's current selection).
    func sidebarGrouped(
        excluding: UUID? = nil,
        alwaysInclude: UUID? = nil
    ) -> SidebarGroups

    /// Flat sidebar-ordered list (current first, then investment),
    /// honouring the same hidden / exclusion rules as `sidebarGrouped`.
    func sidebarOrdered(
        excluding: UUID? = nil,
        alwaysInclude: UUID? = nil
    ) -> [Account]
}
```

Rules (identical for both):

1. Drop `account.id == excluding`.
2. Drop `account.hidden == true`, **unless** `account.id == alwaysInclude`.
3. Partition by `account.type.isCurrent`.
4. Within each partition, sort ascending by `account.position`.

Both helpers are pure functions on the domain collection. They have no
store, view, or backend dependencies.

### 2. UI: shared `AccountPickerOptions` view

A new SwiftUI view that emits the `Section` + row content for any
`Picker` that selects an account.

```swift
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
                        .tag(account.id as UUID?)
                }
            }
        }
        if !groups.investment.isEmpty {
            Section("Investments") {
                ForEach(groups.investment) { account in
                    Label(account.name, systemImage: account.sidebarIcon)
                        .tag(account.id as UUID?)
                }
            }
        }
    }
}
```

Call sites use it inside their existing `Picker`:

```swift
Picker("Account", selection: $accountId) {
    AccountPickerOptions(
        accounts: accounts,
        exclude: nil,
        currentSelection: accountId
    )
}
```

The transfer-counterpart picker passes `exclude: currentAccountId`. The
trade and leg pickers pass `exclude: nil`.

Empty sections are omitted so a profile with no investment accounts
doesn't show an empty "Investments" header.

#### Tag type

Existing call sites tag with `UUID?` (optional). The new view emits
`tag(account.id as UUID?)` to match. If a call site needs a non-optional
tag, either coerce at the call site or add a generic overload — decide
during implementation, do not pre-design for it.

### 3. Move `Account.sidebarIcon` to a shared file

Today `account.sidebarIcon` lives in
`Features/Accounts/Views/AccountSidebarRow.swift`. The picker now needs
the same mapping. Extract the extension to a new
`Features/Accounts/Views/Account+Icon.swift` so both consumers share one
definition. No change to the icon logic itself.

### 4. Migrate the three call sites

Replace the inline `ForEach(sortedAccounts) { Text($0.name).tag(...) }`
in each picker with `AccountPickerOptions(...)`.

- `TransactionDetailAccountSection`:
  - Primary picker: `exclude: nil`, `currentSelection: accountId`.
  - Transfer-counterpart picker: `exclude: fromAccountId`,
    `currentSelection: counterpartAccountId`.
- `TransactionDetailTradeSection`: `exclude: nil`, current selection is
  the shared trade-account id.
- `TransactionDetailLegRow`: `exclude: nil`, current selection is the
  leg's account id.

Delete the local `sortedAccounts` helper in
`TransactionDetailView+Helpers.swift` — it is superseded by the new
`AccountPickerOptions` (which derives ordering from `Accounts` directly).

### 5. Fix smart-default in `TransactionDraft.setType`

`TransactionDraft+SimpleMode.swift` currently does:

```swift
let defaultAccount = accounts.ordered.first { $0.id != currentAccountId }
```

`accounts.ordered` is creation order, not sidebar order, so the
"first valid" default is whichever account happened to be created
earliest. Replace with:

```swift
let defaultAccount = accounts.sidebarOrdered(
    excluding: currentAccountId,
    alwaysInclude: nil
).first
```

`alwaysInclude: nil` is correct here: we are choosing a *new* default,
not preserving an existing selection, so hidden accounts should never be
auto-picked.

Grep during implementation for any other `accounts.ordered.first` /
`accounts.ordered.first(where:)` usage that picks an account; apply the
same fix where appropriate. Do not blanket-rewrite unrelated uses of
`accounts.ordered`.

## Hidden Accounts — Behaviour Summary

| Context | Hidden accounts shown? |
| --- | --- |
| Picker dropdown list | No, except the currently-selected account |
| Smart-default counterpart on type-switch | No |
| Sidebar | No (unchanged) |

## Testing

### New unit tests

`MoolahTests/Domain/AccountsSidebarOrderingTests.swift`:

- `sidebarGrouped` partitions Current vs Investment correctly across all
  four account types (`bank`, `creditCard`, `asset` → current;
  `investment` → investment).
- Within each group, sort order follows `position` ascending.
- `excluding` removes that account from the result.
- `hidden` accounts are filtered out by default.
- `alwaysInclude` retains a hidden account in the result.
- `alwaysInclude` of a non-existent id is a no-op (does not crash).
- `excluding` an id that is also `alwaysInclude` — exclusion wins
  (defensive: avoid surfacing a transfer's own account just because it's
  the current selection on the counterpart picker). Document the choice.
- `sidebarOrdered` produces `current ++ investment` of the same groups.

### Extended existing tests

`MoolahTests/Domain/TransactionDraft*` (find the existing setType test
file during implementation):

- Add a regression case: a profile with accounts created in
  non-sidebar order across both groups, switching type to `.transfer`
  picks the first sidebar-ordered non-from account, not the first
  creation-order non-from account.
- Cover the case where the from-account is the first sidebar-ordered
  account: counterpart should fall to the second sidebar-ordered
  account.
- Cover hidden accounts: a hidden account is never picked as the
  default counterpart.

### View-level

No new view-level tests for the picker rendering itself. SwiftUI
`Picker` content rendering is covered visually in `#Preview` per the
project's iterate-via-preview convention.

If any existing snapshot or UI test asserts on picker row text, update
it to expect the new `Label` rendering (icon + name).

## Non-Goals / Explicit Trade-offs

- **No balance in picker rows.** Confirmed in design discussion. Picker
  rows render `Label(name, systemImage: icon)` only. Balance stays in
  the sidebar.
- **No custom popover / Menu replacement.** Native `Picker` stays,
  matching other form controls and the project preference for native
  controls (see "Keep stepper date picker on macOS" memory).
- **No change to filtering rules per call site.** Each call site keeps
  its existing eligibility rules (transfer excludes from-account; others
  permit all). This spec only changes presentation and ordering, not
  eligibility.

## Risks

- `Picker` rendering of `Label`s differs slightly between iOS and macOS.
  On macOS the `NSMenu` shows the icon at the leading edge of the menu
  item; on iOS the inline picker shows it next to the text. Both are
  acceptable. Verify visually on both platforms during implementation.
- Existing UI tests that match accessibility text on picker rows might
  need to expect the icon-bearing `Label`'s accessibility output.
  Discover during the test pass; update if needed.

## Acceptance Criteria

1. Every account picker in `TransactionDetail*` shows the type-based
   icon next to the account name.
2. Every account picker is grouped into "Current Accounts" and
   "Investments" sections in that order, with native dividers, and
   within each section accounts appear in `position` order.
3. Hidden accounts do not appear in the picker, except when the
   currently-selected account is hidden (in which case it remains
   visible).
4. Switching transaction type to `.transfer` (or any other type-switch
   that auto-picks a counterpart account) picks the first
   sidebar-ordered account that isn't the from-account, not the first
   creation-order account.
5. `account.sidebarIcon` is defined in exactly one place and used by
   both the sidebar and the new picker view.
6. `just format-check` clean. Full `just test` green on iOS and macOS.
   `code-review`, `ui-review`, and `concurrency-review` (if any
   concurrency surface is touched) all clean — including any
   pre-existing findings in touched files.
