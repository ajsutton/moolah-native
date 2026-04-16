# Earmark Instrument Field & Balance Removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit `instrument` field to `Earmark`, migrate all `.balance.instrument` references, then remove the legacy `balance`/`saved`/`spent` fields so display values come from positions via `EarmarkStore`.

**Architecture:** Two-phase refactor. Phase 1 (Tasks 1–5) adds the `instrument` field and migrates all references. Phase 2 (Tasks 6–10) removes legacy fields, makes `EarmarkStore` the sole source of converted per-earmark amounts, and updates views to read from the store. Each task produces a committable unit.

**Tech Stack:** Swift, SwiftUI, SwiftData, CloudKit (CKRecord)

---

## File Map

**Phase 1 — Add `instrument` field:**
- Modify: `Domain/Models/Earmark.swift` — add `instrument: Instrument` field
- Modify: `Backends/CloudKit/Models/EarmarkRecord.swift` — add `instrumentId: String` field
- Modify: `Backends/CloudKit/Sync/RecordMapping.swift` — read/write `instrumentId` on CKRecord
- Modify: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift` — pass instrument through `toDomain()`
- Modify: `Backends/Remote/DTOs/EarmarkDTO.swift` — set instrument from profile currency
- Modify: `Backends/Remote/Repositories/RemoteEarmarkRepository.swift` — pass instrument through
- Modify: `Features/Earmarks/EarmarkStore.swift` — remove `totalBalance`
- Modify: `Features/Earmarks/Views/EarmarksView.swift` — use `targetInstrument` for create sheet
- Modify: `Features/Earmarks/Views/EarmarkFormSheet.swift` — use `.instrument` instead of `.balance.instrument`
- Modify: `Features/Earmarks/Views/AddBudgetLineItemSheet.swift` — use `.instrument`
- Modify: `Features/Navigation/SidebarView.swift` — use `targetInstrument` for create sheet
- Modify: `Shared/Models/TransactionDraft.swift` — use `.instrument`
- Modify: `Features/Transactions/Views/TransactionDetailView.swift` — use `.instrument`
- Modify: `Automation/Intents/Entities/EarmarkEntity.swift` — use `.instrument` (balance stays for now)
- Modify: `MoolahTests/Features/EarmarkStoreTests.swift` — update fixtures, remove `totalBalance` tests
- Modify: `MoolahTests/Support/TestBackend.swift` — seed `instrumentId` on `EarmarkRecord`

**Phase 2 — Remove `balance`/`saved`/`spent`:**
- Modify: `Domain/Models/Earmark.swift` — remove `balance`/`saved`/`spent` fields, update Codable/Equatable/Hashable
- Modify: `Features/Earmarks/EarmarkStore.swift` — compute per-earmark converted amounts, publish them
- Modify: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift` — drop legacy balance computation
- Modify: `Backends/CloudKit/Models/EarmarkRecord.swift` — drop `balance`/`saved`/`spent` from `toDomain()`
- Modify: `Backends/Remote/DTOs/EarmarkDTO.swift` — drop `balance`/`saved`/`spent` from `toDomain()`
- Modify: All views that read `earmark.balance`/`earmark.saved`/`earmark.spent` — read from store instead
- Modify: `MoolahTests/Features/EarmarkStoreTests.swift` — assert on positions and store-computed amounts
- Modify: `MoolahTests/Support/TestBackend.swift` — update `seedWithTransactions` to not reference balance/saved/spent

---

## Phase 1: Add `instrument` field

### Task 1: Add `instrument` to domain model and storage

**Files:**
- Modify: `Domain/Models/Earmark.swift`
- Modify: `Backends/CloudKit/Models/EarmarkRecord.swift`
- Modify: `Backends/CloudKit/Sync/RecordMapping.swift:240-270`
- Test: `MoolahTests/Sync/RecordMappingTests.swift`

- [ ] **Step 1: Add `instrument` field to `Earmark`**

In `Domain/Models/Earmark.swift`, add `instrument` as a stored property after `name`:

```swift
struct Earmark: Codable, Sendable, Identifiable, Hashable, Comparable {
  let id: UUID
  var name: String
  var instrument: Instrument
  var balance: InstrumentAmount
  // ... rest unchanged
```

Update the memberwise init to accept `instrument` with a default:

```swift
  init(
    id: UUID = UUID(),
    name: String,
    instrument: Instrument = .AUD,
    balance: InstrumentAmount = .zero(instrument: .AUD),
    // ... rest unchanged
  ) {
    self.id = id
    self.name = name
    self.instrument = instrument
    self.balance = balance
    // ... rest unchanged
  }
```

Add `instrument` to `CodingKeys`:

```swift
  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case instrument
    case balance
    // ... rest unchanged
  }
```

Add to `init(from decoder:)` with a fallback to `balance.instrument` for backwards compatibility with existing JSON:

```swift
    name = try container.decode(String.self, forKey: .name)
    balance = try container.decode(InstrumentAmount.self, forKey: .balance)
    instrument = try container.decodeIfPresent(Instrument.self, forKey: .instrument) ?? balance.instrument
```

Add to `encode(to:)`:

```swift
    try container.encode(instrument, forKey: .instrument)
```

Add to `==` and `hash(into:)`:

```swift
  static func == (lhs: Earmark, rhs: Earmark) -> Bool {
    lhs.id == rhs.id && lhs.name == rhs.name
      && lhs.instrument == rhs.instrument
      && lhs.balance == rhs.balance && lhs.saved == rhs.saved && lhs.spent == rhs.spent
      // ... rest unchanged
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(name)
    hasher.combine(instrument)
    hasher.combine(balance)
    // ... rest unchanged
  }
```

- [ ] **Step 2: Add `instrumentId` to `EarmarkRecord`**

In `Backends/CloudKit/Models/EarmarkRecord.swift`, add a new field:

```swift
  var instrumentId: String?
```

Update init:

```swift
  init(
    id: UUID = UUID(),
    name: String,
    instrumentId: String? = nil,
    position: Int = 0,
    // ... rest unchanged
  ) {
    self.id = id
    self.name = name
    self.instrumentId = instrumentId
    self.position = position
    // ... rest unchanged
  }
```

Update `toDomain()` — accept a `defaultInstrument` parameter for records that predate this field:

```swift
  func toDomain(
    defaultInstrument: Instrument,
    balance: InstrumentAmount, saved: InstrumentAmount, spent: InstrumentAmount,
    positions: [Position] = [], savedPositions: [Position] = [], spentPositions: [Position] = []
  ) -> Earmark {
    let instrument = instrumentId.map { Instrument.fiat(code: $0) } ?? defaultInstrument
    let savingsGoal: InstrumentAmount? = savingsTarget.flatMap { target in
      guard let instrumentId = savingsTargetInstrumentId else { return nil }
      let inst = Instrument.fiat(code: instrumentId)
      return InstrumentAmount(storageValue: target, instrument: inst)
    }
    return Earmark(
      id: id,
      name: name,
      instrument: instrument,
      balance: balance,
      saved: saved,
      spent: spent,
      positions: positions,
      savedPositions: savedPositions,
      spentPositions: spentPositions,
      isHidden: isHidden,
      position: position,
      savingsGoal: savingsGoal,
      savingsStartDate: savingsStartDate,
      savingsEndDate: savingsEndDate
    )
  }
```

Update `from(_:)`:

```swift
  static func from(_ earmark: Earmark) -> EarmarkRecord {
    EarmarkRecord(
      id: earmark.id,
      name: earmark.name,
      instrumentId: earmark.instrument.id,
      position: earmark.position,
      isHidden: earmark.isHidden,
      savingsTarget: earmark.savingsGoal?.storageValue,
      savingsTargetInstrumentId: earmark.savingsGoal?.instrument.id,
      savingsStartDate: earmark.savingsStartDate,
      savingsEndDate: earmark.savingsEndDate
    )
  }
```

- [ ] **Step 3: Update CKRecord mapping**

In `Backends/CloudKit/Sync/RecordMapping.swift`, update the `EarmarkRecord` extension.

In `toCKRecord(in:)`, add after the `name` line:

```swift
    if let instrumentId { record["instrumentId"] = instrumentId as CKRecordValue }
```

In `fieldValues(from:)`, add `instrumentId` parameter:

```swift
  static func fieldValues(from ckRecord: CKRecord) -> EarmarkRecord {
    EarmarkRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      name: ckRecord["name"] as? String ?? "",
      instrumentId: ckRecord["instrumentId"] as? String,
      position: ckRecord["position"] as? Int ?? 0,
      // ... rest unchanged
    )
  }
```

- [ ] **Step 4: Build and verify no compiler errors**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-phase1-task1.txt`

This will have errors from `CloudKitEarmarkRepository` because `toDomain()` signature changed — that's expected, fixed in Task 2.

- [ ] **Step 5: Commit**

```bash
git add Domain/Models/Earmark.swift Backends/CloudKit/Models/EarmarkRecord.swift Backends/CloudKit/Sync/RecordMapping.swift
git commit -m "feat: add instrument field to Earmark and EarmarkRecord"
```

### Task 2: Update repositories to pass instrument

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift`
- Modify: `Backends/Remote/DTOs/EarmarkDTO.swift`
- Modify: `Backends/Remote/Repositories/RemoteEarmarkRepository.swift`

- [ ] **Step 1: Update `CloudKitEarmarkRepository.fetchAll()`**

In `CloudKitEarmarkRepository.swift`, update the `toDomain()` call at line 35 to pass `defaultInstrument`:

```swift
        return record.toDomain(
          defaultInstrument: instrument,
          balance: totals.balance, saved: totals.saved, spent: totals.spent,
          positions: totals.positions, savedPositions: totals.savedPositions,
          spentPositions: totals.spentPositions
        )
```

- [ ] **Step 2: Update `EarmarkDTO.toDomain()`**

In `Backends/Remote/DTOs/EarmarkDTO.swift`, add `instrument` to the `Earmark` construction:

```swift
  func toDomain(instrument: Instrument) -> Earmark {
    Earmark(
      id: id.uuid,
      name: name,
      instrument: instrument,
      balance: InstrumentAmount(quantity: Decimal(balance) / 100, instrument: instrument),
      // ... rest unchanged
    )
  }
```

- [ ] **Step 3: Build and verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-phase1-task2.txt`
Expected: Clean build (or only test compilation warnings).

- [ ] **Step 4: Commit**

```bash
git add Backends/
git commit -m "feat: repositories pass instrument through to Earmark domain model"
```

### Task 3: Remove `totalBalance`, migrate `.balance.instrument` references

**Files:**
- Modify: `Features/Earmarks/EarmarkStore.swift`
- Modify: `Features/Earmarks/Views/EarmarksView.swift`
- Modify: `Features/Earmarks/Views/EarmarkFormSheet.swift`
- Modify: `Features/Earmarks/Views/AddBudgetLineItemSheet.swift`
- Modify: `Features/Navigation/SidebarView.swift`
- Modify: `Shared/Models/TransactionDraft.swift`
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`
- Modify: `Automation/Intents/Entities/EarmarkEntity.swift`

- [ ] **Step 1: Remove `totalBalance` from `EarmarkStore`**

In `Features/Earmarks/EarmarkStore.swift`, delete lines 79–83 (the `totalBalance` computed property).

- [ ] **Step 2: Update `EarmarksView` create sheet**

In `Features/Earmarks/Views/EarmarksView.swift`, the `EarmarkStore` needs to expose `targetInstrument`. First, in `EarmarkStore.swift`, make `targetInstrument` accessible:

```swift
  // Change from:
  private let targetInstrument: Instrument
  // To:
  let targetInstrument: Instrument
```

Then in `EarmarksView.swift` line 72–73, change:

```swift
        CreateEarmarkSheet(
          instrument: earmarkStore.totalBalance.instrument,
```

To:

```swift
        CreateEarmarkSheet(
          instrument: earmarkStore.targetInstrument,
```

- [ ] **Step 3: Update `SidebarView` create sheet**

In `Features/Navigation/SidebarView.swift` line 209–210, change:

```swift
      CreateEarmarkSheet(
        instrument: accountStore.currentTotal.instrument,
```

To:

```swift
      CreateEarmarkSheet(
        instrument: earmarkStore.targetInstrument,
```

- [ ] **Step 4: Update `EditEarmarkSheet` to use `.instrument`**

In `Features/Earmarks/Views/EarmarkFormSheet.swift`:

Line 112 — change `earmark.balance.instrument.id` to `earmark.instrument.id`

Line 164 — change `earmark.balance.instrument.decimals` to `earmark.instrument.decimals`

Line 167 — change `earmark.balance.instrument` to `earmark.instrument`

- [ ] **Step 5: Update `AddBudgetLineItemSheet` to use `.instrument`**

In `Features/Earmarks/Views/AddBudgetLineItemSheet.swift`:

Line 52 — change `earmark.balance.instrument.currencySymbol ?? earmark.balance.instrument.id` to `earmark.instrument.currencySymbol ?? earmark.instrument.id`

Line 136 — change `earmark.balance.instrument.decimals` to `earmark.instrument.decimals`

Line 138 — change `earmark.balance.instrument` to `earmark.instrument`

- [ ] **Step 6: Update `TransactionDraft` to use `.instrument`**

In `Shared/Models/TransactionDraft.swift` line 406, change:

```swift
        instrument = earmark.balance.instrument
```

To:

```swift
        instrument = earmark.instrument
```

- [ ] **Step 7: Update `TransactionDetailView` to use `.instrument`**

In `Features/Transactions/Views/TransactionDetailView.swift` line 174, change:

```swift
      return earmark.balance.instrument.id
```

To:

```swift
      return earmark.instrument.id
```

And line 183, change:

```swift
      .balance.instrument
```

To:

```swift
      .instrument
```

- [ ] **Step 8: Build and verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-phase1-task3.txt`
Expected: Clean build.

- [ ] **Step 9: Commit**

```bash
git add Features/ Shared/ Automation/
git commit -m "refactor: migrate .balance.instrument to .instrument, remove totalBalance"
```

### Task 4: Update tests for Phase 1

**Files:**
- Modify: `MoolahTests/Features/EarmarkStoreTests.swift`
- Modify: `MoolahTests/Support/TestBackend.swift`

- [ ] **Step 1: Update `TestBackend.seed(earmarks:)` to pass `instrumentId`**

In `MoolahTests/Support/TestBackend.swift`, update the `seed(earmarks:in:instrument:)` method. The `EarmarkRecord.from(earmark)` call will now automatically include `instrumentId` since we updated `from(_:)` in Task 1. No change needed here — verify this is the case.

Also check `seedWithTransactions` — same logic applies: `EarmarkRecord.from(earmark)` picks up the instrument. No change needed.

- [ ] **Step 2: Update test fixtures to include `instrument`**

In `MoolahTests/Features/EarmarkStoreTests.swift`, add `instrument` parameter to earmark fixtures that specify a balance. For tests that only set a name (like reorder tests), the default `.AUD` works fine.

For tests that set balance with `Instrument.defaultTestInstrument`, also set `instrument`:

```swift
    let earmark = Earmark(
      name: "Holiday Fund",
      instrument: Instrument.defaultTestInstrument,
      balance: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
```

Apply this pattern to all test methods that construct `Earmark` with an explicit balance: `testPopulatesFromRepository`, `testSortingByPosition`, `testCalculatesTotalBalance`, `testApplyDeltaAdjustsPositionsAndBalance`, `testApplyDeltaWithSavedIncreasesBalance`, `testApplyDeltaAffectsMultipleEarmarks`, `testConvertedTotalBalancePopulatedAfterLoad`, `testConvertedTotalBalanceUpdatesAfterApplyDelta`, `hiddenEarmarksExcluded`, `hiddenEarmarksIncluded`.

- [ ] **Step 3: Update `testCalculatesTotalBalance` — remove `totalBalance` assertion**

Replace the `totalBalance` assertion with a test that the earmarks loaded correctly and verifies `instrument` is set:

```swift
  @Test func testEarmarkInstrumentSetCorrectly() async throws {
    let earmarks = [
      Earmark(
        name: "Holiday",
        instrument: Instrument.defaultTestInstrument,
        balance: InstrumentAmount(
          quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument)),
      Earmark(
        name: "Car Repair",
        instrument: Instrument.defaultTestInstrument,
        balance: InstrumentAmount(
          quantity: Decimal(30000) / 100, instrument: Instrument.defaultTestInstrument)),
    ]
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container,
    )
    TestBackend.seedWithTransactions(
      earmarks: earmarks, accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)

    await store.load()

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks[0].instrument == Instrument.defaultTestInstrument)
    #expect(store.earmarks[1].instrument == Instrument.defaultTestInstrument)
  }
```

Remove the old `testCalculatesTotalBalance` test.

- [ ] **Step 4: Run tests**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-phase1.txt
```

Check for failures: `grep -i 'failed\|error:' .agent-tmp/test-phase1.txt`

- [ ] **Step 5: Fix any test failures and re-run**

- [ ] **Step 6: Commit**

```bash
git add MoolahTests/
git commit -m "test: update earmark test fixtures for instrument field"
```

### Task 5: Phase 1 verification

- [ ] **Step 1: Check for compiler warnings**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` or run:

```bash
just build-mac 2>&1 | grep -i warning | grep -v '#Preview' | tee .agent-tmp/warnings.txt
```

Fix any warnings in user code.

- [ ] **Step 2: Run full test suite**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-phase1-final.txt
grep -c 'Test run completed' .agent-tmp/test-phase1-final.txt
grep -i 'failed' .agent-tmp/test-phase1-final.txt
```

Expected: All tests pass, zero failures.

- [ ] **Step 3: Verify no remaining `.balance.instrument` references (except in `Earmark.swift` Codable fallback)**

```bash
grep -rn '\.balance\.instrument' Features/ Shared/ Automation/ Backends/ --include='*.swift' | grep -v 'Earmark.swift'
```

Expected: No results (or only preview code that will be updated in Phase 2).

- [ ] **Step 4: Clean up temp files**

```bash
rm -f .agent-tmp/build-*.txt .agent-tmp/test-*.txt .agent-tmp/warnings.txt
```

---

## Phase 2: Remove `balance`, `saved`, `spent`

### Task 6: EarmarkStore computes per-earmark converted amounts

**Files:**
- Modify: `Features/Earmarks/EarmarkStore.swift`
- Test: `MoolahTests/Features/EarmarkStoreTests.swift`

- [ ] **Step 1: Write failing tests for per-earmark converted amounts**

In `MoolahTests/Features/EarmarkStoreTests.swift`, add tests:

```swift
  @Test func testConvertedBalancePerEarmarkPopulatedAfterLoad() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          instrument: instrument,
          balance: InstrumentAmount(quantity: 500, instrument: instrument),
          saved: InstrumentAmount(quantity: 500, instrument: instrument),
          spent: InstrumentAmount(quantity: 0, instrument: instrument))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    let convertedBalance = store.convertedBalance(for: earmarkId)
    #expect(convertedBalance?.quantity == 500)
    let convertedSaved = store.convertedSaved(for: earmarkId)
    #expect(convertedSaved?.quantity == 500)
    let convertedSpent = store.convertedSpent(for: earmarkId)
    #expect(convertedSpent?.quantity == 0)
  }

  @Test func testConvertedBalancePerEarmarkUpdatesAfterDelta() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(
          id: earmarkId, name: "Holiday Fund",
          instrument: instrument,
          balance: InstrumentAmount(quantity: 500, instrument: instrument),
          saved: InstrumentAmount(quantity: 500, instrument: instrument),
          spent: InstrumentAmount(quantity: 0, instrument: instrument))
      ], accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedBalance(for: earmarkId)?.quantity == 400)
    #expect(store.convertedSpent(for: earmarkId)?.quantity == 100)
  }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-phase2-task6-fail.txt
grep -i 'convertedBalance\|convertedSaved\|convertedSpent' .agent-tmp/test-phase2-task6-fail.txt
```

Expected: Compilation error — `convertedBalance(for:)` doesn't exist yet.

- [ ] **Step 3: Implement per-earmark converted amounts in EarmarkStore**

In `Features/Earmarks/EarmarkStore.swift`, add a published dictionary for per-earmark amounts:

```swift
  private(set) var convertedBalances: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSavedAmounts: [UUID: InstrumentAmount] = [:]
  private(set) var convertedSpentAmounts: [UUID: InstrumentAmount] = [:]

  func convertedBalance(for earmarkId: UUID) -> InstrumentAmount? {
    convertedBalances[earmarkId]
  }

  func convertedSaved(for earmarkId: UUID) -> InstrumentAmount? {
    convertedSavedAmounts[earmarkId]
  }

  func convertedSpent(for earmarkId: UUID) -> InstrumentAmount? {
    convertedSpentAmounts[earmarkId]
  }
```

Update `recomputeConvertedTotals()` to also compute per-earmark totals:

```swift
  private func recomputeConvertedTotals() {
    conversionTask?.cancel()
    conversionTask = Task {
      do {
        var grandTotal = InstrumentAmount.zero(instrument: targetInstrument)
        var balances: [UUID: InstrumentAmount] = [:]
        var saved: [UUID: InstrumentAmount] = [:]
        var spent: [UUID: InstrumentAmount] = [:]

        for earmark in visibleEarmarks {
          var earmarkBalance = InstrumentAmount.zero(instrument: earmark.instrument)
          var earmarkSaved = InstrumentAmount.zero(instrument: earmark.instrument)
          var earmarkSpent = InstrumentAmount.zero(instrument: earmark.instrument)

          // Convert positions to earmark's own instrument
          for position in earmark.positions {
            guard let conversionService else {
              earmarkBalance += position.amount
              continue
            }
            let converted = try await conversionService.convertAmount(
              position.amount, to: earmark.instrument, on: Date())
            guard !Task.isCancelled else { return }
            earmarkBalance += converted
          }
          for position in earmark.savedPositions {
            guard let conversionService else {
              earmarkSaved += position.amount
              continue
            }
            let converted = try await conversionService.convertAmount(
              position.amount, to: earmark.instrument, on: Date())
            guard !Task.isCancelled else { return }
            earmarkSaved += converted
          }
          for position in earmark.spentPositions {
            guard let conversionService else {
              earmarkSpent += position.amount
              continue
            }
            let converted = try await conversionService.convertAmount(
              position.amount, to: earmark.instrument, on: Date())
            guard !Task.isCancelled else { return }
            earmarkSpent += converted
          }

          balances[earmark.id] = earmarkBalance
          saved[earmark.id] = earmarkSaved
          spent[earmark.id] = earmarkSpent

          // Convert earmark balance to target instrument for grand total
          if let conversionService {
            let convertedToTarget = try await conversionService.convertAmount(
              earmarkBalance, to: targetInstrument, on: Date())
            guard !Task.isCancelled else { return }
            grandTotal += convertedToTarget
          } else {
            grandTotal += earmarkBalance
          }
        }

        convertedBalances = balances
        convertedSavedAmounts = saved
        convertedSpentAmounts = spent
        convertedTotalBalance = grandTotal
      } catch {
        guard !Task.isCancelled else { return }
        logger.error("Failed to compute converted earmark totals: \(error.localizedDescription)")
      }
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-phase2-task6-pass.txt
grep -i 'failed' .agent-tmp/test-phase2-task6-pass.txt
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Features/Earmarks/EarmarkStore.swift MoolahTests/Features/EarmarkStoreTests.swift
git commit -m "feat: EarmarkStore computes per-earmark converted amounts from positions"
```

### Task 7: Remove `balance`/`saved`/`spent` from Earmark domain model

**Files:**
- Modify: `Domain/Models/Earmark.swift`
- Modify: `Backends/CloudKit/Models/EarmarkRecord.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift`
- Modify: `Backends/Remote/DTOs/EarmarkDTO.swift`

- [ ] **Step 1: Remove fields from `Earmark`**

In `Domain/Models/Earmark.swift`, remove `balance`, `saved`, `spent` from:
- The stored properties (lines 18–20)
- The init parameter list and body
- `CodingKeys` enum
- `init(from decoder:)` — remove the three decode lines
- `encode(to:)` — remove the three encode lines
- `==` operator — remove the three comparisons
- `hash(into:)` — remove the three combine calls

The init becomes:

```swift
  init(
    id: UUID = UUID(),
    name: String,
    instrument: Instrument = .AUD,
    positions: [Position] = [],
    savedPositions: [Position] = [],
    spentPositions: [Position] = [],
    isHidden: Bool = false,
    position: Int = 0,
    savingsGoal: InstrumentAmount? = nil,
    savingsStartDate: Date? = nil,
    savingsEndDate: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.instrument = instrument
    self.positions = positions
    self.savedPositions = savedPositions
    self.spentPositions = spentPositions
    self.isHidden = isHidden
    self.position = position
    self.savingsGoal = savingsGoal
    self.savingsStartDate = savingsStartDate
    self.savingsEndDate = savingsEndDate
  }
```

- [ ] **Step 2: Remove legacy sync from `Earmarks.adjustingPositions()`**

In `Domain/Models/Earmark.swift`, simplify `adjustingPositions()` to only update positions:

```swift
  func adjustingPositions(
    of earmarkId: UUID,
    positionDeltas: [Instrument: Decimal],
    savedDeltas: [Instrument: Decimal],
    spentDeltas: [Instrument: Decimal]
  ) -> Earmarks {
    guard byId[earmarkId] != nil else { return self }
    let adjusted = ordered.map { earmark in
      guard earmark.id == earmarkId else { return earmark }
      var copy = earmark
      copy.positions = copy.positions.applying(deltas: positionDeltas)
      copy.savedPositions = copy.savedPositions.applying(deltas: savedDeltas)
      copy.spentPositions = copy.spentPositions.applying(deltas: spentDeltas)
      return copy
    }
    return Earmarks(from: adjusted)
  }
```

- [ ] **Step 3: Update `EarmarkRecord.toDomain()`**

Remove `balance`, `saved`, `spent` parameters:

```swift
  func toDomain(
    defaultInstrument: Instrument,
    positions: [Position] = [], savedPositions: [Position] = [], spentPositions: [Position] = []
  ) -> Earmark {
    let instrument = instrumentId.map { Instrument.fiat(code: $0) } ?? defaultInstrument
    let savingsGoal: InstrumentAmount? = savingsTarget.flatMap { target in
      guard let instrumentId = savingsTargetInstrumentId else { return nil }
      let inst = Instrument.fiat(code: instrumentId)
      return InstrumentAmount(storageValue: target, instrument: inst)
    }
    return Earmark(
      id: id,
      name: name,
      instrument: instrument,
      positions: positions,
      savedPositions: savedPositions,
      spentPositions: spentPositions,
      isHidden: isHidden,
      position: position,
      savingsGoal: savingsGoal,
      savingsStartDate: savingsStartDate,
      savingsEndDate: savingsEndDate
    )
  }
```

- [ ] **Step 4: Update `CloudKitEarmarkRepository`**

In `CloudKitEarmarkRepository.swift`, update `fetchAll()` call to `toDomain()`:

```swift
        return record.toDomain(
          defaultInstrument: instrument,
          positions: totals.positions, savedPositions: totals.savedPositions,
          spentPositions: totals.spentPositions
        )
```

In `computeEarmarkPositions()`, remove the legacy single-instrument computation. Change return type:

```swift
  @MainActor
  private func computeEarmarkPositions(
    for earmarkId: UUID,
    instruments: [String: Instrument]
  ) throws -> (
    positions: [Position], savedPositions: [Position], spentPositions: [Position]
  ) {
```

Remove the legacy `balance`/`saved`/`spent` variables and their accumulation. Keep only `positionTotals`/`savedTotals`/`spentTotals` and the position-building code. Remove the `zero`/`balance`/`saved`/`spent`/`legacyAmount` lines. The return becomes:

```swift
    return (positions, savedPositions, spentPositions)
```

- [ ] **Step 5: Update `EarmarkDTO.toDomain()`**

In `Backends/Remote/DTOs/EarmarkDTO.swift`, update `toDomain()` — the server still sends balance/saved/spent but we ignore the values. We do need to create positions from them since the remote backend is the source of truth:

```swift
  func toDomain(instrument: Instrument) -> Earmark {
    let balanceAmount = InstrumentAmount(quantity: Decimal(balance) / 100, instrument: instrument)
    let savedAmount = InstrumentAmount(quantity: Decimal(saved) / 100, instrument: instrument)
    let spentAmount = InstrumentAmount(quantity: Decimal(spent) / 100, instrument: instrument)

    return Earmark(
      id: id.uuid,
      name: name,
      instrument: instrument,
      positions: balanceAmount.isZero ? [] : [Position(instrument: instrument, quantity: balanceAmount.quantity)],
      savedPositions: savedAmount.isZero ? [] : [Position(instrument: instrument, quantity: savedAmount.quantity)],
      spentPositions: spentAmount.isZero ? [] : [Position(instrument: instrument, quantity: spentAmount.quantity)],
      isHidden: hidden,
      position: position ?? 0,
      savingsGoal: savingsTarget.map {
        InstrumentAmount(quantity: Decimal($0) / 100, instrument: instrument)
      },
      savingsStartDate: savingsStartDate.flatMap { BackendDateFormatter.date(from: $0) },
      savingsEndDate: savingsEndDate.flatMap { BackendDateFormatter.date(from: $0) }
    )
  }
```

Update `fromDomain()` — still send balance/saved/spent to the server (it expects them). Compute from positions:

```swift
  static func fromDomain(_ earmark: Earmark) -> EarmarkDTO {
    let balanceQty = earmark.positions.reduce(Decimal.zero) { $0 + $1.quantity }
    let savedQty = earmark.savedPositions.reduce(Decimal.zero) { $0 + $1.quantity }
    let spentQty = earmark.spentPositions.reduce(Decimal.zero) { $0 + $1.quantity }

    return EarmarkDTO(
      id: ServerUUID(earmark.id),
      name: earmark.name,
      position: earmark.position,
      hidden: earmark.isHidden,
      savingsTarget: earmark.savingsGoal.map {
        Int(truncating: ($0.quantity * 100) as NSDecimalNumber)
      },
      savingsStartDate: earmark.savingsStartDate.map { BackendDateFormatter.string(from: $0) },
      savingsEndDate: earmark.savingsEndDate.map { BackendDateFormatter.string(from: $0) },
      balance: Int(truncating: (balanceQty * 100) as NSDecimalNumber),
      saved: Int(truncating: (savedQty * 100) as NSDecimalNumber),
      spent: Int(truncating: (spentQty * 100) as NSDecimalNumber)
    )
  }
```

- [ ] **Step 6: Commit**

```bash
git add Domain/ Backends/
git commit -m "refactor: remove balance/saved/spent from Earmark, use positions only"
```

### Task 8: Update views to read from EarmarkStore

**Files:**
- Modify: `Features/Earmarks/Views/EarmarksView.swift`
- Modify: `Features/Earmarks/Views/EarmarkDetailView.swift`
- Modify: `Features/Navigation/SidebarView.swift`
- Modify: `Automation/Intents/Entities/EarmarkEntity.swift`

- [ ] **Step 1: Update `SidebarView` earmark rows**

In `Features/Navigation/SidebarView.swift` line 70, change:

```swift
              SidebarRowView(
                icon: "bookmark.fill", name: earmark.name, amount: earmark.balance,
                isSelected: selection == .earmark(earmark.id))
```

To use the store's converted balance:

```swift
              SidebarRowView(
                icon: "bookmark.fill", name: earmark.name,
                amount: earmarkStore.convertedBalance(for: earmark.id),
                isSelected: selection == .earmark(earmark.id))
```

Check what `SidebarRowView` expects for `amount` — it may need to accept `InstrumentAmount?`. If so, update its signature to handle nil with a placeholder or zero.

- [ ] **Step 2: Update `EarmarksView` list**

In `Features/Earmarks/Views/EarmarksView.swift`, the list displays `earmark.balance`, `earmark.saved`, `earmark.spent`. These need to come from the store. Add `@Environment(EarmarkStore.self) private var earmarkStoreEnv` or pass the store. The store is already available as a parameter `earmarkStore`.

Line 113 — change `earmark.balance` to `earmarkStore.convertedBalance(for: earmark.id)`:

```swift
            InstrumentAmountView(amount: earmarkStore.convertedBalance(for: earmark.id) ?? .zero(instrument: earmark.instrument), font: .headline)
```

Line 118 — change `earmark.saved`:

```swift
              InstrumentAmountView(amount: earmarkStore.convertedSaved(for: earmark.id) ?? .zero(instrument: earmark.instrument), font: .caption)
```

Line 128 — change `earmark.spent`:

```swift
              InstrumentAmountView(amount: earmarkStore.convertedSpent(for: earmark.id) ?? .zero(instrument: earmark.instrument), font: .caption)
```

Line 136 — update accessibility label:

```swift
          .accessibilityLabel(
            "\(earmark.name), balance \(earmarkStore.convertedBalance(for: earmark.id)?.formatted ?? "loading")"
          )
```

- [ ] **Step 3: Update `EarmarkDetailView` overview panel**

In `Features/Earmarks/Views/EarmarkDetailView.swift`, the overview panel at line 89 uses `earmark.balance`, `earmark.saved`, `earmark.spent`. The store is already available via `@Environment(EarmarkStore.self) private var earmarkStore`.

Update the overview panel:

```swift
  private var overviewPanel: some View {
    VStack(spacing: 12) {
      HStack(spacing: 24) {
        summaryItem(label: "Balance", amount: earmarkStore.convertedBalance(for: earmark.id) ?? .zero(instrument: earmark.instrument))
        Divider().frame(maxHeight: 32)
        summaryItem(label: "Saved", amount: earmarkStore.convertedSaved(for: earmark.id) ?? .zero(instrument: earmark.instrument))
        Divider().frame(maxHeight: 32)
        summaryItem(label: "Spent", amount: earmarkStore.convertedSpent(for: earmark.id) ?? .zero(instrument: earmark.instrument))
      }
```

Update the savings goal progress calculation (lines 98–101):

```swift
      if let goal = earmark.savingsGoal, goal.isPositive {
        VStack(spacing: 4) {
          let balance = earmarkStore.convertedBalance(for: earmark.id) ?? .zero(instrument: earmark.instrument)
          let progress =
            balance.isPositive
            ? Double(truncating: (balance.quantity / goal.quantity) as NSDecimalNumber)
            : 0.0

          ProgressView(value: min(progress, 1.0)) {
            HStack {
              Text("Savings Goal")
                .font(.caption)
              Spacer()
              InstrumentAmountView(amount: balance)
                .font(.caption)
              Text("of")
                .font(.caption)
                .foregroundStyle(.secondary)
              InstrumentAmountView(amount: goal)
                .font(.caption)
            }
          }
```

- [ ] **Step 4: Update `EditEarmarkSheet` — remove "Current Values" section**

In `Features/Earmarks/Views/EarmarkFormSheet.swift`, the "Current Values" section (lines 128–138) displays `earmark.balance`, `earmark.saved`, `earmark.spent`. Since these fields no longer exist, remove this entire section. The edit sheet is for editing metadata (name, savings goal, hidden), not displaying computed balances — that's what the detail view is for.

- [ ] **Step 5: Update `EarmarkEntity`**

In `Automation/Intents/Entities/EarmarkEntity.swift`, line 20 uses `earmark.balance.doubleValue`. Since we no longer have balance, and Siri Shortcuts entities need a simple value, use zero for now (the entity is primarily for identification, not display of computed values):

```swift
  init(from earmark: Earmark) {
    self.id = earmark.id
    self.name = earmark.name
    self.balance = 0  // Balance is computed asynchronously by EarmarkStore, not available here
  }
```

- [ ] **Step 6: Build and verify**

```bash
mkdir -p .agent-tmp && just build-mac 2>&1 | tee .agent-tmp/build-phase2-task8.txt
grep -i 'error:' .agent-tmp/build-phase2-task8.txt
```

Fix any remaining compilation errors from references to removed fields.

- [ ] **Step 7: Commit**

```bash
git add Features/ Automation/
git commit -m "refactor: views read earmark amounts from EarmarkStore instead of model fields"
```

### Task 9: Update tests for Phase 2

**Files:**
- Modify: `MoolahTests/Features/EarmarkStoreTests.swift`
- Modify: `MoolahTests/Support/TestBackend.swift`

- [ ] **Step 1: Update test fixtures — remove `balance`/`saved`/`spent` from Earmark construction**

In `MoolahTests/Features/EarmarkStoreTests.swift`, tests that construct `Earmark` with `balance`/`saved`/`spent` need updating. The `seedWithTransactions` helper creates the transactions that produce positions, so we still need to tell it what amounts to create. Update `seedWithTransactions` to accept amounts directly instead of reading them from the earmark.

First, update `TestBackend.seedWithTransactions` in `MoolahTests/Support/TestBackend.swift`. The method currently reads `earmark.saved`, `earmark.spent`, and `earmark.balance` to decide what transactions to create. Change it to accept an explicit amounts parameter:

```swift
  /// Seeds earmarks along with transactions that produce the desired saved/spent/balance values.
  /// `amounts` maps earmark ID to (saved, spent) quantities. If an earmark has no entry,
  /// no transactions are created for it.
  @discardableResult
  static func seedWithTransactions(
    earmarks: [Earmark],
    amounts: [UUID: (saved: Decimal, spent: Decimal)] = [:],
    accountId: UUID,
    in container: ModelContainer,
    instrument: Instrument = .defaultTestInstrument
  ) -> [Earmark] {
    let context = ModelContext(container)
    for earmark in earmarks {
      context.insert(EarmarkRecord.from(earmark))

      let earmarkAmounts = amounts[earmark.id]
      let savedQty = earmarkAmounts?.saved ?? 0
      let spentQty = earmarkAmounts?.spent ?? 0

      // Create income transaction for saved amount
      if savedQty != 0 {
        let txnId = UUID()
        let txn = TransactionRecord(id: txnId, date: Date())
        context.insert(txn)
        let leg = TransactionLegRecord(
          transactionId: txnId,
          accountId: accountId,
          instrumentId: instrument.id,
          quantity: InstrumentAmount(quantity: savedQty, instrument: instrument).storageValue,
          type: TransactionType.income.rawValue,
          earmarkId: earmark.id,
          sortOrder: 0
        )
        context.insert(leg)
      }

      // Create expense transaction for spent amount
      if spentQty != 0 {
        let txnId = UUID()
        let txn = TransactionRecord(id: txnId, date: Date())
        context.insert(txn)
        let leg = TransactionLegRecord(
          transactionId: txnId,
          accountId: accountId,
          instrumentId: instrument.id,
          quantity: InstrumentAmount(quantity: -spentQty, instrument: instrument).storageValue,
          type: TransactionType.expense.rawValue,
          earmarkId: earmark.id,
          sortOrder: 0
        )
        context.insert(leg)
      }
    }
    try! context.save()
    return earmarks
  }
```

- [ ] **Step 2: Update all test call sites**

Update each test that uses `seedWithTransactions` to pass `amounts` instead of setting `balance`/`saved`/`spent` on the Earmark. For example, `testApplyDeltaAdjustsPositionsAndBalance`:

```swift
  @Test func testApplyDeltaAdjustsPositionsAndBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank)], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)
      ],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(repository: backend.earmarks)
    await store.load()

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )

    // Check positions instead of balance/saved/spent fields
    let earmark = store.earmarks.by(id: earmarkId)
    #expect(earmark?.positions.first?.quantity == 400)
    #expect(earmark?.spentPositions.first?.quantity == 100)
  }
```

Apply the same pattern to all other tests: `testApplyDeltaWithSavedIncreasesBalance`, `testApplyDeltaAffectsMultipleEarmarks`, `testConvertedTotalBalancePopulatedAfterLoad`, `testConvertedTotalBalanceUpdatesAfterApplyDelta`, `testPopulatesFromRepository`, `testSortingByPosition`, `hiddenEarmarksExcluded`, `hiddenEarmarksIncluded`.

For simpler tests that only used balance for seeding (like `testPopulatesFromRepository`), pass amounts:

```swift
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(name: "Holiday Fund", instrument: instrument)],
      amounts: [earmark.id: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
```

Tests that construct earmarks with only a name and no balance (reorder tests, create tests) need no changes since they use `seed(earmarks:)` not `seedWithTransactions`.

- [ ] **Step 3: Update applyDelta assertions**

Change all assertions from `earmark?.balance.quantity` to checking positions or store-computed amounts:

```swift
    // Instead of:
    #expect(store.earmarks.by(id: earmarkId)?.balance.quantity == 400)
    // Use:
    #expect(store.earmarks.by(id: earmarkId)?.positions.first?.quantity == 400)
```

- [ ] **Step 4: Run tests**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-phase2.txt
grep -i 'failed\|error:' .agent-tmp/test-phase2.txt
```

- [ ] **Step 5: Fix any test failures and re-run**

- [ ] **Step 6: Commit**

```bash
git add MoolahTests/
git commit -m "test: update earmark tests to use positions instead of legacy balance fields"
```

### Task 10: Phase 2 verification and cleanup

- [ ] **Step 1: Search for any remaining references to removed fields**

```bash
grep -rn 'earmark\.balance\|earmark\.saved\|earmark\.spent\|\.balance\.instrument' --include='*.swift' Features/ Shared/ Backends/ Automation/ Domain/ MoolahTests/ | grep -v '\.md'
```

Fix any remaining references.

- [ ] **Step 2: Update previews**

Check and update any `#Preview` blocks that construct `Earmark` with `balance`/`saved`/`spent`. Key files:
- `Features/Earmarks/Views/EarmarkDetailView.swift` (lines 195–203)
- `Features/Navigation/SidebarView.swift` (lines 275–277)

These previews will need to construct earmarks without balance/saved/spent. The preview won't show correct amounts unless the preview backend seeds transactions — but for visual previews that's acceptable.

- [ ] **Step 3: Check for compiler warnings**

```bash
mkdir -p .agent-tmp && just build-mac 2>&1 | grep -i warning | grep -v '#Preview' | tee .agent-tmp/warnings-final.txt
```

Fix any warnings.

- [ ] **Step 4: Run full test suite**

```bash
mkdir -p .agent-tmp && just test 2>&1 | tee .agent-tmp/test-final.txt
grep -c 'Test run completed' .agent-tmp/test-final.txt
grep -i 'failed' .agent-tmp/test-final.txt
```

Expected: All tests pass, zero failures.

- [ ] **Step 5: Clean up temp files**

```bash
rm -rf .agent-tmp/*.txt
```

- [ ] **Step 6: Final commit if any cleanup changes were made**

```bash
git add -A
git commit -m "chore: final cleanup for earmark instrument field refactor"
```
