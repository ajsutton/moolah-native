# Trade Transaction UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the design in `plans/2026-04-28-trade-transaction-ui-design.md`. Add `TransactionType.trade` to the domain model, a dedicated Trade mode in `TransactionDetailView`, a generalised per-instrument amount column in `TransactionRowView`, and the supporting changes in `TradeEventClassifier`, `TransactionDraft`, and the row's data pipeline.

**Architecture:** New leg type `.trade` plus the structural rule in design §1.2 makes "is this a trade" a one-line check. `TradeEventClassifier` filters by `type == .trade`. Detail view gets a dedicated `tradeModeContent` parallel to the existing simple/custom/earmark-only branches. Row layout pivots on a new vector of per-instrument leg sums (`[InstrumentAmount]`) replacing today's scalar `displayAmount`, with a zero-sum-transfer fallback to preserve current behaviour for same-currency transfers in the unfiltered view. The running-balance pipeline continues to produce a single converted scalar for the balance line.

**Tech Stack:** Swift 5.x, Swift Testing (`@Suite` / `@Test` / `#expect`), SwiftUI, SwiftData (in-memory test backend), `just` task runner. CloudKit schema is unchanged — `TransactionType` is a free-form string at the wire layer, so we only need to ensure all platforms ship the new case in the same release (design §1.3).

**Critical context:**
- The branch ships as one PR. All 21 tasks land together to avoid leaving `main` with a half-supported `.trade` value.
- Per project memory, every PR opened goes through the merge-queue skill once CI is green.
- Per `CLAUDE.md`'s "Pre-Commit Checklist", every commit runs `just format` first; do not modify `.swiftlint-baseline.yml`.
- Per `CLAUDE.md`'s "Thin Views" rule, business logic for trade-mode switching, verb selection, and per-instrument summing belongs in model extensions / shared utilities, not in the row or detail views.
- The project uses **Swift Testing** (`@Test`, `#expect`), not XCTest — even though `MoolahUITests_macOS` still uses `XCTestCase`.
- Tests under `MoolahTests/Domain/` exercise domain types; `MoolahTests/Shared/` exercises shared utilities (`TradeEventClassifier`, `TransactionDraft`); `MoolahTests/Features/` exercises stores and view-model logic.
- After each task, run the **`code-review` agent** (and `ui-review` for UI tasks, `concurrency-review` for store changes, `instrument-conversion-review` for any task that touches conversion math). Address findings before commit. (See `CLAUDE.md` "Agents" section.)
- Use `git -C <worktree> ...` for every git command per project memory.

**File structure (created/modified, in order):**

| Path | Action | Task |
|---|---|---|
| `Domain/Models/TransactionType.swift` | modify | 1 |
| `MoolahTests/Domain/TransactionTypeTests.swift` | new | 1 |
| `Domain/Models/Transaction.swift` | modify | 2 |
| `MoolahTests/Domain/TransactionIsTradeTests.swift` | new | 2 |
| `MoolahTests/Domain/TransactionIsSimpleTests.swift` | modify | 2 |
| `Shared/TradeEventClassifier.swift` | full rewrite | 3 |
| `MoolahTests/Shared/TradeEventClassifierTests.swift` | rewrite | 3 |
| `MoolahTests/Shared/CapitalGainsCalculatorTests.swift` (+ `*More`, `*MoreExtra`) | adjust fixtures | 4 |
| `MoolahTests/Shared/PositionsHistoryBuilderTests.swift` | adjust fixtures | 4 |
| `Domain/Models/RunningBalanceResult.swift` | modify | 5 |
| `Domain/Models/Transaction.swift` | modify (`computeDisplayAmount` → vector + scalar) | 6 |
| `MoolahTests/Domain/TransactionDisplayAmountTests.swift` | new | 6 |
| `Domain/Models/Transaction+Display.swift` | modify (add trade-title + scope-reference helpers) | 7 |
| `MoolahTests/Domain/TransactionTradeTitleTests.swift` | new | 7 |
| `Features/Transactions/Views/TransactionRowView.swift` | rewrite amount column + icon/title | 8, 9 |
| `Features/Transactions/Views/TransactionListView+List.swift` | call-site update (pass scope-reference) | 9 |
| `Shared/Models/TransactionDraft+TradeMode.swift` | new | 10 |
| `MoolahTests/Shared/TransactionDraftTradeAccessorsTests.swift` | new | 10 |
| `MoolahTests/Shared/TransactionDraftForwardSwitchTests.swift` | new | 11 |
| `Shared/Models/TransactionDraft+SimpleMode.swift` | modify (`setType` extension for `.trade` forward) | 11 |
| `MoolahTests/Shared/TransactionDraftReverseSwitchTests.swift` | new | 12 |
| `Shared/Models/TransactionDraft+TradeMode.swift` | modify (reverse-switch helpers) | 12 |
| `Features/Transactions/Views/Detail/TransactionDetailModeSection.swift` | modify | 13 |
| `Features/Transactions/Views/Detail/TransactionDetailTradeSection.swift` | new | 14 |
| `Features/Transactions/Views/Detail/TransactionDetailFeeSection.swift` | new | 15 |
| `Features/Transactions/Views/TransactionDetailView.swift` | modify (wire `tradeModeContent`) | 16 |
| `Shared/Models/TransactionDraft.swift` | modify (validation pass for trade legs) | 16 |
| `UITestSupport/UITestIdentifiers.swift` | modify | 17 |
| `UITestSupport/UITestSeed.swift` | modify (add trade-eligible seed if missing) | 17 |
| `App/UITestSeedHydrator+Upserts.swift` | modify (hydrate the seed) | 17 |
| `MoolahUITests_macOS/Tests/TradeFlowUITests.swift` | new | 18 |
| `MoolahUITests_macOS/Helpers/MoolahApp.swift` (or `Detail` driver) | modify (driver methods) | 18 |
| `Moolah.xcodeproj` | regenerated by `just generate` | various |
| `plans/completed/...` | move design + this plan after merge | post-merge |

---

## Task 1: Add `TransactionType.trade` enum case

Domain enum gets the new case. No behaviour change beyond `displayName` and `userSelectableTypes` inclusion.

**Files:**
- Modify: `Domain/Models/TransactionType.swift`
- Test (new): `MoolahTests/Domain/TransactionTypeTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/TransactionTypeTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionType")
struct TransactionTypeTests {
  @Test("trade case has stable raw value")
  func tradeRawValue() {
    #expect(TransactionType.trade.rawValue == "trade")
  }

  @Test("trade is in CaseIterable.allCases")
  func tradeInAllCases() {
    #expect(TransactionType.allCases.contains(.trade))
  }

  @Test("trade displayName is Trade")
  func tradeDisplayName() {
    #expect(TransactionType.trade.displayName == "Trade")
  }

  @Test("trade is user-editable")
  func tradeIsUserEditable() {
    #expect(TransactionType.trade.isUserEditable == true)
  }

  @Test("trade is in userSelectableTypes")
  func tradeIsUserSelectable() {
    #expect(TransactionType.userSelectableTypes.contains(.trade))
  }

  @Test("trade Codable round-trips")
  func tradeCodableRoundTrip() throws {
    let encoded = try JSONEncoder().encode(TransactionType.trade)
    let decoded = try JSONDecoder().decode(TransactionType.self, from: encoded)
    #expect(decoded == .trade)
    let raw = String(data: encoded, encoding: .utf8)
    #expect(raw == "\"trade\"")
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mkdir -p .agent-tmp
just test-mac TransactionTypeTests 2>&1 | tee .agent-tmp/task1-fail.txt
grep -i 'failed\|error' .agent-tmp/task1-fail.txt
```

Expected: build error or compile failure — `.trade` is not a member of `TransactionType`.

- [ ] **Step 3: Add the enum case**

Edit `Domain/Models/TransactionType.swift` so the file reads:

```swift
import Foundation

enum TransactionType: String, Codable, Sendable, CaseIterable {
  case income
  case expense
  case transfer
  case openingBalance
  case trade

  /// Whether this transaction type can be manually created or edited by users.
  /// Opening balance transactions are system-generated and cannot be modified.
  var isUserEditable: Bool {
    self != .openingBalance
  }

  /// Display name for the transaction type
  var displayName: String {
    switch self {
    case .income: return "Income"
    case .expense: return "Expense"
    case .transfer: return "Transfer"
    case .openingBalance: return "Opening Balance"
    case .trade: return "Trade"
    }
  }

  /// Only types that users can select when creating/editing transactions
  static var userSelectableTypes: [TransactionType] {
    [.income, .expense, .transfer, .trade]
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
just test-mac TransactionTypeTests 2>&1 | tee .agent-tmp/task1-pass.txt
grep -i 'failed\|error' .agent-tmp/task1-pass.txt
```

Expected: 6 tests passing, no failures.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C $WORKTREE add Domain/Models/TransactionType.swift MoolahTests/Domain/TransactionTypeTests.swift
git -C $WORKTREE commit -m "feat(transactions): add TransactionType.trade case"
rm .agent-tmp/task1-*.txt
```

(`$WORKTREE` is the absolute path of the worktree, e.g. `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/trade-ui-design`. Use it consistently for every git command in this plan.)

---

## Task 2: Add `Transaction.isTrade` computed property

Add the structural detector defined in design §1.2, plus tests for every accept and reject shape from spec §5.1.

**Files:**
- Modify: `Domain/Models/Transaction.swift`
- Test (new): `MoolahTests/Domain/TransactionIsTradeTests.swift`
- Test (modify): `MoolahTests/Domain/TransactionIsSimpleTests.swift` (add cases asserting trade-shaped txns are *not* `isSimple`)

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/TransactionIsTradeTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.isTrade")
struct TransactionIsTradeTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let account = UUID()
  let otherAccount = UUID()
  let categoryId = UUID()
  let earmarkId = UUID()

  private func tradeLeg(_ instr: Instrument, _ qty: Decimal,
                        account: UUID, category: UUID? = nil, earmark: UUID? = nil) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: instr, quantity: qty,
                   type: .trade, categoryId: category, earmarkId: earmark)
  }

  private func feeLeg(_ instr: Instrument, _ qty: Decimal,
                      account: UUID, category: UUID? = nil, earmark: UUID? = nil) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: instr, quantity: qty,
                   type: .expense, categoryId: category, earmarkId: earmark)
  }

  private func txn(_ legs: [TransactionLeg]) -> Transaction {
    Transaction(date: Date(), legs: legs)
  }

  // MARK: - Accept

  @Test("two trade legs no fee")
  func twoTradeLegsNoFee() {
    let t = txn([tradeLeg(aud, -300, account: account), tradeLeg(vgs, 20, account: account)])
    #expect(t.isTrade)
  }

  @Test("two trade legs plus one fee")
  func twoTradeLegsOneFee() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: account),
    ])
    #expect(t.isTrade)
  }

  @Test("two trade legs plus multiple fees in different instruments")
  func twoTradeLegsMultipleFees() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: account),
      feeLeg(usd, -5, account: account),
    ])
    #expect(t.isTrade)
  }

  @Test("same-instrument paid and received is allowed")
  func sameInstrumentPaidReceived() {
    let t = txn([tradeLeg(aud, -100, account: account), tradeLeg(aud, 100, account: account)])
    #expect(t.isTrade)
  }

  @Test("same-sign trade legs are allowed")
  func sameSignLegs() {
    let t = txn([tradeLeg(aud, 100, account: account), tradeLeg(vgs, 5, account: account)])
    #expect(t.isTrade)
  }

  @Test("zero-quantity trade legs are allowed")
  func zeroQuantityLegs() {
    let t = txn([tradeLeg(aud, 0, account: account), tradeLeg(vgs, 0, account: account)])
    #expect(t.isTrade)
  }

  @Test("fee leg may carry a category")
  func feeWithCategory() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: account, category: categoryId),
    ])
    #expect(t.isTrade)
  }

  @Test("fee leg may carry an earmark")
  func feeWithEarmark() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: account, earmark: earmarkId),
    ])
    #expect(t.isTrade)
  }

  // MARK: - Reject

  @Test("one trade leg is not a trade")
  func oneTradeLeg() {
    let t = txn([tradeLeg(aud, -300, account: account)])
    #expect(!t.isTrade)
  }

  @Test("three trade legs is not a trade")
  func threeTradeLegs() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 10, account: account),
      tradeLeg(bhp, 5, account: account),
    ])
    #expect(!t.isTrade)
  }

  @Test("trade leg with a category is not a trade")
  func tradeLegWithCategory() {
    let t = txn([
      tradeLeg(aud, -300, account: account, category: categoryId),
      tradeLeg(vgs, 20, account: account),
    ])
    #expect(!t.isTrade)
  }

  @Test("trade leg with an earmark is not a trade")
  func tradeLegWithEarmark() {
    let t = txn([
      tradeLeg(aud, -300, account: account, earmark: earmarkId),
      tradeLeg(vgs, 20, account: account),
    ])
    #expect(!t.isTrade)
  }

  @Test("legs on different accounts is not a trade")
  func mixedAccounts() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: otherAccount),
    ])
    #expect(!t.isTrade)
  }

  @Test("fee leg on a different account is not a trade")
  func feeOnOtherAccount() {
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      feeLeg(aud, -10, account: otherAccount),
    ])
    #expect(!t.isTrade)
  }

  @Test("non-expense extra leg (e.g. income) is not a trade")
  func incomeExtraLeg() {
    let income = TransactionLeg(accountId: account, instrument: aud,
                                quantity: 5, type: .income)
    let t = txn([
      tradeLeg(aud, -300, account: account),
      tradeLeg(vgs, 20, account: account),
      income,
    ])
    #expect(!t.isTrade)
  }

  @Test("legs without an account id are not a trade")
  func legsMissingAccount() {
    let leg1 = TransactionLeg(accountId: nil, instrument: aud, quantity: -300, type: .trade)
    let leg2 = TransactionLeg(accountId: nil, instrument: vgs, quantity: 20, type: .trade)
    #expect(!txn([leg1, leg2]).isTrade)
  }
}
```

Append to `MoolahTests/Domain/TransactionIsSimpleTests.swift`, inside the existing `@Suite` struct:

```swift
  @Test("trade-shaped transaction is not isSimple")
  func tradeIsNotSimple() {
    let aud = Instrument.AUD
    let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
    let account = UUID()
    let legs = [
      TransactionLeg(accountId: account, instrument: aud, quantity: -300, type: .trade),
      TransactionLeg(accountId: account, instrument: vgs, quantity: 20, type: .trade),
    ]
    let t = Transaction(date: Date(), legs: legs)
    #expect(t.isSimple == false)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
just test-mac TransactionIsTradeTests TransactionIsSimpleTests 2>&1 | tee .agent-tmp/task2-fail.txt
grep -i 'failed\|error' .agent-tmp/task2-fail.txt
```

Expected: build error — `Transaction` has no member `isTrade`.

- [ ] **Step 3: Implement `isTrade`**

Inside `Domain/Models/Transaction.swift`, immediately after the existing `isSimpleCrossCurrencyTransfer`, add:

```swift
  /// Whether this transaction has the structural shape of a trade per
  /// `plans/2026-04-28-trade-transaction-ui-design.md` §1.2:
  /// exactly two `.trade` legs (no category, no earmark) plus zero or
  /// more `.expense` fee legs (which may have a category and/or earmark),
  /// all on the same non-nil account. Sign and instrument of the
  /// `.trade` legs are unrestricted.
  var isTrade: Bool {
    let tradeLegs = legs.filter { $0.type == .trade }
    guard tradeLegs.count == 2 else { return false }
    guard tradeLegs.allSatisfy({ $0.categoryId == nil && $0.earmarkId == nil })
    else { return false }
    let extra = legs.filter { $0.type != .trade }
    guard extra.allSatisfy({ $0.type == .expense }) else { return false }
    let accountIds = Set(legs.compactMap(\.accountId))
    guard accountIds.count == 1, !legs.contains(where: { $0.accountId == nil })
    else { return false }
    return true
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
just test-mac TransactionIsTradeTests TransactionIsSimpleTests 2>&1 | tee .agent-tmp/task2-pass.txt
grep -i 'failed\|error' .agent-tmp/task2-pass.txt
```

Expected: all `TransactionIsTradeTests` cases pass plus the new `TransactionIsSimpleTests` case; existing `isSimple` tests unchanged.

- [ ] **Step 5: Run `code-review` agent on the diff**

Invoke `@code-review` (or `Agent` with `subagent_type: code-review`). Address any findings before commit.

- [ ] **Step 6: Format and commit**

```bash
just format
git -C $WORKTREE add Domain/Models/Transaction.swift MoolahTests/Domain/TransactionIsTradeTests.swift MoolahTests/Domain/TransactionIsSimpleTests.swift
git -C $WORKTREE commit -m "feat(transactions): add Transaction.isTrade structural detector"
rm .agent-tmp/task2-*.txt
```

---

## Task 3: Rewrite `TradeEventClassifier` to filter by `.trade` type

Replace the existing fiat-paired / non-fiat-swap inference with a flat "find the `.trade` legs and classify them" rule (design §2). The classifier's output type (`TradeEventClassification`) and consumers don't change — only the input filtering.

**Files:**
- Full rewrite: `Shared/TradeEventClassifier.swift`
- Rewrite: `MoolahTests/Shared/TradeEventClassifierTests.swift`

- [ ] **Step 1: Rewrite the test file first (TDD)**

Replace the contents of `MoolahTests/Shared/TradeEventClassifierTests.swift` with cases that exercise the new rule. The existing tests are kept for the same scenarios but updated to use `.trade` legs:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TradeEventClassifier")
struct TradeEventClassifierTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let account = UUID()

  private func tradeLeg(_ instr: Instrument, _ qty: Decimal) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: instr, quantity: qty, type: .trade)
  }

  private func feeLeg(_ instr: Instrument, _ qty: Decimal) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: instr, quantity: qty, type: .expense)
  }

  @Test("buy: positive trade leg + negative trade leg")
  func buy() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == bhp)
    #expect(result.buys[0].quantity == 100)
    #expect(result.buys[0].costPerUnit == 40)
    #expect(result.sells.isEmpty)
  }

  @Test("sell: positive fiat + negative non-fiat")
  func sell() async throws {
    let legs = [tradeLeg(aud, 2_500), tradeLeg(bhp, -50)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == bhp)
    #expect(result.sells[0].quantity == 50)
    #expect(result.sells[0].proceedsPerUnit == 50)
  }

  @Test("non-fiat swap is priced via host-currency conversion")
  func swap() async throws {
    let legs = [tradeLeg(eth, -2), tradeLeg(btc, 0.1)]
    let service = FixedConversionService(rates: [
      eth.id: Decimal(3_000),
      btc.id: Decimal(60_000),
    ])
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud, conversionService: service)
    #expect(result.buys.count == 1)
    #expect(result.buys[0].instrument == btc)
    #expect(result.buys[0].costPerUnit == Decimal(60_000))
    #expect(result.sells.count == 1)
    #expect(result.sells[0].instrument == eth)
    #expect(result.sells[0].proceedsPerUnit == Decimal(3_000))
  }

  @Test("fee legs are ignored")
  func feeIgnored() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 100), feeLeg(aud, -10)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.buys[0].costPerUnit == 40)  // 4000/100, not (4000+10)/100
  }

  @Test("non-trade-typed legs are ignored entirely (older custom shapes)")
  func nonTradeLegsIgnored() async throws {
    let legs = [
      TransactionLeg(accountId: account, instrument: aud,
                     quantity: -4_000, type: .expense),
      TransactionLeg(accountId: account, instrument: bhp,
                     quantity: 100, type: .income),
    ]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.buys.isEmpty)
    #expect(result.sells.isEmpty)
  }

  @Test("zero-quantity trade leg is skipped (no divide-by-zero)")
  func zeroQuantityTradeLeg() async throws {
    let legs = [tradeLeg(aud, -4_000), tradeLeg(bhp, 0)]
    let result = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.buys.isEmpty)
    #expect(result.sells.isEmpty)
  }

  @Test("fewer than two .trade legs returns empty")
  func fewerThanTwo() async throws {
    let result = try await TradeEventClassifier.classify(
      legs: [tradeLeg(aud, -100)], on: date, hostCurrency: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.buys.isEmpty && result.sells.isEmpty)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
just test-mac TradeEventClassifierTests 2>&1 | tee .agent-tmp/task3-fail.txt
grep -i 'failed\|error' .agent-tmp/task3-fail.txt
```

Expected: existing classifier returns wrong shapes / empty (since its current rule looks at instrument kinds, not `.trade` type). Failures across most cases.

- [ ] **Step 3: Rewrite `Shared/TradeEventClassifier.swift`**

Replace the entire body with:

```swift
import Foundation

/// One step in the FIFO cost-basis machine. Shape unchanged from the previous
/// implementation; consumers (CapitalGainsCalculator, InvestmentStore cost
/// basis snapshot, PositionsHistoryBuilder) read these structurally.
struct TradeBuyEvent: Sendable, Equatable {
  let instrument: Instrument
  let quantity: Decimal
  let costPerUnit: Decimal
}

struct TradeSellEvent: Sendable, Equatable {
  let instrument: Instrument
  let quantity: Decimal
  let proceedsPerUnit: Decimal
}

struct TradeEventClassification: Sendable, Equatable {
  let buys: [TradeBuyEvent]
  let sells: [TradeSellEvent]
}

/// Classifies a transaction's `.trade` legs into FIFO buy / sell events.
///
/// Per design §2, the classifier filters by `type == .trade` and ignores
/// every other leg. For each `.trade` leg, the per-unit value is derived
/// from the *other* `.trade` leg's value converted to `hostCurrency` on
/// the transaction date. Fee legs (`.expense`) are not part of cost basis
/// in this iteration; that decision moves with the SelfWealthParser
/// brokerage-attach work tracked in
/// https://github.com/ajsutton/moolah-native/issues/558.
///
/// Zero-quantity `.trade` legs are skipped to avoid divide-by-zero.
enum TradeEventClassifier {
  static func classify(
    legs: [TransactionLeg],
    on date: Date,
    hostCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> TradeEventClassification {
    let tradeLegs = legs.filter { $0.type == .trade }
    guard tradeLegs.count == 2 else {
      return TradeEventClassification(buys: [], sells: [])
    }
    let other = [tradeLegs[1], tradeLegs[0]]  // pair each leg with the *other* one

    var buys: [TradeBuyEvent] = []
    var sells: [TradeSellEvent] = []
    for index in tradeLegs.indices {
      let leg = tradeLegs[index]
      guard leg.quantity != 0 else { continue }
      let pair = other[index]
      let pairValue = try await conversionService.convert(
        pair.quantity, from: pair.instrument, to: hostCurrency, on: date)
      // pair.quantity has the *opposite* sign by convention (paid vs received),
      // so |pairValue / leg.quantity| is the per-unit cost or proceed.
      let perUnit = abs(pairValue / leg.quantity)
      if leg.quantity > 0 {
        buys.append(TradeBuyEvent(
          instrument: leg.instrument, quantity: leg.quantity,
          costPerUnit: perUnit))
      } else {
        sells.append(TradeSellEvent(
          instrument: leg.instrument, quantity: -leg.quantity,
          proceedsPerUnit: perUnit))
      }
    }
    return TradeEventClassification(buys: buys, sells: sells)
  }
}
```

(Note: `abs()` here is on a derived ratio used for per-unit display, not on a leg quantity — see the design's "monetary sign convention" note. The leg quantities themselves retain their signs throughout.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test-mac TradeEventClassifierTests 2>&1 | tee .agent-tmp/task3-pass.txt
grep -i 'failed\|error' .agent-tmp/task3-pass.txt
```

Expected: all 7 cases pass.

- [ ] **Step 5: `instrument-conversion-review` and `code-review` agents**

Invoke both. The classifier touches the conversion service so the conversion-review agent applies. Address findings before commit.

- [ ] **Step 6: Format and commit**

```bash
just format
git -C $WORKTREE add Shared/TradeEventClassifier.swift MoolahTests/Shared/TradeEventClassifierTests.swift
git -C $WORKTREE commit -m "refactor(trades): TradeEventClassifier filters by TransactionType.trade"
rm .agent-tmp/task3-*.txt
```

---

## Task 4: Update CapitalGainsCalculator and InvestmentStore test fixtures

The classifier's runtime behaviour for trade-shaped transactions is preserved, but the *inputs* now must use `.trade` legs. Existing fixtures in `MoolahTests/Shared/CapitalGainsCalculator*` and `MoolahTests/Shared/PositionsHistoryBuilderTests.swift` build trade-shaped transactions with `.income` / `.expense` legs and need to be flipped.

**Files:**
- Modify: `MoolahTests/Shared/CapitalGainsCalculatorTests.swift`
- Modify: `MoolahTests/Shared/CapitalGainsCalculatorTestsMore.swift`
- Modify: `MoolahTests/Shared/CapitalGainsCalculatorTestsMoreExtra.swift`
- Modify: `MoolahTests/Shared/PositionsHistoryBuilderTests.swift`

(Note: production code in `CapitalGainsCalculator` and `InvestmentStore+PositionsInput` does **not** need changes — they consume `TradeEventClassification`, whose shape is unchanged.)

- [ ] **Step 1: Run the affected suites to see what's red**

```bash
just test-mac CapitalGainsCalculatorTests CapitalGainsCalculatorTestsMore CapitalGainsCalculatorTestsMoreExtra PositionsHistoryBuilderTests 2>&1 | tee .agent-tmp/task4-fail.txt
grep -B1 -A10 'failed\|error' .agent-tmp/task4-fail.txt | head -200
```

Expected: every test that builds a buy/sell transaction with `.income` + `.expense` legs now fails because the classifier no longer recognises that shape.

- [ ] **Step 2: Update the fixture helpers**

In each test file, find the helper that builds a buy or sell transaction (commonly `buyTxn` / `sellTxn` / `swapTxn` factory methods) and change the leg type from `.income`/`.expense` to `.trade`. For example, an existing helper:

```swift
private func buyTxn(_ instr: Instrument, qty: Decimal, cost: Decimal, on date: Date) -> Transaction {
  Transaction(date: date, legs: [
    TransactionLeg(accountId: account, instrument: instr,
                   quantity: qty, type: .income),
    TransactionLeg(accountId: account, instrument: aud,
                   quantity: -cost, type: .expense),
  ])
}
```

becomes:

```swift
private func buyTxn(_ instr: Instrument, qty: Decimal, cost: Decimal, on date: Date) -> Transaction {
  Transaction(date: date, legs: [
    TransactionLeg(accountId: account, instrument: instr,
                   quantity: qty, type: .trade),
    TransactionLeg(accountId: account, instrument: aud,
                   quantity: -cost, type: .trade),
  ])
}
```

Apply the same `.income → .trade` and `.expense → .trade` substitution wherever the fixture is constructing a "trade-shaped" transaction. Leave non-trade fixtures alone.

`PositionsHistoryBuilderTests.swift` likely has its own helper — apply the same change.

- [ ] **Step 3: Run the suites to verify green**

```bash
just test-mac CapitalGainsCalculatorTests CapitalGainsCalculatorTestsMore CapitalGainsCalculatorTestsMoreExtra PositionsHistoryBuilderTests 2>&1 | tee .agent-tmp/task4-pass.txt
grep -i 'failed\|error' .agent-tmp/task4-pass.txt
```

Expected: all suites green.

- [ ] **Step 4: Format and commit**

```bash
just format
git -C $WORKTREE add MoolahTests/Shared/CapitalGainsCalculator*.swift MoolahTests/Shared/PositionsHistoryBuilderTests.swift
git -C $WORKTREE commit -m "test(trades): update fixtures to use TransactionType.trade legs"
rm .agent-tmp/task4-*.txt
```

---

## Task 5: Add `displayAmounts: [InstrumentAmount]` to `TransactionWithBalance`

Today `TransactionWithBalance.displayAmount` is a single converted scalar that drives the row's amount column. The new row-amount rule (design §4.2) needs a *vector* of per-instrument leg sums — these are computed in the **leg's native instrument**, not converted.

This task only adds the new field to the data type. Computing it lives in Task 6.

**Files:**
- Modify: `Domain/Models/RunningBalanceResult.swift`

- [ ] **Step 1: Add the new field**

Edit `Domain/Models/RunningBalanceResult.swift`. Inside `struct TransactionWithBalance`, add a new property between `convertedLegs` and `displayAmount`:

```swift
struct TransactionWithBalance: Sendable, Identifiable {
  let transaction: Transaction
  let convertedLegs: [ConvertedTransactionLeg]
  /// Per-instrument leg sums in the legs' native instruments, restricted
  /// to the legs that match the row's scope (account / earmark filter, or
  /// all legs when unfiltered). Empty when conversion failed (paired with
  /// `displayAmount == nil`). See design §4.2.
  let displayAmounts: [InstrumentAmount]
  /// Single scalar in the running-balance target instrument. Retained for
  /// backwards-compatible diagnostics and any consumer that wants the
  /// converted total; the row no longer reads it for rendering.
  let displayAmount: InstrumentAmount?
  let balance: InstrumentAmount?

  // ... id and existing legs(forAccount:) / legs(forEarmark:) helpers unchanged
}
```

- [ ] **Step 2: Update all `TransactionWithBalance(...)` constructor call sites in `Domain/Models/Transaction.swift`**

`Transaction.withRunningBalances` constructs `TransactionWithBalance` in two places (success and failure branches). Pass `displayAmounts: []` to both call sites for now — Task 6 will populate the field properly.

- [ ] **Step 3: Build to verify both call sites compile**

```bash
just build-mac 2>&1 | tee .agent-tmp/task5-build.txt
grep -i 'error' .agent-tmp/task5-build.txt
```

Expected: clean build, no errors. (No new tests yet — those land with Task 6 alongside the actual computation.)

- [ ] **Step 4: Format and commit**

```bash
just format
git -C $WORKTREE add Domain/Models/RunningBalanceResult.swift Domain/Models/Transaction.swift
git -C $WORKTREE commit -m "refactor(transactions): add TransactionWithBalance.displayAmounts vector"
rm .agent-tmp/task5-build.txt
```

---

## Task 6: Compute per-instrument `displayAmounts` with zero-sum-transfer fallback

Replace the current `computeDisplayAmount` with a function that returns a vector of per-instrument sums. The scalar `displayAmount` continues to be computed as it is today (its only remaining caller is the running-balance chain itself, which still needs a single value). Both fields are populated per-row.

**Files:**
- Modify: `Domain/Models/Transaction.swift`
- Test (new): `MoolahTests/Domain/TransactionDisplayAmountTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/TransactionDisplayAmountTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.displayAmounts")
struct TransactionDisplayAmountTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let accountA = UUID()
  let accountB = UUID()
  let earmarkId = UUID()
  let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func leg(_ accountId: UUID?, _ instr: Instrument, _ qty: Decimal,
                   _ type: TransactionType, earmark: UUID? = nil) -> TransactionLeg {
    TransactionLeg(accountId: accountId, instrument: instr, quantity: qty,
                   type: type, earmarkId: earmark)
  }

  @Test("simple expense scoped to its account: one entry")
  func simpleExpense() async {
    let t = Transaction(date: date, legs: [leg(accountA, aud, -50, .expense)])
    let result = await TransactionPage.withRunningBalances(
      transactions: [t], priorBalance: InstrumentAmount(quantity: 100, instrument: aud),
      accountId: accountA, targetInstrument: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.rows[0].displayAmounts == [InstrumentAmount(quantity: -50, instrument: aud)])
  }

  @Test("trade with cross-currency fee: three entries (legs not summed)")
  func tradeWithCrossCurrencyFee() async {
    let t = Transaction(date: date, legs: [
      leg(accountA, aud, -300, .trade),
      leg(accountA, bhp, 2, .trade),
      leg(accountA, usd, -10, .expense),
    ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [t], priorBalance: InstrumentAmount(quantity: 5_000, instrument: aud),
      accountId: accountA, targetInstrument: aud,
      conversionService: FixedConversionService(rates: [
        bhp.id: Decimal(150), usd.id: Decimal(1.5),
      ]))
    let amounts = Set(result.rows[0].displayAmounts)
    #expect(amounts == Set([
      InstrumentAmount(quantity: -300, instrument: aud),
      InstrumentAmount(quantity: 2, instrument: bhp),
      InstrumentAmount(quantity: -10, instrument: usd),
    ]))
  }

  @Test("trade with same-currency fee: AUD legs sum")
  func tradeWithSameCurrencyFee() async {
    let t = Transaction(date: date, legs: [
      leg(accountA, aud, -300, .trade),
      leg(accountA, bhp, 2, .trade),
      leg(accountA, aud, -10, .expense),
    ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [t], priorBalance: InstrumentAmount(quantity: 5_000, instrument: aud),
      accountId: accountA, targetInstrument: aud,
      conversionService: FixedConversionService(rates: [bhp.id: Decimal(150)]))
    let amounts = Set(result.rows[0].displayAmounts)
    #expect(amounts == Set([
      InstrumentAmount(quantity: -310, instrument: aud),
      InstrumentAmount(quantity: 2, instrument: bhp),
    ]))
  }

  @Test("cross-currency transfer scoped to source: only AUD entry")
  func crossCurrencyTransferSourceScope() async {
    let t = Transaction(date: date, legs: [
      leg(accountA, aud, -1_000, .transfer),
      leg(accountB, usd, 660, .transfer),
    ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [t], priorBalance: InstrumentAmount(quantity: 5_000, instrument: aud),
      accountId: accountA, targetInstrument: aud,
      conversionService: FixedConversionService(rates: [usd.id: Decimal(1.5)]))
    #expect(result.rows[0].displayAmounts == [InstrumentAmount(quantity: -1_000, instrument: aud)])
  }

  @Test("same-currency transfer unfiltered: zero-sum fallback shows negative leg")
  func sameCurrencyTransferUnfiltered() async {
    let t = Transaction(date: date, legs: [
      leg(accountA, aud, -200, .transfer),
      leg(accountB, aud, 200, .transfer),
    ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [t], priorBalance: nil,
      accountId: nil, targetInstrument: aud,
      conversionService: FixedConversionService(rates: [:]))
    #expect(result.rows[0].displayAmounts == [InstrumentAmount(quantity: -200, instrument: aud)])
  }

  @Test("earmark scope: only legs touching the earmark are summed")
  func earmarkScope() async {
    let t = Transaction(date: date, legs: [
      leg(accountA, aud, 100, .income, earmark: earmarkId),
      leg(accountA, aud, -10, .expense),  // not earmarked
    ])
    let result = await TransactionPage.withRunningBalances(
      transactions: [t], priorBalance: nil, accountId: nil, earmarkId: earmarkId,
      targetInstrument: aud, conversionService: FixedConversionService(rates: [:]))
    #expect(result.rows[0].displayAmounts == [InstrumentAmount(quantity: 100, instrument: aud)])
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
just test-mac TransactionDisplayAmountTests 2>&1 | tee .agent-tmp/task6-fail.txt
grep -i 'failed\|error' .agent-tmp/task6-fail.txt
```

Expected: `displayAmounts` is empty in every result (Task 5 left it as `[]`), so most assertions fail.

- [ ] **Step 3: Implement the per-instrument summer**

In `Domain/Models/Transaction.swift`, add a new private static helper alongside `computeDisplayAmount`:

```swift
  /// Returns one entry per distinct native instrument for the legs that
  /// match the row's scope. Zero-net entries are dropped. When *every*
  /// per-instrument net is zero (a same-currency transfer cancels), falls
  /// back to the negative-quantity transfer leg(s) so the row still shows
  /// something sensible — preserving today's behaviour for unfiltered
  /// transfers (design §4.2).
  private static func computeDisplayAmounts(
    for transaction: Transaction,
    accountId: UUID?,
    earmarkId: UUID?
  ) -> [InstrumentAmount] {
    let scopedLegs: [TransactionLeg]
    if let accountId {
      scopedLegs = transaction.legs.filter { $0.accountId == accountId }
    } else if let earmarkId {
      scopedLegs = transaction.legs.filter { $0.earmarkId == earmarkId }
    } else {
      scopedLegs = transaction.legs
    }

    // Sum per instrument, preserving first-seen order for stable rendering.
    var order: [Instrument] = []
    var sums: [Instrument: Decimal] = [:]
    for leg in scopedLegs {
      if sums[leg.instrument] == nil { order.append(leg.instrument) }
      sums[leg.instrument, default: 0] += leg.quantity
    }
    let nonZero = order.compactMap { instr -> InstrumentAmount? in
      guard let qty = sums[instr], qty != 0 else { return nil }
      return InstrumentAmount(quantity: qty, instrument: instr)
    }
    if !nonZero.isEmpty { return nonZero }

    // Zero-sum fallback: surface the negative-quantity transfer leg(s).
    let negatives = scopedLegs.filter { $0.type == .transfer && $0.quantity < 0 }
    return negatives.map { $0.amount }
  }
```

Then, in `Transaction.withRunningBalances`, change the `case .success`/`case .failure` branches that build `TransactionWithBalance` so they pass the new field:

```swift
        result.append(
          TransactionWithBalance(
            transaction: transaction,
            convertedLegs: convertedLegs,
            displayAmounts: Self.computeDisplayAmounts(
              for: transaction, accountId: accountId, earmarkId: earmarkId),
            displayAmount: displayAmount,
            balance: balance))
```

```swift
        result.append(
          TransactionWithBalance(
            transaction: transaction,
            convertedLegs: [],
            displayAmounts: [],
            displayAmount: nil,
            balance: nil))
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
just test-mac TransactionDisplayAmountTests 2>&1 | tee .agent-tmp/task6-pass.txt
grep -i 'failed\|error' .agent-tmp/task6-pass.txt
```

Expected: all 6 cases pass.

- [ ] **Step 5: `code-review` and `instrument-conversion-review`**

Both apply (`Transaction.swift` is conversion-adjacent). Address findings.

- [ ] **Step 6: Format and commit**

```bash
just format
git -C $WORKTREE add Domain/Models/Transaction.swift MoolahTests/Domain/TransactionDisplayAmountTests.swift
git -C $WORKTREE commit -m "feat(transactions): per-instrument displayAmounts vector for row layout"
rm .agent-tmp/task6-*.txt
```

---

## Task 7: Add trade-title scope-reference helpers in `Transaction+Display.swift`

Title verb selection (design §4.3) is pure logic that lives in a model extension, per the "Thin Views" rule.

**Files:**
- Modify: `Domain/Models/Transaction+Display.swift`
- Test (new): `MoolahTests/Domain/TransactionTradeTitleTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/TransactionTradeTitleTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.tradeTitleSentence")
struct TransactionTradeTitleTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let gbp = Instrument.fiat(code: "GBP")
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let usdc = Instrument.crypto(
    chainId: 1, contractAddress: "0xa0b86", symbol: "USDC", name: "USD Coin", decimals: 6)
  let account = UUID()

  private func tradeTxn(_ a: Instrument, _ aQty: Decimal,
                        _ b: Instrument, _ bQty: Decimal) -> Transaction {
    Transaction(date: Date(), legs: [
      TransactionLeg(accountId: account, instrument: a, quantity: aQty, type: .trade),
      TransactionLeg(accountId: account, instrument: b, quantity: bQty, type: .trade),
    ])
  }

  @Test("matching leg negative → Bought")
  func boughtVerb() {
    let t = tradeTxn(aud, -300, vgs, 20)
    #expect(t.tradeTitleSentence(scopeReference: aud) == "Bought 20 VGS.AX")
  }

  @Test("matching leg positive → Sold")
  func soldVerb() {
    let t = tradeTxn(aud, 425, vgs, -10)
    #expect(t.tradeTitleSentence(scopeReference: aud) == "Sold 10 VGS.AX")
  }

  @Test("neither leg matches reference → Swapped")
  func swappedVerb() {
    let t = tradeTxn(usd, -100, gbp, 50)
    #expect(t.tradeTitleSentence(scopeReference: aud) == "Swapped 100 USD for 50 GBP")
  }

  @Test("neither matches, mixed fiat / non-fiat")
  func swappedVerbFiatToNonFiat() {
    let t = tradeTxn(usd, -100, vgs, 5)
    #expect(t.tradeTitleSentence(scopeReference: aud) == "Swapped 100 USD for 5 VGS.AX")
  }

  @Test("non-fiat ↔ non-fiat swap")
  func swappedVerbCryptoSwap() {
    let t = tradeTxn(eth, -1, usdc, 30_000)
    #expect(t.tradeTitleSentence(scopeReference: aud) == "Swapped 1 ETH for 30,000 USDC")
  }

  @Test("both legs share the reference instrument → Swapped")
  func bothMatchRef() {
    let t = tradeTxn(aud, -100, aud, 100)
    #expect(t.tradeTitleSentence(scopeReference: aud) == "Swapped 100 AUD for 100 AUD")
  }

  @Test("non-trade transaction returns nil")
  func nonTradeReturnsNil() {
    let t = Transaction(date: Date(), legs: [
      TransactionLeg(accountId: account, instrument: aud, quantity: -50, type: .expense),
    ])
    #expect(t.tradeTitleSentence(scopeReference: aud) == nil)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
just test-mac TransactionTradeTitleTests 2>&1 | tee .agent-tmp/task7-fail.txt
grep -i 'failed\|error' .agent-tmp/task7-fail.txt
```

Expected: build error — `tradeTitleSentence` is not a member.

- [ ] **Step 3: Implement the helper**

Append to `Domain/Models/Transaction+Display.swift`:

```swift
extension Transaction {
  /// The action sentence that goes on a row's title for a `.trade`-shaped
  /// transaction. Returns `nil` for non-trade transactions. See design §4.3.
  ///
  /// `scopeReference` is the row's reference instrument: the account's
  /// instrument when account-scoped, the earmark's instrument when
  /// earmark-scoped, otherwise the profile currency.
  func tradeTitleSentence(scopeReference: Instrument) -> String? {
    guard isTrade else { return nil }
    let tradeLegs = legs.filter { $0.type == .trade }
    guard tradeLegs.count == 2 else { return nil }
    let (a, b) = (tradeLegs[0], tradeLegs[1])

    let aMatches = a.instrument == scopeReference
    let bMatches = b.instrument == scopeReference
    if aMatches != bMatches {
      let matching = aMatches ? a : b
      let other = aMatches ? b : a
      let verb = matching.quantity < 0 ? "Bought" : "Sold"
      return "\(verb) \(formatLegMagnitude(other))"
    }
    // Neither matches, or both match — render Paid → Received.
    let paid = a.quantity < 0 ? a : b
    let received = a.quantity < 0 ? b : a
    return "Swapped \(formatLegMagnitude(paid)) for \(formatLegMagnitude(received))"
  }

  private func formatLegMagnitude(_ leg: TransactionLeg) -> String {
    let magnitude = InstrumentAmount(
      quantity: abs(leg.quantity), instrument: leg.instrument)
    return magnitude.formatted
  }
}
```

(`abs()` here applies to a *display-magnitude*, not to a stored leg quantity used in arithmetic — consistent with the project's monetary-sign convention.)

- [ ] **Step 4: Run to verify they pass**

```bash
just test-mac TransactionTradeTitleTests 2>&1 | tee .agent-tmp/task7-pass.txt
grep -i 'failed\|error' .agent-tmp/task7-pass.txt
```

Expected: all 7 cases pass.

- [ ] **Step 5: `code-review`**

- [ ] **Step 6: Format and commit**

```bash
just format
git -C $WORKTREE add Domain/Models/Transaction+Display.swift MoolahTests/Domain/TransactionTradeTitleTests.swift
git -C $WORKTREE commit -m "feat(trades): scope-aware title-sentence helper"
rm .agent-tmp/task7-*.txt
```

---

## Task 8: `TransactionRowView` amount column rewrite

Replace the single `InstrumentAmountView` in the amount column with a wrapping inline layout over `displayAmounts`. Keep balance line unchanged.

**Files:**
- Modify: `Features/Transactions/Views/TransactionRowView.swift`

- [ ] **Step 1: Replace the row signature and amount column**

In `TransactionRowView.swift`:

1. Change the property `let displayAmount: InstrumentAmount?` to `let displayAmounts: [InstrumentAmount]`. (The scalar is dropped from the row's signature; any call site that still wants it can read `.displayAmount` from `TransactionWithBalance` directly.)
2. Replace the `amountColumn` body:

```swift
  private var amountColumn: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if displayAmounts.isEmpty {
        Text("—")
          .font(.body)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        TradeAmountFlow(amounts: displayAmounts)
      }
      if let balance {
        InstrumentAmountView(amount: balance, font: .caption)
      }
    }
  }
```

3. Add a `TradeAmountFlow` helper view at the bottom of the file:

```swift
/// Inline-with-wrap layout for the row's per-instrument amount entries.
/// Lays out children horizontally with hairline spacing; wraps to a new
/// line when there isn't horizontal room. SwiftUI 6 / iOS 26 supports
/// `.layoutDirectionBehavior` and the `Layout` protocol — using a thin
/// custom `Layout` here keeps wrapping deterministic without nesting
/// `ViewThatFits`.
private struct TradeAmountFlow: View {
  let amounts: [InstrumentAmount]
  var body: some View {
    WrappedHStack(spacing: 6) {
      ForEach(Array(amounts.enumerated()), id: \.offset) { _, amount in
        InstrumentAmountView(amount: amount, font: .body)
      }
    }
    .multilineTextAlignment(.trailing)
  }
}

/// Minimal trailing-aligned wrap layout. Lays each subview out on the
/// current line if it fits within the proposed width; otherwise wraps.
private struct WrappedHStack: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize,
                    subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var lineWidth: CGFloat = 0
    var totalWidth: CGFloat = 0
    var totalHeight: CGFloat = 0
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let advance = (lineWidth == 0 ? 0 : spacing) + size.width
      if lineWidth + advance > maxWidth {
        totalWidth = max(totalWidth, lineWidth)
        totalHeight += lineHeight + spacing
        lineWidth = size.width
        lineHeight = size.height
      } else {
        lineWidth += advance
        lineHeight = max(lineHeight, size.height)
      }
    }
    totalWidth = max(totalWidth, lineWidth)
    totalHeight += lineHeight
    return CGSize(width: totalWidth, height: totalHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                     subviews: Subviews, cache: inout ()) {
    // Right-aligned wrap. Build line-by-line, then place trailing-justified.
    var lines: [[(index: Int, size: CGSize)]] = [[]]
    var lineWidth: CGFloat = 0
    let maxWidth = bounds.width
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let advance = (lineWidth == 0 ? 0 : spacing) + size.width
      if lineWidth + advance > maxWidth, !lines[lines.count - 1].isEmpty {
        lines.append([])
        lineWidth = 0
      }
      lines[lines.count - 1].append((index, size))
      lineWidth += (lineWidth == 0 ? size.width : advance)
    }
    var y = bounds.minY
    for line in lines {
      let lineHeight = line.map(\.size.height).max() ?? 0
      let totalLineWidth = line.reduce(0) { $0 + $1.size.width } +
        CGFloat(max(line.count - 1, 0)) * spacing
      var x = bounds.maxX - totalLineWidth
      for (index, size) in line {
        subviews[index].place(at: CGPoint(x: x, y: y),
                              proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += lineHeight + spacing
    }
  }
}
```

4. Update the row's preview block at the bottom: `previewRow(...)` must take `[InstrumentAmount]` instead of a scalar; thread that through `previewRowSpecs`.

- [ ] **Step 2: Update the production call site**

In `Features/Transactions/Views/TransactionListView+List.swift` (around line 147), change:

```swift
TransactionRowView(
  transaction: entry.transaction, accounts: accounts,
  categories: categories, earmarks: earmarks,
  displayAmount: entry.displayAmount,        // <-- old
  ...)
```

to:

```swift
TransactionRowView(
  transaction: entry.transaction, accounts: accounts,
  categories: categories, earmarks: earmarks,
  displayAmounts: entry.displayAmounts,      // <-- new
  ...)
```

- [ ] **Step 3: Build to verify**

```bash
just build-mac 2>&1 | tee .agent-tmp/task8-build.txt
grep -i 'error' .agent-tmp/task8-build.txt
```

Expected: clean build. If `UpcomingTransactionRow.swift` or any other view also constructs `TransactionRowView`, update its call site too — `git -C $WORKTREE grep -n 'TransactionRowView('` to find them.

- [ ] **Step 4: Manual visual check via #Preview**

Open `TransactionRowView.swift` in Xcode, run the preview, verify:
- Single-amount rows look unchanged.
- The "Stock Trade" multi-leg preview now renders three inline entries.

Skip if running headless — the next UI tests (Task 18) cover end-to-end.

- [ ] **Step 5: `ui-review` agent**

Address findings.

- [ ] **Step 6: Format and commit**

```bash
just format
git -C $WORKTREE add Features/Transactions/Views/TransactionRowView.swift Features/Transactions/Views/TransactionListView+List.swift
git -C $WORKTREE commit -m "feat(transactions): per-instrument amount column with wrap"
rm .agent-tmp/task8-build.txt
```

---

## Task 9: `TransactionRowView` icon, title, and scope-reference plumbing for trades

Wire the trade icon, indigo colour, and the parenthetical-action title. The row gets a new `scopeReferenceInstrument: Instrument` parameter that drives `tradeTitleSentence`.

**Files:**
- Modify: `Features/Transactions/Views/TransactionRowView.swift`
- Modify: `Features/Transactions/Views/TransactionListView+List.swift`
- Modify: `Features/Transactions/Views/UpcomingTransactionRow.swift` (if it builds a `TransactionRowView` — verify with grep)

- [ ] **Step 1: Update `TransactionRowView`**

Add a new property:

```swift
let scopeReferenceInstrument: Instrument
```

Update `iconName` and `iconColor` to handle trade:

```swift
  private var iconName: String {
    if transaction.isTrade { return "arrow.up.arrow.down" }
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
      return "arrow.trianglehead.branch"
    }
    switch type {
    case .income: return "arrow.up"
    case .expense: return "arrow.down"
    case .transfer: return "arrow.left.arrow.right"
    case .openingBalance: return "flag.fill"
    case .trade: return "arrow.up.arrow.down"  // unreachable via isSimple but exhaustive
    }
  }

  private var iconColor: Color {
    if transaction.isTrade { return .indigo }
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
      return .purple
    }
    switch type {
    case .income: return .green
    case .expense: return .red
    case .transfer: return .blue
    case .openingBalance: return .orange
    case .trade: return .indigo
    }
  }
```

Update `displayPayee` rendering (at the top of the title `Text`) to append the trade sentence when applicable. Replace:

```swift
Text(displayPayee).lineLimit(1)
```

with:

```swift
Text(titleText).lineLimit(1)
```

and add:

```swift
  private var titleText: String {
    if let sentence = transaction.tradeTitleSentence(scopeReference: scopeReferenceInstrument) {
      let payee = transaction.payee?.trimmingCharacters(in: .whitespaces) ?? ""
      if payee.isEmpty {
        return sentence
      }
      return "\(payee) (\(sentence))"
    }
    return displayPayee
  }
```

Also update the `accessibilityDescription` block to use `titleText` when describing trade rows (to keep VoiceOver consistent).

- [ ] **Step 2: Pass the scope reference at every call site**

In `TransactionListView+List.swift`, the row needs:

```swift
.scopeReferenceInstrument(for: filter, accounts: accounts, earmarks: earmarks, profile: profile)
```

i.e. compute it inline as:

```swift
let scopeRef: Instrument = {
  if let id = filter.accountId, let acc = accounts.by(id: id) { return acc.instrument }
  if let id = filter.earmarkId, let em = earmarks.by(id: id) { return em.instrument }
  return profile.currency
}()
```

then pass it as `scopeReferenceInstrument: scopeRef` into the `TransactionRowView` initializer. Read `profile` from the existing `@Environment(ProfileSession.self)` if it isn't already in scope (grep `TransactionListView+List.swift` for `session.profile` to find the idiom used elsewhere).

Apply the same change to `UpcomingTransactionRow.swift` and any other site `git -C $WORKTREE grep -n 'TransactionRowView(' Features App` surfaces.

- [ ] **Step 3: Build & sanity-test**

```bash
just build-mac 2>&1 | tee .agent-tmp/task9-build.txt
just test-mac TransactionIsTradeTests TransactionTradeTitleTests 2>&1 | tee -a .agent-tmp/task9-build.txt
grep -i 'failed\|error' .agent-tmp/task9-build.txt
```

Expected: clean build, all relevant tests still green.

- [ ] **Step 4: `ui-review` and `code-review`**

Address findings (especially: VoiceOver coverage of the parenthetical sentence; keyboard navigation unchanged).

- [ ] **Step 5: Format and commit**

```bash
just format
git -C $WORKTREE add Features/Transactions/Views/TransactionRowView.swift Features/Transactions/Views/TransactionListView+List.swift Features/Transactions/Views/UpcomingTransactionRow.swift
git -C $WORKTREE commit -m "feat(transactions): trade row icon, indigo colour, and title verb"
rm .agent-tmp/task9-build.txt
```

---

## Task 10: `TransactionDraft+TradeMode.swift` — accessors

A new sibling extension file (parallel to `TransactionDraft+SimpleMode.swift`) that holds trade-specific accessors: `paidLegIndex`, `receivedLegIndex`, `feeIndices`, plus typed binders the detail view will use.

**Files:**
- Create: `Shared/Models/TransactionDraft+TradeMode.swift`
- Test (new): `MoolahTests/Shared/TransactionDraftTradeAccessorsTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Shared/TransactionDraftTradeAccessorsTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft trade accessors")
struct TransactionDraftTradeAccessorsTests {
  let aud = Instrument.AUD
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let account = UUID()

  private func tradeDraft(extraFees: [TransactionDraft.LegDraft] = []) -> TransactionDraft {
    var d = TransactionDraft(accountId: account, instrumentId: aud.id)
    d.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: account, amountText: "300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id),
      TransactionDraft.LegDraft(
        type: .trade, accountId: account, amountText: "20",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: vgs.id),
    ] + extraFees
    return d
  }

  @Test("paid index is the first .trade leg")
  func paidLegIndex() {
    let d = tradeDraft()
    #expect(d.paidLegIndex == 0)
  }

  @Test("received index is the second .trade leg")
  func receivedLegIndex() {
    let d = tradeDraft()
    #expect(d.receivedLegIndex == 1)
  }

  @Test("feeIndices returns the .expense legs in order")
  func feeIndices() {
    let fee1 = TransactionDraft.LegDraft(
      type: .expense, accountId: account, amountText: "10",
      categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id)
    let fee2 = TransactionDraft.LegDraft(
      type: .expense, accountId: account, amountText: "0.5",
      categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id)
    let d = tradeDraft(extraFees: [fee1, fee2])
    #expect(d.feeIndices == [2, 3])
  }

  @Test("appendFee adds an expense leg with default 0 amount")
  func appendFee() {
    var d = tradeDraft()
    d.appendFee(defaultInstrumentId: aud.id)
    #expect(d.legDrafts.count == 3)
    #expect(d.legDrafts[2].type == .expense)
    #expect(d.legDrafts[2].amountText == "0")
    #expect(d.legDrafts[2].instrumentId == aud.id)
    #expect(d.legDrafts[2].accountId == account)
  }

  @Test("removeFee at index drops only that leg")
  func removeFeeIndex() {
    let fee = TransactionDraft.LegDraft(
      type: .expense, accountId: account, amountText: "10",
      categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id)
    var d = tradeDraft(extraFees: [fee])
    d.removeFee(at: 2)
    #expect(d.legDrafts.count == 2)
    #expect(d.legDrafts.allSatisfy { $0.type == .trade })
  }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
just test-mac TransactionDraftTradeAccessorsTests 2>&1 | tee .agent-tmp/task10-fail.txt
grep -i 'failed\|error' .agent-tmp/task10-fail.txt
```

- [ ] **Step 3: Create the extension**

Create `Shared/Models/TransactionDraft+TradeMode.swift`:

```swift
import Foundation

// MARK: - Computed Accessors (Trade Mode)

extension TransactionDraft {
  /// Index of the first `.trade` leg (the "Paid" side). `nil` when the
  /// draft is not in trade shape.
  var paidLegIndex: Int? {
    legDrafts.firstIndex { $0.type == .trade }
  }

  /// Index of the second `.trade` leg (the "Received" side). `nil` when
  /// the draft does not have two `.trade` legs.
  var receivedLegIndex: Int? {
    let trade = legDrafts.enumerated().filter { $0.element.type == .trade }
    return trade.count == 2 ? trade[1].offset : nil
  }

  /// Indices of all `.expense` fee legs, in storage order.
  var feeIndices: [Int] {
    legDrafts.enumerated().compactMap { $0.element.type == .expense ? $0.offset : nil }
  }
}

// MARK: - Editing Methods (Trade Mode)

extension TransactionDraft {
  /// Append a new fee leg defaulting to amount `0` in the supplied
  /// instrument and the current trade account.
  mutating func appendFee(defaultInstrumentId: String) {
    legDrafts.append(
      LegDraft(
        type: .expense,
        accountId: paidLegIndex.flatMap { legDrafts[$0].accountId },
        amountText: "0",
        categoryId: nil,
        categoryText: "",
        earmarkId: nil,
        instrumentId: defaultInstrumentId
      ))
  }

  /// Remove the fee leg at the absolute draft index. No-op if the index
  /// is out of bounds or the leg is not `.expense`.
  mutating func removeFee(at index: Int) {
    guard legDrafts.indices.contains(index),
          legDrafts[index].type == .expense else { return }
    legDrafts.remove(at: index)
  }
}
```

- [ ] **Step 4: Run tests to verify pass**

```bash
just test-mac TransactionDraftTradeAccessorsTests 2>&1 | tee .agent-tmp/task10-pass.txt
grep -i 'failed\|error' .agent-tmp/task10-pass.txt
```

- [ ] **Step 5: Add the new file to `project.yml` if the project uses Xcode group-by-folder (verify with `just generate` and look for compile errors)**

```bash
just generate 2>&1 | tee -a .agent-tmp/task10-pass.txt
just build-mac 2>&1 | tee -a .agent-tmp/task10-pass.txt
```

- [ ] **Step 6: `code-review`**

- [ ] **Step 7: Format and commit**

```bash
just format
git -C $WORKTREE add Shared/Models/TransactionDraft+TradeMode.swift MoolahTests/Shared/TransactionDraftTradeAccessorsTests.swift
git -C $WORKTREE commit -m "feat(trades): TransactionDraft trade-mode accessors"
rm .agent-tmp/task10-*.txt
```

---

## Task 11: Forward mode-switch helpers (Income / Expense / Transfer / Custom → Trade)

Implement the rules in design §3.3 "Forward". The switch starts from the existing simple-mode `setType` helper but adds a parallel `switchToTrade` that handles the structural differences (extra `.trade` leg appended).

**Files:**
- Modify: `Shared/Models/TransactionDraft+TradeMode.swift`
- Test (new): `MoolahTests/Shared/TransactionDraftForwardSwitchTests.swift`

- [ ] **Step 1: Failing tests**

Create `MoolahTests/Shared/TransactionDraftForwardSwitchTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft forward switch to Trade")
struct TransactionDraftForwardSwitchTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let acctA = UUID()
  let acctB = UUID()

  private func accountsAUD() -> Accounts {
    Accounts(from: [
      Account(id: acctA, name: "A", type: .bank, instrument: aud, positions: []),
      Account(id: acctB, name: "B", type: .bank, instrument: aud, positions: []),
    ])
  }

  @Test("Income → Trade: existing leg becomes Received, Paid added at 0 in account currency")
  func incomeToTrade() {
    var d = TransactionDraft(accountId: acctA, instrumentId: aud.id)
    d.legDrafts = [TransactionDraft.LegDraft(
      type: .income, accountId: acctA, amountText: "3500",
      categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id)]
    d.switchToTrade(accounts: accountsAUD())
    #expect(d.legDrafts.count == 2)
    #expect(d.legDrafts.allSatisfy { $0.type == .trade })
    let received = d.legDrafts[d.receivedLegIndex!]
    #expect(received.amountText == "3500")
    #expect(received.instrumentId == aud.id)
    let paid = d.legDrafts[d.paidLegIndex!]
    #expect(paid.amountText == "0")
    #expect(paid.instrumentId == aud.id)
  }

  @Test("Expense → Trade: existing leg becomes Paid, Received added at 0")
  func expenseToTrade() {
    var d = TransactionDraft(accountId: acctA, instrumentId: aud.id)
    d.legDrafts = [TransactionDraft.LegDraft(
      type: .expense, accountId: acctA, amountText: "300",
      categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id)]
    d.switchToTrade(accounts: accountsAUD())
    let paid = d.legDrafts[d.paidLegIndex!]
    let received = d.legDrafts[d.receivedLegIndex!]
    #expect(paid.amountText == "300")
    #expect(received.amountText == "0")
  }

  @Test("Transfer → Trade: counterpart leg dropped, then Expense flow")
  func transferToTrade() {
    var d = TransactionDraft(accountId: acctA, instrumentId: aud.id)
    d.legDrafts = [
      TransactionDraft.LegDraft(
        type: .transfer, accountId: acctA, amountText: "500",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id),
      TransactionDraft.LegDraft(
        type: .transfer, accountId: acctB, amountText: "500",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id),
    ]
    d.switchToTrade(accounts: accountsAUD())
    #expect(d.legDrafts.count == 2)
    #expect(d.legDrafts.allSatisfy { $0.accountId == acctA })
    #expect(d.legDrafts.allSatisfy { $0.type == .trade })
  }

  @Test("Custom (already trade-shaped) → Trade: no structural change, isCustom flips")
  func customToTrade() {
    var d = TransactionDraft(accountId: acctA, instrumentId: aud.id)
    d.isCustom = true
    d.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id),
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "20",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: vgs.id),
    ]
    d.switchToTrade(accounts: accountsAUD())
    #expect(d.isCustom == false)
    #expect(d.legDrafts.count == 2)
  }

  @Test("canSwitchToTrade reflects shape compatibility")
  func canSwitch() {
    var d = TransactionDraft(accountId: acctA, instrumentId: aud.id)
    d.legDrafts = [TransactionDraft.LegDraft(
      type: .income, accountId: acctA, amountText: "100",
      categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id)]
    #expect(d.canSwitchToTrade(accounts: accountsAUD()) == true)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
just test-mac TransactionDraftForwardSwitchTests 2>&1 | tee .agent-tmp/task11-fail.txt
grep -i 'failed\|error' .agent-tmp/task11-fail.txt
```

- [ ] **Step 3: Implement `switchToTrade` and `canSwitchToTrade`**

Append to `Shared/Models/TransactionDraft+TradeMode.swift`:

```swift
// MARK: - Mode Switching (Forward → Trade)

extension TransactionDraft {
  /// Whether the current draft can transition to trade mode without
  /// losing data semantically. True when the existing legs already match
  /// the trade-shape rule (custom → trade) **or** when the draft is
  /// simple income / expense / transfer with at least one accounted leg.
  func canSwitchToTrade(accounts: Accounts) -> Bool {
    if isCustom {
      // Already-trade-shaped legs: 2 .trade + 0+ .expense, all on one
      // account, no category/earmark on .trade legs.
      let tradeCount = legDrafts.filter { $0.type == .trade }.count
      let nonTrade = legDrafts.filter { $0.type != .trade }
      let accounts = Set(legDrafts.compactMap(\.accountId))
      return tradeCount == 2
        && nonTrade.allSatisfy { $0.type == .expense }
        && accounts.count == 1
    }
    return relevantLeg.accountId != nil
  }

  /// Convert the draft into trade shape. Mirrors the rules in design §3.3
  /// "Forward". Caller is responsible for ensuring `canSwitchToTrade` is
  /// true; otherwise the result is ill-defined.
  mutating func switchToTrade(accounts: Accounts) {
    if isCustom {
      isCustom = false
      return
    }

    let existing = relevantLeg
    let acct = existing.accountId
    let acctInstrument = acct.flatMap { accounts.by(id: $0) }?.instrument.id ?? existing.instrumentId

    // Strip any counterpart for transfers (and non-relevant earmark legs).
    let originalLegs = legDrafts
    var newLegs: [LegDraft] = []

    let isReceivedFromIncome = (existing.type == .income)
    let received: LegDraft
    let paid: LegDraft

    if isReceivedFromIncome {
      received = LegDraft(
        type: .trade, accountId: acct, amountText: existing.amountText,
        categoryId: nil, categoryText: "", earmarkId: nil,
        instrumentId: existing.instrumentId)
      paid = LegDraft(
        type: .trade, accountId: acct, amountText: "0",
        categoryId: nil, categoryText: "", earmarkId: nil,
        instrumentId: acctInstrument)
    } else {
      paid = LegDraft(
        type: .trade, accountId: acct, amountText: existing.amountText,
        categoryId: nil, categoryText: "", earmarkId: nil,
        instrumentId: existing.instrumentId)
      received = LegDraft(
        type: .trade, accountId: acct, amountText: "0",
        categoryId: nil, categoryText: "", earmarkId: nil,
        instrumentId: acctInstrument)
    }
    newLegs = [paid, received]
    legDrafts = newLegs
    relevantLegIndex = 0
    isCustom = false
    _ = originalLegs  // counterpart legs are intentionally discarded
  }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
just test-mac TransactionDraftForwardSwitchTests 2>&1 | tee .agent-tmp/task11-pass.txt
grep -i 'failed\|error' .agent-tmp/task11-pass.txt
```

- [ ] **Step 5: `code-review`**

- [ ] **Step 6: Format and commit**

```bash
just format
git -C $WORKTREE add Shared/Models/TransactionDraft+TradeMode.swift MoolahTests/Shared/TransactionDraftForwardSwitchTests.swift
git -C $WORKTREE commit -m "feat(trades): forward mode-switch helpers into Trade"
rm .agent-tmp/task11-*.txt
```

---

## Task 12: Reverse mode-switch (Trade → Income / Expense / Transfer / Custom)

Implement the reverse rules from design §3.3.

**Files:**
- Modify: `Shared/Models/TransactionDraft+TradeMode.swift`
- Test (new): `MoolahTests/Shared/TransactionDraftReverseSwitchTests.swift`

- [ ] **Step 1: Failing tests**

Create `MoolahTests/Shared/TransactionDraftReverseSwitchTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft reverse switch from Trade")
struct TransactionDraftReverseSwitchTests {
  let aud = Instrument.AUD
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let acctA = UUID()
  let acctB = UUID()

  private func accounts() -> Accounts {
    Accounts(from: [
      Account(id: acctA, name: "A", type: .bank, instrument: aud, positions: []),
      Account(id: acctB, name: "B", type: .bank, instrument: aud, positions: []),
    ])
  }

  private func tradeDraft(withFee: Bool = false) -> TransactionDraft {
    var d = TransactionDraft(accountId: acctA, instrumentId: aud.id)
    d.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id),
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "20",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: vgs.id),
    ]
    if withFee {
      d.legDrafts.append(
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctA, amountText: "10",
          categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id))
    }
    return d
  }

  @Test("Trade → Income: keep Received leg, retype, drop Paid + fees")
  func toIncome() {
    var d = tradeDraft(withFee: true)
    d.switchFromTrade(to: .income, accounts: accounts())
    #expect(d.legDrafts.count == 1)
    #expect(d.legDrafts[0].type == .income)
    #expect(d.legDrafts[0].amountText == "20")
    #expect(d.legDrafts[0].instrumentId == vgs.id)
    #expect(d.legDrafts[0].accountId == acctA)
  }

  @Test("Trade → Expense: keep Paid leg, retype, drop Received + fees")
  func toExpense() {
    var d = tradeDraft(withFee: true)
    d.switchFromTrade(to: .expense, accounts: accounts())
    #expect(d.legDrafts.count == 1)
    #expect(d.legDrafts[0].type == .expense)
    #expect(d.legDrafts[0].amountText == "300")
    #expect(d.legDrafts[0].instrumentId == aud.id)
  }

  @Test("Trade → Transfer: keep Paid leg + add counterpart on a different account")
  func toTransfer() {
    var d = tradeDraft(withFee: false)
    d.switchFromTrade(to: .transfer, accounts: accounts())
    #expect(d.legDrafts.count == 2)
    #expect(d.legDrafts.allSatisfy { $0.type == .transfer })
    let acctIds = Set(d.legDrafts.compactMap(\.accountId))
    #expect(acctIds == Set([acctA, acctB]))
  }

  @Test("Trade → Custom: lossless, all legs preserved with .trade types")
  func toCustom() {
    var d = tradeDraft(withFee: true)
    d.switchFromTrade(to: nil, accounts: accounts())
    #expect(d.isCustom == true)
    #expect(d.legDrafts.count == 3)
    #expect(d.legDrafts.filter { $0.type == .trade }.count == 2)
    #expect(d.legDrafts.filter { $0.type == .expense }.count == 1)
  }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
just test-mac TransactionDraftReverseSwitchTests 2>&1 | tee .agent-tmp/task12-fail.txt
grep -i 'failed\|error' .agent-tmp/task12-fail.txt
```

- [ ] **Step 3: Implement `switchFromTrade(to:)`**

Append to `Shared/Models/TransactionDraft+TradeMode.swift`:

```swift
// MARK: - Mode Switching (Reverse from Trade)

extension TransactionDraft {
  /// Convert a trade-shaped draft into one of the simpler modes. Pass
  /// `nil` for `to` to flip to Custom (lossless escape hatch).
  mutating func switchFromTrade(to target: TransactionType?,
                                accounts: Accounts) {
    if target == nil {
      isCustom = true
      return
    }
    guard let paidIdx = paidLegIndex, let receivedIdx = receivedLegIndex else {
      // Not actually a trade — defensive no-op.
      return
    }
    let paidLeg = legDrafts[paidIdx]
    let receivedLeg = legDrafts[receivedIdx]
    let acctId = paidLeg.accountId

    switch target {
    case .income:
      legDrafts = [LegDraft(
        type: .income, accountId: receivedLeg.accountId,
        amountText: receivedLeg.amountText,
        categoryId: nil, categoryText: "",
        earmarkId: nil, instrumentId: receivedLeg.instrumentId)]
      relevantLegIndex = 0
    case .expense:
      legDrafts = [LegDraft(
        type: .expense, accountId: paidLeg.accountId,
        amountText: paidLeg.amountText,
        categoryId: nil, categoryText: "",
        earmarkId: nil, instrumentId: paidLeg.instrumentId)]
      relevantLegIndex = 0
    case .transfer:
      let other = accounts.ordered.first { $0.id != acctId }
      let counterpart = LegDraft(
        type: .transfer,
        accountId: other?.id,
        amountText: negatedAmountText(paidLeg.amountText),
        categoryId: nil, categoryText: "",
        earmarkId: nil,
        instrumentId: other?.instrument.id ?? paidLeg.instrumentId)
      let primary = LegDraft(
        type: .transfer, accountId: paidLeg.accountId,
        amountText: paidLeg.amountText,
        categoryId: nil, categoryText: "",
        earmarkId: nil, instrumentId: paidLeg.instrumentId)
      legDrafts = [primary, counterpart]
      relevantLegIndex = 0
    case .openingBalance, .trade, .none:
      // .openingBalance not user-selectable; .trade is a no-op; nil
      // handled above. Defensive default.
      break
    }
    isCustom = false
  }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
just test-mac TransactionDraftReverseSwitchTests 2>&1 | tee .agent-tmp/task12-pass.txt
grep -i 'failed\|error' .agent-tmp/task12-pass.txt
```

- [ ] **Step 5: `code-review`**

- [ ] **Step 6: Format and commit**

```bash
just format
git -C $WORKTREE add Shared/Models/TransactionDraft+TradeMode.swift MoolahTests/Shared/TransactionDraftReverseSwitchTests.swift
git -C $WORKTREE commit -m "feat(trades): reverse mode-switch helpers from Trade"
rm .agent-tmp/task12-*.txt
```

---

## Task 13: Add `.trade` to `TransactionMode` in `TransactionDetailModeSection`

Wire the picker so the user can pick Trade. The action handlers call the helpers from Tasks 11 and 12.

**Files:**
- Modify: `Features/Transactions/Views/Detail/TransactionDetailModeSection.swift`

- [ ] **Step 1: Extend `TransactionMode` and `availableModes`**

Replace the file contents:

```swift
import SwiftUI

private enum TransactionMode: Hashable {
  case income, expense, transfer, trade, custom

  var displayName: String {
    switch self {
    case .income: return "Income"
    case .expense: return "Expense"
    case .transfer: return "Transfer"
    case .trade: return "Trade"
    case .custom: return "Custom"
    }
  }
}

struct TransactionDetailModeSection: View {
  let transaction: Transaction
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  let supportsComplexTransactions: Bool

  private var availableModes: [TransactionMode] {
    var modes: [TransactionMode] = [.income, .expense, .transfer, .trade]
    if supportsComplexTransactions { modes.append(.custom) }
    return modes
  }

  private var modeBinding: Binding<TransactionMode> {
    Binding(
      get: {
        if draft.isCustom { return .custom }
        if draft.legDrafts.contains(where: { $0.type == .trade }) { return .trade }
        switch draft.type {
        case .income: return .income
        case .expense: return .expense
        case .transfer: return .transfer
        case .openingBalance: return .expense
        case .trade: return .trade
        }
      },
      set: { newMode in
        let wasTrade = draft.legDrafts.contains { $0.type == .trade }
        switch newMode {
        case .custom:
          draft.isCustom = true
        case .trade:
          if wasTrade && draft.isCustom {
            draft.isCustom = false
          } else if !wasTrade {
            draft.switchToTrade(accounts: accounts)
          }
        case .income:
          if wasTrade { draft.switchFromTrade(to: .income, accounts: accounts) }
          else if draft.isCustom { draft.switchToSimple() }
          if !wasTrade { draft.setType(.income, accounts: accounts) }
        case .expense:
          if wasTrade { draft.switchFromTrade(to: .expense, accounts: accounts) }
          else if draft.isCustom { draft.switchToSimple() }
          if !wasTrade { draft.setType(.expense, accounts: accounts) }
        case .transfer:
          if wasTrade { draft.switchFromTrade(to: .transfer, accounts: accounts) }
          else if draft.isCustom { draft.switchToSimple() }
          if !wasTrade { draft.setType(.transfer, accounts: accounts) }
        }
      }
    )
  }

  var body: some View {
    Section {
      if transaction.legs.contains(where: { $0.type == .openingBalance }) {
        LabeledContent("Type") {
          Text(TransactionType.openingBalance.displayName)
            .foregroundStyle(.secondary)
        }
      } else if !transaction.isSimple && !transaction.isTrade && !draft.isCustom {
        LabeledContent("Type") {
          Text("Custom").foregroundStyle(.secondary)
        }
        .accessibilityHint(
          "This transaction has custom sub-transactions and cannot be changed to a simpler type.")
      } else {
        Picker("Type", selection: modeBinding) {
          ForEach(availableModes, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .accessibilityLabel("Transaction type")
        #if os(iOS)
          .pickerStyle(.segmented)
        #endif
      }
    }
  }
}
```

- [ ] **Step 2: Build & sanity-test**

```bash
just build-mac 2>&1 | tee .agent-tmp/task13-build.txt
just test-mac TransactionDraftForwardSwitchTests TransactionDraftReverseSwitchTests 2>&1 | tee -a .agent-tmp/task13-build.txt
grep -i 'failed\|error' .agent-tmp/task13-build.txt
```

- [ ] **Step 3: `ui-review`**

- [ ] **Step 4: Format and commit**

```bash
just format
git -C $WORKTREE add Features/Transactions/Views/Detail/TransactionDetailModeSection.swift
git -C $WORKTREE commit -m "feat(transactions): mode picker offers Trade"
rm .agent-tmp/task13-build.txt
```

---

## Task 14: Build `TransactionDetailTradeSection.swift`

Single section view: Account picker + Paid row + Received row + derived-rate caption.

**Files:**
- Create: `Features/Transactions/Views/Detail/TransactionDetailTradeSection.swift`

- [ ] **Step 1: Write the view**

Create the file:

```swift
import SwiftUI

/// Trade-mode primary section. Mirrors the structure of
/// `TransactionDetailDetailsSection` + `TransactionDetailAccountSection` for
/// transfers, but with a single shared account picker and dual amount
/// rows. See design §3.2.
struct TransactionDetailTradeSection: View {
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  let sortedAccounts: [Account]
  let knownInstruments: [Instrument]
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  var body: some View {
    Section("Trade") {
      accountPicker
      paidRow
      receivedRow
      if let rateText = derivedRateText {
        Text(rateText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityLabel(rateText)
      }
    }
  }

  private var accountBinding: Binding<UUID?> {
    Binding(
      get: { draft.legDrafts.first?.accountId },
      set: { newId in
        for index in draft.legDrafts.indices {
          draft.legDrafts[index].accountId = newId
          if let id = newId, let account = accounts.by(id: id),
             draft.legDrafts[index].type == .expense {
            // Default new fee instruments to the account's currency.
            draft.legDrafts[index].instrumentId =
              draft.legDrafts[index].instrumentId ?? account.instrument.id
          }
        }
      }
    )
  }

  private var accountPicker: some View {
    Picker("Account", selection: accountBinding) {
      Text("None").tag(UUID?.none)
      ForEach(sortedAccounts) { account in
        Text(account.name).tag(UUID?.some(account.id))
      }
    }
    .accessibilityIdentifier(UITestIdentifiers.Detail.tradeAccount)
  }

  private var paidRow: some View {
    legAmountRow(label: "Paid", indexAccessor: { draft.paidLegIndex },
                 focus: .tradePaidAmount,
                 identifier: UITestIdentifiers.Detail.tradePaidAmount,
                 instrumentIdentifier: UITestIdentifiers.Detail.tradePaidInstrument)
  }

  private var receivedRow: some View {
    legAmountRow(label: "Received", indexAccessor: { draft.receivedLegIndex },
                 focus: .tradeReceivedAmount,
                 identifier: UITestIdentifiers.Detail.tradeReceivedAmount,
                 instrumentIdentifier: UITestIdentifiers.Detail.tradeReceivedInstrument)
  }

  @ViewBuilder
  private func legAmountRow(
    label: String,
    indexAccessor: () -> Int?,
    focus: TransactionDetailFocus,
    identifier: String,
    instrumentIdentifier: String
  ) -> some View {
    if let idx = indexAccessor() {
      let amountBinding = Binding(
        get: { draft.legDrafts[idx].amountText },
        set: { draft.legDrafts[idx].amountText = $0 })
      let instrumentBinding = Binding<Instrument>(
        get: {
          let id = draft.legDrafts[idx].instrumentId ?? Instrument.AUD.id
          return knownInstruments.first { $0.id == id } ?? Instrument.fiat(code: id)
        },
        set: { draft.legDrafts[idx].instrumentId = $0.id })

      HStack {
        Text(label)
        Spacer()
        TextField(label, text: amountBinding)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .focused($focusedField, equals: focus)
          .accessibilityIdentifier(identifier)
        InstrumentPickerField(
          label: "",
          kinds: Set(Instrument.Kind.allCases),
          selection: instrumentBinding
        )
        .labelsHidden()
        .accessibilityIdentifier(instrumentIdentifier)
      }
    }
  }

  /// Derived rate caption: `≈ 1 {received} = X.XX {paid}`. Hidden when
  /// either side is unparseable or zero.
  private var derivedRateText: String? {
    guard let paidIdx = draft.paidLegIndex,
          let receivedIdx = draft.receivedLegIndex else { return nil }
    let paid = draft.legDrafts[paidIdx]
    let received = draft.legDrafts[receivedIdx]
    let paidInst = paid.instrumentId.flatMap { id in
      knownInstruments.first { $0.id == id } ?? Instrument.fiat(code: id)
    } ?? Instrument.AUD
    let receivedInst = received.instrumentId.flatMap { id in
      knownInstruments.first { $0.id == id } ?? Instrument.fiat(code: id)
    } ?? Instrument.AUD
    guard
      let paidQty = InstrumentAmount.parseQuantity(
        from: paid.amountText, decimals: paidInst.decimals),
      let receivedQty = InstrumentAmount.parseQuantity(
        from: received.amountText, decimals: receivedInst.decimals),
      paidQty != 0, receivedQty != 0
    else { return nil }
    let rate = paidQty / receivedQty
    let rateFormatted = rate.formatted(
      .number.precision(.significantDigits(2...4)).grouping(.never))
    return "≈ 1 \(receivedInst.id) = \(rateFormatted) \(paidInst.id)"
  }
}
```

- [ ] **Step 2: Add new `TransactionDetailFocus` cases**

In `TransactionDetailFocus.swift`, add:

```swift
case tradePaidAmount
case tradeReceivedAmount
case tradeFeeAmount(Int)  // index into legDrafts; used by Task 15
```

(Update the existing `Hashable` synthesis if the enum has associated values requiring a manual conformance — `Hashable` is auto-synthesised for enums with `Hashable` payloads, so this should compile cleanly.)

- [ ] **Step 3: Add identifiers to `UITestSupport/UITestIdentifiers.swift`**

In the `Detail` namespace:

```swift
static let tradeAccount = "transactionDetail.trade.account"
static let tradePaidAmount = "transactionDetail.trade.paidAmount"
static let tradePaidInstrument = "transactionDetail.trade.paidInstrument"
static let tradeReceivedAmount = "transactionDetail.trade.receivedAmount"
static let tradeReceivedInstrument = "transactionDetail.trade.receivedInstrument"
static let tradeAddFeeButton = "transactionDetail.trade.addFee"
static func tradeFeeAmount(_ index: Int) -> String { "transactionDetail.trade.feeAmount.\(index)" }
static func tradeFeeRemove(_ index: Int) -> String { "transactionDetail.trade.feeRemove.\(index)" }
```

- [ ] **Step 4: Build**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task14-build.txt
grep -i 'error' .agent-tmp/task14-build.txt
```

- [ ] **Step 5: `ui-review` and `code-review`**

- [ ] **Step 6: Format and commit**

```bash
just format
git -C $WORKTREE add Features/Transactions/Views/Detail/TransactionDetailTradeSection.swift Features/Transactions/Views/Detail/TransactionDetailFocus.swift UITestSupport/UITestIdentifiers.swift
git -C $WORKTREE commit -m "feat(transactions): TransactionDetailTradeSection view"
rm .agent-tmp/task14-build.txt
```

---

## Task 15: Build `TransactionDetailFeeSection.swift`

Per-fee section: amount + instrument + category + earmark + remove. Plus an `+ Add fee` button is provided by Task 16's parent view.

**Files:**
- Create: `Features/Transactions/Views/Detail/TransactionDetailFeeSection.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI

/// One fee section in the trade-mode editor. Renders amount + instrument,
/// category, earmark, and a destructive Remove button.
struct TransactionDetailFeeSection: View {
  let legIndex: Int
  let displayNumber: Int
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let knownInstruments: [Instrument]
  @Binding var categoryState: CategoryAutocompleteState
  @FocusState.Binding var focusedField: TransactionDetailFocus?
  let onRequestRemove: () -> Void

  var body: some View {
    Section("Fee \(displayNumber)") {
      amountRow
      categoryField
      earmarkPicker
      Button(role: .destructive, action: onRequestRemove) {
        Text("Remove Fee").frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier(UITestIdentifiers.Detail.tradeFeeRemove(displayNumber - 1))
    }
  }

  private var amountRow: some View {
    let amountBinding = Binding(
      get: { draft.legDrafts[legIndex].amountText },
      set: { draft.legDrafts[legIndex].amountText = $0 })
    let instrumentBinding = Binding<Instrument>(
      get: {
        let id = draft.legDrafts[legIndex].instrumentId ?? Instrument.AUD.id
        return knownInstruments.first { $0.id == id } ?? Instrument.fiat(code: id)
      },
      set: { draft.legDrafts[legIndex].instrumentId = $0.id })

    return HStack {
      Text("Amount")
      Spacer()
      TextField("Amount", text: amountBinding)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        #if os(iOS)
          .keyboardType(.decimalPad)
        #endif
        .focused($focusedField, equals: .tradeFeeAmount(legIndex))
        .accessibilityIdentifier(UITestIdentifiers.Detail.tradeFeeAmount(displayNumber - 1))
      InstrumentPickerField(
        label: "",
        kinds: Set(Instrument.Kind.allCases),
        selection: instrumentBinding
      )
      .labelsHidden()
    }
  }

  // Reuse the same legCategory autocomplete machinery used by Custom mode
  // (TransactionDetailLegRow). The category field component is small
  // enough to inline here; mirror that file's pattern.
  @ViewBuilder
  private var categoryField: some View {
    LegCategoryAutocompleteField(
      legIndex: legIndex,
      text: Binding(
        get: { draft.legDrafts[legIndex].categoryText },
        set: { draft.legDrafts[legIndex].categoryText = $0 }),
      highlightedIndex: $categoryState.highlightedIndex,
      suggestionCount: categoryState.visibleSuggestions(
        for: draft.legDrafts[legIndex].categoryText, in: categories).count,
      onTextChange: { _ in categoryState.showSuggestions = true },
      onAcceptHighlighted: {},
      onCancel: { categoryState.cancel() }
    )
  }

  private var earmarkPicker: some View {
    Picker("Earmark", selection: Binding(
      get: { draft.legDrafts[legIndex].earmarkId },
      set: { draft.legDrafts[legIndex].earmarkId = $0 })
    ) {
      Text("None").tag(UUID?.none)
      ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
        Text(earmark.name).tag(UUID?.some(earmark.id))
      }
    }
    #if os(macOS)
      .pickerStyle(.menu)
    #endif
  }
}
```

- [ ] **Step 2: Build**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task15-build.txt
grep -i 'error' .agent-tmp/task15-build.txt
```

- [ ] **Step 3: `ui-review`**

- [ ] **Step 4: Format and commit**

```bash
just format
git -C $WORKTREE add Features/Transactions/Views/Detail/TransactionDetailFeeSection.swift
git -C $WORKTREE commit -m "feat(transactions): TransactionDetailFeeSection per-fee row"
rm .agent-tmp/task15-build.txt
```

---

## Task 16: Wire `tradeModeContent` into `TransactionDetailView`

Add a `tradeModeContent` branch to `modeAwareSections` and the `+ Add fee` button below the fee sections.

**Files:**
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`

- [ ] **Step 1: Branch on `isTrade`**

In `modeAwareSections`:

```swift
  @ViewBuilder private var modeAwareSections: some View {
    if isSimpleEarmarkOnly {
      earmarkOnlyContent
    } else if isTradeMode {
      tradeModeContent
    } else if draft.isCustom {
      customModeContent
    } else {
      simpleModeContent
    }
  }
```

Add a helper:

```swift
  private var isTradeMode: Bool {
    !draft.isCustom && draft.legDrafts.contains { $0.type == .trade }
  }
```

- [ ] **Step 2: Add `tradeModeContent`**

```swift
  @ViewBuilder private var tradeModeContent: some View {
    modeSection.disabled(!isEditable)
    TransactionDetailTradeSection(
      draft: $draft,
      accounts: accounts,
      sortedAccounts: sortedAccounts,
      knownInstruments: knownInstruments,
      focusedField: $focusedField
    )
    .disabled(!isEditable)

    ForEach(Array(draft.feeIndices.enumerated()), id: \.element) { ordinal, legIndex in
      TransactionDetailFeeSection(
        legIndex: legIndex,
        displayNumber: ordinal + 1,
        draft: $draft,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        knownInstruments: knownInstruments,
        categoryState: legCategoryStateBinding(for: legIndex),
        focusedField: $focusedField,
        onRequestRemove: { draft.removeFee(at: legIndex) }
      )
    }

    Section {
      Button {
        let fallback = draft.legDrafts.first?.accountId
          .flatMap { accounts.by(id: $0) }?.instrument.id ?? Instrument.AUD.id
        draft.appendFee(defaultInstrumentId: fallback)
      } label: {
        Label("Add Fee", systemImage: "plus")
          .frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier(UITestIdentifiers.Detail.tradeAddFeeButton)
    }

    TransactionDetailCustomDetailsSection(  // payee + date — same component used by custom
      draft: $draft,
      suggestionSource: transactionStore.payeeSuggestionSource,
      payeeState: $payeeState,
      onAutofill: autofillFromPayee,
      focusedField: $focusedField
    )

    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft).disabled(!isEditable)
    }
    TransactionDetailNotesSection(notes: $draft.notes)
  }
```

- [ ] **Step 3: Update `TransactionDraft.toTransaction` validation**

Open `Shared/Models/TransactionDraft.swift`. The trade-mode draft passes `instrumentId`-resolved legs through `toTransaction`; that path already accepts arbitrary `.trade` legs because it just maps `LegDraft` → `TransactionLeg`. Verify no extra logic needed; if `isValid` short-circuits on shapes that look "weird" (e.g. zero amount), confirm trade legs with zero amount still serialise cleanly by extending `isValid` if necessary:

```swift
  var isValid: Bool {
    guard !legDrafts.isEmpty else { return false }
    for leg in legDrafts {
      // .trade and .expense fee legs may have an account but no earmark requirement.
      if leg.type == .trade {
        guard leg.accountId != nil else { return false }
      } else {
        guard leg.accountId != nil || leg.earmarkId != nil else { return false }
      }
      guard !leg.amountText.isEmpty,
        InstrumentAmount.parseQuantity(from: leg.amountText, decimals: 10) != nil
      else { return false }
    }
    if isRepeating {
      guard let period = recurPeriod, period != .once, recurEvery >= 1 else { return false }
    }
    return true
  }
```

- [ ] **Step 4: Build & smoke test**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task16-build.txt
just test-mac TransactionDraftForwardSwitchTests TransactionDraftReverseSwitchTests TransactionDraftTradeAccessorsTests TransactionIsTradeTests 2>&1 | tee -a .agent-tmp/task16-build.txt
grep -i 'failed\|error' .agent-tmp/task16-build.txt
```

- [ ] **Step 5: Manual smoke test**

```bash
just run-mac
```

In the app: open a transaction inspector → switch type to Trade → enter Paid + Received → press Add Fee → enter a fee → save → confirm row updates and balance reflects the cash leg.

- [ ] **Step 6: `ui-review` and `code-review`**

- [ ] **Step 7: Format and commit**

```bash
just format
git -C $WORKTREE add Features/Transactions/Views/TransactionDetailView.swift Shared/Models/TransactionDraft.swift
git -C $WORKTREE commit -m "feat(transactions): wire trade mode into TransactionDetailView"
rm .agent-tmp/task16-build.txt
```

---

## Task 17: UI test seed and identifiers

Add (or reuse) a UI test seed that exposes a trade-eligible account and a couple of registered non-fiat instruments so the UI test in Task 18 can drive the flow without depending on remote data.

**Files:**
- Modify: `UITestSupport/UITestSeed.swift`
- Modify: `App/UITestSeedHydrator+Upserts.swift`

- [ ] **Step 1: Inspect existing seeds**

```bash
git -C $WORKTREE grep -n 'enum UITestSeed\|case .*=.*"' UITestSupport/UITestSeed.swift | head -40
```

If a `tradeReady` seed (or equivalent — a profile with at least one account + one stock instrument registered) already exists, skip to Task 18. Otherwise add one:

- [ ] **Step 2: Add a `.tradeReady` case**

In `UITestSupport/UITestSeed.swift`:

```swift
case tradeReady = "trade-ready"
```

In `App/UITestSeedHydrator+Upserts.swift`, add a new branch in the seed switch that hydrates:
- One profile with currency `.AUD`.
- One bank-type account named "Brokerage" with `instrument: .AUD`.
- A registered stock instrument `Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")` so it appears in the InstrumentPickerField.
- (Optional) one category named "Brokerage" so the fee leg can pick one.

Mirror an existing single-account seed (e.g. the one used by `InstrumentPickerUITests`) for structure.

- [ ] **Step 3: Build and verify the seed loads**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/task17-build.txt
grep -i 'error' .agent-tmp/task17-build.txt
```

- [ ] **Step 4: Format and commit**

```bash
just format
git -C $WORKTREE add UITestSupport/UITestSeed.swift App/UITestSeedHydrator+Upserts.swift
git -C $WORKTREE commit -m "test(ui): tradeReady seed for trade-flow UI tests"
rm .agent-tmp/task17-build.txt
```

---

## Task 18: `TradeFlowUITests` end-to-end

Per design §5.3, drive the full create-trade-with-fee flow.

**Files:**
- Create: `MoolahUITests_macOS/Tests/TradeFlowUITests.swift`
- Modify: `MoolahUITests_macOS/Helpers/MoolahApp.swift` (or add a `TradeFormDriver` under `MoolahUITests_macOS/Helpers/` per `guides/UI_TEST_GUIDE.md`).

- [ ] **Step 1: Read `guides/UI_TEST_GUIDE.md` for the screen-driver pattern**

Per project memory, UI tests import only `XCTest` and never poke `Moolah` types directly; everything goes through a screen-driver helper that hides element resolution. Add a `TradeFormDriver` (or extend the existing `TransactionDetailDriver` if there is one) with methods for the trade flow:

```swift
import XCTest

@MainActor
struct TradeFormDriver {
  let app: XCUIApplication

  func switchToTradeMode() { /* tap segmented picker option labelled "Trade" */ }
  func setPaid(amount: String, instrument: String) { /* ... */ }
  func setReceived(amount: String, instrument: String) { /* ... */ }
  func addFee(amount: String, instrument: String, category: String?) { /* ... */ }
  func save() { /* hit Cmd-S or focus loss; depends on existing pattern */ }
}
```

- [ ] **Step 2: Write the test**

Create `MoolahUITests_macOS/Tests/TradeFlowUITests.swift`:

```swift
import XCTest

final class TradeFlowUITests: MoolahUITestCase {
  func testCreateTradeWithFeeRendersTradeRow() throws {
    let app = launch(with: .tradeReady)
    let driver = TradeFormDriver(app: app)

    // Navigate to a new transaction (depends on existing nav idiom — mirror
    // a passing test, e.g. InstrumentPickerUITests, for the open path).
    openNewTransaction(in: app, accountName: "Brokerage")

    driver.switchToTradeMode()
    driver.setPaid(amount: "300", instrument: "AUD")
    driver.setReceived(amount: "20", instrument: "VGS.AX")
    driver.addFee(amount: "10", instrument: "AUD", category: "Brokerage")
    driver.save()

    // Assert the resulting row.
    let row = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Bought 20 VGS.AX")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
  }
}
```

- [ ] **Step 3: Run on macOS**

```bash
just test-mac TradeFlowUITests 2>&1 | tee .agent-tmp/task18-pass.txt
grep -B2 -A5 'failed\|error' .agent-tmp/task18-pass.txt | head -100
```

If failures surface, debug by inspecting the `xcresult` artefact via `MoolahUITestCase` infrastructure — do not paper over with sleeps.

- [ ] **Step 4: `ui-test-review`**

Address findings (no element caching, identifier discipline, no sleeps).

- [ ] **Step 5: Format and commit**

```bash
just format
git -C $WORKTREE add MoolahUITests_macOS/Tests/TradeFlowUITests.swift MoolahUITests_macOS/Helpers/
git -C $WORKTREE commit -m "test(ui): end-to-end trade flow"
rm .agent-tmp/task18-pass.txt
```

---

## Task 19: Final pass — format, full test run, agent reviews

- [ ] **Step 1: Run `just format`**

```bash
just format
git -C $WORKTREE diff --stat
```

If the diff is empty, format was clean. Otherwise commit the formatting changes:

```bash
git -C $WORKTREE add -u
git -C $WORKTREE commit -m "chore: apply just format"
```

- [ ] **Step 2: Run `just format-check`**

```bash
just format-check 2>&1 | tee .agent-tmp/task19-format.txt
grep -i 'error\|warning' .agent-tmp/task19-format.txt
```

Expected: zero diffs, zero new SwiftLint baseline violations. If a violation appears: **fix the underlying code** (split a too-large file, rename, etc.). Do **not** modify `.swiftlint-baseline.yml`.

- [ ] **Step 3: Full test run**

```bash
just test 2>&1 | tee .agent-tmp/task19-test.txt
grep -i 'failed\|error:' .agent-tmp/task19-test.txt
```

Expected: every suite green on both iOS and macOS.

- [ ] **Step 4: Agent reviews on the cumulative diff**

Run the relevant agents on the `feature/trade-transaction-ui-design` branch diff against `origin/main`:

- `@code-review` — every Swift file touched
- `@ui-review` — `TransactionRowView.swift`, `TransactionDetailView.swift`, `TransactionDetailModeSection.swift`, `TransactionDetailTradeSection.swift`, `TransactionDetailFeeSection.swift`
- `@concurrency-review` — `Transaction.swift`, `TradeEventClassifier.swift`, anything else `async`
- `@instrument-conversion-review` — `TradeEventClassifier.swift`, `Transaction.swift` `computeDisplayAmounts`, the per-instrument summing
- `@ui-test-review` — `TradeFlowUITests.swift` and the new driver

Address findings. Per project memory: don't dismiss findings; apply Critical / Important / Minor; if anything seems pre-existing-elsewhere, ask before deferring.

- [ ] **Step 5: Format-check sanity once more**

```bash
just format-check
just build-mac
```

- [ ] **Step 6: Commit any review fixes**

```bash
git -C $WORKTREE status
git -C $WORKTREE add -u
git -C $WORKTREE commit -m "chore(trades): address agent review findings"
```

---

## Task 20: Open PR and queue

- [ ] **Step 1: Push branch**

```bash
git -C $WORKTREE push -u origin feature/trade-transaction-ui-design
```

- [ ] **Step 2: Create PR**

```bash
gh -R ajsutton/moolah-native pr create \
  --base main \
  --head feature/trade-transaction-ui-design \
  --title "feat(transactions): first-class Trade transaction UI" \
  --body "$(cat <<'EOF'
## Summary
- Adds `TransactionType.trade` and structural `Transaction.isTrade` detector.
- Dedicated Trade mode in `TransactionDetailView` with single-account picker, Paid / Received rows, optional multiple fee rows.
- Generalised per-instrument amount column in `TransactionRowView` (sums legs by native instrument in scope; balance line unchanged).
- Indigo `arrow.up.arrow.down` icon and a scope-aware "Bought / Sold / Swapped" title sentence (in parentheses after payee when one is set).
- `TradeEventClassifier` simplified to filter by `type == .trade`.
- End-to-end UI test for the create-trade-with-fee flow.
- Follow-up issue [#558](https://github.com/ajsutton/moolah-native/issues/558) tracks the SelfWealthParser fee-attach + cost-basis decision.

Spec: `plans/2026-04-28-trade-transaction-ui-design.md`
Plan: `plans/2026-04-28-trade-transaction-ui-implementation.md`

## Test plan
- [ ] `just test` — full iOS + macOS suite green
- [ ] `just format-check` clean
- [ ] Manual: open a brokerage account, create a trade, add a fee, verify row + detail
- [ ] Manual: switch a trade to Income → Expense → Transfer → Custom and back; data preserved per design §3.3
EOF
)"
```

- [ ] **Step 3: Wait for CI to start, then queue via merge-queue skill**

Per project memory: every PR opened goes through the merge-queue skill, never manual merge. Once the PR number is known and CI is running:

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <pr-number>
```

Or invoke the `merge-queue-manager` agent with the PR number.

- [ ] **Step 4: After merge, move design + plan into `plans/completed/`**

A short follow-up commit on `main` (via a tiny worktree + PR per the project's own rules) that runs:

```bash
git mv plans/2026-04-28-trade-transaction-ui-design.md plans/completed/
git mv plans/2026-04-28-trade-transaction-ui-implementation.md plans/completed/
```

This step is post-merge bookkeeping — not strictly part of the feature PR — and can be batched with other completed plans if convenient.

---

## Self-review checklist

After writing the plan, the author ran the following checks (see `superpowers:writing-plans` Self-Review section):

1. **Spec coverage** — every section of `plans/2026-04-28-trade-transaction-ui-design.md` maps to one or more tasks above:
   - §1.1 → Task 1 · §1.2 → Task 2 · §1.3 → §1.3 of design doc + critical-context note above (no separate task: rollout requirement is operational)
   - §2 → Task 3 · §2 fee-ignored note → Task 3 docstring
   - §3.1 → Task 13 · §3.2 → Tasks 14, 15, 16 · §3.3 → Tasks 11, 12 · §3.4 → preserved by leaving `simpleModeContent` untouched (verified by Task 16 reading the existing branch)
   - §4.1 → Task 9 · §4.2 → Tasks 5, 6, 8 · §4.3 → Tasks 7, 9 · §4.4 → covered by leaving the metadata row alone in Task 9 · §4.5 → unchanged · §4.6 → Task 9
   - §5.1 → Tasks 1, 2, 6, 7, 10, 11, 12 (test files) · §5.2 → Task 4 · §5.3 → Task 18

2. **Placeholder scan** — no "TBD", "fill in details", "similar to Task N", or "write tests for the above" without code. The few cross-task references (e.g. Task 14 mentioning Task 15's button location) repeat the necessary context inline.

3. **Type consistency** — `displayAmounts: [InstrumentAmount]`, `paidLegIndex` / `receivedLegIndex` / `feeIndices`, `switchToTrade(accounts:)` / `switchFromTrade(to:accounts:)`, and `tradeTitleSentence(scopeReference:)` are used identically in every reference.

4. **Scope** — the plan is one cohesive PR. No subsystem warrants splitting.
