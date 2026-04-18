import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore -- Conversion")
@MainActor
struct AccountStoreConversionTests {

  @Test func singleCurrencyAccountPositions() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

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

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    let positions = store.positions(for: accountId)
    #expect(positions.count == 1)
    #expect(positions.first?.instrument == .AUD)
    // Quantity will be from storage (Int64 scaled), so compare with tolerance
    #expect(positions.first?.quantity == Decimal(string: "1000.00")!)
  }

  @Test func multiCurrencyAccountShowsMultiplePositions() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Revolut", type: .bank,
      instrument: .defaultTestInstrument)
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

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    let positions = store.positions(for: accountId)
    #expect(positions.count == 2)
    #expect(
      positions.contains(where: {
        $0.instrument == .AUD && $0.quantity == Decimal(string: "1000.00")!
      }))
    #expect(
      positions.contains(where: {
        $0.instrument == .USD && $0.quantity == Decimal(string: "500.00")!
      }))
  }

  @Test func convertedTotalSumsAllPositionsInProfileCurrency() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Revolut", type: .bank,
      instrument: .defaultTestInstrument)
    let todayString = Date().iso8601DateOnlyString
    let rates: [String: [String: Decimal]] = [
      todayString: [
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
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    // 1000 AUD + 500 USD converted to AUD (500 * 1.5385 = 769.25)
    let total = try await store.computeConvertedCurrentTotal(in: .AUD)
    let expectedUsdInAud = Decimal(string: "500.00")! * Decimal(string: "1.5385")!
    let expected = Decimal(string: "1000.00")! + expectedUsdInAud
    #expect(total.quantity == expected)
    #expect(total.instrument == .AUD)
  }

  @Test func positionsForUnknownAccountReturnsEmpty() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()
    #expect(store.positions(for: UUID()).isEmpty)
  }

  @Test func mixedKindAccountShowsFiatAndStockPositions() async throws {
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let account = Account(
      id: accountId, name: "Sharesight", type: .investment,
      instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: Decimal(string: "5000.00")!, type: .openingBalance)
      ]
    )
    let stockTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: Decimal(100),
          type: .transfer)
      ]
    )
    TestBackend.seed(transactions: [audTx, stockTx], in: container)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    let positions = store.positions(for: accountId)
    #expect(positions.count == 2)
    #expect(positions.contains { $0.instrument == .AUD })
    #expect(positions.contains { $0.instrument == bhp })
  }

  @Test func mixedKindAccountShowsFiatStockAndCryptoPositions() async throws {
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment,
      instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let txns = [
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD,
            quantity: Decimal(string: "1000.00")!, type: .openingBalance)
        ]),
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: bhp, quantity: Decimal(100),
            type: .transfer)
        ]),
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: eth,
            quantity: Decimal(string: "0.5")!, type: .transfer)
        ]),
    ]
    TestBackend.seed(transactions: txns, in: container)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    await store.load()

    let positions = store.positions(for: accountId)
    #expect(positions.count == 3)
    let kinds = Set(positions.map(\.instrument.kind))
    #expect(kinds == [.fiatCurrency, .stock, .cryptoToken])
  }

  // MARK: - displayBalance

  @Test func displayBalanceSumsAllPositionsInAccountInstrument() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Revolut", type: .bank, instrument: .AUD)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: Decimal(string: "1000.00")!, type: .openingBalance)
      ]
    )
    let usdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .USD,
          quantity: Decimal(string: "200.00")!, type: .openingBalance)
      ]
    )
    TestBackend.seed(transactions: [audTx, usdTx], in: container)

    // 1 USD = 1.5 AUD
    let conversion = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let store = AccountStore(
      repository: backend.accounts, conversionService: conversion,
      targetInstrument: .AUD)
    await store.load()

    let balance = try await store.displayBalance(for: accountId)
    #expect(balance.instrument == .AUD)
    // 1000 AUD + 200 USD * 1.5 = 1300 AUD
    #expect(balance.quantity == Decimal(string: "1300.00")!)
  }

  @Test func displayBalanceForSingleCurrencyAccountReturnsPrimaryPosition() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Bank", type: .bank, instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: Decimal(string: "750.00")!, type: .openingBalance)
      ]
    )
    TestBackend.seed(transactions: [tx], in: container)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let balance = try await store.displayBalance(for: accountId)
    #expect(balance.quantity == Decimal(string: "750.00")!)
    #expect(balance.instrument == .defaultTestInstrument)
  }

  @Test func displayBalanceForInvestmentAccountPrefersInvestmentValue() async throws {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment, instrument: .AUD)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let usdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .USD,
          quantity: Decimal(string: "100.00")!, type: .openingBalance)
      ]
    )
    TestBackend.seed(transactions: [usdTx], in: container)

    let conversion = FixedConversionService(rates: ["USD": Decimal(string: "1.5")!])
    let store = AccountStore(
      repository: backend.accounts, conversionService: conversion,
      targetInstrument: .AUD)
    await store.load()

    // No investment value yet → falls back to converted position sum (USD * 1.5 = 150 AUD)
    let sumBalance = try await store.displayBalance(for: accountId)
    #expect(sumBalance.quantity == Decimal(string: "150.00")!)

    // Investment value set externally → wins over converted positions
    let externalValue = InstrumentAmount(
      quantity: Decimal(string: "999.00")!, instrument: .AUD)
    store.updateInvestmentValue(accountId: accountId, value: externalValue)
    let override = try await store.displayBalance(for: accountId)
    #expect(override == externalValue)
  }

  @Test func displayBalanceForUnknownAccountReturnsZero() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    await store.load()
    let balance = try await store.displayBalance(for: UUID())
    #expect(balance == .zero(instrument: .defaultTestInstrument))
  }

  // MARK: - Partial conversion failures (sidebar bug)

  /// When one account's conversion fails, other accounts whose conversions
  /// succeed still appear in `convertedBalances`. Aggregate totals stay nil
  /// because we cannot accurately sum a set with a missing value.
  @Test func perAccountBalancePopulatesEvenWhenAnotherAccountFails() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let eur = Instrument.fiat(code: "EUR")
    let bankAud = Account(name: "AUD Bank", type: .bank, instrument: aud)
    let bankMixed = Account(name: "Mixed Bank", type: .bank, instrument: eur)

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [bankAud, bankMixed], in: container)
    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankAud.id, instrument: aud,
          quantity: Decimal(1000), type: .openingBalance)
      ])
    let mixedEurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankMixed.id, instrument: eur,
          quantity: Decimal(200), type: .openingBalance)
      ])
    let mixedUsdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankMixed.id, instrument: usd,
          quantity: Decimal(50), type: .openingBalance)
      ])
    TestBackend.seed(transactions: [audTx, mixedEurTx, mixedUsdTx], in: container)

    // USD conversions fail; AUD and EUR conversions succeed (1:1 fallback).
    let conversion = FailingConversionService(failingInstrumentIds: ["USD"])
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .seconds(60))

    await store.load()
    // Wait for the first conversion pass to publish bankAud's balance. We
    // poll the observable we actually assert on: when bankAud is present,
    // the pass has written the whole `newBalances` / totals set atomically
    // within a single MainActor tick, so the other invariants below hold.
    // Timeout is generous because iOS simulator CI has been observed to
    // take >10s for the first pass under CoreData/SwiftData setup load.
    try await waitForCondition(timeout: .seconds(30)) {
      store.convertedBalances[bankAud.id] != nil
    }

    // AUD bank: only AUD positions → succeeds.
    #expect(store.convertedBalances[bankAud.id]?.quantity == 1000)
    // Mixed bank (EUR + USD): needs USD → EUR conversion which fails → nil.
    #expect(store.convertedBalances[bankMixed.id] == nil)
    // Aggregate cannot be accurate with a missing unit → nil.
    #expect(store.convertedCurrentTotal == nil)
    #expect(store.convertedNetWorth == nil)
  }

  /// After conversion service recovers, a retry populates the previously
  /// failing account balance and the aggregate totals.
  @Test func conversionFailuresAreRetriedAfterDelay() async throws {
    let aud = Instrument.AUD
    let eur = Instrument.fiat(code: "EUR")
    let bankAud = Account(name: "AUD Bank", type: .bank, instrument: aud)
    let bankEur = Account(name: "EUR Bank", type: .bank, instrument: eur)

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [bankAud, bankEur], in: container)
    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankAud.id, instrument: aud,
          quantity: Decimal(1000), type: .openingBalance)
      ])
    let eurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: bankEur.id, instrument: eur,
          quantity: Decimal(500), type: .openingBalance)
      ])
    TestBackend.seed(transactions: [audTx, eurTx], in: container)

    let conversion = FailingConversionService(failingInstrumentIds: ["EUR"])
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .milliseconds(20))

    await store.load()
    // Wait for the first pass to publish the succeeding account's balance
    // before probing the partial-failure state. Polling an observable we
    // actually care about keeps this robust on slow iOS simulator CI.
    try await waitForCondition(timeout: .seconds(30)) {
      store.convertedBalances[bankAud.id] != nil
    }

    // Initial state: EUR bank can't be converted to AUD aggregate target → aggregate nil.
    #expect(store.convertedCurrentTotal == nil)

    // Recover the conversion service.
    await conversion.setFailing([])

    // Retry should fire within retryDelay × a few attempts.
    try await waitForCondition(timeout: .seconds(30)) {
      store.convertedCurrentTotal != nil
    }

    // 1000 AUD + 500 EUR (1:1 fallback) = 1500 AUD
    #expect(store.convertedCurrentTotal?.quantity == 1500)
    #expect(store.convertedNetWorth?.quantity == 1500)
    #expect(store.convertedBalances[bankAud.id]?.quantity == 1000)
    #expect(store.convertedBalances[bankEur.id]?.quantity == 500)
  }
  /// Regression for #96: `computeConvertedInvestmentTotal` must not route
  /// through `displayBalance` (which converts every position to the
  /// account's instrument) and then convert the bottom line again to the
  /// target. That extra hop doubles the round-trip through the conversion
  /// actor and doubles the retry blast radius when the outer hop fails.
  /// The implementation should mirror `computeConvertedCurrentTotal` and
  /// convert each position directly to `target` in one pass.
  @Test func computeConvertedInvestmentTotalDoesNotDoubleConvert() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let eur = Instrument.fiat(code: "EUR")
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment, instrument: aud)

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    // Two foreign-currency positions in distinct instruments so the
    // repository yields two `Position` entries.
    let txns = [
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: usd,
            quantity: Decimal(100), type: .openingBalance)
        ]),
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: eur,
            quantity: Decimal(50), type: .openingBalance)
        ]),
    ]
    TestBackend.seed(transactions: txns, in: container)

    let counter = CountingConversionService(rates: [
      "USD": Decimal(string: "1.5")!,
      "EUR": Decimal(string: "2.0")!,
    ])
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: counter,
      targetInstrument: aud)
    await store.load()
    // Wait for load's own convertedBalances pass to finish so the counter's
    // baseline is stable before we measure this call.
    await store.waitForPendingConversions()

    let baseline = await counter.convertAmountCallCount
    let total = try await store.computeConvertedInvestmentTotal(in: aud)
    let delta = await counter.convertAmountCallCount - baseline

    // 100 USD * 1.5 + 50 EUR * 2.0 = 150 + 100 = 250 AUD.
    #expect(total == InstrumentAmount(quantity: Decimal(250), instrument: aud))
    // One conversion per position (USD→AUD, EUR→AUD). The old implementation
    // made 3 calls: 2 per-position (→ account.instrument AUD) plus 1 outer
    // (accountBalance → target). New: 2 calls.
    #expect(delta == 2)
  }
}

@MainActor
private func waitForCondition(
  timeout: Duration,
  _ predicate: @MainActor () -> Bool
) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if predicate() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for condition")
}
