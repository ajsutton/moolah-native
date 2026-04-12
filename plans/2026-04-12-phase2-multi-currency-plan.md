# Phase 2: Multi-Currency Accounts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable accounts to hold positions in multiple fiat currencies, with converted totals in the sidebar and a currency conversion transaction flow.

**Architecture:** Introduce `InstrumentConversionService` protocol wrapping the existing `ExchangeRateService` for fiat-to-fiat conversion. Add `Position` type computed from leg aggregation per (account, instrument). `AccountStore` gains async conversion for sidebar totals. `TransactionDraft` and `TransactionFormView` support two-amount transfers when accounts use different currencies.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, CloudKit, Swift Testing

**Key files to read before starting:** `plans/2026-04-12-multi-instrument-design.md` (design spec), `plans/2026-04-12-phase1-foundation-plan.md` (Phase 1 — must be complete before starting), `CLAUDE.md`, `CONCURRENCY_GUIDE.md`.

**Prerequisite:** Phase 1 must be fully implemented. This plan assumes `Instrument`, `InstrumentAmount`, `TransactionLeg`, and the leg-based `Transaction` model are in place. All references to types below (e.g. `Instrument.fiat(code:)`, `InstrumentAmount`, `Transaction.legs`, `TransactionLeg`) refer to the Phase 1 types.

---

## File Structure

### New Files
- `Domain/Services/InstrumentConversionService.swift` — Protocol and fiat implementation
- `Domain/Models/Position.swift` — Position type (accountId, instrument, quantity)
- `Shared/Views/PositionListView.swift` — Reusable view for showing per-instrument positions
- `MoolahTests/Domain/InstrumentConversionServiceTests.swift` — Conversion service unit tests
- `MoolahTests/Domain/PositionTests.swift` — Position computation tests
- `MoolahTests/Features/AccountStoreConversionTests.swift` — Store-level conversion tests

### Major Modifications
- `Features/Accounts/AccountStore.swift` — Add position computation, async converted totals
- `Features/Navigation/SidebarView.swift` — Show converted totals, loading states
- `Shared/Models/TransactionDraft.swift` — Add `toAmountText` for cross-currency transfers
- `Features/Transactions/Views/TransactionFormView.swift` — Second amount field for cross-currency transfers
- `Domain/Repositories/BackendProvider.swift` — Expose `InstrumentConversionService`

### No Files Deleted

---

## Task 1: InstrumentConversionService Protocol and Fiat Implementation

**Files:**
- Create: `Domain/Services/InstrumentConversionService.swift`
- Create: `MoolahTests/Domain/InstrumentConversionServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Domain/InstrumentConversionServiceTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentConversionService")
struct InstrumentConversionServiceTests {
  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  private func makeService(
    rates: [String: [String: Decimal]] = [:]
  ) -> FiatConversionService {
    let client = FixedRateClient(rates: rates)
    let cacheDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("conversion-tests")
      .appendingPathComponent(UUID().uuidString)
    let exchangeRates = ExchangeRateService(client: client, cacheDirectory: cacheDir)
    return FiatConversionService(exchangeRates: exchangeRates)
  }

  @Test func sameCurrencyReturnsIdentity() async throws {
    let service = makeService()
    let result = try await service.convert(
      Decimal(string: "100.00")!,
      from: .AUD, to: .AUD,
      on: date("2025-06-15")
    )
    #expect(result == Decimal(string: "100.00")!)
  }

  @Test func convertsAUDtoUSD() async throws {
    let service = makeService(rates: [
      "2025-06-15": ["USD": Decimal(string: "0.6500")!]
    ])
    let result = try await service.convert(
      Decimal(string: "1000.00")!,
      from: .AUD, to: .USD,
      on: date("2025-06-15")
    )
    #expect(result == Decimal(string: "650.00")!)
  }

  @Test func convertsUSDtoAUD() async throws {
    let service = makeService(rates: [
      "2025-06-15": ["AUD": Decimal(string: "1.5385")!]
    ])
    let result = try await service.convert(
      Decimal(string: "650.00")!,
      from: .USD, to: .AUD,
      on: date("2025-06-15")
    )
    // 650 * 1.5385 = 1000.025
    #expect(result == Decimal(string: "650.00")! * Decimal(string: "1.5385")!)
  }

  @Test func convertAmount() async throws {
    let service = makeService(rates: [
      "2025-06-15": ["USD": Decimal(string: "0.6500")!]
    ])
    let amount = InstrumentAmount(
      quantity: Decimal(string: "1000.00")!,
      instrument: .AUD
    )
    let result = try await service.convertAmount(
      amount, to: .USD, on: date("2025-06-15")
    )
    #expect(result.instrument == .USD)
    #expect(result.quantity == Decimal(string: "650.00")!)
  }

  @Test func convertAmountSameCurrency() async throws {
    let service = makeService()
    let amount = InstrumentAmount(
      quantity: Decimal(string: "1000.00")!,
      instrument: .AUD
    )
    let result = try await service.convertAmount(
      amount, to: .AUD, on: date("2025-06-15")
    )
    #expect(result == amount)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-conversion.txt`
Expected: FAIL — `InstrumentConversionService` and `FiatConversionService` not defined.

- [ ] **Step 3: Implement the protocol and fiat implementation**

```swift
// Domain/Services/InstrumentConversionService.swift
import Foundation

/// Converts quantities between instruments. Phase 2: fiat-to-fiat only.
/// Phase 3+ will add stock and crypto conversion paths.
protocol InstrumentConversionService: Sendable {
  /// Convert a raw quantity from one instrument to another on a given date.
  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal

  /// Convenience: convert an InstrumentAmount to a different instrument.
  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount
}

/// Fiat-to-fiat conversion backed by ExchangeRateService.
actor FiatConversionService: InstrumentConversionService {
  private let exchangeRates: ExchangeRateService

  init(exchangeRates: ExchangeRateService) {
    self.exchangeRates = exchangeRates
  }

  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal {
    guard from != to else { return quantity }
    guard from.kind == .fiatCurrency, to.kind == .fiatCurrency else {
      throw ConversionError.unsupportedInstrumentKind
    }
    let fromCurrency = Currency.from(code: from.id)
    let toCurrency = Currency.from(code: to.id)
    let rate = try await exchangeRates.rate(from: fromCurrency, to: toCurrency, on: date)
    return quantity * rate
  }

  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount {
    guard amount.instrument != instrument else { return amount }
    let converted = try await convert(
      amount.quantity, from: amount.instrument, to: instrument, on: date
    )
    return InstrumentAmount(quantity: converted, instrument: instrument)
  }
}

enum ConversionError: Error, Equatable {
  case unsupportedInstrumentKind
}
```

Note: `FiatConversionService` uses `Currency.from(code:)` to bridge between `Instrument.id` and the `Currency` type still used by `ExchangeRateService`. In Phase 1, `ExchangeRateService` continues to accept `Currency` parameters since it's a shared service. If Phase 1 migrates `ExchangeRateService` to accept `Instrument` directly, adjust accordingly.

- [ ] **Step 4: Add `Domain/Services` to project.yml if needed**

Check `project.yml` for source paths. If `Domain/Services/` is not automatically included, add it. Run `just generate` after changes.

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-conversion.txt`
Expected: All InstrumentConversionService tests PASS.

- [ ] **Step 6: Clean up and commit**

```bash
rm .agent-tmp/test-conversion.txt
git add Domain/Services/InstrumentConversionService.swift MoolahTests/Domain/InstrumentConversionServiceTests.swift
git commit -m "feat: add InstrumentConversionService protocol and FiatConversionService"
```

---

## Task 2: Position Type

**Files:**
- Create: `Domain/Models/Position.swift`
- Create: `MoolahTests/Domain/PositionTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Domain/PositionTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("Position")
struct PositionTests {
  let accountId = UUID()
  let aud = Instrument.AUD
  let usd = Instrument.USD

  @Test func initStoresProperties() {
    let pos = Position(accountId: accountId, instrument: aud, quantity: Decimal(string: "1500.00")!)
    #expect(pos.accountId == accountId)
    #expect(pos.instrument == aud)
    #expect(pos.quantity == Decimal(string: "1500.00")!)
  }

  @Test func amount() {
    let pos = Position(accountId: accountId, instrument: aud, quantity: Decimal(string: "1500.00")!)
    #expect(pos.amount.quantity == Decimal(string: "1500.00")!)
    #expect(pos.amount.instrument == aud)
  }

  @Test func computeFromLegsGroupsByInstrument() {
    let legs = [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(accountId: accountId, instrument: usd, quantity: Decimal(string: "50.00")!, type: .income),
      TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "-30.00")!, type: .expense),
    ]
    let positions = Position.compute(for: accountId, from: legs)
    #expect(positions.count == 2)

    let audPos = positions.first(where: { $0.instrument == aud })
    #expect(audPos?.quantity == Decimal(string: "70.00")!)

    let usdPos = positions.first(where: { $0.instrument == usd })
    #expect(usdPos?.quantity == Decimal(string: "50.00")!)
  }

  @Test func computeFiltersToAccount() {
    let otherAccount = UUID()
    let legs = [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(accountId: otherAccount, instrument: aud, quantity: Decimal(string: "200.00")!, type: .income),
    ]
    let positions = Position.compute(for: accountId, from: legs)
    #expect(positions.count == 1)
    #expect(positions.first?.quantity == Decimal(string: "100.00")!)
  }

  @Test func computeEmptyLegs() {
    let positions = Position.compute(for: accountId, from: [])
    #expect(positions.isEmpty)
  }

  @Test func computeExcludesZeroQuantity() {
    let legs = [
      TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!, type: .income),
      TransactionLeg(accountId: accountId, instrument: aud, quantity: Decimal(string: "-100.00")!, type: .expense),
    ]
    let positions = Position.compute(for: accountId, from: legs)
    #expect(positions.isEmpty)
  }

  @Test func hashableAndEquatable() {
    let a = Position(accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!)
    let b = Position(accountId: accountId, instrument: aud, quantity: Decimal(string: "100.00")!)
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-position.txt`
Expected: FAIL — `Position` type not defined.

- [ ] **Step 3: Implement Position**

```swift
// Domain/Models/Position.swift
import Foundation

/// A computed position for a specific instrument within an account.
/// Derived from leg aggregation — not persisted.
struct Position: Hashable, Sendable {
  let accountId: UUID
  let instrument: Instrument
  var quantity: Decimal

  /// The quantity as an InstrumentAmount.
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  /// Compute positions for a given account from a flat list of legs.
  /// Groups by instrument, sums quantities, excludes zero-quantity results.
  static func compute(for accountId: UUID, from legs: [TransactionLeg]) -> [Position] {
    var totals: [Instrument: Decimal] = [:]
    for leg in legs where leg.accountId == accountId {
      totals[leg.instrument, default: 0] += leg.quantity
    }
    return totals.compactMap { instrument, quantity in
      guard quantity != 0 else { return nil }
      return Position(accountId: accountId, instrument: instrument, quantity: quantity)
    }.sorted { $0.instrument.id < $1.instrument.id }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-position.txt`
Expected: All Position tests PASS.

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-position.txt
git add Domain/Models/Position.swift MoolahTests/Domain/PositionTests.swift
git commit -m "feat: add Position type computed from transaction leg aggregation"
```

---

## Task 3: Wire InstrumentConversionService into BackendProvider

**Files:**
- Modify: `Domain/Repositories/BackendProvider.swift`
- Modify: `Backends/CloudKit/CloudKitBackend.swift` (or wherever the concrete `BackendProvider` is)
- Modify: `MoolahTests/Support/TestBackend.swift`

- [ ] **Step 1: Add conversion service to BackendProvider protocol**

In `Domain/Repositories/BackendProvider.swift`, add:

```swift
var conversionService: any InstrumentConversionService { get }
```

- [ ] **Step 2: Implement in CloudKitBackend**

The `CloudKitBackend` (or whatever concrete backend is used) must create a `FiatConversionService` backed by its `ExchangeRateService` instance and expose it as `conversionService`.

Find where `ExchangeRateService` is currently created (likely in the app setup or backend init) and wire it:

```swift
// In CloudKitBackend or the backend factory
let exchangeRateService = ExchangeRateService(client: frankfurterClient)
let conversionService: any InstrumentConversionService = FiatConversionService(exchangeRates: exchangeRateService)
```

- [ ] **Step 3: Update TestBackend**

In `MoolahTests/Support/TestBackend.swift`, provide a `FiatConversionService` backed by a `FixedRateClient`:

```swift
static func create(
  currency: Currency = .defaultTestCurrency,
  exchangeRates: [String: [String: Decimal]] = [:]
) throws -> (backend: CloudKitBackend, container: ModelContainer) {
  let container = try TestModelContainer.create()
  let rateClient = FixedRateClient(rates: exchangeRates)
  let cacheDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("test-rates-\(UUID().uuidString)")
  let exchangeRateService = ExchangeRateService(client: rateClient, cacheDirectory: cacheDir)
  let conversionService = FiatConversionService(exchangeRates: exchangeRateService)
  let backend = CloudKitBackend(
    modelContainer: container,
    currency: currency,
    profileLabel: "Test",
    conversionService: conversionService
  )
  return (backend, container)
}
```

Ensure existing callers that don't pass `exchangeRates` continue to work (empty rates is fine for most tests — they don't need conversion).

- [ ] **Step 4: Fix any compilation errors from the protocol change**

All `BackendProvider` conformances must now provide `conversionService`. Fix each one.

- [ ] **Step 5: Run tests to verify everything still passes**

Run: `just test 2>&1 | tee .agent-tmp/test-backend.txt`
Expected: All existing tests PASS.

- [ ] **Step 6: Clean up and commit**

```bash
rm .agent-tmp/test-backend.txt
git add Domain/Repositories/BackendProvider.swift
git add Backends/ MoolahTests/Support/
git commit -m "feat: wire InstrumentConversionService into BackendProvider"
```

---

## Task 4: AccountStore — Positions and Converted Totals

**Files:**
- Modify: `Features/Accounts/AccountStore.swift`
- Create: `MoolahTests/Features/AccountStoreConversionTests.swift`

This task adds:
1. Per-account positions (computed from legs via the repository).
2. Async profile-currency total that converts each account's positions.

- [ ] **Step 1: Write the failing tests**

```swift
// MoolahTests/Features/AccountStoreConversionTests.swift
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore — Conversion")
@MainActor
struct AccountStoreConversionTests {
  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  @Test func singleCurrencyAccountTotalNoConversion() async throws {
    let accountId = UUID()
    let account = Account(id: accountId, name: "Bank", type: .bank)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    // Seed a transaction with one AUD leg
    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: Decimal(string: "1000.00")!,
          type: .openingBalance
        )
      ]
    )
    TestBackend.seed(transactions: [tx], in: container)

    let store = AccountStore(repository: backend.accounts)
    await store.load()

    // For single-currency account, positions should show one AUD position
    let positions = store.positions(for: accountId)
    #expect(positions.count == 1)
    #expect(positions.first?.instrument == .AUD)
    #expect(positions.first?.quantity == Decimal(string: "1000.00")!)
  }

  @Test func multiCurrencyAccountShowsMultiplePositions() async throws {
    let accountId = UUID()
    let account = Account(id: accountId, name: "Revolut", type: .bank)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let tx1 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: Decimal(string: "1000.00")!,
          type: .openingBalance
        )
      ]
    )
    let tx2 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .USD,
          quantity: Decimal(string: "500.00")!,
          type: .openingBalance
        )
      ]
    )
    TestBackend.seed(transactions: [tx1, tx2], in: container)

    let store = AccountStore(repository: backend.accounts)
    await store.load()

    let positions = store.positions(for: accountId)
    #expect(positions.count == 2)
    #expect(positions.contains(where: { $0.instrument == .AUD && $0.quantity == Decimal(string: "1000.00")! }))
    #expect(positions.contains(where: { $0.instrument == .USD && $0.quantity == Decimal(string: "500.00")! }))
  }

  @Test func convertedTotalSumsAllPositionsInProfileCurrency() async throws {
    let accountId = UUID()
    let account = Account(id: accountId, name: "Revolut", type: .bank)
    let rates: [String: [String: Decimal]] = [
      // Use today's date formatted as ISO8601 date-only
      ISO8601DateFormatter.dateOnly.string(from: Date()): [
        "AUD": Decimal(string: "1.5385")!
      ]
    ]
    let (backend, container) = try TestBackend.create(exchangeRates: rates)
    TestBackend.seed(accounts: [account], in: container)

    let tx1 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: Decimal(string: "1000.00")!,
          type: .openingBalance
        )
      ]
    )
    let tx2 = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .USD,
          quantity: Decimal(string: "500.00")!,
          type: .openingBalance
        )
      ]
    )
    TestBackend.seed(transactions: [tx1, tx2], in: container)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService
    )
    await store.load()

    // 1000 AUD + 500 USD converted to AUD (500 * 1.5385 = 769.25)
    let total = try await store.convertedTotal(in: .AUD)
    let expectedUsdInAud = Decimal(string: "500.00")! * Decimal(string: "1.5385")!
    let expected = Decimal(string: "1000.00")! + expectedUsdInAud
    #expect(total.quantity == expected)
    #expect(total.instrument == .AUD)
  }
}
```

Note: The exact test seeding approach depends on the Phase 1 outcome. If `Account` no longer has a `balance` field (balance computed from legs), `TestBackend.seed(accounts:)` won't need balance parameters. Adjust accordingly.

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-store-conv.txt`
Expected: FAIL — `positions(for:)` and `convertedTotal(in:)` not defined.

- [ ] **Step 3: Add positions and converted totals to AccountStore**

In `Features/Accounts/AccountStore.swift`:

```swift
// Add a stored conversion service
private let conversionService: (any InstrumentConversionService)?

// Update init
init(repository: AccountRepository, conversionService: (any InstrumentConversionService)? = nil) {
  self.repository = repository
  self.conversionService = conversionService
}

// Add positions cache — populated from leg queries after load
private(set) var positionsByAccount: [UUID: [Position]] = [:]

/// Positions for a given account. Returns empty array if not loaded.
func positions(for accountId: UUID) -> [Position] {
  positionsByAccount[accountId] ?? []
}

/// Compute the total value of all current accounts in a target instrument,
/// converting foreign-currency positions via the conversion service.
func convertedTotal(in targetInstrument: Instrument) async throws -> InstrumentAmount {
  guard let conversionService else {
    // Fallback: sum primary amounts without conversion
    return currentAccounts.reduce(.zero(instrument: targetInstrument)) { $0 + $1.primaryAmount }
  }

  var total = InstrumentAmount.zero(instrument: targetInstrument)
  let date = Date()

  for account in currentAccounts {
    let positions = self.positions(for: account.id)
    for position in positions {
      let converted = try await conversionService.convertAmount(
        position.amount, to: targetInstrument, on: date
      )
      total += converted
    }
  }
  return total
}
```

The position loading needs to happen during `load()`. After Phase 1, balances are computed from legs. The repository layer should provide a method to fetch legs for position computation, or the positions can be computed from the account's leg data. The exact wiring depends on Phase 1's repository API. Add a `fetchPositions(for accountId: UUID)` method to `AccountRepository` if needed, or compute positions from the transaction repository's legs.

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-store-conv.txt`
Expected: All AccountStoreConversion tests PASS. All existing AccountStore tests PASS.

- [ ] **Step 5: Clean up and commit**

```bash
rm .agent-tmp/test-store-conv.txt
git add Features/Accounts/AccountStore.swift MoolahTests/Features/AccountStoreConversionTests.swift
git commit -m "feat: add position tracking and converted totals to AccountStore"
```

---

## Task 5: Sidebar — Converted Account Totals

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`
- Modify: `Features/Accounts/Views/AccountRowView.swift` (SidebarRowView)

This task updates the sidebar to display profile-currency converted totals. Currently `currentTotal` sums `MonetaryAmount` values directly. After Phase 1, this becomes `InstrumentAmount`. With multi-currency, we need async conversion.

- [ ] **Step 1: Add converted total state to SidebarView**

In `SidebarView.swift`, add state for the converted total:

```swift
@State private var convertedCurrentTotal: InstrumentAmount?
@State private var convertedNetWorth: InstrumentAmount?
```

Load the converted totals using `.task`:

```swift
.task {
  await loadConvertedTotals()
}

private func loadConvertedTotals() async {
  let profileInstrument = Instrument.fiat(code: profileCurrencyCode)
  do {
    convertedCurrentTotal = try await accountStore.convertedTotal(in: profileInstrument)
    // Net worth = current + investment
    let investmentTotal = try await accountStore.convertedInvestmentTotal(in: profileInstrument)
    convertedNetWorth = (convertedCurrentTotal ?? .zero(instrument: profileInstrument)) + investmentTotal
  } catch {
    // Fall back to non-converted totals (already displayed)
  }
}
```

Where `profileCurrencyCode` comes from the profile (available in the environment or passed as a parameter).

- [ ] **Step 2: Update total rows to show converted values**

Replace the hardcoded `accountStore.currentTotal` in the total row with the converted amount (falling back to the non-converted total while loading):

```swift
totalRow(
  label: "Current Total",
  value: convertedCurrentTotal ?? accountStore.currentTotal
)
```

Similarly for net worth:

```swift
LabeledContent("Net Worth") {
  MonetaryAmountView(amount: convertedNetWorth ?? accountStore.netWorth)
}
```

Note: `MonetaryAmountView` needs to accept `InstrumentAmount` after Phase 1. If Phase 1 renamed this to `InstrumentAmountView`, use that name.

- [ ] **Step 3: Run tests to verify compilation and existing tests pass**

Run: `just test 2>&1 | tee .agent-tmp/test-sidebar.txt`
Expected: All tests PASS.

- [ ] **Step 4: Clean up and commit**

```bash
rm .agent-tmp/test-sidebar.txt
git add Features/Navigation/SidebarView.swift Features/Accounts/Views/AccountRowView.swift
git commit -m "feat: sidebar shows profile-currency converted totals"
```

---

## Task 6: Account Detail — Position List View

**Files:**
- Create: `Shared/Views/PositionListView.swift`
- Modify: Account detail view (the view shown when an account is selected in the sidebar — likely `TransactionListView.swift` or a wrapper)

This task adds a section to the account detail view that shows per-instrument positions when an account holds more than one instrument.

- [ ] **Step 1: Create PositionListView**

```swift
// Shared/Views/PositionListView.swift
import SwiftUI

/// Displays a list of instrument positions for an account.
/// Only shown when the account holds more than one instrument.
struct PositionListView: View {
  let positions: [Position]
  let profileInstrument: Instrument

  var body: some View {
    if positions.count > 1 {
      Section("Balances") {
        ForEach(positions, id: \.instrument) { position in
          HStack {
            Text(position.instrument.name)
            Spacer()
            Text(position.amount.formatted)
              .monospacedDigit()
              .foregroundStyle(positionColor(position))
          }
          .accessibilityLabel(
            "\(position.instrument.name): \(position.amount.formatted)"
          )
        }
      }
    }
  }

  private func positionColor(_ position: Position) -> Color {
    if position.quantity > 0 { return .green }
    if position.quantity < 0 { return .red }
    return .primary
  }
}
```

- [ ] **Step 2: Wire into account detail view**

In the view that renders when an account is selected (likely the header area of `TransactionListView` or a dedicated account header), add:

```swift
let positions = accountStore.positions(for: account.id)
PositionListView(
  positions: positions,
  profileInstrument: Instrument.fiat(code: profileCurrencyCode)
)
```

This only renders when `positions.count > 1`, so single-currency accounts look identical to before.

- [ ] **Step 3: Run tests and verify compilation**

Run: `just test 2>&1 | tee .agent-tmp/test-posview.txt`
Expected: All tests PASS.

- [ ] **Step 4: Clean up and commit**

```bash
rm .agent-tmp/test-posview.txt
git add Shared/Views/PositionListView.swift
git add Features/Transactions/Views/TransactionListView.swift
git commit -m "feat: account detail shows per-instrument positions for multi-currency accounts"
```

---

## Task 7: TransactionDraft — Cross-Currency Transfer Support

**Files:**
- Modify: `Shared/Models/TransactionDraft.swift`
- Modify: `MoolahTests/Shared/TransactionDraftTests.swift` (or wherever draft tests live)

After Phase 1, `TransactionDraft` produces legs via its `toTransaction` method. This task adds `toAmountText` for the receiving side of a cross-currency transfer.

- [ ] **Step 1: Write the failing tests**

```swift
// Add to existing TransactionDraft tests or create new file
@Suite("TransactionDraft — Cross-Currency")
struct TransactionDraftCrossCurrencyTests {
  let fromAccountId = UUID()
  let toAccountId = UUID()

  @Test func sameCurrencyTransferProducesTwoLegsWithSameAmount() {
    var draft = TransactionDraft(accountId: fromAccountId)
    draft.type = .transfer
    draft.toAccountId = toAccountId
    draft.amountText = "100.00"
    // toAmountText empty means same amount, same instrument
    draft.toAmountText = ""

    let tx = draft.toTransaction(
      id: UUID(),
      fromInstrument: .AUD,
      toInstrument: .AUD
    )

    #expect(tx != nil)
    #expect(tx!.legs.count == 2)

    let outflow = tx!.legs.first(where: { $0.accountId == fromAccountId })
    #expect(outflow?.quantity == Decimal(string: "-100.00")!)
    #expect(outflow?.instrument == .AUD)

    let inflow = tx!.legs.first(where: { $0.accountId == toAccountId })
    #expect(inflow?.quantity == Decimal(string: "100.00")!)
    #expect(inflow?.instrument == .AUD)
  }

  @Test func crossCurrencyTransferProducesTwoLegsWithDifferentAmounts() {
    var draft = TransactionDraft(accountId: fromAccountId)
    draft.type = .transfer
    draft.toAccountId = toAccountId
    draft.amountText = "1000.00"
    draft.toAmountText = "650.00"

    let tx = draft.toTransaction(
      id: UUID(),
      fromInstrument: .AUD,
      toInstrument: .USD
    )

    #expect(tx != nil)
    #expect(tx!.legs.count == 2)

    let outflow = tx!.legs.first(where: { $0.accountId == fromAccountId })
    #expect(outflow?.quantity == Decimal(string: "-1000.00")!)
    #expect(outflow?.instrument == .AUD)

    let inflow = tx!.legs.first(where: { $0.accountId == toAccountId })
    #expect(inflow?.quantity == Decimal(string: "650.00")!)
    #expect(inflow?.instrument == .USD)
  }

  @Test func crossCurrencyTransferInvalidWithoutToAmount() {
    var draft = TransactionDraft(accountId: fromAccountId)
    draft.type = .transfer
    draft.toAccountId = toAccountId
    draft.amountText = "1000.00"
    draft.toAmountText = ""

    // When instruments differ but toAmountText is empty, it should still be valid
    // (default: same numeric amount in target currency)
    let tx = draft.toTransaction(
      id: UUID(),
      fromInstrument: .AUD,
      toInstrument: .USD
    )

    #expect(tx != nil)
    let inflow = tx!.legs.first(where: { $0.accountId == toAccountId })
    // Default: same numeric amount
    #expect(inflow?.quantity == Decimal(string: "1000.00")!)
    #expect(inflow?.instrument == .USD)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test 2>&1 | tee .agent-tmp/test-draft.txt`
Expected: FAIL — `toAmountText` property and new `toTransaction` signature not defined.

- [ ] **Step 3: Add toAmountText and update toTransaction**

In `Shared/Models/TransactionDraft.swift`:

```swift
// Add new property
var toAmountText: String

// Update memberwise init to include toAmountText with default ""
// Update convenience inits to set toAmountText = ""

// Add parsed to-amount
var parsedToQuantity: Decimal? {
  guard !toAmountText.isEmpty else { return nil }
  return InstrumentAmount.parseQuantity(from: toAmountText, decimals: 2)
}
```

Update `toTransaction` to accept `fromInstrument` and `toInstrument` parameters:

```swift
func toTransaction(
  id: UUID,
  fromInstrument: Instrument,
  toInstrument: Instrument? = nil
) -> Transaction? {
  guard let quantity = InstrumentAmount.parseQuantity(from: amountText, decimals: fromInstrument.decimals),
        quantity > 0,
        isValid
  else { return nil }

  var legs: [TransactionLeg] = []

  switch type {
  case .expense:
    legs.append(TransactionLeg(
      accountId: accountId!,
      instrument: fromInstrument,
      quantity: -quantity,
      type: .expense,
      categoryId: categoryId,
      earmarkId: earmarkId
    ))

  case .income, .openingBalance:
    legs.append(TransactionLeg(
      accountId: accountId!,
      instrument: fromInstrument,
      quantity: quantity,
      type: type,
      categoryId: categoryId,
      earmarkId: earmarkId
    ))

  case .transfer:
    guard let toAccountId else { return nil }
    let resolvedToInstrument = toInstrument ?? fromInstrument

    // Outflow leg
    legs.append(TransactionLeg(
      accountId: accountId!,
      instrument: fromInstrument,
      quantity: -quantity,
      type: .transfer
    ))

    // Inflow leg — use toAmountText if provided, otherwise mirror the from amount
    let toQuantity: Decimal
    if let parsed = parsedToQuantity {
      toQuantity = parsed
    } else {
      toQuantity = quantity
    }
    legs.append(TransactionLeg(
      accountId: toAccountId,
      instrument: resolvedToInstrument,
      quantity: toQuantity,
      type: .transfer
    ))
  }

  return Transaction(
    id: id,
    date: date,
    payee: payee.isEmpty ? nil : payee,
    notes: notes.isEmpty ? nil : notes,
    legs: legs,
    recurPeriod: isRepeating ? recurPeriod : nil,
    recurEvery: isRepeating ? recurEvery : nil
  )
}
```

Note: The exact `Transaction` init depends on Phase 1's final signature. Adjust field names accordingly.

- [ ] **Step 4: Update existing `toTransaction` callers**

The old `toTransaction(id:currency:)` callers need to be updated to `toTransaction(id:fromInstrument:)`. This is a mechanical update — the compiler will guide it. Key callers:
- `TransactionFormView.save()`
- Any tests that call `draft.toTransaction`

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test 2>&1 | tee .agent-tmp/test-draft.txt`
Expected: All TransactionDraft tests PASS (old and new).

- [ ] **Step 6: Clean up and commit**

```bash
rm .agent-tmp/test-draft.txt
git add Shared/Models/TransactionDraft.swift MoolahTests/
git commit -m "feat: TransactionDraft supports cross-currency transfers with toAmountText"
```

---

## Task 8: TransactionFormView — Cross-Currency Amount Field

**Files:**
- Modify: `Features/Transactions/Views/TransactionFormView.swift`

This task adds a second amount field that appears when a transfer's source and destination accounts use different primary instruments.

- [ ] **Step 1: Add state for the to-amount**

```swift
@State private var toAmountText: String
```

Initialize from existing transaction (if editing a cross-currency transfer, extract the inflow leg's amount) or empty string for new transactions.

- [ ] **Step 2: Determine when to show the second amount field**

Add a computed property:

```swift
private var isCrossCurrencyTransfer: Bool {
  guard type == .transfer,
        let fromAccount = accounts.by(id: accountId ?? UUID()),
        let toAccount = accounts.by(id: toAccountId ?? UUID())
  else { return false }
  return fromAccount.primaryInstrument != toAccount.primaryInstrument
}
```

Note: `Account.primaryInstrument` may need to be derived from the account's positions or from the profile's currency. After Phase 1, accounts may not store a currency directly. The heuristic: look at the account's positions; if there's exactly one, use that instrument; if there are multiple or zero, use the profile's instrument.

For simplicity, this can initially check whether the two accounts are known to hold different currencies. A simpler approach: let the user manually toggle "amounts differ" or auto-detect from account positions.

- [ ] **Step 3: Add the second amount field to the form**

In `detailsSection`, after the existing amount field, add:

```swift
if type == .transfer {
  if isCrossCurrencyTransfer || !toAmountText.isEmpty {
    HStack {
      Text(toInstrument.id)
        .foregroundStyle(.secondary)
      TextField("Received Amount", text: $toAmountText)
        #if os(iOS)
          .keyboardType(.decimalPad)
        #endif
    }
  }
}
```

Where `toInstrument` is derived from the destination account.

- [ ] **Step 4: Update the save method**

The `save()` method must pass the instruments through:

```swift
private func save() {
  let fromInstrument = instrumentForAccount(accountId)
  let toInstrument = type == .transfer ? instrumentForAccount(toAccountId) : nil

  var draft = self.draft
  draft.toAmountText = toAmountText

  guard let transaction = draft.toTransaction(
    id: existing?.id ?? UUID(),
    fromInstrument: fromInstrument,
    toInstrument: toInstrument
  ) else { return }

  onSave(transaction)
  dismiss()
}

private func instrumentForAccount(_ accountId: UUID?) -> Instrument {
  // Derive from account positions or fall back to profile currency
  guard let id = accountId,
        let positions = accountStore?.positions(for: id),
        let primary = positions.first
  else {
    return Instrument.fiat(code: profileCurrencyCode)
  }
  return primary.instrument
}
```

This requires `accountStore` or positions to be accessible from the form. Options:
- Pass `AccountStore` as an environment/parameter (it's already available in the parent view).
- Pass the positions for each account directly.

- [ ] **Step 5: Run tests and verify compilation**

Run: `just test 2>&1 | tee .agent-tmp/test-form.txt`
Expected: All tests PASS.

- [ ] **Step 6: Clean up and commit**

```bash
rm .agent-tmp/test-form.txt
git add Features/Transactions/Views/TransactionFormView.swift
git commit -m "feat: transaction form shows second amount field for cross-currency transfers"
```

---

## Task 9: ISO8601DateFormatter Helper and Test Utilities

**Files:**
- Modify: A shared extension file (e.g. `Shared/Extensions/ISO8601DateFormatter+DateOnly.swift` or existing extension file)
- Modify: `MoolahTests/Support/TestCurrency.swift` (or create `TestInstrument.swift`)

This is a small utility task that other tasks depend on. It can be done first or as needed.

- [ ] **Step 1: Add dateOnly formatter**

```swift
extension ISO8601DateFormatter {
  /// Formatter that produces date-only strings like "2025-06-15".
  static let dateOnly: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    return f
  }()
}
```

- [ ] **Step 2: Add test instrument constant**

If Phase 1 created `TestInstrument.swift`, add:

```swift
extension Instrument {
  static let defaultTestInstrument: Instrument = .AUD
}
```

Otherwise, update `TestCurrency.swift` to also provide a test instrument.

- [ ] **Step 3: Run tests, commit**

```bash
git add Shared/Extensions/ MoolahTests/Support/
git commit -m "chore: add ISO8601 dateOnly formatter and test instrument constant"
```

---

## Task 10: End-to-End Verification

**Files:** None new — this is a verification pass.

- [ ] **Step 1: Run full test suite**

```bash
just test 2>&1 | tee .agent-tmp/test-final.txt
grep -i 'failed\|error:' .agent-tmp/test-final.txt
```

Expected: Zero failures.

- [ ] **Step 2: Check for compiler warnings**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` or:

```bash
just build-mac 2>&1 | grep -i warning | grep -v Preview
```

Expected: Zero warnings (SWIFT_TREAT_WARNINGS_AS_ERRORS is enabled).

- [ ] **Step 3: Manual smoke test**

```bash
just run-mac
```

Verify:
- Sidebar shows account totals (single-currency accounts unchanged).
- Creating a transfer between two accounts works.
- The second amount field appears only when accounts have different currencies (if testable with available data).

- [ ] **Step 4: Clean up temp files**

```bash
rm -rf .agent-tmp/test-final.txt
```
