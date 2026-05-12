# Observation Region Trim — Exclude `encoded_system_fields` from Tracked Regions

**Issue:** [#865](https://github.com/ajsutton/moolah-native/issues/865)
**Companion:** [#864](https://github.com/ajsutton/moolah-native/pull/864) (per-recordType batching of system-fields writes)

## Problem

`ValueObservation.tracking { db in … }` in every GRDB `+Observation.swift` uses
GRDB's auto-region inference. The inference includes **every column on every
table fetched** — including `encoded_system_fields`, which is pure
CKSyncEngine bookkeeping that no UI consumer reads.

After CKSyncEngine reports a successful 400-record send, the
`ProfileDataSyncHandler` writes the new `encoded_system_fields` blob back
onto each saved row. Even with the #864 batching follow-up collapsing 400
per-row writes into ~9 (one per recordType), each commit still fires every
`ValueObservation` whose tracked region intersects the affected table. A
sample(1) profile of a ~8000-record upload showed the main thread dominated
by GRDB observer re-fetches re-firing on every sync-fields write.

## Goal

Switch the affected observation closures to a tracked region that **excludes
`encoded_system_fields`**, so a sync-fields write commits without re-firing
any UI observer. Sync uploads become invisible to the UI thread.

## Approach

GRDB's `ValueObservation.tracking(regions:fetch:)` decouples the **tracked
region** from the **fetched projection**:

- `regions:` — what we observe. Each element is `DatabaseRegionConvertible`.
  Passing a column-restricted `QueryInterfaceRequest`
  (`AccountRow.select(AccountRow.observableColumns)`) produces a region
  scoped to the named columns only.
- `fetch:` — what we read on each fire. Unchanged: same projection as today.

This is the same shape used by `RateCacheTickStream` (which passes
`[Table("exchange_rate"), …]`); we just take it further by passing
column-restricted requests instead of whole tables.

### Per-row `observableRegion`

For each `*Row` type whose table has an `encoded_system_fields` column,
add a column-restricted request in a sibling `+ObservableRegion.swift`
file (one extension per Row, to satisfy SwiftLint's `file_name` rule):

```swift
extension AccountRow {
  /// Column-restricted region UI `ValueObservation`s pass to
  /// `tracking(regions:fetch:)`. Excludes `encoded_system_fields` so
  /// the per-batch sync-bookkeeping write CKSyncEngine performs after
  /// a successful send does not re-fire UI observers. See issue #865.
  static var observableRegion: QueryInterfaceRequest<AccountRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}
```

`Columns: CaseIterable` already; this is the same boilerplate per Row.

### Observation closures

Each affected `+Observation.swift` swaps:

```swift
ValueObservation.tracking { db in … }
```

for:

```swift
ValueObservation.tracking(
  regions: [
    AccountRow.observableRegion,
    InstrumentRow.observableRegion,
    // … one entry per table read by the fetch closure
  ],
  fetch: { db in
    // unchanged
  }
)
```

`fetch:` continues to decode full rows; only the **observed** region is
trimmed.

## Scope — Affected Files

Every `+Observation.swift` whose tracking closure reads at least one table
with an `encoded_system_fields` column:

| Repository | Tables observed |
|---|---|
| `GRDBTransactionRepository+Observation.swift` | `transaction`, `transaction_leg`, `instrument`, `account` |
| `GRDBAccountRepository+Observation.swift` | `account`, `instrument`, `transaction_leg`, `transaction` |
| `GRDBEarmarkRepository+Observation.swift` (`observeAll`, `observeBudget`) | `earmark`, `earmark_budget_item`, `instrument`, `transaction_leg`, `transaction` |
| `GRDBCategoryRepository+Observation.swift` | `category` |
| `GRDBInvestmentRepository+Observation.swift` (`observeValues`, `observeDailyBalances`) | `investment_value`, `transaction`, `transaction_leg`, `instrument` |
| `GRDBCSVImportProfileRepository+Observation.swift` | `csv_import_profile` |
| `GRDBImportRuleRepository+Observation.swift` | `import_rule` |

`GRDBInvestmentRepository.observeAllValues` already uses the explicit-region
form with `[Table("investment_value")]`; we narrow it to
`investment_value.select(observableColumns)` for the same reason.

### Out of scope

- `GRDBInstrumentRegistryRepository.observeChanges` — manual subscriber
  pattern, not `ValueObservation`. Already unaffected.
- The issue's scope list mentions `GRDBTransactionLegRepository` and
  `GRDBEarmarkBudgetItemRepository`, but neither has an observation method;
  the `transaction_leg` and `earmark_budget_item` tables are observed
  transitively through `GRDBTransactionRepository` and
  `GRDBEarmarkRepository.observeBudget`. Both are covered.

## Tests

For each affected repo, add two test cases to the existing
`*RepoObservationContractTests` suite (under `MoolahTests/Domain/`):

1. **`encodedSystemFieldsWriteDoesNotEmit`** — subscribe to `observeAll(…)`,
   call `setEncodedSystemFieldsSync(id:data:)` on an existing row, expect no
   re-emission within the standard 200 ms poll window. Uses the same
   `LockedBox<Bool>` + cancellable poll-task pattern as the existing
   `noOpUpdateDoesNotReEmit` test (`removeDuplicates()` is in play, but
   the cleaner positive assertion is "the observation never fires at all"
   because the tracked region itself excludes the column).
2. **`nonBookkeepingColumnEmits`** — same setup, mutate a real domain
   column (e.g. `update(…)` with a changed `name` / `amount`), expect one
   emission. Confirms the region trim hasn't accidentally muted real
   writes.

The transaction suite covers both `observe(filter:page:pageSize:)` and
`observeAll(filter:)` because the column set is identical.

## Risks & Mitigations

- **Forgotten column.** If a new column is added to `AccountRow` etc. and
  the writer of `observableColumns` doesn't notice, the new column won't
  be tracked. Mitigation: implement `observableColumns` as `Columns.allCases
  - { .encodedSystemFields }` rather than an explicit allowlist, so any
  new case auto-enrols. `CaseIterable` is already present on every
  affected row's `Columns` enum.
- **Empty-table caveat.** Doesn't apply: explicit regions are registered
  unconditionally, whether or not the table has rows. This is in fact
  cleaner than the current inferred form, which the existing comments
  acknowledge as "empty-table-safe because the row decoder touches columns".
- **`WITHOUT ROWID` caveat.** Doesn't apply: none of the listed tables are
  `WITHOUT ROWID` (only the rate-cache tables and `instrument` in the
  shared-registry index are; neither carries `encoded_system_fields` in the
  affected set).
- **Region union behaviour.** GRDB unions the tracked regions, so passing
  multiple column-restricted requests for the same table is well-defined
  — but no repo does that here.

## Acceptance

- After change, writing `encoded_system_fields` on any row in any of the 7
  tables produces **zero** UI re-emissions across all 7 observation
  surfaces.
- Writing any other column produces exactly one re-emission (modulo
  `removeDuplicates` for no-op writes).
- Sync upload of N records produces zero UI re-fetches in the consumer
  stores (`TransactionStore`, `AccountStore`, `EarmarkStore`, etc.).
- All existing observation contract tests still pass.
