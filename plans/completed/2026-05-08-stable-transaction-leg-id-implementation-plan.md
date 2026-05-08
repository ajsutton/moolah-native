# Stable `TransactionLeg.id` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Each stage is one commit.

**Goal:** Give `TransactionLeg` a stable `let id: UUID` that survives `update(_:)`, switch the GRDB repository's update flow to diff-by-id (delete legs no longer in the new array, upsert the rest in place), and propagate the id through `LegDraft`, the SwiftData mirror, and `paidCopy(of:)`. Closes the class of bugs where a dropped leg-delete uplink leaves orphan legs on the CloudKit server which propagate back as duplicates on later edits (production symptom: 5 scheduled transactions in the Large Test profile).

**Architecture:**
- `TransactionLeg.id: UUID` (`let`) becomes part of the domain model, defaulting to `UUID()` for fixture/import callers.
- `GRDBTransactionRepository.create(_:)` and `performUpdate(...)` use `leg.id` instead of generating a fresh `UUID()` per write.
- `update(_:)` switches from "delete every old leg, insert every new leg with fresh ids" to "delete legs whose id disappeared from the new array, upsert the rest by id".
- `Transaction.paidCopy(of:)` and `TransactionDraft.applyAutofill(...)` explicitly allocate fresh leg ids — those paths model "this is a *new* set of legs in a different transaction".
- `TransactionDraft.LegDraft` carries an optional `legId: UUID?` populated from existing transactions and `nil` for legs added in-draft (`addLeg`, transfer counterpart insertion, trade fee/blank legs).
- No schema change. `transaction_leg.id` already holds stable ids; the row→domain mapper simply stops discarding them.

**Tech Stack:** Swift 6, GRDB.swift, Swift Testing (`@Test` / `#expect`), `@MainActor`, `TestBackend.create()` for repository tests, `ProfileDatabase.openInMemory()` for header+legs unit tests.

**Spec:** [`plans/2026-05-08-stable-transaction-leg-id-design.md`](2026-05-08-stable-transaction-leg-id-design.md) (must be read first).

**Branch context:** Land the design spec and this plan together on `spec/stable-leg-id` as a single doc-only PR. The implementation itself ships on a separate `feat/stable-leg-id` branch via subagent-driven execution against this plan.

---

## File structure

### New files

| Path | Responsibility |
|---|---|
| `MoolahTests/Domain/TransactionLegIdentityTests.swift` | Domain-level identity tests: default `id` is unique per init, `paidCopy(of:)` allocates fresh ids, `Hashable` derives id-aware equality. |
| `MoolahTests/Backends/GRDB/GRDBTransactionRepositoryStableLegIdTests.swift` | Repository-level: round-trip preserves leg ids; reorder rewrites `sort_order` without changing ids; add/remove only touches the deltas; editing only the parent header (e.g. `payee`) leaves leg ids unchanged; header-only edit preserves `encodedSystemFields`; mid-write throw rolls back legs and header. |
| `MoolahTests/Shared/TransactionDraftLegIdTests.swift` | Draft-level: `init(from:)` populates `legId` from existing legs; `toTransaction(id:)` round-trips ids; `applyAutofill(...)` clears `legId` so a subsequent save does not collide with the autofill source's leg rows. |
| `MoolahTests/Sync/TransactionLegSyncSemanticTests.swift` | Sync ingestion: same-id leg upsert is idempotent (no duplicate); different-id orphan lands as a second row (documents residual race). |

### Modified files

| Path | Change |
|---|---|
| `Domain/Models/TransactionLeg.swift` | Add `let id: UUID` (default `UUID()`), conform to `Identifiable`, update memberwise init. |
| `Domain/Models/Transaction+Defaults.swift` | `paidCopy(of:)` maps each source leg to a copy with a fresh `UUID()` — paid copy is a new transaction with its own legs. |
| `Backends/CloudKit/Models/TransactionLegRecord.swift` | `from(_:transactionId:sortOrder:)` uses `leg.id` for the SwiftData record id; `toDomain(instrument:)` passes `id` through. |
| `Backends/GRDB/Records/TransactionLegRow+Mapping.swift` | `init(domain:transactionId:sortOrder:)` defaults `id` to `leg.id` (still allows an explicit override for the rare callsite that wants a fresh row id); `toDomain(instrument:)` passes `id` through. |
| `Backends/GRDB/Repositories/GRDBTransactionRepository.swift` | `create(_:)` uses `leg.id` instead of `UUID()`. `performUpdate(database:transaction:)` switches to diff-by-id: compute old/new id sets, delete legs whose id is missing from the new array, upsert the rest. Emit hooks for upserted / deleted ids only. |
| `Shared/Models/TransactionDraft.swift` | `LegDraft` gains `let legId: UUID?` (nil for legs added in-draft). Memberwise init takes a `legId:` argument with default `nil`. `init(from: Transaction, ...)` populates `legId` from each source leg's id. `toTransaction(id:)` resolves `legId ?? UUID()` per leg. `addLeg(...)` builds a `LegDraft(legId: nil, ...)`. |
| `Shared/Models/TransactionDraft+SimpleMode.swift` | Transfer counterpart insert in `setType(.transfer)` builds `LegDraft(legId: nil, ...)`. |
| `Shared/Models/TransactionDraft+TradeMode.swift` | `appendFee`, `tradeLeg(...)`, the `[blank, carried]` pair in `switchToTrade`, and the `switchFromTrade` pair build `LegDraft(legId: nil, ...)` for newly-constructed legs and preserve `legId` on legs they carry forward. |
| `Shared/Models/TransactionDraft+Autofill.swift` | After `var newDraft = TransactionDraft(from: match, ...)`, walk `newDraft.legDrafts.indices` and rewrite each `LegDraft` to `legId: nil`. Comment: "Autofill copies content from a different transaction; legs save into *this* transaction so they need new ids." |
| `MoolahTests/Sync/TransactionHookUpdateDeleteTests.swift` | Update `transactionUpdateEmitsLegRecordType` to reflect the new semantics: when the new `legs` array preserves leg ids, hook fan-out is `1 transaction change + N leg-changes (upserts) + 0 leg-deletes`. Add a sibling test `transactionUpdateWithReplacedLegsEmitsDeletes` that builds `legs` with fresh ids and asserts the legacy fan-out shape (delete + insert). |

### Deleted files

None.

---

## Reference patterns

### Reference R1: Diff-by-id update body

```swift
private static func performUpdate(
  database: Database,
  transaction: Transaction
) throws -> UpdateOutcome {
  guard
    var existing =
      try TransactionRow
      .filter(TransactionRow.Columns.id == transaction.id)
      .fetchOne(database)
  else {
    throw BackendError.notFound("Transaction not found")
  }
  applyMetadata(of: transaction, to: &existing)
  try existing.update(database)

  // Fetch the existing leg rows in full so we can preserve their
  // cached `encodedSystemFields` blob across the upsert. GRDB's
  // `upsert(_:)` is `INSERT … ON CONFLICT DO UPDATE SET …` — every
  // column in the new struct is written, including
  // `encodedSystemFields`, which the row factory hardcodes to `nil`.
  // Without preserving the blob, the next sync pass would see the leg
  // as unsynced (`unsyncedRowIdsSync` filters on
  // `encodedSystemFields IS NULL`) and re-upload it on every save.
  let existingRows =
    try TransactionLegRow
    .filter(TransactionLegRow.Columns.transactionId == transaction.id)
    .fetchAll(database)
  let oldLegIds: Set<UUID> = Set(existingRows.map(\.id))
  let existingFieldsByLegId: [UUID: Data?] = Dictionary(
    uniqueKeysWithValues: existingRows.map { ($0.id, $0.encodedSystemFields) })

  // New leg ids in the supplied transaction (may be a subset, superset,
  // or rearrangement of `oldLegIds`). Domain types now carry stable ids,
  // so `leg.id` is authoritative — no fresh allocation here.
  let newLegIds: Set<UUID> = Set(transaction.legs.map(\.id))

  // Legs the caller removed from the new array — must be deleted.
  let deletedLegIds = oldLegIds.subtracting(newLegIds)
  if !deletedLegIds.isEmpty {
    _ =
      try TransactionLegRow
      .filter(deletedLegIds.contains(TransactionLegRow.Columns.id))
      .deleteAll(database)
  }

  // Upsert every leg in the new array. Idempotent for unchanged rows;
  // updates `sort_order` for legs that moved; inserts new legs.
  // Order: deletions first so the (transaction_id, sort_order) pair is
  // never transiently duplicated by a moving leg landing on a soon-to-be-
  // deleted leg's slot. There is no UNIQUE(transaction_id, sort_order)
  // constraint so this is defensive rather than required, but it keeps
  // the intermediate state consistent for any future debugger snapshot.
  // **Preserve the comment verbatim in the implementation.** If a future
  // schema migration adds `UNIQUE(transaction_id, sort_order)`, this
  // ordering becomes load-bearing rather than defensive and the comment
  // must be updated.
  var upsertedLegIds: [UUID] = []
  upsertedLegIds.reserveCapacity(transaction.legs.count)
  for (index, leg) in transaction.legs.enumerated() {
    try Self.ensureInstrumentReadable(database: database, leg: leg)
    var legRow = TransactionLegRow(
      id: leg.id,
      domain: leg,
      transactionId: transaction.id,
      sortOrder: index)
    // Re-attach the cached CK system fields blob for legs that already
    // existed; new legs land with `nil` and the sync layer stamps them
    // after the first successful upload.
    if let existingFields = existingFieldsByLegId[leg.id] {
      legRow.encodedSystemFields = existingFields
    }
    try legRow.upsert(database)
    upsertedLegIds.append(leg.id)
  }

  return UpdateOutcome(
    deletedLegIds: Array(deletedLegIds),
    upsertedLegIds: upsertedLegIds)
}
```

`UpdateOutcome` is renamed to use `upsertedLegIds` (was `insertedLegIds`) to reflect the new semantics. Callers in `update(_:)` fan out `onRecordChanged(TransactionLegRow.recordType, legId)` for every entry in `upsertedLegIds`. The CK upload path is untouched — CK upserts are themselves idempotent, so re-emitting a leg that didn't actually change content is a no-op on the wire.

**Why the encodedSystemFields preservation matters.** Every leg in the upserted set already has its CKRecord change-tag cached locally. Replacing it with `nil` would make the sync layer believe the leg is unsynced — every header-only edit (e.g. renaming a payee) would re-upload every leg in the transaction. The fetch + reattach pattern keeps the change-tag intact so CK only sees the leg records that actually changed.

### Reference R2: `paidCopy` with fresh leg ids

```swift
static func paidCopy(of scheduled: Transaction) -> Transaction {
  Transaction(
    id: UUID(),
    date: scheduled.date,
    payee: scheduled.payee,
    notes: scheduled.notes,
    legs: scheduled.legs.map { source in
      TransactionLeg(
        id: UUID(),
        accountId: source.accountId,
        instrument: source.instrument,
        quantity: source.quantity,
        externalId: source.externalId,
        counterpartyAddress: source.counterpartyAddress,
        type: source.type,
        categoryId: source.categoryId,
        earmarkId: source.earmarkId)
    }
  )
}
```

The paid copy is a separate `Transaction` row with its own legs; preserving the scheduled record's leg ids would PK-collide on insert.

### Reference R3: `LegDraft.legId` resolution

```swift
// Shared/Models/TransactionDraft.swift, in toTransaction(id:)
for legDraft in legDrafts {
  guard let instrument = legDraft.instrument else { return nil }
  guard
    let quantity = Self.parseDisplayText(
      legDraft.amountText, type: legDraft.type, decimals: instrument.decimals)
  else { return nil }

  legs.append(
    TransactionLeg(
      id: legDraft.legId ?? UUID(),
      accountId: legDraft.accountId,
      instrument: instrument,
      quantity: quantity,
      type: legDraft.type,
      categoryId: legDraft.categoryId,
      earmarkId: legDraft.earmarkId))
}
```

`legId == nil` ⇒ leg was added during this draft session ⇒ allocate a fresh id at save time. `legId != nil` ⇒ this leg came from the persisted transaction at draft init ⇒ reuse it so the GRDB upsert lands on the existing row.

### Reference R4: Repository round-trip stability test

```swift
// MoolahTests/Backends/GRDB/GRDBTransactionRepositoryStableLegIdTests.swift
@Suite("GRDBTransactionRepository preserves leg ids across update")
@MainActor
struct GRDBTransactionRepositoryStableLegIdTests {

  @Test("editing only the parent header keeps every leg id stable")
  func headerOnlyEditPreservesLegIds() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId,
        name: "Cash",
        type: .bank,
        instrument: Currency.defaultTestCurrency,
        positions: []))
    let original = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Coffee",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Currency.defaultTestCurrency,
            quantity: -10, type: .expense)
        ]))
    let originalLegIds = original.legs.map(\.id)

    var edited = original
    edited.payee = "Espresso"
    _ = try await backend.transactions.update(edited)

    let reloaded = try await backend.transactions.fetch(id: original.id)
    let reloadedLegIds = try #require(reloaded).legs.map(\.id)
    #expect(reloadedLegIds == originalLegIds)
  }

  @Test("removing one leg from a two-leg transaction keeps the surviving leg's id")
  func removeOneLegPreservesSurvivor() async throws {
    let (backend, _) = try TestBackend.create()
    let acctA = UUID(), acctB = UUID()
    for id in [acctA, acctB] {
      _ = try await backend.accounts.create(
        Account(
          id: id, name: id.uuidString, type: .bank,
          instrument: Currency.defaultTestCurrency, positions: []))
    }
    let original = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Move",
        legs: [
          TransactionLeg(
            accountId: acctA, instrument: Currency.defaultTestCurrency,
            quantity: -50, type: .transfer),
          TransactionLeg(
            accountId: acctB, instrument: Currency.defaultTestCurrency,
            quantity: 50, type: .transfer),
        ]))
    let survivorId = original.legs[0].id

    var edited = original
    edited.legs = [original.legs[0]]   // drop the second leg
    _ = try await backend.transactions.update(edited)

    let reloaded = try #require(try await backend.transactions.fetch(id: original.id))
    #expect(reloaded.legs.count == 1)
    #expect(reloaded.legs[0].id == survivorId)
  }

  @Test("create(_:) writes the caller-supplied leg id, not a fresh UUID")
  func createUsesCallerSuppliedLegId() async throws {
    // Without this test, a regression that leaves
    // `let legId = UUID()` in `create(_:)` (while only fixing
    // `performUpdate`) would not be caught by the round-trip / reorder
    // / remove tests below — those capture `original.legs.map(\.id)`
    // *after* `create`, so they verify update-stability but not
    // create-stability. Pin the create-time id explicitly.
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: Currency.defaultTestCurrency, positions: []))
    let preassignedLegId = UUID()
    let txn = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Tagged",
        legs: [
          TransactionLeg(
            id: preassignedLegId,
            accountId: accountId,
            instrument: Currency.defaultTestCurrency,
            quantity: -7, type: .expense)
        ]))
    // Returned domain object reflects the caller's id.
    #expect(txn.legs.first?.id == preassignedLegId)
    // Re-fetched row from GRDB also uses the caller's id (i.e.
    // create wrote `leg.id` to the transaction_leg.id column).
    let reloaded = try #require(try await backend.transactions.fetch(id: txn.id))
    #expect(reloaded.legs.map(\.id) == [preassignedLegId])
  }

  @Test("reordering legs rewrites sort_order but keeps ids")
  func reorderRewritesSortOrderKeepsIds() async throws {
    let (backend, _) = try TestBackend.create()
    let acctA = UUID(), acctB = UUID()
    for id in [acctA, acctB] {
      _ = try await backend.accounts.create(
        Account(
          id: id, name: id.uuidString, type: .bank,
          instrument: Currency.defaultTestCurrency, positions: []))
    }
    let original = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Swap",
        legs: [
          TransactionLeg(
            accountId: acctA, instrument: Currency.defaultTestCurrency,
            quantity: -25, type: .transfer),
          TransactionLeg(
            accountId: acctB, instrument: Currency.defaultTestCurrency,
            quantity: 25, type: .transfer),
        ]))
    let firstId = original.legs[0].id
    let secondId = original.legs[1].id

    var edited = original
    edited.legs = [original.legs[1], original.legs[0]]   // swap
    _ = try await backend.transactions.update(edited)

    let reloaded = try #require(try await backend.transactions.fetch(id: original.id))
    #expect(reloaded.legs.map(\.id) == [secondId, firstId])
  }
}
```

`TestBackend.create()` returns `(any BackendProvider, ModelContainer)` per the project's existing convention; the in-memory SwiftData container plus the GRDB sidecar is wired in `MoolahTests/Support/TestBackend.swift`.

---

## Stage 0: Worktree + baseline

### Task 0: Set up isolated worktree and confirm baseline tests pass

**Files:**
- No source changes in this stage.

- [ ] **Step 1: Create worktree off main with `--no-track`**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track \
  /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/feat-stable-leg-id \
  -b feat/stable-leg-id origin/main
```

Or via the harness's `EnterWorktree` tool with `name: "feat/stable-leg-id"`.

- [ ] **Step 2: Verify baseline build is clean**

```bash
WT=/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/feat-stable-leg-id
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Verify baseline contract tests pass**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionRepositoryPersistenceTests \
  2>&1 | tee "$WT/.agent-tmp/baseline.txt" | tail -3
```

Expected: `** TEST SUCCEEDED **` and `==> All tests passed.`

- [ ] **Step 4: No commit at this stage**

The worktree is set up; the rest of the plan adds commits.

---

## Stage 1: Add `TransactionLeg.id`

### Task 1: Domain model gains a stable `id`

**Files:**
- Modify: `Domain/Models/TransactionLeg.swift`
- Test: `MoolahTests/Domain/TransactionLegIdentityTests.swift` (new)

- [ ] **Step 1: Write the failing identity tests**

Create `MoolahTests/Domain/TransactionLegIdentityTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionLeg identity")
struct TransactionLegIdentityTests {

  @Test("default initializer allocates a fresh id per call")
  func defaultIdIsUnique() {
    let a = TransactionLeg(
      accountId: nil,
      instrument: Currency.defaultTestCurrency,
      quantity: 0, type: .expense)
    let b = TransactionLeg(
      accountId: nil,
      instrument: Currency.defaultTestCurrency,
      quantity: 0, type: .expense)
    #expect(a.id != b.id)
  }

  @Test("explicit id round-trips through init")
  func explicitIdRoundTrips() {
    let id = UUID()
    let leg = TransactionLeg(
      id: id,
      accountId: nil,
      instrument: Currency.defaultTestCurrency,
      quantity: 0, type: .expense)
    #expect(leg.id == id)
  }

  @Test("two legs with same content but different ids are not equal")
  func differentIdsBreakEquality() {
    let a = TransactionLeg(
      accountId: nil,
      instrument: Currency.defaultTestCurrency,
      quantity: 0, type: .expense)
    let b = TransactionLeg(
      accountId: nil,
      instrument: Currency.defaultTestCurrency,
      quantity: 0, type: .expense)
    // Same content, distinct identities: must compare unequal so callers
    // depending on equality (e.g. `Equatable` diffs in SwiftUI ForEach
    // identity) treat them as separate legs.
    #expect(a != b)
  }
}
```

- [ ] **Step 2: Run the failing tests**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionLegIdentityTests \
  2>&1 | tee "$WT/.agent-tmp/stage1.txt" | tail -5
```

Expected: build failure citing `argument 'id'` in the explicit-id test (the field doesn't exist yet).

- [ ] **Step 3: Add `id` to `TransactionLeg`**

Update `Domain/Models/TransactionLeg.swift`:

```swift
import Foundation

struct TransactionLeg: Codable, Sendable, Hashable, Identifiable {
  let id: UUID
  let accountId: UUID?
  let instrument: Instrument
  let quantity: Decimal
  let externalId: String?
  let counterpartyAddress: String?
  var type: TransactionType
  var categoryId: UUID?
  var earmarkId: UUID?

  init(
    id: UUID = UUID(),
    accountId: UUID?,
    instrument: Instrument,
    quantity: Decimal,
    externalId: String? = nil,
    counterpartyAddress: String? = nil,
    type: TransactionType,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.instrument = instrument
    self.quantity = quantity
    self.externalId = externalId
    self.counterpartyAddress = counterpartyAddress
    self.type = type
    self.categoryId = categoryId
    self.earmarkId = earmarkId
  }

  /// Convenience: the quantity as an InstrumentAmount.
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }
}
```

The retained doc comment for `counterpartyAddress` (currently 9 lines starting at the existing struct) is preserved; only the property declarations and init signature change.

- [ ] **Step 4: Run the new tests**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionLegIdentityTests \
  2>&1 | tee "$WT/.agent-tmp/stage1.txt" | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Run the full `just test-mac` to surface any callsite that breaks under id-aware equality**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac 2>&1 | tee "$WT/.agent-tmp/stage1-full.txt" | grep -E "Test Suite.*passed|FAIL|error:" | head -20
```

Existing tests that compare `TransactionLeg` values for equality and rely on "same content ⇒ equal" will fail. The fix in each case is to compare the fields you care about explicitly (`#expect(reloaded.legs[0].quantity == ...)`) rather than the full struct. Check `MoolahTests/Domain/TransactionRepository*Tests.swift` and `MoolahTests/Backends/GRDB/CoreFinancialGraphSyncRoundTripTests.swift` first.

> **Expected interim state.** After Stage 1 alone, `TransactionLegRecord.toDomain(...)` (SwiftData) and `TransactionLegRow.toDomain(...)` (GRDB) still construct `TransactionLeg(...)` without `id:`, which means the `id: UUID = UUID()` default fires and every fetched leg gets an ephemeral id. Stages 2 and 3 fix the SwiftData and GRDB read paths respectively. Any test that asserts on stable leg ids (Stage 4 onwards) will fail until both Stage 2 and Stage 3 are committed. Do not investigate Stage 4 test failures until those two stages land.

- [ ] **Step 6: Format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
git -C "$WT" add Domain/Models/TransactionLeg.swift \
  MoolahTests/Domain/TransactionLegIdentityTests.swift \
  $(git -C "$WT" diff --name-only)
git -C "$WT" commit -m "feat(domain): TransactionLeg gains stable id"
```

---

## Stage 2: SwiftData mirror preserves leg id

> **Companion-change requirement.** Both `from(_:transactionId:sortOrder:)` and `toDomain(instrument:)` in `TransactionLegRecord.swift` must be updated in the same commit. A partial change compiles cleanly but silently allocates a fresh `UUID()` on every `toDomain(...)` call (the `id:` default in `TransactionLeg.init`), reproducing the original bug via the SwiftData read path. The build alone will not catch this — run the round-trip tests.

### Task 2: `TransactionLegRecord.from(...)` and `.toDomain(...)` round-trip the leg id

**Files:**
- Modify: `Backends/CloudKit/Models/TransactionLegRecord.swift`

- [ ] **Step 1: Update `from(_:transactionId:sortOrder:)` to copy `leg.id`**

Replace the existing factory body:

```swift
static func from(_ leg: TransactionLeg, transactionId: UUID, sortOrder: Int)
  -> TransactionLegRecord
{
  TransactionLegRecord(
    id: leg.id,
    transactionId: transactionId,
    accountId: leg.accountId,
    instrumentId: leg.instrument.id,
    quantity: InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument).storageValue,
    type: leg.type.rawValue,
    categoryId: leg.categoryId,
    earmarkId: leg.earmarkId,
    sortOrder: sortOrder,
    externalId: leg.externalId,
    counterpartyAddress: leg.counterpartyAddress
  )
}
```

- [ ] **Step 2: Update `toDomain(instrument:)` to pass the row's `id` through**

```swift
func toDomain(instrument: Instrument) throws -> TransactionLeg {
  TransactionLeg(
    id: id,
    accountId: accountId,
    instrument: instrument,
    quantity: InstrumentAmount(storageValue: quantity, instrument: instrument).quantity,
    externalId: externalId,
    counterpartyAddress: counterpartyAddress,
    type: try TransactionType.decoded(rawValue: type),
    categoryId: categoryId,
    earmarkId: earmarkId)
}
```

- [ ] **Step 3: Build to surface compile errors**

```bash
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
git -C "$WT" add Backends/CloudKit/Models/TransactionLegRecord.swift
git -C "$WT" commit -m "feat(swiftdata): TransactionLegRecord round-trips leg id"
```

---

## Stage 3: GRDB row mapping preserves leg id

### Task 3: `TransactionLegRow → TransactionLeg` and `init(domain:...)` use `leg.id`

**Files:**
- Modify: `Backends/GRDB/Records/TransactionLegRow+Mapping.swift`

- [ ] **Step 1: Default the row builder's `id` to `leg.id`**

Replace the existing init:

```swift
/// Builds a row from a domain `TransactionLeg`. The row's `id` defaults
/// to `leg.id` (the leg's stable domain id). Callers can override `id`
/// only if they need a row id that differs from the leg's own stable
/// id — no in-tree callsite needs that. Passing `leg.id` explicitly
/// (as `create(_:)` does, for callsite-clarity) is also fine; the
/// default and the explicit value are identical. The CK-ingestion
/// path constructs `TransactionLegRow` via the memberwise init in
/// `TransactionLegRow+CloudKit.fieldValues(from:)`, not this factory.
init(
  id: UUID? = nil,
  domain leg: TransactionLeg,
  transactionId: UUID,
  sortOrder: Int
) {
  let resolvedId = id ?? leg.id
  self.id = resolvedId
  self.recordName = Self.recordName(for: resolvedId)
  self.transactionId = transactionId
  self.accountId = leg.accountId
  self.instrumentId = leg.instrument.id
  self.quantity =
    InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument).storageValue
  self.type = leg.type.rawValue
  self.categoryId = leg.categoryId
  self.earmarkId = leg.earmarkId
  self.sortOrder = sortOrder
  self.encodedSystemFields = nil
  self.externalId = leg.externalId
  self.counterpartyAddress = leg.counterpartyAddress
}
```

The `id: UUID? = nil` plus `id ?? leg.id` form serves two purposes: existing callsites in `App/UITestSeedHydrator+*.swift` and `MoolahBenchmarks/...` that omit `id:` continue to compile and now naturally inherit the leg's stable id; and the optional override survives in the API for hypothetical future flexibility (no in-tree caller exercises it).

`encodedSystemFields = nil` is intentional here — the factory is used by `create(_:)` for genuinely new rows, and by `performUpdate` callers that *re-attach* the existing blob after construction (see Reference R1). Do not change this default.

- [ ] **Step 2: Update `toDomain(instrument:)` to pass `id` through**

```swift
func toDomain(instrument: Instrument) throws -> TransactionLeg {
  TransactionLeg(
    id: id,
    accountId: accountId,
    instrument: instrument,
    quantity: InstrumentAmount(storageValue: quantity, instrument: instrument).quantity,
    externalId: externalId,
    counterpartyAddress: counterpartyAddress,
    type: try TransactionType.decoded(rawValue: type),
    categoryId: categoryId,
    earmarkId: earmarkId
  )
}
```

- [ ] **Step 3: Build**

```bash
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the existing transaction repo tests; they should still pass**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionRepositoryPersistenceTests \
  2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
git -C "$WT" add Backends/GRDB/Records/TransactionLegRow+Mapping.swift
git -C "$WT" commit -m "feat(grdb): TransactionLegRow round-trips leg id"
```

---

## Stage 4: Repository switches to diff-by-id update

### Task 4: Diff-by-id `performUpdate` and stable-id `create`

**Files:**
- Modify: `Backends/GRDB/Repositories/GRDBTransactionRepository.swift`
- Test: `MoolahTests/Backends/GRDB/GRDBTransactionRepositoryStableLegIdTests.swift` (new)

- [ ] **Step 1: Write the failing repository tests**

Create `MoolahTests/Backends/GRDB/GRDBTransactionRepositoryStableLegIdTests.swift` with the three test methods from Reference R4 above (`headerOnlyEditPreservesLegIds`, `removeOneLegPreservesSurvivor`, `reorderRewritesSortOrderKeepsIds`). Inline the full test code from R4 — do not abbreviate.

Append two further tests **inside `GRDBTransactionRepositoryStableLegIdTests` (before the struct's closing `}`)** — not as top-level free functions. The first pins `encodedSystemFields` preservation; the second pins single-write rollback for the new diff-by-id path. Both are hard requirements per `guides/DATABASE_CODE_GUIDE.md` §5 and §7.

```swift
@Test(
  "header-only update preserves each leg's encodedSystemFields blob")
func headerOnlyEditPreservesEncodedSystemFields() async throws {
  let database = try ProfileDatabase.openInMemory()
  let txnRepo = GRDBTransactionRepository(
    database: database,
    defaultInstrument: .defaultTestInstrument,
    conversionService: FixedConversionService())
  let accountId = UUID()
  let txn = try await txnRepo.create(
    Transaction(
      date: Date(), payee: "Coffee",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -10, type: .expense)
      ]))
  let legId = txn.legs[0].id

  // Simulate a successful CK round-trip stamping the leg with its
  // cached system fields blob. `try await` selects the async overload
  // of `DatabaseWriter.write` — calling the synchronous overload from
  // an async test silently blocks the cooperative thread pool.
  let stampedFields = Data([0xCA, 0xFE, 0xBA, 0xBE])
  try await database.write { db in
    try TransactionLegRow
      .filter(TransactionLegRow.Columns.id == legId)
      .updateAll(
        db,
        [TransactionLegRow.Columns.encodedSystemFields.set(to: stampedFields)])
  }

  // Header-only edit. After Reference R1's preservation pass, the
  // leg's cached blob must survive verbatim — otherwise the next sync
  // pass treats the leg as unsynced and re-uploads it.
  var edited = txn
  edited.payee = "Espresso"
  _ = try await txnRepo.update(edited)

  let reloadedFields = try await database.read { db in
    try TransactionLegRow
      .filter(TransactionLegRow.Columns.id == legId)
      .select(TransactionLegRow.Columns.encodedSystemFields, as: Data?.self)
      .fetchOne(db) ?? nil
  }
  #expect(reloadedFields == stampedFields)
}

@Test(
  "performUpdate rolls back legs and header on a mid-write throw")
func performUpdateRollsBackOnFailure() async throws {
  let database = try ProfileDatabase.openInMemory()
  let txnRepo = GRDBTransactionRepository(
    database: database,
    defaultInstrument: .defaultTestInstrument,
    conversionService: FixedConversionService())
  let accountId = UUID()
  let txn = try await txnRepo.create(
    Transaction(
      date: Date(), payee: "Original",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -10, type: .expense)
      ]))
  let originalLegId = txn.legs[0].id

  // Force a mid-write failure with a `BEFORE UPDATE` trigger on the
  // header table. The trigger fires inside `performUpdate`'s write
  // closure after the header `UPDATE` is issued and before any leg
  // upserts run; SQLite raises ABORT, which propagates out as a Swift
  // error, and the surrounding `database.write { … }` rolls the
  // entire transaction back per §5 of DATABASE_CODE_GUIDE. Same
  // pattern as `TransactionDeleteRollbackTests`.
  try await database.write { db in
    try db.execute(
      sql: """
        CREATE TRIGGER force_update_failure
        BEFORE UPDATE ON "transaction"
        BEGIN
          SELECT RAISE(ABORT, 'forced failure for rollback test');
        END;
        """)
  }

  var brokenUpdate = txn
  brokenUpdate.payee = "Should not land"

  do {
    _ = try await txnRepo.update(brokenUpdate)
    Issue.record("Expected update to throw — rollback test cannot proceed")
  } catch {
    // Expected: SQLite ABORT propagates out as a Swift error.
  }

  // Header field must be unchanged.
  let reloaded = try #require(try await txnRepo.fetch(id: txn.id))
  #expect(reloaded.payee == "Original")
  // Original leg row must still be present, untouched.
  #expect(reloaded.legs.map(\.id) == [originalLegId])
}
```

The trigger-driven failure mode mirrors the existing `TransactionDeleteRollbackTests` shape; reuse `makeContractTestLeg(...)` (already in the test target's `Support/`). Do **not** try to force the failure by referencing a missing-instrument id — `+FKEnsure.swift`'s `ensureInstrumentReadable` *inserts a placeholder* for unknown non-fiat instruments rather than throwing, so that path would let the update succeed and the rollback assertion would never fire.

- [ ] **Step 2: Run the new tests against the unchanged repository to confirm they fail**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac GRDBTransactionRepositoryStableLegIdTests \
  2>&1 | tee "$WT/.agent-tmp/stage4-pre.txt" | tail -10
```

Expected: `headerOnlyEditPreservesLegIds` and `reorderRewritesSortOrderKeepsIds` FAIL because `update(_:)` allocates fresh leg ids on every save (the assertions on stable ids will not hold). `removeOneLegPreservesSurvivor` may also fail for the same reason.

- [ ] **Step 3: Update `create(_:)` to use `leg.id`**

In `Backends/GRDB/Repositories/GRDBTransactionRepository.swift`, replace the `for (index, leg) in transaction.legs.enumerated()` loop body in `create`:

```swift
func create(_ transaction: Transaction) async throws -> Transaction {
  let insertedLegIds = try await database.write { database -> [UUID] in
    let txnRow = TransactionRow(domain: transaction)
    try txnRow.insert(database)

    var legIds: [UUID] = []
    legIds.reserveCapacity(transaction.legs.count)
    for (index, leg) in transaction.legs.enumerated() {
      try Self.ensureInstrumentReadable(database: database, leg: leg)
      let legRow = TransactionLegRow(
        id: leg.id,
        domain: leg,
        transactionId: transaction.id,
        sortOrder: index)
      try legRow.insert(database)
      legIds.append(leg.id)
    }
    return legIds
  }

  onRecordChanged(TransactionRow.recordType, transaction.id)
  for legId in insertedLegIds {
    onRecordChanged(TransactionLegRow.recordType, legId)
  }
  return transaction
}
```

- [ ] **Step 4: Replace `performUpdate` with the diff-by-id body from Reference R1**

Inline the full code block from R1 verbatim. Update `UpdateOutcome` (the `private struct` adjacent to `performUpdate`) to rename `insertedLegIds` to `upsertedLegIds`:

```swift
private struct UpdateOutcome {
  let deletedLegIds: [UUID]
  let upsertedLegIds: [UUID]
}
```

- [ ] **Step 5: Update the `update(_:)` post-commit hook fan-out to use `upsertedLegIds`**

```swift
func update(_ transaction: Transaction) async throws -> Transaction {
  let outcome = try await database.write { database -> UpdateOutcome in
    try Self.performUpdate(database: database, transaction: transaction)
  }

  onRecordChanged(TransactionRow.recordType, transaction.id)
  for legId in outcome.upsertedLegIds {
    onRecordChanged(TransactionLegRow.recordType, legId)
  }
  for legId in outcome.deletedLegIds {
    onRecordDeleted(TransactionLegRow.recordType, legId)
  }
  return transaction
}
```

- [ ] **Step 6: Run the new tests; they should all pass**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac GRDBTransactionRepositoryStableLegIdTests \
  2>&1 | tee "$WT/.agent-tmp/stage4-post.txt" | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Run the full repo contract suite to surface regressions**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionRepositoryPersistenceTests \
  TransactionRepositoryFilterTests TransactionRepositoryOrderingTests \
  TransactionRepositoryBulkFetchTests TransactionRepositoryMultiInstTests \
  CoreFinancialGraphSyncRoundTripTests TransactionDeleteRollbackTests \
  TransactionHookUpdateDeleteTests \
  2>&1 | tee "$WT/.agent-tmp/stage4-contracts.txt" | tail -5
```

Expected: most suites pass. `TransactionHookUpdateDeleteTests.transactionUpdateEmitsLegRecordType` will FAIL at this stage — it asserts the old "2 leg-deletes" hook fan-out shape that this stage's diff-by-id update no longer produces when leg ids are preserved. **This failure is expected and normal**; Stage 8 replaces the assertion. Do not stop or rewrite the test here. Any *other* failing test that asserts on a specific old leg id pattern (fresh-UUID-per-save) is a real regression and needs updating to assert on stability instead.

- [ ] **Step 8: Format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
git -C "$WT" add Backends/GRDB/Repositories/GRDBTransactionRepository.swift \
  MoolahTests/Backends/GRDB/GRDBTransactionRepositoryStableLegIdTests.swift
git -C "$WT" commit -m "feat(grdb): diff-by-id update preserves stable leg ids"
```

---

## Stage 5: `Transaction.paidCopy` allocates fresh leg ids

### Task 5: paid copies get new leg ids

**Files:**
- Modify: `Domain/Models/Transaction+Defaults.swift`
- Test: `MoolahTests/Domain/TransactionLegIdentityTests.swift` (extend)

- [ ] **Step 1: Add the failing test to `TransactionLegIdentityTests`**

Append to the existing suite:

```swift
@Test("paidCopy(of:) allocates fresh ids for every leg")
func paidCopyAllocatesFreshLegIds() {
  let scheduled = Transaction(
    date: Date(), payee: "Rent",
    legs: [
      TransactionLeg(
        accountId: UUID(),
        instrument: Currency.defaultTestCurrency,
        quantity: -1000, type: .expense),
      TransactionLeg(
        accountId: UUID(),
        instrument: Currency.defaultTestCurrency,
        quantity: 1000, type: .transfer),
    ])
  let copy = Transaction.paidCopy(of: scheduled)
  let scheduledIds = Set(scheduled.legs.map(\.id))
  let copyIds = Set(copy.legs.map(\.id))
  // Different transactions, distinct leg rows: ids must not collide.
  #expect(scheduledIds.isDisjoint(with: copyIds))
  #expect(copy.legs.count == scheduled.legs.count)
  // Content is preserved.
  #expect(copy.legs.map(\.quantity) == scheduled.legs.map(\.quantity))
}
```

- [ ] **Step 2: Run the failing test**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionLegIdentityTests \
  2>&1 | grep -E "FAIL|paidCopy" | head -5
```

Expected: failure with `paidCopy(of:)` returning legs whose ids match the scheduled transaction's legs (because the current implementation copies the whole legs array verbatim).

- [ ] **Step 3: Apply the fix from Reference R2**

Replace the body of `paidCopy(of:)` in `Domain/Models/Transaction+Defaults.swift` with the code in Reference R2 verbatim.

- [ ] **Step 4: Re-run the test**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionLegIdentityTests \
  2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
git -C "$WT" add Domain/Models/Transaction+Defaults.swift \
  MoolahTests/Domain/TransactionLegIdentityTests.swift
git -C "$WT" commit -m "feat(domain): paidCopy allocates fresh leg ids"
```

---

## Stage 6: `LegDraft` carries `legId`

### Task 6: `LegDraft` gains optional `legId`; `init(from: Transaction)` populates it

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Modify: `Shared/Models/TransactionDraft+SimpleMode.swift`
- Modify: `Shared/Models/TransactionDraft+TradeMode.swift`
- Test: `MoolahTests/Shared/TransactionDraftLegIdTests.swift` (new)

- [ ] **Step 1: Write the failing draft tests**

Create `MoolahTests/Shared/TransactionDraftLegIdTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft preserves leg ids end-to-end")
struct TransactionDraftLegIdTests {

  @Test("init(from:) populates legId from each source leg")
  func initFromTransactionPopulatesLegId() {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Currency.defaultTestCurrency,
      quantity: -10, type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    let draft = TransactionDraft(from: txn)
    #expect(draft.legDrafts.first?.legId == leg.id)
  }

  @Test("toTransaction(id:) round-trips legId for legs that came from a transaction")
  func toTransactionRoundTripsLegId() throws {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Currency.defaultTestCurrency,
      quantity: -10, type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    let draft = TransactionDraft(from: txn)
    let rebuilt = try #require(draft.toTransaction(id: txn.id))
    #expect(rebuilt.legs.map(\.id) == [leg.id])
  }

  @Test("addLeg leaves the new draft's legId nil; saving allocates a fresh id")
  func addLegAllocatesFreshIdAtSave() throws {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Currency.defaultTestCurrency,
      quantity: -10, type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    var draft = TransactionDraft(from: txn)
    draft.isCustom = true
    draft.addLeg()
    #expect(draft.legDrafts.last?.legId == nil)

    let rebuilt = try #require(draft.toTransaction(id: txn.id))
    #expect(rebuilt.legs.count == 2)
    #expect(rebuilt.legs[0].id == leg.id)
    #expect(rebuilt.legs[1].id != leg.id)
  }
}
```

- [ ] **Step 2: Run the failing tests**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionDraftLegIdTests \
  2>&1 | tail -5
```

Expected: build failure citing `legId` not a member of `LegDraft`.

- [ ] **Step 3: Add `legId: UUID?` to `LegDraft` and update its init**

In `Shared/Models/TransactionDraft.swift`, modify `LegDraft`:

```swift
struct LegDraft: Sendable, Equatable {
  /// Stable id of the leg this draft maps back to in
  /// `transaction_leg.id`. `nil` for legs added during this draft
  /// session — `toTransaction(id:)` allocates a fresh id at save time.
  let legId: UUID?
  var type: TransactionType
  var accountId: UUID?
  var amountText: String
  var categoryId: UUID?
  var categoryText: String
  var earmarkId: UUID?
  var instrument: Instrument?

  init(
    legId: UUID? = nil,
    type: TransactionType,
    accountId: UUID?,
    amountText: String,
    categoryId: UUID?,
    categoryText: String,
    earmarkId: UUID?,
    instrument: Instrument? = nil
  ) {
    self.legId = legId
    self.type = type
    self.accountId = accountId
    self.amountText = amountText
    self.categoryId = categoryId
    self.categoryText = categoryText
    self.earmarkId = earmarkId
    self.instrument = instrument
  }

  // existing isEarmarkOnly + resolvedInstrument methods stay unchanged
}
```

- [ ] **Step 4: Update `init(from: Transaction, ...)` to populate `legId`**

In the convenience initialiser, change the `transaction.legs.map { leg in ... }` block to set `legId: leg.id`:

```swift
let drafts = transaction.legs.map { leg in
  LegDraft(
    legId: leg.id,
    type: leg.type,
    accountId: leg.accountId,
    amountText: Self.displayText(
      quantity: leg.quantity, type: leg.type, decimals: leg.instrument.decimals),
    categoryId: leg.categoryId,
    categoryText: "",
    earmarkId: leg.earmarkId,
    instrument: leg.instrument)
}
```

- [ ] **Step 5: Update `toTransaction(id:)` to resolve `legId ?? UUID()`**

Replace the `legs.append(...)` block in `toTransaction(id:)`:

```swift
legs.append(
  TransactionLeg(
    id: legDraft.legId ?? UUID(),
    accountId: legDraft.accountId,
    instrument: instrument,
    quantity: quantity,
    type: legDraft.type,
    categoryId: legDraft.categoryId,
    earmarkId: legDraft.earmarkId))
```

- [ ] **Step 6: Update `addLeg(...)` to construct with `legId: nil`**

In the same file:

```swift
mutating func addLeg(defaultAccountId: UUID? = nil, instrument: Instrument? = nil) {
  legDrafts.append(
    LegDraft(
      legId: nil,
      type: .expense, accountId: defaultAccountId, amountText: "0",
      categoryId: nil, categoryText: "", earmarkId: nil,
      instrument: instrument
    ))
}
```

- [ ] **Step 7: Update the other `LegDraft(...)` construction sites to pass `legId: nil` for new-in-draft legs**

Search for every direct `LegDraft(` constructor call:

```bash
grep -rn "LegDraft(" /Users/aj/Documents/code/moolah-project/moolah-native/Shared/Models/ \
  /Users/aj/Documents/code/moolah-project/moolah-native/Features/ \
  /Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/
```

Expected callsites and the right `legId` for each:

| File | Callsite | `legId` |
|---|---|---|
| `Shared/Models/TransactionDraft.swift` `init(earmarkId:...)` | blank earmark draft | `nil` (new draft) |
| `Shared/Models/TransactionDraft.swift` `init(accountId:...)` | blank account draft | `nil` (new draft) |
| `Shared/Models/TransactionDraft.swift` `addLeg` | already covered above | `nil` |
| `Shared/Models/TransactionDraft+SimpleMode.swift` `setType(.transfer)` counterpart | newly inserted counterpart | `nil` |
| `Shared/Models/TransactionDraft+TradeMode.swift` `appendFee(defaultInstrument:)` | new fee leg | `nil` |
| `Shared/Models/TransactionDraft+TradeMode.swift` `tradeLeg(...)` factory (line ~127) | used by `switchToTrade` for both `blank` and `carried` | both `nil` — these are *new* legs constructed during the mode switch; the pre-trade leg's id is intentionally not preserved because trade splits one leg into two and the carried leg is no longer "the same" leg |
| `Shared/Models/TransactionDraft+TradeMode.swift` `applyIncomeLeg(from:)` (line ~171) | new income leg replacing the trade pair | `nil` |
| `Shared/Models/TransactionDraft+TradeMode.swift` `applyExpenseLeg(from:)` (line ~185) | new expense leg replacing the trade pair | `nil` |
| `Shared/Models/TransactionDraft+TradeMode.swift` `applyTransferLegs(paidLeg:accounts:)` (line ~199) — `counterpart` (line ~202) | new transfer counterpart leg | `nil` |
| `Shared/Models/TransactionDraft+TradeMode.swift` `applyTransferLegs(paidLeg:accounts:)` (line ~199) — `primary` (line ~210) | new transfer primary leg | `nil` |
| Test fixtures in `MoolahTests/Shared/` | varies | `nil` for tests that don't care |

For each callsite, add `legId: nil,` as the first argument. The default `nil` in the initialiser means existing test fixtures that omit `legId:` keep working — but make the fact explicit at every production callsite so reviewers can audit which legs are new-in-draft.

- [ ] **Step 8: Run the new tests**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionDraftLegIdTests \
  2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Run the full draft suite to catch regressions**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionDraftAccountTests \
  TransactionDraftSimpleModeTests TransactionDraftTradeModeTests \
  2>&1 | tee "$WT/.agent-tmp/stage6-drafts.txt" | tail -5
```

Expected: `==> All tests passed.`

- [ ] **Step 10: Format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
git -C "$WT" add Shared/Models/TransactionDraft.swift \
  Shared/Models/TransactionDraft+SimpleMode.swift \
  Shared/Models/TransactionDraft+TradeMode.swift \
  MoolahTests/Shared/TransactionDraftLegIdTests.swift
git -C "$WT" commit -m "feat(transactions): LegDraft carries stable legId through edits"
```

---

## Stage 7: `applyAutofill` clears `legId`

### Task 7: Autofill resets leg ids so the saved transaction does not collide with the autofill source

**Files:**
- Modify: `Shared/Models/TransactionDraft+Autofill.swift`
- Test: `MoolahTests/Shared/TransactionDraftLegIdTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Append to `TransactionDraftLegIdTests`:

```swift
@Test("applyAutofill clears legId so saving does not collide with the source's leg rows")
func applyAutofillClearsLegIds() throws {
  let sourceLeg = TransactionLeg(
    accountId: UUID(),
    instrument: Currency.defaultTestCurrency,
    quantity: -25, type: .expense,
    categoryId: UUID())
  let source = Transaction(date: Date(), payee: "Coffee", legs: [sourceLeg])

  // A fresh draft is a brand-new transaction in progress.
  var draft = TransactionDraft(accountId: nil, instrument: Currency.defaultTestCurrency)

  draft.applyAutofill(from: source, categories: Categories(from: []), accounts: Accounts(from: []))

  // The carried leg's content matches `source` but its id is regenerated
  // at save time so it does not collide with `source.legs[0].id` in
  // GRDB's primary key.
  #expect(draft.legDrafts.allSatisfy { $0.legId == nil })

  let savedNewId = UUID()
  let saved = try #require(draft.toTransaction(id: savedNewId))
  #expect(saved.legs.first?.id != sourceLeg.id)
}
```

- [ ] **Step 2: Run the failing test**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionDraftLegIdTests \
  2>&1 | grep -E "FAIL|applyAutofill" | head -5
```

Expected: failure on the `legDrafts.allSatisfy { $0.legId == nil }` assertion (autofill currently copies `legId` from the source).

- [ ] **Step 3: Update `applyAutofill`**

Replace `Shared/Models/TransactionDraft+Autofill.swift` body with the legId-clearing variant. The diff against the existing file is two additions:

1. After `var newDraft = TransactionDraft(from: match, ...)` and the existing legId-irrelevant rewrites, add a loop that nils out `legId` on every leg draft.
2. Add a comment explaining why.

```swift
import Foundation

extension TransactionDraft {
  /// Replace this draft with data from a matching transaction, preserving the current date.
  /// Category text is populated from the categories collection.
  ///
  /// When the draft has a `viewingAccountId` (autofill was triggered while the
  /// user was scoped to a specific account list), the relevant leg is pinned to
  /// the viewed account so a past transaction from a different account can't
  /// silently move the new transaction out of the list the user is working in.
  /// Pass `accounts` to also realign the leg's instrument with the viewed
  /// account's instrument.
  mutating func applyAutofill(
    from match: Transaction,
    categories: Categories,
    accounts: Accounts = Accounts(from: [])
  ) {
    let preservedDate = self.date
    let preservedViewingAccountId = self.viewingAccountId

    // Build a fresh draft from the match
    var newDraft = TransactionDraft(
      from: match, viewingAccountId: preservedViewingAccountId, accounts: accounts)
    newDraft.date = preservedDate

    // Populate category text for all legs
    for i in newDraft.legDrafts.indices {
      if let catId = newDraft.legDrafts[i].categoryId,
        let cat = categories.by(id: catId)
      {
        newDraft.legDrafts[i].categoryText = categories.path(for: cat)
      }
    }

    // Autofill copies content from a different transaction; legs save
    // into *this* transaction so they need new ids — preserving the
    // source's leg ids would PK-collide on the GRDB upsert against the
    // source's own row.
    //
    // **Maintenance note:** if a new field is added to `LegDraft`, add
    // it to this rebuild loop too. `legId` is `let`, so we cannot
    // mutate it in place — a full struct rebuild is required, and any
    // field omitted here will silently revert to its default on every
    // autofill.
    for i in newDraft.legDrafts.indices {
      let existing = newDraft.legDrafts[i]
      newDraft.legDrafts[i] = TransactionDraft.LegDraft(
        legId: nil,
        type: existing.type,
        accountId: existing.accountId,
        amountText: existing.amountText,
        categoryId: existing.categoryId,
        categoryText: existing.categoryText,
        earmarkId: existing.earmarkId,
        instrument: existing.instrument)
    }

    // Preserve the viewed account. Skip custom mode: a complex match has no
    // single "viewed" leg, and adopting its structure means the user is
    // already accepting whatever accounts it references.
    if let viewingId = preservedViewingAccountId, !newDraft.isCustom {
      let idx = newDraft.relevantLegIndex
      if newDraft.legDrafts[idx].accountId != viewingId {
        newDraft.legDrafts[idx].accountId = viewingId
        if let viewedAccount = accounts.by(id: viewingId) {
          newDraft.legDrafts[idx].instrument = viewedAccount.instrument
        }
      }
    }

    self = newDraft
  }
}
```

The rebuild-each-LegDraft loop is needed because `legId` is `let`. The struct cost is negligible.

- [ ] **Step 4: Run the new test**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionDraftLegIdTests \
  2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
git -C "$WT" add Shared/Models/TransactionDraft+Autofill.swift \
  MoolahTests/Shared/TransactionDraftLegIdTests.swift
git -C "$WT" commit -m "feat(transactions): autofill clears legId so saves do not PK-collide"
```

---

## Stage 8: Update existing hook fan-out tests for new semantics

### Task 8: Replace the legacy "delete + re-insert" assertion with the new "upsert in place" assertion, plus a sibling test for the explicit-replace case

**Files:**
- Modify: `MoolahTests/Sync/TransactionHookUpdateDeleteTests.swift`

- [ ] **Step 1: Read the current test, then replace the `transactionUpdateEmitsLegRecordType` body**

The current test's `updated` builds a fresh `Transaction` with default-id legs, expects 2 leg-changes + 2 leg-deletes. Under the new semantics, an update that *preserves* the original leg ids emits 2 leg-upserts (still tagged `TransactionLegRow.recordType`) and 0 leg-deletes.

Update the test body so it walks both flows. Replace the existing `@Test("update(_:) emits TransactionRecord change plus per-leg LegRecord changes/deletes")` body with:

```swift
@Test(
  "update(_:) preserving leg ids emits TransactionRow change + per-leg upserts, no deletes")
func transactionUpdateEmitsLegRecordType() async throws {
  let database = try ProfileDatabase.openInMemory()
  let capture = HookCapture()
  let txnRepo = GRDBTransactionRepository(
    database: database,
    defaultInstrument: .defaultTestInstrument,
    conversionService: FixedConversionService(),
    onRecordChanged: makeChangedHook(capture),
    onRecordDeleted: makeDeletedHook(capture))

  let accountId = UUID()
  let txn = try await txnRepo.create(
    Transaction(
      date: Date(), payee: "Trade",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
        makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
      ]))
  try await drainHookHops()
  capture.changed.removeAll()
  capture.deleted.removeAll()

  // Update with the same legs (preserving ids) but a different payee.
  // Expected hook fan-out: 1 TransactionRow change, N TransactionLegRow
  // changes (one upsert per leg), 0 TransactionLegRow deletes.
  var updated = txn
  updated.payee = "Renamed Trade"
  _ = try await txnRepo.update(updated)
  try await drainHookHops()

  let txnEmits = capture.changed.filter { $0.recordType == TransactionRow.recordType }
  #expect(txnEmits.map(\.id) == [txn.id])
  let legChanges = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
  // Identity check: the upsert must emit the *original* leg ids — not
  // freshly-allocated ones. A regression that reintroduces fresh-UUID
  // allocation in performUpdate would still emit two leg-changes
  // (passing a count-only assertion) while churning the recordName.
  let emittedLegIds = Set(legChanges.map(\.id))
  let originalLegIds = Set(txn.legs.map(\.id))
  #expect(emittedLegIds == originalLegIds)
  // Crucially: no leg-delete events when the leg array is preserved by id.
  let legDeletes = capture.deleted.filter { $0.recordType == TransactionLegRow.recordType }
  #expect(legDeletes.isEmpty)
  let txnDeletes = capture.deleted.filter { $0.recordType == TransactionRow.recordType }
  #expect(txnDeletes.isEmpty)
}
```

- [ ] **Step 2: Add a sibling test for the explicit-replace path**

Append to the suite:

```swift
@Test(
  "update(_:) replacing legs (different ids) emits per-leg upserts + per-leg deletes")
func transactionUpdateWithReplacedLegsEmitsDeletes() async throws {
  let database = try ProfileDatabase.openInMemory()
  let capture = HookCapture()
  let txnRepo = GRDBTransactionRepository(
    database: database,
    defaultInstrument: .defaultTestInstrument,
    conversionService: FixedConversionService(),
    onRecordChanged: makeChangedHook(capture),
    onRecordDeleted: makeDeletedHook(capture))

  let accountId = UUID()
  let txn = try await txnRepo.create(
    Transaction(
      date: Date(), payee: "Trade",
      legs: [
        makeContractTestLeg(accountId: accountId, quantity: -100, type: .transfer),
        makeContractTestLeg(accountId: accountId, quantity: 100, type: .transfer),
      ]))
  try await drainHookHops()
  capture.changed.removeAll()
  capture.deleted.removeAll()

  // Replace the leg array entirely — every leg has a fresh id.
  // Expected: 2 leg-upserts (the new ids) + 2 leg-deletes (the old ids).
  let replacement = Transaction(
    id: txn.id, date: txn.date, payee: txn.payee,
    legs: [
      makeContractTestLeg(accountId: accountId, quantity: -50, type: .transfer),
      makeContractTestLeg(accountId: accountId, quantity: 50, type: .transfer),
    ])
  _ = try await txnRepo.update(replacement)
  try await drainHookHops()

  let legChanges = capture.changed.filter { $0.recordType == TransactionLegRow.recordType }
  // Identity check on the upsert side: emitted ids match the *replacement*
  // legs, not the originals.
  let replacementIds = Set(replacement.legs.map(\.id))
  let changedIds = Set(legChanges.map(\.id))
  #expect(changedIds == replacementIds)
  let legDeletes = capture.deleted.filter { $0.recordType == TransactionLegRow.recordType }
  // The deleted ids are the original legs', not the replacement's.
  let originalIds = Set(txn.legs.map(\.id))
  let deletedIds = Set(legDeletes.map(\.id))
  #expect(deletedIds == originalIds)
}
```

- [ ] **Step 3: Run the suite**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionHookUpdateDeleteTests \
  2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
git -C "$WT" add MoolahTests/Sync/TransactionHookUpdateDeleteTests.swift
git -C "$WT" commit -m "test(sync): hook fan-out reflects diff-by-id update semantics"
```

---

## Stage 8a: Sync-layer ingestion regression tests

### Task 8a: Pin the CK ingestion semantics that stable ids make safe

**Files:**
- Test: `MoolahTests/Sync/TransactionLegSyncSemanticTests.swift` (new)

These tests pin the property that motivates the entire change: a server-side phantom leg with the same id upserts in place (idempotent), while a phantom with a different id still lands as a duplicate row (documenting the residual race the design knowingly leaves open). Without these tests, a future regression that reintroduces fresh-UUID allocation in `performUpdate` would silently re-open the production failure mode.

- [ ] **Step 1: Write the new test suite**

Create `MoolahTests/Sync/TransactionLegSyncSemanticTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

// NOT @MainActor: `applyRemoteChangesSync` is a synchronous, GRDB-queue-
// blocking write. The same constraint that bans `@MainActor` callers in
// production (see `GRDBTransactionLegRepository`'s file-header comment)
// applies to tests — calling a blocking sync write from the main actor
// stalls the cooperative thread pool and risks deadlock under
// contention. The test suite touches no main-actor state, so dropping
// the annotation is safe.
@Suite("TransactionLeg sync ingestion semantics")
struct TransactionLegSyncSemanticTests {

  @Test("applyRemoteChangesSync with same-id leg row is idempotent — no duplicate")
  func sameLegIdUpsertIsIdempotent() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService())
    let legRepo = GRDBTransactionLegRepository(database: database)
    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Rent",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Currency.defaultTestCurrency,
            quantity: -1000, type: .expense)
        ]))
    let originalLegId = txn.legs[0].id

    // Simulate the server re-delivering the same leg (e.g. a re-fetch
    // after a network blip, or the originating device's own queued
    // record bouncing back). Same id ⇒ upsert lands on the existing
    // row.
    let phantomRow = TransactionLegRow(
      id: originalLegId,
      recordName: TransactionLegRow.recordName(for: originalLegId),
      transactionId: txn.id,
      accountId: accountId,
      instrumentId: Currency.defaultTestCurrency.id,
      quantity:
        InstrumentAmount(
          quantity: -1000, instrument: Currency.defaultTestCurrency
        ).storageValue,
      type: TransactionType.expense.rawValue,
      categoryId: nil, earmarkId: nil, sortOrder: 0,
      encodedSystemFields: nil, externalId: nil, counterpartyAddress: nil)
    try legRepo.applyRemoteChangesSync(saved: [phantomRow], deleted: [])

    let reloaded = try #require(try await txnRepo.fetch(id: txn.id))
    #expect(
      reloaded.legs.count == 1,
      "Same-id re-delivery must not duplicate legs — count was \(reloaded.legs.count)")
    #expect(reloaded.legs[0].id == originalLegId)
  }

  @Test(
    "applyRemoteChangesSync with a different-id orphan leg lands as a second row — documents residual race")
  func differentIdOrphanLandsAsSecondRow() async throws {
    let database = try ProfileDatabase.openInMemory()
    let txnRepo = GRDBTransactionRepository(
      database: database,
      defaultInstrument: .defaultTestInstrument,
      conversionService: FixedConversionService())
    let legRepo = GRDBTransactionLegRepository(database: database)
    let accountId = UUID()
    let txn = try await txnRepo.create(
      Transaction(
        date: Date(), payee: "Rent",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Currency.defaultTestCurrency,
            quantity: -1000, type: .expense)
        ]))

    // A server-side orphan with a UUID that the local row does NOT
    // share. Under the new stable-id design this can only happen if
    // the original "leg removed from transaction" delete-uplink failed
    // and the orphan stays on the server with a uuid the device never
    // owned. Stable ids make this less likely (re-queued deletes hit
    // the right record) but do not make it impossible. The user
    // resolves manually (design Section 7).
    let orphanId = UUID()
    let orphanRow = TransactionLegRow(
      id: orphanId,
      recordName: TransactionLegRow.recordName(for: orphanId),
      transactionId: txn.id,
      accountId: accountId,
      instrumentId: Currency.defaultTestCurrency.id,
      quantity:
        InstrumentAmount(
          quantity: -1000, instrument: Currency.defaultTestCurrency
        ).storageValue,
      type: TransactionType.expense.rawValue,
      categoryId: nil, earmarkId: nil, sortOrder: 1,
      encodedSystemFields: nil, externalId: nil, counterpartyAddress: nil)
    try legRepo.applyRemoteChangesSync(saved: [orphanRow], deleted: [])

    let reloaded = try #require(try await txnRepo.fetch(id: txn.id))
    #expect(
      reloaded.legs.count == 2,
      "Different-id orphan must land as a second row — documents residual race")
  }
}
```

- [ ] **Step 2: Run the suite**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac TransactionLegSyncSemanticTests \
  2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Format, commit**

```bash
just -d "$WT" --justfile "$WT/justfile" format
git -C "$WT" add MoolahTests/Sync/TransactionLegSyncSemanticTests.swift
git -C "$WT" commit -m "test(sync): pin leg ingestion idempotence and residual-race semantics"
```

---

## Stage 9: Final review

### Task 9: Run the full Mac test suite, format-check, and the structural review agents

**Files:**
- No source changes.

- [ ] **Step 1: Full `just test-mac`**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac \
  2>&1 | tee "$WT/.agent-tmp/final-tests.txt" | grep -E "Test Suite.*passed|FAIL|error:" | tail -20
```

Expected: `==> All tests passed.`

- [ ] **Step 2: `just format-check`**

```bash
just -d "$WT" --justfile "$WT/justfile" format-check 2>&1 | tail -5
```

Expected: `All Swift files are correctly formatted.`

- [ ] **Step 3: `just build-mac` and inspect for warnings introduced by this branch**

```bash
just -d "$WT" --justfile "$WT/justfile" build-mac 2>&1 \
  | tee "$WT/.agent-tmp/final-build.txt" \
  | grep -E "warning:" | grep -v "Preview\|deprecated_iconset\|run script build phase" | head -10
```

Expected: empty (no new warnings in user code).

- [ ] **Step 4: Run the project review agents in parallel**

Dispatch four reviewers concurrently in a single message:

- `database-code-review` — focused on `GRDBTransactionRepository.swift` (diff-by-id update, hook fan-out), `TransactionLegRow+Mapping.swift`.
- `sync-review` — focused on the hook fan-out changes and the recordName-stability claim.
- `code-review` — broad pass over the whole diff for style, naming, optional discipline, thin-view discipline.
- `concurrency-review` — focused on the repo's `database.write { … }` block in the diff-by-id update.

Apply every Critical / Important / Minor finding inline. Do not defer.

- [ ] **Step 5: Re-run `just test-mac` after review fixes**

```bash
just -d "$WT" --justfile "$WT/justfile" test-mac 2>&1 | tail -3
```

Expected: `==> All tests passed.`

- [ ] **Step 6: Push and open the PR**

```bash
git -C "$WT" push origin feat/stable-leg-id:feat/stable-leg-id
gh -R ajsutton/moolah-native pr create --base main --head feat/stable-leg-id \
  --title "feat(transactions): stable TransactionLeg.id ends leg-churn-on-update" \
  --body "$(cat <<'EOF'
## Summary
- TransactionLeg.id is now part of the domain model (let UUID, default UUID()).
- GRDBTransactionRepository.update(_:) switches to diff-by-id: legs whose id stays in the array are upserted in place; legs whose id is removed are deleted; new legs are inserted.
- record_name on transaction_leg is now stable for the lifetime of a leg, closing the class of bugs where a dropped leg-delete uplink leaves orphan legs on the CloudKit server which propagate back as duplicates on later edits.
- Spec: `plans/2026-05-08-stable-transaction-leg-id-design.md`. Plan: `plans/2026-05-08-stable-transaction-leg-id-implementation-plan.md`.

## Test plan
- [x] just format-check
- [x] just build-mac (no new warnings)
- [x] just test-mac (all suites)
- [x] code-review, concurrency-review, database-code-review, sync-review agents (no open findings)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7: Add the PR to the merge queue**

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR_NUMBER>
```

---

## Self-review checklist

- [ ] Every change in the design spec's Section 1 (`TransactionLeg.id`, `LegDraft.legId`, `paidCopy`) is covered by a stage.
- [ ] Section 2 (diff-by-id update) is implemented in Stage 4 with the round-trip + reorder + remove tests in Reference R4.
- [ ] Section 3 (wire/sync) is verified by the existing CK ingestion path (no source changes needed) plus the updated hook fan-out tests in Stage 8.
- [ ] Section 4 (test plan) is covered:
  - Domain identity → Stage 1 + Stage 5
  - Repository round-trip stability → Stage 4 (`headerOnlyEditPreservesLegIds`, `removeOneLegPreservesSurvivor`, `reorderRewritesSortOrderKeepsIds`)
  - No-spurious-churn (header-only edit) → Stage 4 (`headerOnlyEditPreservesLegIds` for ids; `transactionUpdateEmitsLegRecordType` in Stage 8 for `legDeletes.isEmpty`). The design's named `GRDBTransactionRepositoryUpdateNoSpuriousLegChurnTests` is satisfied by these two tests in combination — no separate test file is needed.
  - `encodedSystemFields` preservation across upsert → Stage 4 (`headerOnlyEditPreservesEncodedSystemFields`)
  - Multi-statement-write rollback (§5/§7 of `DATABASE_CODE_GUIDE.md`) → Stage 4 (`performUpdateRollsBackOnFailure`)
  - Sync push idempotence → Stage 8a (`sameLegIdUpsertIsIdempotent`)
  - Residual different-id race → Stage 8a (`differentIdOrphanLandsAsSecondRow`)
  - Hook fan-out shape (id-equality, not count-only) → Stage 8 (both `transactionUpdateEmitsLegRecordType` and `transactionUpdateWithReplacedLegsEmitsDeletes`)
- [ ] Section 7 (out-of-scope) — no dedup utility for existing in-the-wild duplicates is implemented. User cleans up manually.
- [ ] Every reference to types, methods, or properties exists in the codebase or is introduced by an earlier stage.
- [ ] No placeholder text (`TBD`, `TODO`, "implement later", etc.) anywhere in the plan.
