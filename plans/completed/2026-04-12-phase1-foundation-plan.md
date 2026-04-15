# Phase 1: Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the core financial model (MonetaryAmount/Currency/single-amount transactions) with the unified Instrument/InstrumentAmount/transaction-legs model, keeping all existing functionality working.

**Completed:** `00eb0df` on `feature/multi-instrument` — 589 tests passing on macOS.

**Architecture:** Introduce `Instrument` (fiat only in this phase), `InstrumentAmount` (Decimal-based replacement for MonetaryAmount), and `TransactionLeg` as the unit of financial movement. Transactions become metadata + ordered legs. A new CloudKit container with a leg-based schema replaces the current one. Migration from moolah-server converts legacy transfers into two-leg transactions.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit, Swift Testing

**Key files to read before starting:** `plans/2026-04-12-multi-instrument-design.md` (the design spec this plan implements), `CLAUDE.md` (build/test instructions, architecture constraints), `CONCURRENCY_GUIDE.md`.

---

## File Structure

### New Files
- `Domain/Models/Instrument.swift` — Instrument type (fiat-only for Phase 1)
- `Domain/Models/InstrumentAmount.swift` — Replaces MonetaryAmount
- `Domain/Models/TransactionLeg.swift` — Leg type with account, instrument, quantity, type, category, earmark
- `Backends/CloudKit/Models/TransactionLegRecord.swift` — SwiftData model for legs
- `Backends/CloudKit/Models/InstrumentRecord.swift` — SwiftData model for instrument reference data
- `MoolahTests/Domain/InstrumentTests.swift` — Instrument unit tests
- `MoolahTests/Domain/InstrumentAmountTests.swift` — InstrumentAmount unit tests (replaces MonetaryAmountTests)
- `MoolahTests/Domain/TransactionLegTests.swift` — TransactionLeg unit tests

### Major Modifications
- `Domain/Models/Transaction.swift` — Remove `accountId`, `toAccountId`, `amount`, `categoryId`, `earmarkId`; add `legs: [TransactionLeg]`
- `Domain/Models/Account.swift` — Remove `balance: MonetaryAmount` and `investmentValue`; balance computed from positions
- `Backends/CloudKit/Models/TransactionRecord.swift` — Simplified metadata-only record
- `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift` — Work with legs, simplify filter logic
- `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift` — Compute balances from leg records
- `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift` — Operate on legs
- `Backends/CloudKit/CloudKitBackend.swift` — New container, updated repo initialization
- `Features/Transactions/TransactionStore.swift` — Work with legs
- `Features/Accounts/AccountStore.swift` — `applyTransactionDelta` works with legs
- `Shared/Models/TransactionDraft.swift` — Produce legs instead of amount/accountId/toAccountId
- `MoolahTests/Support/TestModelContainer.swift` — Add new record types
- `MoolahTests/Support/TestBackend.swift` — Seed with legs
- `MoolahTests/Support/TestCurrency.swift` — Becomes TestInstrument with `defaultTestInstrument`

### Files Deleted
- `Domain/Models/MonetaryAmount.swift` — Replaced by InstrumentAmount
- `Domain/Models/Currency.swift` — Replaced by Instrument
- `MoolahTests/Domain/MonetaryAmountTests.swift` — Replaced by InstrumentAmountTests

### Compiler-Guided Updates (~100 files)
After the core type changes, the compiler will flag every remaining reference to `MonetaryAmount`, `Currency`, `transaction.accountId`, `transaction.toAccountId`, `transaction.amount`. These are mechanical updates (rename types, access data through legs). Each task below identifies the category of files affected; the compiler errors guide the specific changes.

---

## Task 1: Instrument Type (Fiat Only)

**Files:**
- Create: `Domain/Models/Instrument.swift`
- Create: `MoolahTests/Domain/InstrumentTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Domain/InstrumentTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("Instrument")
struct InstrumentTests {
  @Test func fiatInstrumentProperties() {
    let aud = Instrument.fiat(code: "AUD")
    #expect(aud.id == "AUD")
    #expect(aud.kind == .fiatCurrency)
    #expect(aud.name == "AUD")
    #expect(aud.decimals == 2)
  }

  @Test func fiatJPYHasZeroDecimals() {
    let jpy = Instrument.fiat(code: "JPY")
    #expect(jpy.id == "JPY")
    #expect(jpy.decimals == 0)
  }

  @Test func equality() {
    let a = Instrument.fiat(code: "AUD")
    let b = Instrument.fiat(code: "AUD")
    let c = Instrument.fiat(code: "USD")
    #expect(a == b)
    #expect(a != c)
  }

  @Test func hashable() {
    let a = Instrument.fiat(code: "AUD")
    let b = Instrument.fiat(code: "AUD")
    #expect(a.hashValue == b.hashValue)
  }

  @Test func codableRoundTrip() throws {
    let original = Instrument.fiat(code: "AUD")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Instrument.self, from: data)
    #expect(decoded == original)
  }

  @Test func currencySymbolDerivedFromLocale() {
    let aud = Instrument.fiat(code: "AUD")
    // currencySymbol is derived at call time, not stored
    let symbol = aud.currencySymbol
    #expect(symbol != nil)
    #expect(!symbol!.isEmpty)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-instrument.txt`
Expected: FAIL — `Instrument` type not defined.

- [ ] **Step 3: Implement Instrument**

```swift
// Domain/Models/Instrument.swift
import Foundation

struct Instrument: Codable, Sendable, Hashable, Identifiable {
  enum Kind: String, Codable, Sendable {
    case fiatCurrency
    case stock
    case cryptoToken
  }

  let id: String
  let kind: Kind
  let name: String
  let decimals: Int

  // Kind-specific metadata (all optional)
  let ticker: String?
  let exchange: String?
  let chainId: Int?
  let contractAddress: String?

  /// Factory for fiat currency instruments.
  /// Derives decimal places from the system locale database.
  static func fiat(code: String) -> Instrument {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    return Instrument(
      id: code,
      kind: .fiatCurrency,
      name: code,
      decimals: formatter.maximumFractionDigits,
      ticker: nil,
      exchange: nil,
      chainId: nil,
      contractAddress: nil
    )
  }

  /// Derive the currency symbol from system locale (fiat only).
  /// Returns nil for non-fiat instruments.
  var currencySymbol: String? {
    guard kind == .fiatCurrency else { return nil }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = id
    return formatter.currencySymbol
  }

  // Convenience constants for common currencies
  static let AUD = Instrument.fiat(code: "AUD")
  static let USD = Instrument.fiat(code: "USD")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-instrument.txt`
Expected: All Instrument tests PASS.

- [ ] **Step 5: Clean up temp files and commit**

```bash
rm .agent-tmp/test-instrument.txt
git add Domain/Models/Instrument.swift MoolahTests/Domain/InstrumentTests.swift
git commit -m "feat: add Instrument type for unified financial instrument model (fiat only)"
```

---

## Task 2: InstrumentAmount Type

**Files:**
- Create: `Domain/Models/InstrumentAmount.swift`
- Create: `MoolahTests/Domain/InstrumentAmountTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Domain/InstrumentAmountTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentAmount")
struct InstrumentAmountTests {
  let aud = Instrument.AUD

  @Test func initStoresQuantityAndInstrument() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.quantity == Decimal(string: "50.23")!)
    #expect(amount.instrument == aud)
  }

  @Test func zeroFactory() {
    let zero = InstrumentAmount.zero(instrument: aud)
    #expect(zero.quantity == 0)
    #expect(zero.instrument == aud)
  }

  @Test func isPositiveNegativeZero() {
    let positive = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud)
    #expect(positive.isPositive)
    #expect(!positive.isNegative)
    #expect(!positive.isZero)

    let negative = InstrumentAmount(quantity: Decimal(string: "-1.00")!, instrument: aud)
    #expect(negative.isNegative)
    #expect(!negative.isPositive)

    let zero = InstrumentAmount.zero(instrument: aud)
    #expect(zero.isZero)
    #expect(!zero.isPositive)
    #expect(!zero.isNegative)
  }

  @Test func addition() {
    let a = InstrumentAmount(quantity: Decimal(string: "1.50")!, instrument: aud)
    let b = InstrumentAmount(quantity: Decimal(string: "2.50")!, instrument: aud)
    let result = a + b
    #expect(result.quantity == Decimal(string: "4.00")!)
    #expect(result.instrument == aud)
  }

  @Test func subtraction() {
    let a = InstrumentAmount(quantity: Decimal(string: "5.00")!, instrument: aud)
    let b = InstrumentAmount(quantity: Decimal(string: "2.00")!, instrument: aud)
    #expect((a - b).quantity == Decimal(string: "3.00")!)
  }

  @Test func negation() {
    let a = InstrumentAmount(quantity: Decimal(string: "5.00")!, instrument: aud)
    #expect((-a).quantity == Decimal(string: "-5.00")!)
    #expect((-a).instrument == aud)
  }

  @Test func plusEquals() {
    var a = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud)
    a += InstrumentAmount(quantity: Decimal(string: "0.50")!, instrument: aud)
    #expect(a.quantity == Decimal(string: "1.50")!)
  }

  @Test func comparison() {
    let a = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud)
    let b = InstrumentAmount(quantity: Decimal(string: "2.00")!, instrument: aud)
    #expect(a < b)
    #expect(!(b < a))
  }

  @Test func decimalValue() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.decimalValue == Decimal(string: "50.23")!)
  }

  @Test func formatted() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    // Formatted should include currency symbol (locale-dependent)
    #expect(amount.formatted.contains("50.23"))
  }

  @Test func formatNoSymbol() {
    let amount = InstrumentAmount(quantity: Decimal(string: "1234.56")!, instrument: aud)
    let text = amount.formatNoSymbol
    #expect(text.contains("1234.56") || text.contains("1,234.56"))
  }

  @Test func reduceForSumming() {
    let amounts = [
      InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: aud),
      InstrumentAmount(quantity: Decimal(string: "2.00")!, instrument: aud),
      InstrumentAmount(quantity: Decimal(string: "-0.50")!, instrument: aud),
    ]
    let total = amounts.reduce(.zero(instrument: aud)) { $0 + $1 }
    #expect(total.quantity == Decimal(string: "2.50")!)
  }

  @Test func equality() {
    let a = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: .AUD)
    let b = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: .AUD)
    let c = InstrumentAmount(quantity: Decimal(string: "1.00")!, instrument: .USD)
    #expect(a == b)
    #expect(a != c)
  }

  @Test func codableRoundTrip() throws {
    let original = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: .AUD)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(InstrumentAmount.self, from: data)
    #expect(decoded == original)
  }

  // MARK: - Storage Scaling

  @Test func toStorageValueScalesBy10e8() {
    let amount = InstrumentAmount(quantity: Decimal(string: "50.23")!, instrument: aud)
    #expect(amount.storageValue == 5_023_000_000)
  }

  @Test func fromStorageValueRoundTrips() {
    let original = InstrumentAmount(quantity: Decimal(string: "47046.61094572")!, instrument: aud)
    let stored = original.storageValue
    let restored = InstrumentAmount(storageValue: stored, instrument: aud)
    #expect(restored.quantity == Decimal(string: "47046.61094572")!)
  }

  @Test func storageValueZero() {
    let zero = InstrumentAmount.zero(instrument: aud)
    #expect(zero.storageValue == 0)
  }

  @Test func storageValueNegative() {
    let amount = InstrumentAmount(quantity: Decimal(string: "-50.23")!, instrument: aud)
    #expect(amount.storageValue == -5_023_000_000)
  }

  // MARK: - Parse

  @Test func parseQuantityWholeNumber() {
    #expect(InstrumentAmount.parseQuantity(from: "100", decimals: 2) == Decimal(string: "100"))
  }

  @Test func parseQuantityDecimal() {
    #expect(InstrumentAmount.parseQuantity(from: "12.50", decimals: 2) == Decimal(string: "12.50"))
  }

  @Test func parseQuantityStripsNonNumeric() {
    #expect(InstrumentAmount.parseQuantity(from: "$12.50", decimals: 2) == Decimal(string: "12.50"))
  }

  @Test func parseQuantityEmptyString() {
    #expect(InstrumentAmount.parseQuantity(from: "", decimals: 2) == nil)
  }

  @Test func parseQuantityInvalid() {
    #expect(InstrumentAmount.parseQuantity(from: "abc", decimals: 2) == nil)
  }

  @Test func parseQuantityMultipleDecimals() {
    #expect(InstrumentAmount.parseQuantity(from: "1.2.3", decimals: 2) == nil)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-ia.txt`
Expected: FAIL — `InstrumentAmount` type not defined.

- [ ] **Step 3: Implement InstrumentAmount**

```swift
// Domain/Models/InstrumentAmount.swift
import Foundation

/// The universal scaling factor for storage: all quantities are stored as Int64 × 10^8.
private let storageScale: Decimal = 100_000_000  // 10^8

struct InstrumentAmount: Codable, Sendable, Hashable, Comparable {
  let quantity: Decimal
  let instrument: Instrument

  static func zero(instrument: Instrument) -> InstrumentAmount {
    InstrumentAmount(quantity: 0, instrument: instrument)
  }

  var decimalValue: Decimal { quantity }

  var isPositive: Bool { quantity > 0 }
  var isNegative: Bool { quantity < 0 }
  var isZero: Bool { quantity == 0 }

  // MARK: - Formatting

  var formatted: String {
    quantity.formatted(.currency(code: instrument.id))
  }

  var formatNoSymbol: String {
    quantity.formatted(.number.precision(.fractionLength(instrument.decimals)))
  }

  // MARK: - Storage (Int64 scaled by 10^8)

  /// Convert to Int64 for SwiftData/CloudKit storage. All instruments use the same 10^8 scaling.
  var storageValue: Int64 {
    let scaled = quantity * storageScale
    return Int64(truncating: scaled as NSDecimalNumber)
  }

  /// Restore from Int64 storage value.
  init(storageValue: Int64, instrument: Instrument) {
    self.quantity = Decimal(storageValue) / storageScale
    self.instrument = instrument
  }

  // MARK: - Arithmetic

  static func + (lhs: InstrumentAmount, rhs: InstrumentAmount) -> InstrumentAmount {
    InstrumentAmount(quantity: lhs.quantity + rhs.quantity, instrument: lhs.instrument)
  }

  static func - (lhs: InstrumentAmount, rhs: InstrumentAmount) -> InstrumentAmount {
    InstrumentAmount(quantity: lhs.quantity - rhs.quantity, instrument: lhs.instrument)
  }

  static prefix func - (amount: InstrumentAmount) -> InstrumentAmount {
    InstrumentAmount(quantity: -amount.quantity, instrument: amount.instrument)
  }

  static func += (lhs: inout InstrumentAmount, rhs: InstrumentAmount) {
    lhs = lhs + rhs
  }

  static func -= (lhs: inout InstrumentAmount, rhs: InstrumentAmount) {
    lhs = lhs - rhs
  }

  static func < (lhs: InstrumentAmount, rhs: InstrumentAmount) -> Bool {
    lhs.quantity < rhs.quantity
  }

  // MARK: - Parsing

  /// Parse a user-entered amount string into a Decimal quantity.
  /// Strips non-numeric characters except decimal point.
  static func parseQuantity(from text: String, decimals: Int) -> Decimal? {
    let cleaned = text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
    guard !cleaned.isEmpty,
      cleaned.filter({ $0 == "." }).count <= 1,
      let decimal = Decimal(string: cleaned)
    else { return nil }
    return decimal
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-ia.txt`
Expected: All InstrumentAmount tests PASS.

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-ia.txt
git add Domain/Models/InstrumentAmount.swift MoolahTests/Domain/InstrumentAmountTests.swift
git commit -m "feat: add InstrumentAmount type with Decimal quantity and Int64 storage scaling"
```

---

## Task 3: TransactionLeg Type

**Files:**
- Create: `Domain/Models/TransactionLeg.swift`
- Create: `MoolahTests/Domain/TransactionLegTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Domain/TransactionLegTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("TransactionLeg")
struct TransactionLegTests {
  let accountId = UUID()
  let aud = Instrument.AUD

  @Test func expenseLeg() {
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: Decimal(string: "-50.00")!,
      type: .expense
    )
    #expect(leg.accountId == accountId)
    #expect(leg.instrument == aud)
    #expect(leg.quantity == Decimal(string: "-50.00")!)
    #expect(leg.type == .expense)
    #expect(leg.categoryId == nil)
    #expect(leg.earmarkId == nil)
  }

  @Test func legWithCategoryAndEarmark() {
    let catId = UUID()
    let earId = UUID()
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: Decimal(string: "-50.00")!,
      type: .expense,
      categoryId: catId,
      earmarkId: earId
    )
    #expect(leg.categoryId == catId)
    #expect(leg.earmarkId == earId)
  }

  @Test func codableRoundTrip() throws {
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: Decimal(string: "-50.23")!,
      type: .expense,
      categoryId: UUID()
    )
    let data = try JSONEncoder().encode(leg)
    let decoded = try JSONDecoder().decode(TransactionLeg.self, from: data)
    #expect(decoded == leg)
  }

  @Test func amount() {
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: Decimal(string: "-50.23")!,
      type: .expense
    )
    #expect(leg.amount == InstrumentAmount(quantity: Decimal(string: "-50.23")!, instrument: aud))
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-leg.txt`
Expected: FAIL — `TransactionLeg` type not defined.

- [ ] **Step 3: Implement TransactionLeg**

```swift
// Domain/Models/TransactionLeg.swift
import Foundation

struct TransactionLeg: Codable, Sendable, Hashable {
  let accountId: UUID
  let instrument: Instrument
  let quantity: Decimal
  var type: TransactionType
  var categoryId: UUID?
  var earmarkId: UUID?

  init(
    accountId: UUID,
    instrument: Instrument,
    quantity: Decimal,
    type: TransactionType,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil
  ) {
    self.accountId = accountId
    self.instrument = instrument
    self.quantity = quantity
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-leg.txt`
Expected: All TransactionLeg tests PASS.

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-leg.txt
git add Domain/Models/TransactionLeg.swift MoolahTests/Domain/TransactionLegTests.swift
git commit -m "feat: add TransactionLeg type for multi-instrument transaction model"
```

---

## Task 4: Update Transaction to Use Legs

This is the core model change. Transaction loses `accountId`, `toAccountId`, `amount`, `categoryId`, `earmarkId` and gains `legs: [TransactionLeg]`. This will break compilation across the codebase — subsequent tasks fix each layer.

**Files:**
- Modify: `Domain/Models/Transaction.swift`

- [ ] **Step 1: Add legs to Transaction, add convenience accessors, remove old fields**

Update `Transaction` struct in `Domain/Models/Transaction.swift`:

```swift
struct Transaction: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var date: Date
  var payee: String?
  var notes: String?
  var recurPeriod: RecurPeriod?
  var recurEvery: Int?

  var legs: [TransactionLeg]

  var isScheduled: Bool {
    recurPeriod != nil
  }

  var isRecurring: Bool {
    guard let period = recurPeriod else { return false }
    return period != .once
  }

  init(
    id: UUID = UUID(),
    date: Date,
    payee: String? = nil,
    notes: String? = nil,
    recurPeriod: RecurPeriod? = nil,
    recurEvery: Int? = nil,
    legs: [TransactionLeg]
  ) {
    self.id = id
    self.date = date
    self.payee = payee
    self.notes = notes
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
    self.legs = legs
  }

  // MARK: - Convenience Accessors

  /// The distinct account IDs referenced by this transaction's legs.
  var accountIds: Set<UUID> {
    Set(legs.map(\.accountId))
  }

  /// The primary account (first leg's account). Used for display and filtering.
  var primaryAccountId: UUID? {
    legs.first?.accountId
  }

  /// The primary type (first leg's type). Used for display.
  var type: TransactionType {
    legs.first?.type ?? .expense
  }

  /// The primary category (first leg's category). Used for display and filtering.
  var categoryId: UUID? {
    legs.first?.categoryId
  }

  /// The primary earmark (first leg's earmark). Used for filtering.
  var earmarkId: UUID? {
    legs.first?.earmarkId
  }

  /// The primary amount (first leg's amount). Used for display in transaction lists.
  var primaryAmount: InstrumentAmount {
    legs.first?.amount ?? .zero(instrument: .AUD)
  }

  /// Whether this is a transfer (legs span multiple accounts or instruments).
  var isTransfer: Bool {
    let accounts = Set(legs.filter { $0.type == .transfer }.map(\.accountId))
    let instruments = Set(legs.filter { $0.type == .transfer }.map(\.instrument))
    return accounts.count > 1 || instruments.count > 1
  }
}
```

- [ ] **Step 2: Update TransactionPage and TransactionWithBalance**

In the same file, update `TransactionPage.withRunningBalances`. This method currently assumes single-amount transactions. For Phase 1 (fiat only, single currency), we keep the same semantic — running balance uses the primary leg's amount. The method will be revisited in Phase 2 for multi-currency.

```swift
struct TransactionPage: Sendable {
  let transactions: [Transaction]
  let priorBalance: InstrumentAmount
  let totalCount: Int?

  static func withRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount
  ) -> [TransactionWithBalance] {
    var balance = priorBalance
    var result: [TransactionWithBalance] = []
    result.reserveCapacity(transactions.count)

    for transaction in transactions.reversed() {
      balance += transaction.primaryAmount
      result.append(TransactionWithBalance(transaction: transaction, balance: balance))
    }

    result.reverse()
    return result
  }
}

struct TransactionWithBalance: Sendable, Identifiable {
  let transaction: Transaction
  let balance: InstrumentAmount

  var id: UUID { transaction.id }
}
```

- [ ] **Step 3: Update TransactionFilter**

`TransactionFilter.accountId` stays — it's used for filtering which transactions appear in an account's view. The filter logic will need to check legs rather than `transaction.accountId`, but the filter type itself stays the same.

No changes needed to `TransactionFilter` itself.

- [ ] **Step 4: Remove Transaction.validate() for transfer-specific rules**

The old validation checked `toAccountId`. Transfer validation now operates on legs — a transfer needs at least two legs. Update the validation:

```swift
extension Transaction {
  func validate() throws {
    if (recurPeriod != nil) != (recurEvery != nil) {
      throw ValidationError.incompleteRecurrence
    }
    if let every = recurEvery, every < 1 {
      throw ValidationError.invalidRecurEvery
    }
    if legs.isEmpty {
      throw ValidationError.noLegs
    }
  }

  enum ValidationError: LocalizedError {
    case incompleteRecurrence
    case invalidRecurEvery
    case noLegs

    var errorDescription: String? {
      switch self {
      case .incompleteRecurrence:
        return "Recurrence must have both period and frequency set"
      case .invalidRecurEvery:
        return "Recurrence frequency must be at least 1"
      case .noLegs:
        return "Transaction must have at least one leg"
      }
    }
  }
}
```

- [ ] **Step 5: Do NOT attempt to build yet** — the codebase will not compile until the remaining tasks update all consumers. Commit this change:

```bash
git add Domain/Models/Transaction.swift
git commit -m "feat: replace Transaction amount/accountId/toAccountId with legs

BREAKING: Transaction now uses legs: [TransactionLeg] instead of single
amount/accountId/toAccountId. Subsequent commits will update all consumers."
```

---

## Task 5: Replace MonetaryAmount with InstrumentAmount Across Domain Models

**Files to modify** (compiler-guided — look for every `MonetaryAmount` and `Currency` reference):
- `Domain/Models/Account.swift`
- `Domain/Models/Earmark.swift`
- `Domain/Models/InvestmentValue.swift`
- `Domain/Models/AccountDailyBalance.swift`
- `Domain/Models/DailyBalance.swift`
- `Domain/Models/ExpenseBreakdown.swift`
- `Domain/Models/MonthlyIncomeExpense.swift`
- `Domain/Models/BudgetLineItem.swift`
- `Domain/Models/InvestmentChartDataPoint.swift`
- `Domain/Models/Profile.swift` (Profile.currency → Profile.instrument)
- Delete: `Domain/Models/MonetaryAmount.swift`
- Delete: `Domain/Models/Currency.swift`

This is a large but mechanical task. The compiler guides every change. The key pattern:
- `MonetaryAmount` → `InstrumentAmount`
- `Currency` → `Instrument`
- `.cents` → `.quantity` (or `.storageValue` at boundaries)
- `MonetaryAmount(cents: X, currency: Y)` → `InstrumentAmount(quantity: Decimal(X) / 100, instrument: Instrument.fiat(code: Y))`
- `MonetaryAmount.zero(currency:)` → `InstrumentAmount.zero(instrument:)`
- `MonetaryAmount.parseCents(from:)` → `InstrumentAmount.parseQuantity(from:decimals:)`

- [ ] **Step 1: Update Account.swift**

Key changes:
- `balance: MonetaryAmount` → remove (balance is now computed from positions; for Phase 1 we keep it as a property but change the type)
- Actually, for Phase 1, Account still needs a display balance. Keep `balance: InstrumentAmount` and `investmentValue: InstrumentAmount?` — the balance is provided by the repository layer (computed from legs). The Account struct is just a data carrier.
- `displayBalance` returns `investmentValue` if set, else `balance`.
- Update `Accounts.adjustingBalance(of:by:)` to use `InstrumentAmount`.

```swift
struct Account: Codable, Sendable, Comparable, Identifiable, Hashable {
  let id: UUID
  var name: String
  var type: AccountType
  var balance: InstrumentAmount
  var investmentValue: InstrumentAmount?
  var position: Int
  var isHidden: Bool

  var displayBalance: InstrumentAmount {
    if type == .investment, let value = investmentValue {
      return value
    }
    return balance
  }

  static func < (lhs: Account, rhs: Account) -> Bool {
    lhs.position < rhs.position
  }
}
```

Update `Accounts.adjustingBalance`:
```swift
func adjustingBalance(of accountId: UUID, by amount: InstrumentAmount) -> Accounts {
  // ... same logic, new type
}
```

- [ ] **Step 2: Update remaining domain model files**

For each file, replace `MonetaryAmount` → `InstrumentAmount` and `Currency` → `Instrument`. These are mechanical. Key files:

- `Earmark.swift`: `balance`, `saved`, `spent`, `savingsGoal` — all `InstrumentAmount`
- `InvestmentValue.swift`: `value: InstrumentAmount`
- `DailyBalance.swift`: all amount fields → `InstrumentAmount`
- `AccountDailyBalance.swift`: `balance: InstrumentAmount`
- `ExpenseBreakdown.swift`: `totalExpenses: InstrumentAmount`
- `MonthlyIncomeExpense.swift`: all amount fields → `InstrumentAmount`
- `BudgetLineItem.swift`: `actual`, `budgeted` → `InstrumentAmount`
- `Profile.swift`: `currency: Currency` → `instrument: Instrument`, and the computed property: `var instrument: Instrument { Instrument.fiat(code: currencyCode) }`

- [ ] **Step 3: Delete old files**

```bash
git rm Domain/Models/MonetaryAmount.swift Domain/Models/Currency.swift
```

- [ ] **Step 4: Do NOT attempt to build yet.** Commit:

```bash
git add -A Domain/Models/
git commit -m "refactor: replace MonetaryAmount/Currency with InstrumentAmount/Instrument across domain models

BREAKING: All domain models now use InstrumentAmount and Instrument.
Subsequent commits update backends, features, and tests."
```

---

## Task 6: Update Test Infrastructure

**Files:**
- Modify: `MoolahTests/Support/TestCurrency.swift` → rename to `TestInstrument.swift`
- Modify: `MoolahTests/Support/TestModelContainer.swift`
- Modify: `MoolahTests/Support/TestBackend.swift`
- Delete: `MoolahTests/Domain/MonetaryAmountTests.swift`

- [ ] **Step 1: Replace TestCurrency with TestInstrument**

```swift
// MoolahTests/Support/TestInstrument.swift (rename from TestCurrency.swift)
@testable import Moolah

extension Instrument {
  /// Default instrument for test fixtures.
  static let defaultTestInstrument: Instrument = .AUD
}
```

- [ ] **Step 2: Update TestModelContainer**

Add `TransactionLegRecord.self` and `InstrumentRecord.self` to the schema (these will be created in Task 8):

```swift
enum TestModelContainer {
  static func create() throws -> ModelContainer {
    let schema = Schema([
      AccountRecord.self,
      TransactionRecord.self,
      TransactionLegRecord.self,
      InstrumentRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
  }
}
```

- [ ] **Step 3: Update TestBackend**

Update all seed methods to use `InstrumentAmount` and `Instrument` instead of `MonetaryAmount` and `Currency`. Update `seed(accounts:)` to create opening balance transactions using the leg model. Update `seed(transactions:)` to write leg records.

Key changes in `seed(accounts:)`:
- Replace `account.balance.cents` with `account.balance.storageValue`
- Replace `currencyCode: currency.code` with references to the instrument
- Update TransactionRecord creation to also create TransactionLegRecords

Key changes in `seedWithTransactions(earmarks:)`:
- Replace `earmark.saved.cents` etc. with `earmark.saved.quantity` comparisons
- Update TransactionRecord + TransactionLegRecord creation

- [ ] **Step 4: Delete old test file**

```bash
git rm MoolahTests/Domain/MonetaryAmountTests.swift
```

- [ ] **Step 5: Commit**

```bash
git add -A MoolahTests/Support/ MoolahTests/Domain/MonetaryAmountTests.swift
git commit -m "refactor: update test infrastructure for Instrument/InstrumentAmount model"
```

---

## Task 7: Update Repository Protocols

**Files:**
- Modify: `Domain/Repositories/TransactionRepository.swift`
- Modify: `Domain/Repositories/AccountRepository.swift`
- Modify: `Domain/Repositories/AnalysisRepository.swift`
- Modify: `Domain/Repositories/InvestmentRepository.swift`
- Modify: `Domain/Repositories/BackendProvider.swift` (if it references Currency)

- [ ] **Step 1: Update TransactionRepository**

The protocol itself barely changes — it still accepts/returns `Transaction` and `TransactionPage`. The types inside Transaction have changed (legs instead of single amount), but the protocol signature stays the same. Verify no `MonetaryAmount` or `Currency` references remain.

- [ ] **Step 2: Update AnalysisRepository**

Replace `MonetaryAmount` return types with `InstrumentAmount`:
- `fetchCategoryBalances` returns `[UUID: InstrumentAmount]`

- [ ] **Step 3: Update InvestmentRepository**

Replace `MonetaryAmount` with `InstrumentAmount` in `setValue` parameter.

- [ ] **Step 4: Commit**

```bash
git add Domain/Repositories/
git commit -m "refactor: update repository protocols for InstrumentAmount"
```

---

## Task 8: New CloudKit SwiftData Records

**Files:**
- Create: `Backends/CloudKit/Models/TransactionLegRecord.swift`
- Create: `Backends/CloudKit/Models/InstrumentRecord.swift`
- Modify: `Backends/CloudKit/Models/TransactionRecord.swift`
- Modify: `Backends/CloudKit/Models/AccountRecord.swift`

- [ ] **Step 1: Create TransactionLegRecord**

```swift
// Backends/CloudKit/Models/TransactionLegRecord.swift
import Foundation
import SwiftData

@Model
final class TransactionLegRecord {
  var id: UUID = UUID()
  var transactionId: UUID = UUID()
  var accountId: UUID = UUID()
  var instrumentId: String = ""      // "AUD", "ASX:BHP", etc.
  var quantity: Int64 = 0            // Actual value × 10^8
  var type: String = "expense"       // Raw value of TransactionType
  var categoryId: UUID?
  var earmarkId: UUID?
  var sortOrder: Int = 0

  init(
    id: UUID = UUID(),
    transactionId: UUID,
    accountId: UUID,
    instrumentId: String,
    quantity: Int64,
    type: String,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil,
    sortOrder: Int = 0
  ) {
    self.id = id
    self.transactionId = transactionId
    self.accountId = accountId
    self.instrumentId = instrumentId
    self.quantity = quantity
    self.type = type
    self.categoryId = categoryId
    self.earmarkId = earmarkId
    self.sortOrder = sortOrder
  }

  func toDomain(instrument: Instrument) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId,
      instrument: instrument,
      quantity: InstrumentAmount(storageValue: quantity, instrument: instrument).quantity,
      type: TransactionType(rawValue: type) ?? .expense,
      categoryId: categoryId,
      earmarkId: earmarkId
    )
  }

  static func from(_ leg: TransactionLeg, transactionId: UUID, sortOrder: Int) -> TransactionLegRecord {
    TransactionLegRecord(
      transactionId: transactionId,
      accountId: leg.accountId,
      instrumentId: leg.instrument.id,
      quantity: InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument).storageValue,
      type: leg.type.rawValue,
      categoryId: leg.categoryId,
      earmarkId: leg.earmarkId,
      sortOrder: sortOrder
    )
  }
}
```

- [ ] **Step 2: Create InstrumentRecord**

```swift
// Backends/CloudKit/Models/InstrumentRecord.swift
import Foundation
import SwiftData

@Model
final class InstrumentRecord {
  @Attribute(.unique)
  var id: String = ""
  var kind: String = "fiatCurrency"
  var name: String = ""
  var decimals: Int = 2
  var ticker: String?
  var exchange: String?
  var chainId: Int?
  var contractAddress: String?

  init(
    id: String,
    kind: String,
    name: String,
    decimals: Int,
    ticker: String? = nil,
    exchange: String? = nil,
    chainId: Int? = nil,
    contractAddress: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.decimals = decimals
    self.ticker = ticker
    self.exchange = exchange
    self.chainId = chainId
    self.contractAddress = contractAddress
  }

  func toDomain() -> Instrument {
    Instrument(
      id: id,
      kind: Instrument.Kind(rawValue: kind) ?? .fiatCurrency,
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: chainId,
      contractAddress: contractAddress
    )
  }

  static func from(_ instrument: Instrument) -> InstrumentRecord {
    InstrumentRecord(
      id: instrument.id,
      kind: instrument.kind.rawValue,
      name: instrument.name,
      decimals: instrument.decimals,
      ticker: instrument.ticker,
      exchange: instrument.exchange,
      chainId: instrument.chainId,
      contractAddress: instrument.contractAddress
    )
  }
}
```

- [ ] **Step 3: Simplify TransactionRecord**

TransactionRecord becomes metadata-only. The old `amount`, `accountId`, `toAccountId`, `categoryId`, `earmarkId` fields are removed (new CloudKit container = clean slate).

```swift
@Model
final class TransactionRecord {
  var id: UUID = UUID()
  var date: Date = Date()
  var payee: String?
  var notes: String?
  var recurPeriod: String?
  var recurEvery: Int?

  init(
    id: UUID = UUID(),
    date: Date,
    payee: String? = nil,
    notes: String? = nil,
    recurPeriod: String? = nil,
    recurEvery: Int? = nil
  ) {
    self.id = id
    self.date = date
    self.payee = payee
    self.notes = notes
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
  }

  /// Convert to domain model. Legs must be provided separately (fetched from TransactionLegRecord).
  func toDomain(legs: [TransactionLeg]) -> Transaction {
    Transaction(
      id: id,
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery,
      legs: legs
    )
  }

  static func from(_ transaction: Transaction) -> TransactionRecord {
    TransactionRecord(
      id: transaction.id,
      date: transaction.date,
      payee: transaction.payee,
      notes: transaction.notes,
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }
}
```

- [ ] **Step 4: Update AccountRecord**

Remove `cachedBalance` (positions computed from legs). Remove `currencyCode` (accounts no longer carry a single currency — instruments are on the legs).

```swift
@Model
final class AccountRecord {
  var id: UUID = UUID()
  var name: String = ""
  var type: String = "bank"
  var position: Int = 0
  var isHidden: Bool = false

  init(
    id: UUID = UUID(),
    name: String,
    type: String,
    position: Int = 0,
    isHidden: Bool = false
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.position = position
    self.isHidden = isHidden
  }

  func toDomain(balance: InstrumentAmount, investmentValue: InstrumentAmount?) -> Account {
    Account(
      id: id,
      name: name,
      type: AccountType(rawValue: type) ?? .bank,
      balance: balance,
      investmentValue: investmentValue,
      position: position,
      isHidden: isHidden
    )
  }

  static func from(_ account: Account) -> AccountRecord {
    AccountRecord(
      id: account.id,
      name: account.name,
      type: account.type.rawValue,
      position: account.position,
      isHidden: account.isHidden
    )
  }
}
```

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Models/
git commit -m "feat: add TransactionLegRecord and InstrumentRecord, simplify TransactionRecord and AccountRecord"
```

---

## Task 9: Update CloudKitTransactionRepository

This is the most complex backend change. The repository must now read/write legs alongside transactions.

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift`

- [ ] **Step 1: Update create method**

The new create inserts a `TransactionRecord` plus one `TransactionLegRecord` per leg. Also ensures the leg's instrument is registered in `InstrumentRecord`.

Key changes:
- Remove transfer validation (toAccountId checks) — validation is now on the leg structure
- Insert TransactionRecord (metadata only)
- Insert TransactionLegRecords for each leg
- Ensure InstrumentRecords exist for each leg's instrument (upsert)
- No more `updateAccountBalance` — positions computed from legs via aggregate queries

- [ ] **Step 2: Update fetch method**

The fetch now needs to join TransactionRecords with their TransactionLegRecords. Key changes:
- Fetch TransactionRecords matching the filter
- For the accountId filter, query TransactionLegRecords where `accountId` matches, get the distinct `transactionId` values, then fetch those TransactionRecords
- For each TransactionRecord in the page, fetch its legs and resolve instruments
- Build domain Transaction objects with legs
- Prior balance: SUM of leg quantities for the filtered account from records after the current page

The predicate push-down logic simplifies dramatically. Instead of filtering on `transaction.accountId` vs `transaction.toAccountId`, filter on `TransactionLegRecord.accountId` — a single query path.

- [ ] **Step 3: Update update and delete methods**

For update:
- Delete old leg records for the transaction
- Insert new leg records
- Update transaction metadata

For delete:
- Delete leg records then transaction record

- [ ] **Step 4: Build an InstrumentCache helper**

Create a helper on the repository that maintains an in-memory cache of instrumentId → Instrument, fetched from InstrumentRecord on first access. This avoids repeated DB lookups when resolving legs.

```swift
@MainActor
private var instrumentCache: [String: Instrument] = [:]

@MainActor
private func resolveInstrument(id: String) throws -> Instrument {
  if let cached = instrumentCache[id] {
    return cached
  }
  let descriptor = FetchDescriptor<InstrumentRecord>(
    predicate: #Predicate { $0.id == id }
  )
  if let record = try context.fetch(descriptor).first {
    let instrument = record.toDomain()
    instrumentCache[id] = instrument
    return instrument
  }
  // Fallback for fiat currencies not yet in the instrument table
  let instrument = Instrument.fiat(code: id)
  instrumentCache[id] = instrument
  return instrument
}

@MainActor
private func ensureInstrument(_ instrument: Instrument) throws {
  let iid = instrument.id
  let descriptor = FetchDescriptor<InstrumentRecord>(
    predicate: #Predicate { $0.id == iid }
  )
  if try context.fetch(descriptor).isEmpty {
    context.insert(InstrumentRecord.from(instrument))
  }
  instrumentCache[instrument.id] = instrument
}
```

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitTransactionRepository.swift
git commit -m "refactor: update CloudKitTransactionRepository to use transaction legs"
```

---

## Task 10: Update CloudKitAccountRepository

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAccountRepository.swift`

- [ ] **Step 1: Rewrite balance computation from legs**

Replace `recomputeAllBalances` and `computeBalance` to work with `TransactionLegRecord`. The new logic:
- Query all non-scheduled leg records (join via transactionId to non-scheduled TransactionRecords, or filter legs where the parent transaction's `recurPeriod` is nil)
- SUM `quantity` grouped by `accountId` and `instrumentId`

Since SwiftData can't do JOINs or GROUP BY, the practical approach is:
1. Fetch all non-scheduled TransactionRecord IDs
2. Fetch all TransactionLegRecords where transactionId is in that set
3. Accumulate in-memory: `[UUID: Int64]` keyed by accountId (for the profile currency, which is the only currency in Phase 1)

For Phase 1 (fiat only), each account will have at most one instrument (the profile currency), so the balance is a single `SUM(quantity)` per account.

- [ ] **Step 2: Update fetchAll**

Replace the cached balance pattern with fresh computation from legs.

- [ ] **Step 3: Update create**

When creating an account with a non-zero opening balance, create a Transaction with one `openingBalance` leg instead of the old TransactionRecord with `amount`.

- [ ] **Step 4: Update delete**

Check balance via leg-based computation instead of `computeBalance`.

- [ ] **Step 5: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAccountRepository.swift
git commit -m "refactor: update CloudKitAccountRepository to compute balances from legs"
```

---

## Task 11: Update CloudKitAnalysisRepository

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift`

- [ ] **Step 1: Update transaction fetching to include legs**

The analysis repo currently fetches all TransactionRecords and calls `toDomain()`. Update to also fetch associated TransactionLegRecords and resolve instruments, then build Transaction objects with legs.

- [ ] **Step 2: Update daily balance computation**

Currently accumulates `transaction.amount` per day. Change to accumulate leg quantities per day, considering only legs matching the relevant accounts and types.

For Phase 1 (single currency), this simplifies to: for each leg, accumulate `leg.quantity` to the running balance.

- [ ] **Step 3: Update expense breakdown**

Currently groups by `transaction.categoryId`. Change to group by `leg.categoryId` for expense-type legs.

- [ ] **Step 4: Update income and expense computation**

Currently splits by `transaction.type`. Change to split by `leg.type` — sum income legs, sum expense legs.

- [ ] **Step 5: Update category balances**

Currently groups by `transaction.categoryId`. Change to group by `leg.categoryId`.

- [ ] **Step 6: Commit**

```bash
git add Backends/CloudKit/Repositories/CloudKitAnalysisRepository.swift
git commit -m "refactor: update CloudKitAnalysisRepository to operate on transaction legs"
```

---

## Task 12: Update CloudKitEarmarkRepository and CloudKitInvestmentRepository

**Files:**
- Modify: `Backends/CloudKit/Repositories/CloudKitEarmarkRepository.swift`
- Modify: `Backends/CloudKit/Repositories/CloudKitInvestmentRepository.swift`
- Modify: `Backends/CloudKit/Models/EarmarkRecord.swift`
- Modify: `Backends/CloudKit/Models/InvestmentValueRecord.swift`
- Modify: `Backends/CloudKit/Models/EarmarkBudgetItemRecord.swift`

- [ ] **Step 1: Update EarmarkRepository**

The earmark repository computes `saved`, `spent`, `balance` from earmark-tagged transactions. Update to compute from legs where `earmarkId` matches. Replace `MonetaryAmount` → `InstrumentAmount` throughout.

- [ ] **Step 2: Update InvestmentRepository**

Replace `MonetaryAmount` → `InstrumentAmount` in `setValue` and return types. Update InvestmentValueRecord to use `InstrumentAmount` storage.

- [ ] **Step 3: Update supporting records**

Replace `MonetaryAmount`/`Currency` references in EarmarkRecord, EarmarkBudgetItemRecord, InvestmentValueRecord with `InstrumentAmount`/`Instrument`.

- [ ] **Step 4: Commit**

```bash
git add Backends/CloudKit/
git commit -m "refactor: update earmark and investment repositories for InstrumentAmount"
```

---

## Task 13: Update CloudKitBackend Assembly

**Files:**
- Modify: `Backends/CloudKit/CloudKitBackend.swift`

- [ ] **Step 1: Update constructor**

Replace `currency: Currency` parameter with `instrument: Instrument`. Pass to repositories.

```swift
init(modelContainer: ModelContainer, instrument: Instrument, profileLabel: String) {
  self.auth = CloudKitAuthProvider(profileLabel: profileLabel)
  self.accounts = CloudKitAccountRepository(modelContainer: modelContainer, instrument: instrument)
  self.transactions = CloudKitTransactionRepository(modelContainer: modelContainer, instrument: instrument)
  self.categories = CloudKitCategoryRepository(modelContainer: modelContainer)
  self.earmarks = CloudKitEarmarkRepository(modelContainer: modelContainer, instrument: instrument)
  self.analysis = CloudKitAnalysisRepository(modelContainer: modelContainer, instrument: instrument)
  self.investments = CloudKitInvestmentRepository(modelContainer: modelContainer, instrument: instrument)
}
```

- [ ] **Step 2: Update all callers**

Search for `CloudKitBackend(` to find all call sites and update them. Key locations:
- The main app's backend creation (likely in a profile/session setup)
- `TestBackend.create()`

- [ ] **Step 3: Commit**

```bash
git add Backends/CloudKit/CloudKitBackend.swift
git commit -m "refactor: update CloudKitBackend to use Instrument instead of Currency"
```

---

## Task 14: Update Feature Stores

**Files:**
- Modify: `Features/Transactions/TransactionStore.swift`
- Modify: `Features/Accounts/AccountStore.swift`
- Modify: `Features/Earmarks/EarmarkStore.swift`
- Modify: `Features/Investments/InvestmentStore.swift`
- Modify: `Features/Analysis/AnalysisStore.swift`

- [ ] **Step 1: Update TransactionStore**

Key changes:
- `priorBalance: MonetaryAmount` → `priorBalance: InstrumentAmount`
- `createDefault()`: Build a single-leg Transaction instead of using accountId/amount
- `payScheduledTransaction()`: Copy legs from scheduled transaction to new transaction
- All `MonetaryAmount` → `InstrumentAmount`

```swift
func createDefault(
  accountId: UUID?,
  fallbackAccountId: UUID?,
  instrument: Instrument
) async -> Transaction? {
  guard let acctId = accountId ?? fallbackAccountId else { return nil }
  let tx = Transaction(
    date: Date(),
    payee: "",
    legs: [
      TransactionLeg(
        accountId: acctId,
        instrument: instrument,
        quantity: 0,
        type: .expense
      )
    ]
  )
  return await create(tx)
}
```

For `payScheduledTransaction`, copy the legs from the scheduled transaction:
```swift
let paidTransaction = Transaction(
  id: UUID(),
  date: Date(),
  payee: scheduledTransaction.payee,
  notes: scheduledTransaction.notes,
  recurPeriod: nil,
  recurEvery: nil,
  legs: scheduledTransaction.legs
)
```

- [ ] **Step 2: Update AccountStore**

The critical change is `applyTransactionDelta`. With legs, this becomes much simpler:

```swift
func applyTransactionDelta(old: Transaction?, new: Transaction?) {
  var result = accounts

  // Remove old transaction's effect (reverse each leg)
  if let old {
    for leg in old.legs {
      result = result.adjustingBalance(of: leg.accountId, by: -leg.amount)
    }
  }

  // Apply new transaction's effect
  if let new {
    for leg in new.legs {
      result = result.adjustingBalance(of: leg.accountId, by: leg.amount)
    }
  }

  accounts = result
}
```

Replace all `MonetaryAmount` → `InstrumentAmount`, `Currency` → `Instrument`.

- [ ] **Step 3: Update remaining stores**

EarmarkStore, InvestmentStore, AnalysisStore — replace `MonetaryAmount` → `InstrumentAmount`, `Currency` → `Instrument`. These should be straightforward type renames.

- [ ] **Step 4: Commit**

```bash
git add Features/
git commit -m "refactor: update feature stores for leg-based transactions and InstrumentAmount"
```

---

## Task 15: Update TransactionDraft

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Modify: `MoolahTests/Shared/TransactionDraftTests.swift`

- [ ] **Step 1: Update TransactionDraft**

TransactionDraft produces legs instead of amount/accountId/toAccountId. The form still collects the same user inputs — the draft converts them into the right leg structure.

```swift
struct TransactionDraft: Sendable {
  var type: TransactionType
  var payee: String
  var amountText: String
  var date: Date
  var accountId: UUID?
  var toAccountId: UUID?   // For transfers — becomes a second leg
  var categoryId: UUID?
  var earmarkId: UUID?
  var notes: String
  var isRepeating: Bool
  var recurPeriod: RecurPeriod?
  var recurEvery: Int

  var parsedQuantity: Decimal? {
    guard let qty = InstrumentAmount.parseQuantity(from: amountText, decimals: 2),
      qty > 0
    else { return nil }
    return qty
  }

  var isValid: Bool {
    guard parsedQuantity != nil else { return false }
    if type == .transfer {
      guard toAccountId != nil, toAccountId != accountId else { return false }
    }
    if isRepeating {
      guard recurPeriod != nil, recurEvery >= 1 else { return false }
    }
    return true
  }

  func toTransaction(id: UUID, instrument: Instrument) -> Transaction? {
    guard let qty = parsedQuantity, isValid else { return nil }

    let signedQty: Decimal
    switch type {
    case .expense, .transfer:
      signedQty = -abs(qty)
    case .income, .openingBalance:
      signedQty = abs(qty)
    }

    var legs: [TransactionLeg] = []

    guard let acctId = accountId else { return nil }

    // Primary leg
    legs.append(TransactionLeg(
      accountId: acctId,
      instrument: instrument,
      quantity: signedQty,
      type: type == .transfer ? .transfer : type,
      categoryId: type == .transfer ? nil : categoryId,
      earmarkId: type == .transfer ? nil : earmarkId
    ))

    // Transfer: add destination leg with opposite sign
    if type == .transfer, let toAcctId = toAccountId {
      legs.append(TransactionLeg(
        accountId: toAcctId,
        instrument: instrument,
        quantity: -signedQty,
        type: .transfer
      ))
    }

    return Transaction(
      id: id,
      date: date,
      payee: payee.isEmpty ? nil : payee,
      notes: notes.isEmpty ? nil : notes,
      recurPeriod: isRepeating ? recurPeriod : nil,
      recurEvery: isRepeating ? recurEvery : nil,
      legs: legs
    )
  }
}
```

Update `init(from transaction:)` to read from legs:
```swift
init(from transaction: Transaction) {
  let primaryLeg = transaction.legs.first
  let transferLeg = transaction.legs.count > 1
    ? transaction.legs.first(where: { $0.accountId != primaryLeg?.accountId })
    : nil

  self.init(
    type: primaryLeg?.type == .transfer ? .transfer : (primaryLeg?.type ?? .expense),
    payee: transaction.payee ?? "",
    amountText: primaryLeg?.amount.formatNoSymbol ?? "",
    date: transaction.date,
    accountId: primaryLeg?.accountId,
    toAccountId: transferLeg?.accountId,
    categoryId: primaryLeg?.categoryId,
    earmarkId: primaryLeg?.earmarkId,
    notes: transaction.notes ?? "",
    isRepeating: transaction.recurPeriod != nil && transaction.recurPeriod != .once,
    recurPeriod: transaction.recurPeriod,
    recurEvery: transaction.recurEvery ?? 1
  )
}
```

- [ ] **Step 2: Update TransactionDraftTests**

Update all test methods to construct Transactions with legs instead of amount/accountId. Update assertions to use `InstrumentAmount` and `Instrument`.

- [ ] **Step 3: Commit**

```bash
git add Shared/Models/TransactionDraft.swift MoolahTests/Shared/TransactionDraftTests.swift
git commit -m "refactor: update TransactionDraft to produce leg-based transactions"
```

---

## Task 16: Update Remaining Shared Files

**Files (compiler-guided):**
- `Shared/ExchangeRateService.swift` — `convert()` now works with `InstrumentAmount`
- `Shared/PriceConversionService.swift` — Update types
- `Shared/MonetaryAmountView.swift` — Rename to `InstrumentAmountView.swift`, update types
- Any other files under `Shared/` that reference `MonetaryAmount` or `Currency`

- [ ] **Step 1: Update ExchangeRateService**

The `convert()` method signature changes from `MonetaryAmount` to `InstrumentAmount`. Internal logic stays the same but uses `Decimal` arithmetic instead of Int cents.

- [ ] **Step 2: Update MonetaryAmountView → InstrumentAmountView**

Rename the file and type. Update to use `InstrumentAmount` properties.

- [ ] **Step 3: Compiler-guided updates for remaining Shared/ files**

Fix all remaining compilation errors in `Shared/`.

- [ ] **Step 4: Commit**

```bash
git add Shared/
git commit -m "refactor: update shared services and views for InstrumentAmount"
```

---

## Task 17: Update Remote Backend (Migration Source Only)

**Files:**
- Modify: `Backends/Remote/DTOs/TransactionDTO.swift`
- Modify: `Backends/Remote/DTOs/AccountDTO.swift`
- Modify: Other DTOs under `Backends/Remote/DTOs/`
- Modify: `Backends/Remote/Repositories/RemoteTransactionRepository.swift`
- Modify: Other repositories under `Backends/Remote/Repositories/`

The Remote backend is retained only as a migration data source. Update DTOs and repositories to produce `InstrumentAmount`/`Instrument` types. The TransactionDTO `toDomain()` method should convert the legacy single-amount format into a single-leg Transaction.

- [ ] **Step 1: Update TransactionDTO.toDomain()**

```swift
func toDomain() -> Transaction {
  // Convert legacy single-amount to single leg
  let instrument = Instrument.fiat(code: currencyCode)
  var legs: [TransactionLeg] = []

  if let acctId = accountId {
    legs.append(TransactionLeg(
      accountId: acctId,
      instrument: instrument,
      quantity: Decimal(amount) / 100,  // cents → decimal
      type: TransactionType(rawValue: type) ?? .expense,
      categoryId: categoryId,
      earmarkId: earmarkId
    ))
  }

  // For transfers, add destination leg
  if type == "transfer", let toAcctId = toAccountId {
    legs.append(TransactionLeg(
      accountId: toAcctId,
      instrument: instrument,
      quantity: -(Decimal(amount) / 100),  // Opposite sign
      type: .transfer
    ))
  }

  return Transaction(
    id: id,
    date: date,
    payee: payee,
    notes: notes,
    recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
    recurEvery: recurEvery,
    legs: legs
  )
}
```

- [ ] **Step 2: Update remaining DTOs and repositories**

Replace `MonetaryAmount` → `InstrumentAmount`, `Currency` → `Instrument` throughout all Remote backend files.

- [ ] **Step 3: Commit**

```bash
git add Backends/Remote/
git commit -m "refactor: update Remote backend DTOs to produce leg-based transactions"
```

---

## Task 18: Update Feature Views (Compiler-Guided)

This is the largest single task by file count (~50+ view files) but mostly mechanical. The compiler flags every remaining error.

**Files (examples — use compiler errors as the definitive list):**
- `Features/Transactions/Views/TransactionFormView.swift`
- `Features/Transactions/Views/TransactionDetailView.swift`
- `Features/Transactions/Views/TransactionRowView.swift`
- `Features/Transactions/Views/TransactionListView.swift`
- `Features/Accounts/Views/*.swift`
- `Features/Earmarks/Views/*.swift`
- `Features/Investments/Views/*.swift`
- `Features/Analysis/Views/*.swift`

- [ ] **Step 1: Fix transaction views**

Key changes:
- `transaction.amount` → `transaction.primaryAmount`
- `transaction.accountId` → `transaction.primaryAccountId`
- `transaction.type` → `transaction.type` (now computed from first leg — same API)
- `transaction.categoryId` → `transaction.categoryId` (now computed from first leg — same API)
- `MonetaryAmount` → `InstrumentAmount` in all view bindings
- `Currency` → `Instrument` in all view parameters
- `MonetaryAmountView` → `InstrumentAmountView`

- [ ] **Step 2: Fix account views**

- `Currency` parameters → `Instrument`
- Balance displays use `InstrumentAmount`

- [ ] **Step 3: Fix all remaining views**

Use `just build-mac 2>&1 | tee .agent-tmp/build-errors.txt` to get the full error list. Work through them systematically.

- [ ] **Step 4: Build successfully**

Run: `just build-mac 2>&1 | tee .agent-tmp/build.txt`
Expected: BUILD SUCCEEDED with no errors.

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/build.txt
git add Features/ App/
git commit -m "refactor: update all views for InstrumentAmount and leg-based transactions"
```

---

## Task 19: Update and Fix All Tests

**Files:**
- All files under `MoolahTests/`

- [ ] **Step 1: Update contract tests**

The key test suites to update:
- `TransactionRepositoryContractTests.swift` — Create transactions with legs, verify filtering/pagination works
- `AccountRepositoryContractTests.swift` — Balances computed from legs
- `AnalysisRepositoryContractTests.swift` — Analysis operates on legs
- `EarmarkRepositoryContractTests.swift` — Earmarks computed from legs
- `InvestmentRepositoryContractTests.swift` — Types updated

For each test file, the pattern is:
- Replace `Transaction(type:date:accountId:amount:)` with `Transaction(date:legs:[TransactionLeg(...)])`
- Replace `MonetaryAmount(cents:currency:)` with `InstrumentAmount(quantity:instrument:)`
- Replace `Currency.defaultTestCurrency` with `Instrument.defaultTestInstrument`

- [ ] **Step 2: Update store tests**

- `TransactionStoreTests.swift` — Update transaction creation to use legs
- `InvestmentStoreTests.swift` — Update types
- Any other store test files

- [ ] **Step 3: Run full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test-all.txt`
Expected: ALL TESTS PASS.

- [ ] **Step 4: If tests fail, fix and re-run**

Check failures: `grep -i 'failed\|error:' .agent-tmp/test-all.txt`
Fix issues and re-run until green.

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-all.txt
git add MoolahTests/
git commit -m "refactor: update all tests for leg-based transaction model"
```

---

## Task 20: New CloudKit Container Setup

**Files:**
- Modify: App entitlements file (the `.entitlements` file referencing the CloudKit container)
- Modify: Any container identifier references

- [ ] **Step 1: Document the container setup**

The developer needs to:
1. Go to https://developer.apple.com/account/ → Certificates, Identifiers & Profiles → CloudKit Containers
2. Create a new container (e.g. `iCloud.rocks.moolah.v2`)
3. Update the app's entitlements to reference the new container
4. In Xcode, update the CloudKit container entitlement

Search the codebase for the current CloudKit container identifier:
```bash
grep -r "iCloud" --include="*.entitlements" --include="*.plist" --include="*.swift" .
```

- [ ] **Step 2: Update the entitlements**

Change the CloudKit container identifier to the new one.

- [ ] **Step 3: Update any Swift code referencing the container ID**

Search and update.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: switch to new CloudKit container for leg-based schema"
```

---

## Task 21: Migration from moolah-server

**Files:**
- Modify: `Backends/CloudKit/Migration/CloudKitDataImporter.swift`
- Modify: `MoolahTests/Migration/CloudKitDataImporterTests.swift`

- [ ] **Step 1: Update CloudKitDataImporter**

The importer reads from the Remote backend and writes to CloudKit. Update it to:
- Read legacy transactions from Remote backend (now returns leg-based Transactions thanks to Task 17)
- Write TransactionRecords + TransactionLegRecords to the new CloudKit schema
- Ensure InstrumentRecords are created for the profile currency

The Remote backend's `TransactionDTO.toDomain()` already converts legacy single-amount transactions to leg-based format (Task 17), so the importer receives properly structured data.

- [ ] **Step 2: Update migration tests**

Update test expectations for the new leg-based format.

- [ ] **Step 3: Run migration tests**

Run: `just test 2>&1 | tee .agent-tmp/test-migration.txt`
Expected: Migration tests pass.

- [ ] **Step 4: Clean up and commit**

```bash
rm .agent-tmp/test-migration.txt
git add Backends/CloudKit/Migration/ MoolahTests/Migration/
git commit -m "refactor: update migration importer for leg-based CloudKit schema"
```

---

## Task 22: Final Verification

- [ ] **Step 1: Full build (both platforms)**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```

Expected: Both BUILD SUCCEEDED.

- [ ] **Step 2: Full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-final.txt
```

Expected: ALL TESTS PASS.

- [ ] **Step 3: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` or check build output for warnings. Fix any warnings in user code.

- [ ] **Step 4: Verify no MonetaryAmount or Currency references remain**

```bash
grep -r "MonetaryAmount" --include="*.swift" Domain/ Backends/ Features/ Shared/ App/
grep -r "Currency\b" --include="*.swift" Domain/ Backends/ Features/ Shared/ App/
```

Expected: No matches (except possibly comments or string literals).

- [ ] **Step 5: Verify no transaction.accountId direct access remains**

```bash
grep -r "\.accountId\b" --include="*.swift" Domain/Models/Transaction.swift
```

Expected: Only the convenience computed property `primaryAccountId` and within `TransactionLeg`.

- [ ] **Step 6: Clean up temp files**

```bash
rm -f .agent-tmp/build-mac.txt .agent-tmp/build-ios.txt .agent-tmp/test-final.txt
```

- [ ] **Step 7: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "chore: Phase 1 foundation complete — all builds and tests passing"
```
