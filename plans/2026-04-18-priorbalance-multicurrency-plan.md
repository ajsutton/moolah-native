# Fix priorBalance for Multi-Currency Accounts (#50) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `CloudKitTransactionRepository.fetch`'s `priorBalance` so it produces correct values for accounts whose legs mix instruments (trading, crypto), while preserving the existing fast-path (no per-leg `toDomain`).

**Architecture:** Group raw `Int64` leg storage values by `instrumentId` inside the SwiftData/MainActor block, then convert each per-instrument subtotal to the account's instrument using the current date (`Date()`) via `conversionService`. On any conversion failure, set `priorBalance` to `nil` and log via `os.Logger`; `Transaction.withRunningBalances` already tolerates a missing prior-balance start and will show every running-balance cell as unavailable.

`TransactionPage` gains a new non-optional `targetInstrument: Instrument` field (the account's instrument for account-scoped fetches, profile instrument otherwise). `priorBalance` becomes `InstrumentAmount?`. Downstream (`TransactionStore`) adopts `targetInstrument` unconditionally and uses `priorBalance` only when present.

**Tech Stack:** Swift 6 / SwiftData / CloudKit, Swift Testing (`@Suite` / `@Test`), XCTest for benchmarks, `os.Logger`, `just` targets for test/build.

**Why this shape:**
- Reduction stays O(legs) on raw `Int64` — no per-leg Decimal, no per-leg `resolveInstrument`, no per-leg await. Fast path preserved.
- Conversion calls are O(unique instruments on the account) — typically 1-5. Each rate lookup is cached after the first hit.
- `Date()` matches Rule 6 of `guides/INSTRUMENT_CONVERSION_GUIDE.md` (current-value reads) — this IS a "present-day value of the account" figure.
- Graceful degradation for rate outages: the transaction list still renders; only the running-balance column disappears.

---

## Context the engineer needs

- **Where the bug lives:** `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` lines 225-241. The comment on line 220 (`"legs of an account share its instrument"`) is **false** — `Shared/Models/TradeDraft.swift` and `Shared/Models/TokenSwapDraft.swift` both emit multi-instrument legs on the same accountId.
- **Performance budget:** guarded by `MoolahBenchmarks/BalanceBenchmarks.swift::testFetchHeavyAccountPriorBalance`. Single-instrument accounts should see essentially no change (one conversion call, same-instrument shortcut). Multi-instrument accounts pay O(unique instruments) cached rate lookups.
- **Downstream chain:** `TransactionPage.priorBalance` → `TransactionStore.priorBalance` → `Transaction.withRunningBalances(priorBalance:)`. `withRunningBalances` already handles per-transaction conversion failures by setting `balance = nil` from that point; we're extending the same pattern to "priorBalance unavailable."
- **Instrument flow today:** `TransactionStore.fetchPage` adopts `page.priorBalance.instrument` as `currentTargetInstrument` on the first page load (`TransactionStore.swift:252-254`). Because `priorBalance` is going optional, the instrument must come from a separate non-optional field.
- **Rule 11 of the conversion guide** requires failures to be logged via `os.Logger` and surfaced to the user. Today `priorBalance` is silently wrong; this plan adds the logger and makes "unavailable" a first-class state that the view can detect (`priorBalance == nil`).
- **Remote backend is unaffected semantically.** The server still ships `priorBalance` as an `Int` of cents and we still treat it as non-nil from that source. Only the shape of `TransactionPage` changes (optional + new targetInstrument field).

## File Structure

Files created: none.

Files modified:
- `Domain/Models/Transaction.swift` — `TransactionPage` (add `targetInstrument`, make `priorBalance` optional); `withRunningBalances` (accept optional `priorBalance`, treat nil as "balance unavailable from start").
- `Backends/CloudKit/CloudKitBackend.swift` — pass `conversionService` to `CloudKitTransactionRepository`.
- `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` — accept `conversionService` in init, add `os.Logger`, rewrite `priorBalance` calculation and populate `targetInstrument`.
- `Backends/Remote/Repositories/RemoteTransactionRepository.swift` — populate `targetInstrument` on returned `TransactionPage`.
- `Features/Transactions/TransactionStore.swift` — adopt `page.targetInstrument` for `currentTargetInstrument`; handle optional `priorBalance`.
- `MoolahTests/Domain/TransactionRepositoryContractTests.swift` — update `makeCloudKitTransactionRepository` helper; add multi-instrument tests; update existing tests for optional `priorBalance`.
- `MoolahTests/Backends/RemoteTransactionRepositoryTests.swift` — update priorBalance assertions for optionality.
- `MoolahTests/Domain/TransactionRunningBalanceTests.swift` — update for optional signature.

---

## Task 1: Extend `TransactionPage` shape (breaking API change)

**Files:**
- Modify: `Domain/Models/Transaction.swift:248-345`
- Modify: `Backends/Remote/Repositories/RemoteTransactionRepository.swift:56-61`
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:192-245`
- Modify: `Features/Transactions/TransactionStore.swift:36, 60, 247-254, 339-353`
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift:225-284`
- Modify: `MoolahTests/Backends/RemoteTransactionRepositoryTests.swift:82, 114, 150, 183, 222, 261`
- Modify: `MoolahTests/Domain/TransactionRunningBalanceTests.swift:51, 72, 105, 136`

- [ ] **Step 1.1: Change `TransactionPage` fields.**

In `Domain/Models/Transaction.swift`, replace the `TransactionPage` struct's stored properties (around line 248-251) so `priorBalance` is optional and a new non-optional `targetInstrument` is added:

```swift
struct TransactionPage: Sendable {
  let transactions: [Transaction]
  /// The instrument in which the running balance column should be displayed for
  /// this fetch. For account-scoped fetches this is the account's own instrument;
  /// for global fetches it's the profile instrument. Always populated — even when
  /// `priorBalance` is `nil` due to a conversion failure.
  let targetInstrument: Instrument
  /// Account balance before the oldest transaction in `transactions`. `nil` when
  /// the repository could not compute it (e.g. exchange-rate lookup failed). The
  /// transactions themselves are still returned so the list renders; running
  /// balances are just unavailable.
  let priorBalance: InstrumentAmount?
  let totalCount: Int?
}
```

- [ ] **Step 1.2: Relax `withRunningBalances` to accept an optional `priorBalance`.**

In the same file, change the signature and the initialisation of `balance`:

```swift
static func withRunningBalances(
  transactions: [Transaction],
  priorBalance: InstrumentAmount?,
  accountId: UUID?,
  earmarkId: UUID? = nil,
  targetInstrument: Instrument,
  conversionService: InstrumentConversionService
) async -> [TransactionWithBalance] {
  var balance: InstrumentAmount? = priorBalance
  // ... rest unchanged
```

A `nil` `priorBalance` already cascades correctly through the existing `if let displayAmount, var runningBalance = balance` guard — every transaction will get `balance == nil`, which matches "running total unknown from the start."

- [ ] **Step 1.3: Populate `targetInstrument` in `RemoteTransactionRepository`.**

In `Backends/Remote/Repositories/RemoteTransactionRepository.swift` replace lines 56-61 with:

```swift
return TransactionPage(
  transactions: wrapper.transactions.map { $0.toDomain(instrument: self.instrument) },
  targetInstrument: self.instrument,
  priorBalance: InstrumentAmount(
    quantity: Decimal(wrapper.priorBalance) / 100, instrument: self.instrument),
  totalCount: wrapper.totalNumberOfTransactions
)
```

- [ ] **Step 1.4: Populate `targetInstrument` in `CloudKitTransactionRepository` (no behaviour change yet).**

In `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`, update the two `TransactionPage(...)` returns inside `fetch(...)`:

First the empty-page return (around line 196-206). Replace with:

```swift
let emptyInstrument: Instrument
if let filterAccountId = filter.accountId {
  emptyInstrument = (try? accountInstrument(id: filterAccountId)) ?? self.instrument
} else {
  emptyInstrument = self.instrument
}
return TransactionPage(
  transactions: [],
  targetInstrument: emptyInstrument,
  priorBalance: InstrumentAmount.zero(instrument: emptyInstrument),
  totalCount: filteredRecords.count)
```

Then the normal return (around line 244-245). The existing code already computes `priorBalance` in the account's instrument (even though wrongly for mixed-instrument accounts — we'll fix that in Task 4). For now:

```swift
let resolvedTarget: Instrument
if let filterAccountId = filter.accountId {
  resolvedTarget = (try? accountInstrument(id: filterAccountId)) ?? self.instrument
} else {
  resolvedTarget = self.instrument
}
return TransactionPage(
  transactions: pageTransactions,
  targetInstrument: resolvedTarget,
  priorBalance: priorBalance,
  totalCount: totalCount)
```

(The `accountInstrument(id:)` call is cheap — it's cached and it's also the same call the existing code at line 236 is making. A small duplication is acceptable here; it collapses in Task 4.)

- [ ] **Step 1.5: Update `TransactionStore` to read from `targetInstrument` and handle optional `priorBalance`.**

In `Features/Transactions/TransactionStore.swift`:

Change the stored property (line 36):

```swift
private var priorBalance: InstrumentAmount? = nil
```

In `load(filter:)` (line 60), update the reset:

```swift
priorBalance = nil
```

In `fetchPage()` (lines 247-254), replace with:

```swift
rawTransactions.append(contentsOf: page.transactions)
priorBalance = page.priorBalance
// Adopt the repository's target instrument for the display currency. For
// single-account views the repo reports the account's instrument so native
// legs never need conversion; for global views it's the profile instrument.
// Only changes on the first page load.
if currentPage == 0 {
  currentTargetInstrument = page.targetInstrument
}
```

In `recomputeBalances()` (lines 345-352), the call to `withRunningBalances(...)` now passes an optional priorBalance — the signature change in Step 1.2 already accepts it, so the call site needs no change beyond confirming it compiles.

- [ ] **Step 1.6: Update existing contract test assertions for optional `priorBalance`.**

In `MoolahTests/Domain/TransactionRepositoryContractTests.swift`:

Around line 225-229 (`testPriorBalanceAcrossPages`), the arithmetic currently treats `priorBalance` as non-optional. Unwrap it:

```swift
let page1Prior = try #require(page1.priorBalance)
let page0Prior = try #require(page0.priorBalance)
let page1PriorSum = page1Sum + page1Prior

#expect(
  page0Prior == page1PriorSum,
  "priorBalance of page 0 should equal sum of all older transactions")
```

Around line 232-244 (`testEmptyPagePriorBalance`):

```swift
#expect(page.transactions.isEmpty)
#expect(page.priorBalance?.isZero == true)
```

Around line 246-285 (`testPriorBalanceUsesAccountInstrument`), replace the two assertions about `page.priorBalance.instrument` with assertions against `page.targetInstrument`:

```swift
#expect(page0.targetInstrument == accountInstrument)
// ...
#expect(pageN.targetInstrument == accountInstrument)
```

- [ ] **Step 1.7: Update `RemoteTransactionRepositoryTests` for optional.**

In `MoolahTests/Backends/RemoteTransactionRepositoryTests.swift`, there are assertions like `#expect(page.priorBalance == .zero(instrument: .defaultTestInstrument))` (around line 82). Change each such assertion to:

```swift
#expect(page.priorBalance == .zero(instrument: .defaultTestInstrument))
```

If the direct equality against an optional doesn't compile, wrap in `#require`:

```swift
let prior = try #require(page.priorBalance)
#expect(prior == .zero(instrument: .defaultTestInstrument))
```

Apply the same change to each of lines 82, 114 (fixture JSON), 150, 183, 222, 261. (The fixture JSON still emits `"priorBalance": 0` — no fixture change needed; `RemoteTransactionRepository` always produces a non-nil value from the DTO.)

- [ ] **Step 1.8: Update `TransactionRunningBalanceTests` for the optional parameter.**

In `MoolahTests/Domain/TransactionRunningBalanceTests.swift` (lines 51, 72, 105, 136), the existing `priorBalance: .zero(instrument: target)` still compiles because `.zero(...)` returns a non-optional that implicitly lifts to `Optional`. No change needed. Verify by compilation.

- [ ] **Step 1.9: Build and run tests.**

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/task1-test.txt
grep -iE 'failed|error:' .agent-tmp/task1-test.txt | head -40
```

Expected: all tests pass (this task is a pure refactor; behaviour unchanged).

- [ ] **Step 1.10: Commit.**

```bash
git add Domain/Models/Transaction.swift \
  Backends/Remote/Repositories/RemoteTransactionRepository.swift \
  Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift \
  Features/Transactions/TransactionStore.swift \
  MoolahTests/Domain/TransactionRepositoryContractTests.swift \
  MoolahTests/Backends/RemoteTransactionRepositoryTests.swift
rm .agent-tmp/task1-test.txt
git commit -m "$(cat <<'EOF'
refactor: make TransactionPage.priorBalance optional, add targetInstrument

Preparatory change for #50. Running-balance display will need a "balance
unavailable" state when rate lookups fail, and the target instrument must
travel separately since it's always known even when the balance isn't.

- TransactionPage.priorBalance: InstrumentAmount?
- TransactionPage.targetInstrument: Instrument (new, always populated)
- TransactionStore.currentTargetInstrument adopts page.targetInstrument
- withRunningBalances accepts optional priorBalance; nil cascades to every
  row's balance as the existing per-transaction failure path already does

Pure refactor, no behaviour change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire `conversionService` into `CloudKitTransactionRepository`

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:5-15`
- Modify: `Backends/CloudKit/CloudKitBackend.swift:23-24`
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift:802-822`

- [ ] **Step 2.1: Add `conversionService` init parameter and stored property.**

In `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`, update the class header and init (lines 5-15):

```swift
final class CloudKitTransactionRepository: TransactionRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let instrument: Instrument
  private let conversionService: any InstrumentConversionService
  private let logger = Logger(subsystem: "com.moolah.app", category: "CloudKitTransactionRepository")
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }
  var onInstrumentChanged: (String) -> Void = { _ in }

  init(
    modelContainer: ModelContainer,
    instrument: Instrument,
    conversionService: any InstrumentConversionService
  ) {
    self.modelContainer = modelContainer
    self.instrument = instrument
    self.conversionService = conversionService
  }
```

Also add `import OSLog` at the top of the file if it isn't already there.

- [ ] **Step 2.2: Pass `conversionService` from `CloudKitBackend`.**

In `Backends/CloudKit/CloudKitBackend.swift` replace lines 23-24:

```swift
self.transactions = CloudKitTransactionRepository(
  modelContainer: modelContainer,
  instrument: instrument,
  conversionService: conversionService)
```

- [ ] **Step 2.3: Update `makeCloudKitTransactionRepository` helper in tests.**

In `MoolahTests/Domain/TransactionRepositoryContractTests.swift` around line 802-822, rewrite the helper so it builds a fresh `FiatConversionService` matching `TestBackend.create`:

```swift
private func makeCloudKitTransactionRepository(
  initialTransactions: [Transaction] = [],
  instrument: Instrument = .defaultTestInstrument,
  exchangeRates: [String: [String: Decimal]] = [:]
) -> CloudKitTransactionRepository {
  let container = try! TestModelContainer.create()
  let rateClient = FixedRateClient(rates: exchangeRates)
  let cacheDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("test-rates-\(UUID().uuidString)")
  let exchangeRateService = ExchangeRateService(client: rateClient, cacheDirectory: cacheDir)
  let conversionService = FiatConversionService(exchangeRates: exchangeRateService)
  let repo = CloudKitTransactionRepository(
    modelContainer: container,
    instrument: instrument,
    conversionService: conversionService)

  if !initialTransactions.isEmpty {
    let context = ModelContext(container)
    for txn in initialTransactions {
      context.insert(TransactionRecord.from(txn))
      for (index, leg) in txn.legs.enumerated() {
        context.insert(TransactionLegRecord.from(leg, transactionId: txn.id, sortOrder: index))
      }
    }
    try! context.save()
  }

  return repo
}
```

- [ ] **Step 2.4: Build and run tests.**

```bash
just test 2>&1 | tee .agent-tmp/task2-test.txt
grep -iE 'failed|error:' .agent-tmp/task2-test.txt | head -40
```

Expected: all tests pass (plumbing change only).

- [ ] **Step 2.5: Commit.**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift \
  Backends/CloudKit/CloudKitBackend.swift \
  MoolahTests/Domain/TransactionRepositoryContractTests.swift
rm .agent-tmp/task2-test.txt
git commit -m "$(cat <<'EOF'
refactor: thread conversionService into CloudKitTransactionRepository

Wiring change for #50. The priorBalance calculation will need to convert
per-instrument subtotals to the account's instrument at today's rate.

Matches the pattern already used by CloudKitAnalysisRepository.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add failing contract tests for multi-instrument priorBalance

**Files:**
- Modify: `MoolahTests/Domain/TransactionRepositoryContractTests.swift` (append new tests near the existing priorBalance tests, ~line 285)

- [ ] **Step 3.1: Add test for multi-instrument account with successful conversion.**

Append to the `TransactionRepositoryContractTests` suite in `MoolahTests/Domain/TransactionRepositoryContractTests.swift`:

```swift
  @Test("priorBalance converts multi-instrument legs to account instrument at today's rate")
  func testPriorBalanceMultiInstrumentConverts() async throws {
    // Account is AUD. Historic transactions left three legs behind (one still
    // in a different instrument) — a trade-style split.
    let accountInstrument = Instrument.AUD
    let foreignInstrument = Instrument.USD
    let accountId = UUID()

    // USD -> AUD at 1.5 today.
    let rates: [String: [String: Decimal]] = [
      "USD": ["AUD": Decimal(string: "1.5")!]
    ]
    let (backend, container) = try TestBackend.create(
      instrument: accountInstrument, exchangeRates: rates)
    let account = Account(
      id: accountId, name: "Brokerage", type: .bank, instrument: accountInstrument)
    TestBackend.seed(
      accounts: [(account, InstrumentAmount.zero(instrument: accountInstrument))],
      in: container)

    // Two older transactions (will be on page 1, contributing to priorBalance).
    // tx1: AUD +100 (cash deposit)
    let tx1 = Transaction(
      date: Date(timeIntervalSince1970: 1_000_000),
      payee: "Cash in",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(100), type: .income)
      ])
    // tx2: USD +20 (foreign cash in — will be converted @ 1.5 = +30 AUD today)
    let tx2 = Transaction(
      date: Date(timeIntervalSince1970: 1_000_001),
      payee: "Foreign in",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: foreignInstrument,
          quantity: Decimal(20), type: .income)
      ])
    // tx3 (newest): a single page-0 entry so priorBalance covers tx1+tx2.
    let tx3 = Transaction(
      date: Date(timeIntervalSince1970: 2_000_000),
      payee: "Today",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(5), type: .income)
      ])
    TestBackend.seed(transactions: [tx1, tx2, tx3], in: container)

    // pageSize: 1 => page 0 has only tx3; priorBalance = tx1 + tx2(USD->AUD).
    let page0 = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 1)

    let prior = try #require(page0.priorBalance)
    #expect(prior.instrument == accountInstrument)
    // 100 AUD + 20 USD @ 1.5 = 130 AUD.
    #expect(prior == InstrumentAmount(quantity: Decimal(130), instrument: accountInstrument))
    #expect(page0.targetInstrument == accountInstrument)
  }
```

- [ ] **Step 3.2: Add test for conversion failure producing nil `priorBalance`.**

```swift
  @Test("priorBalance is nil when conversion fails for any foreign leg")
  func testPriorBalanceNilOnConversionFailure() async throws {
    // Account AUD; historic leg is in an unsupported pair (no rate provided).
    let accountInstrument = Instrument.AUD
    let foreignInstrument = Instrument.USD
    let accountId = UUID()
    // Empty rate table => USD->AUD lookup fails.
    let (backend, container) = try TestBackend.create(
      instrument: accountInstrument, exchangeRates: [:])
    let account = Account(
      id: accountId, name: "Brokerage", type: .bank, instrument: accountInstrument)
    TestBackend.seed(
      accounts: [(account, InstrumentAmount.zero(instrument: accountInstrument))],
      in: container)

    let tx1 = Transaction(
      date: Date(timeIntervalSince1970: 1_000_000),
      payee: "Foreign in",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: foreignInstrument,
          quantity: Decimal(20), type: .income)
      ])
    let tx2 = Transaction(
      date: Date(timeIntervalSince1970: 2_000_000),
      payee: "Today",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(5), type: .income)
      ])
    TestBackend.seed(transactions: [tx1, tx2], in: container)

    let page0 = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 1)

    #expect(page0.priorBalance == nil, "conversion failure should null the prior balance")
    #expect(page0.targetInstrument == accountInstrument)
    // Transactions still flow through — failure degrades gracefully.
    #expect(page0.transactions.count == 1)
  }
```

- [ ] **Step 3.3: Add test for single-instrument account (no conversion needed).**

```swift
  @Test("priorBalance skips conversion when all legs share the account instrument")
  func testPriorBalanceSingleInstrumentNoConversionNeeded() async throws {
    // Empty rate table: if conversion were invoked it would throw. Test asserts
    // the same-instrument short-circuit keeps working.
    let accountInstrument = Instrument.AUD
    let accountId = UUID()
    let (backend, container) = try TestBackend.create(
      instrument: accountInstrument, exchangeRates: [:])
    let account = Account(
      id: accountId, name: "Bank", type: .bank, instrument: accountInstrument)
    TestBackend.seed(
      accounts: [(account, InstrumentAmount.zero(instrument: accountInstrument))],
      in: container)

    let tx1 = Transaction(
      date: Date(timeIntervalSince1970: 1_000_000),
      payee: "Older",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(50), type: .income)
      ])
    let tx2 = Transaction(
      date: Date(timeIntervalSince1970: 2_000_000),
      payee: "Newer",
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: accountInstrument,
          quantity: Decimal(25), type: .income)
      ])
    TestBackend.seed(transactions: [tx1, tx2], in: container)

    let page0 = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 1)

    let prior = try #require(page0.priorBalance)
    #expect(prior == InstrumentAmount(quantity: Decimal(50), instrument: accountInstrument))
  }
```

- [ ] **Step 3.4: Run the new tests and confirm they fail in the expected ways.**

```bash
just test TransactionRepositoryContractTests 2>&1 | tee .agent-tmp/task3-red.txt
```

Expected failures:
- `testPriorBalanceMultiInstrumentConverts` — expected 130 AUD, actual something incoherent (the current code sums raw storage values).
- `testPriorBalanceNilOnConversionFailure` — current code returns a non-nil priorBalance.
- `testPriorBalanceSingleInstrumentNoConversionNeeded` — **this one may already pass** (no conversion is invoked today) — that's fine; the assertion is still a valuable guard against future regression when the new code is added.

- [ ] **Step 3.5: Commit the red tests.**

```bash
git add MoolahTests/Domain/TransactionRepositoryContractTests.swift
rm .agent-tmp/task3-red.txt
git commit -m "$(cat <<'EOF'
test: add failing contract tests for multi-instrument priorBalance

Encodes the behaviour to be delivered in the next commit for #50:
- Multi-instrument account converts each subtotal to account instrument
  at today's rate and sums.
- Conversion failure degrades to nil priorBalance (not garbage).
- Single-instrument accounts skip conversion entirely.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Implement the multi-instrument fast-path in `CloudKitTransactionRepository.fetch`

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift:192-245`

- [ ] **Step 4.1: Replace the `priorBalance` block with per-instrument subtotals + async conversion.**

In `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`, replace the existing `fetch(...)` body's section starting at the empty-page guard (~line 192) through the final `return TransactionPage(...)` (~line 246). Keep everything **above** line 192 (descriptor building, sort, pageRecords slice, `fetch.toDomain` signpost block) unchanged.

The replacement:

```swift
      // --- Paginate ---
      let offset = page * pageSize
      let resolvedTarget: Instrument
      if let filterAccountId = filter.accountId {
        resolvedTarget = (try? accountInstrument(id: filterAccountId)) ?? self.instrument
      } else {
        resolvedTarget = self.instrument
      }

      guard offset < filteredRecords.count else {
        return TransactionPage(
          transactions: [],
          targetInstrument: resolvedTarget,
          priorBalance: InstrumentAmount.zero(instrument: resolvedTarget),
          totalCount: filteredRecords.count)
      }
      let totalCount = filteredRecords.count
      let end = min(offset + pageSize, totalCount)
      let pageRecords = filteredRecords[offset..<end]

      // Convert only the page slice to domain objects (avoid toDomain() on entire dataset)
      os_signpost(.begin, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)
      let pageTransactions = try pageRecords.map { record in
        let legs = try fetchLegs(for: record.id)
        return record.toDomain(legs: legs)
      }
      os_signpost(.end, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)

      // priorBalance: group raw leg storage values by instrument (fast path —
      // no per-leg toDomain / Decimal / conversion). Conversion to the account
      // instrument happens outside MainActor at today's rate (Rule 6 of
      // guides/INSTRUMENT_CONVERSION_GUIDE.md): "present-day value of the
      // account, ignoring older transactions' historical rates."
      os_signpost(
        .begin, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)
      let subtotalsToConvert: [(instrument: Instrument, amount: InstrumentAmount)]?
      if let filterAccountId = filter.accountId {
        let afterPageRecordIds = Set(filteredRecords[end...].map(\.id))
        let aid = filterAccountId
        let legDescriptor = FetchDescriptor<TransactionLegRecord>(
          predicate: #Predicate { $0.accountId == aid }
        )
        let allAccountLegs = try context.fetch(legDescriptor)
        var subtotalsById: [String: Int64] = [:]
        for leg in allAccountLegs where afterPageRecordIds.contains(leg.transactionId) {
          subtotalsById[leg.instrumentId, default: 0] += leg.quantity
        }
        subtotalsToConvert = try subtotalsById.map { (instrumentId, storageValue) in
          let instrument = try resolveInstrument(id: instrumentId)
          return (
            instrument: instrument,
            amount: InstrumentAmount(storageValue: storageValue, instrument: instrument))
        }
      } else {
        subtotalsToConvert = nil
      }
      os_signpost(.end, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)

      return (
        pageTransactions: pageTransactions,
        subtotalsToConvert: subtotalsToConvert,
        resolvedTarget: resolvedTarget,
        totalCount: totalCount)
    }

    // `MainActor.run` above returned the pre-conversion payload. Conversion
    // happens here so we don't block the main actor on async rate lookups.
    let pageTransactions = fetchResult.pageTransactions
    let resolvedTarget = fetchResult.resolvedTarget
    let totalCount = fetchResult.totalCount

    let priorBalance: InstrumentAmount?
    if let subtotals = fetchResult.subtotalsToConvert {
      priorBalance = await convertSubtotals(subtotals, to: resolvedTarget)
    } else {
      priorBalance = InstrumentAmount.zero(instrument: resolvedTarget)
    }

    return TransactionPage(
      transactions: pageTransactions,
      targetInstrument: resolvedTarget,
      priorBalance: priorBalance,
      totalCount: totalCount)
  }
```

This requires `fetch(...)` to receive a typed return value from `try await MainActor.run { ... }`. The current function wraps the work in `try await MainActor.run { ... }` and returns a `TransactionPage`. Change it to return a tuple from `MainActor.run`, then do conversion outside. The empty-page return inside `MainActor.run` must match the tuple shape:

```swift
guard offset < filteredRecords.count else {
  return (
    pageTransactions: [],
    subtotalsToConvert: Optional<[(instrument: Instrument, amount: InstrumentAmount)]>.none,
    resolvedTarget: resolvedTarget,
    totalCount: filteredRecords.count)
}
```

…and the caller branches on `subtotalsToConvert == nil` vs. `nil` tuple case. Concretely — the empty-page fast exit after the guard should still produce a `TransactionPage` with `priorBalance == .zero(instrument: resolvedTarget)` (no conversion needed for an empty account-scoped result). The final return statement uses whichever priorBalance was computed.

**Adjusted final structure for `fetch`:**

```swift
func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
  let signpostID = OSSignpostID(log: Signposts.repository)
  os_signpost(.begin, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
  defer {
    os_signpost(.end, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
  }

  struct FetchResult {
    let pageTransactions: [Transaction]
    let subtotalsToConvert: [(instrument: Instrument, amount: InstrumentAmount)]?
    let resolvedTarget: Instrument
    let totalCount: Int?
    let isEmpty: Bool
  }

  let fetchResult: FetchResult = try await MainActor.run {
    // ... existing descriptor + sort + post-filter logic unchanged ...

    let offset = page * pageSize
    let resolvedTarget: Instrument
    if let filterAccountId = filter.accountId {
      resolvedTarget = (try? accountInstrument(id: filterAccountId)) ?? self.instrument
    } else {
      resolvedTarget = self.instrument
    }

    guard offset < filteredRecords.count else {
      return FetchResult(
        pageTransactions: [],
        subtotalsToConvert: nil,
        resolvedTarget: resolvedTarget,
        totalCount: filteredRecords.count,
        isEmpty: true)
    }

    let totalCount = filteredRecords.count
    let end = min(offset + pageSize, totalCount)
    let pageRecords = filteredRecords[offset..<end]

    os_signpost(.begin, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)
    let pageTransactions = try pageRecords.map { record in
      let legs = try fetchLegs(for: record.id)
      return record.toDomain(legs: legs)
    }
    os_signpost(.end, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)

    os_signpost(.begin, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)
    let subtotalsToConvert: [(instrument: Instrument, amount: InstrumentAmount)]?
    if let filterAccountId = filter.accountId {
      let afterPageRecordIds = Set(filteredRecords[end...].map(\.id))
      let aid = filterAccountId
      let legDescriptor = FetchDescriptor<TransactionLegRecord>(
        predicate: #Predicate { $0.accountId == aid })
      let allAccountLegs = try context.fetch(legDescriptor)
      var subtotalsById: [String: Int64] = [:]
      for leg in allAccountLegs where afterPageRecordIds.contains(leg.transactionId) {
        subtotalsById[leg.instrumentId, default: 0] += leg.quantity
      }
      subtotalsToConvert = try subtotalsById.map { (instrumentId, storageValue) in
        let instrument = try resolveInstrument(id: instrumentId)
        return (
          instrument: instrument,
          amount: InstrumentAmount(storageValue: storageValue, instrument: instrument))
      }
    } else {
      subtotalsToConvert = nil
    }
    os_signpost(.end, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)

    return FetchResult(
      pageTransactions: pageTransactions,
      subtotalsToConvert: subtotalsToConvert,
      resolvedTarget: resolvedTarget,
      totalCount: totalCount,
      isEmpty: false)
  }

  let priorBalance: InstrumentAmount?
  if fetchResult.isEmpty {
    priorBalance = InstrumentAmount.zero(instrument: fetchResult.resolvedTarget)
  } else if let subtotals = fetchResult.subtotalsToConvert {
    priorBalance = await convertSubtotals(
      subtotals, to: fetchResult.resolvedTarget)
  } else {
    // No account filter: no running balance applicable; zero in profile instrument.
    priorBalance = InstrumentAmount.zero(instrument: fetchResult.resolvedTarget)
  }

  return TransactionPage(
    transactions: fetchResult.pageTransactions,
    targetInstrument: fetchResult.resolvedTarget,
    priorBalance: priorBalance,
    totalCount: fetchResult.totalCount)
}
```

Note: `FetchResult`'s tuple element type is not `Sendable` by default. If the Swift compiler complains about crossing the `MainActor.run` boundary, change the tuple member to a concrete nested `Sendable` struct. Declare at file scope or make `FetchResult` conform to `Sendable` and ensure every contained type is `Sendable` (`Instrument`, `InstrumentAmount`, `Transaction` already are). If inference fights you, just spell it out: `struct FetchResult: @unchecked Sendable { ... }` is acceptable because everything inside is value-type `Sendable`.

- [ ] **Step 4.2: Add the `convertSubtotals` helper.**

Add as a private instance method on `CloudKitTransactionRepository`:

```swift
  /// Converts a list of per-instrument subtotals to a single amount in
  /// `target` using today's exchange rate. Returns `nil` on any conversion
  /// failure and logs via `os.Logger` (Rule 11 of
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md`).
  private func convertSubtotals(
    _ subtotals: [(instrument: Instrument, amount: InstrumentAmount)],
    to target: Instrument
  ) async -> InstrumentAmount? {
    var total = InstrumentAmount.zero(instrument: target)
    let today = Date()
    for (instrument, amount) in subtotals {
      if instrument == target {
        total += amount
        continue
      }
      do {
        let converted = try await conversionService.convertAmount(
          amount, to: target, on: today)
        total += converted
      } catch {
        logger.warning(
          "priorBalance conversion failed for \(instrument.id, privacy: .public) -> \(target.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return nil
      }
    }
    return total
  }
```

- [ ] **Step 4.3: Remove the now-obsolete comment about shared-instrument legs.**

Search for and delete lines 220-221's original comment block ("Account balances are tracked in the account's own instrument (legs of an account share its instrument), not the profile instrument."). The new code block already has a correct comment (see Step 4.1).

- [ ] **Step 4.4: Build and run the full test suite.**

```bash
just test 2>&1 | tee .agent-tmp/task4-test.txt
grep -iE 'failed|error:' .agent-tmp/task4-test.txt | head -60
```

Expected: all tests pass, including the three added in Task 3.

If the `MainActor.run` return type causes Sendable complaints, adjust per the note at the end of Step 4.1.

- [ ] **Step 4.5: Commit.**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
rm .agent-tmp/task4-test.txt
git commit -m "$(cat <<'EOF'
fix: convert multi-instrument priorBalance at today's rate (closes #50)

Previously `fetch` summed raw Int64 storage across every leg of an account
regardless of instrument, producing nonsense prior balances for trading
and crypto accounts (which have multi-instrument legs on one accountId via
TradeDraft / TokenSwapDraft).

Now the fast path groups leg storage values by instrument inside the
MainActor/SwiftData block (still O(legs) on Int64, no per-leg toDomain),
then converts each per-instrument subtotal to the account's instrument
using today's rate outside MainActor — O(unique instruments) conversion
calls, typically 1-5.

On any conversion failure, priorBalance becomes nil and the failure is
logged via os.Logger (Rule 11). TransactionStore / withRunningBalances
already degrade gracefully: transactions still render; running-balance
column shows as unavailable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Build validation and final checks

- [ ] **Step 5.1: Clean build for both platforms.**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
grep -iE 'warning:|error:' .agent-tmp/build-mac.txt | head -20
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
grep -iE 'warning:|error:' .agent-tmp/build-ios.txt | head -20
```

Expected: no user-code warnings, no errors. Preview-macro warnings from `#Preview` are acceptable per CLAUDE.md.

- [ ] **Step 5.2: Full test sweep.**

```bash
just test 2>&1 | tee .agent-tmp/task5-test.txt
grep -iE 'failed|error:' .agent-tmp/task5-test.txt | head -20
```

Expected: 0 failures.

- [ ] **Step 5.3: Concurrency review.**

Run the `concurrency-review` agent on the changes to verify the repository still complies with `guides/CONCURRENCY_GUIDE.md` — specifically the split across `MainActor.run` and the post-run conversion step, and that `InstrumentConversionService` is called off the main actor.

- [ ] **Step 5.4: Instrument-conversion review.**

Run the `instrument-conversion-review` agent to verify the fix aligns with `guides/INSTRUMENT_CONVERSION_GUIDE.md` rules 1/2/6/11.

- [ ] **Step 5.5: Cleanup temp files and commit any review-driven fixes.**

```bash
rm -f .agent-tmp/*.txt
```

If either review flags issues, fix inline and commit as `fix: address review feedback on priorBalance multi-currency change`.

---

## Self-review notes

- `priorBalance == nil` cascades cleanly through `withRunningBalances` — verified by reading Transaction.swift:271 (the `balance` var starts as the incoming optional and is set to nil on failure downstream).
- `targetInstrument` is always populated even on error paths (empty page, account lookup failure), so `TransactionStore.currentTargetInstrument` never regresses to a stale value.
- Sign convention preserved: summing `Int64` storage values is sign-preserving by definition (signed integer addition). The per-instrument subtotal carries its natural sign into conversion.
- Conversion is on `Date()` (Rule 6 — present-day value). Historic running-balance *accumulation* through `withRunningBalances` still uses `transaction.date` per-leg; `priorBalance` alone adopts today's rate since it is the running-balance seed, not a per-transaction historical figure.
- Remote backend semantics unchanged; the server still computes priorBalance server-side. DTO is untouched.
