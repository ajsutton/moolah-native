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
    await store.updateInvestmentValue(accountId: accountId, value: externalValue)
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

    // `load()` awaits the first conversion pass inline, so after it returns
    // `convertedBalances` reflects the partial-failure state deterministically
    // — no polling or timeouts needed.
    await store.load()

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

    // `load()` awaits the first pass; since EUR fails we land in the
    // partial-failure state with a retry loop running in the background.
    await store.load()

    // Initial state: EUR bank can't be converted to AUD aggregate target → aggregate nil.
    #expect(store.convertedCurrentTotal == nil)

    // Recover the conversion service and wait for the background retry
    // loop to succeed. `waitForPendingConversions()` returns when the loop
    // terminates, which happens on the first successful attempt.
    await conversion.setFailing([])
    await store.waitForPendingConversions()

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
    // `load()` awaits the first conversion pass, so the counter baseline
    // is stable before we measure this call.
    await store.load()

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

  // MARK: - computeConvertedInvestmentTotal single-pass conversion

  /// Issue #96: `computeConvertedInvestmentTotal` previously routed positions
  /// through two conversions — positions → account instrument → target. For
  /// asymmetric rates (which all real-world rates are), chaining conversions
  /// compounds rounding error and produces a different result than summing
  /// positions directly to `target`. This test uses an asymmetric rate table
  /// where double-conversion and single-pass conversion produce distinct
  /// numerical answers and asserts the single-pass answer is returned.
  @Test func computeConvertedInvestmentTotalSumsPositionsDirectlyToTarget()
    async throws
  {
    let accountId = UUID()
    // Investment account held in AUD; target is USD. Asymmetric rates:
    //   USD -> USD (fast path, 1:1)
    //   AUD -> USD = 0.67
    // With double-conversion:
    //   displayBalance(AUD):  100 USD -> AUD at 1.5 = 150 AUD; + 1000 AUD = 1150 AUD
    //   convert 1150 AUD -> USD at 0.67 = 770.50 USD
    // With single-pass:
    //   100 USD -> USD (fast path) = 100 USD
    //   1000 AUD -> USD at 0.67 = 670 USD
    //   total = 770 USD
    // The 0.50 difference is the double-conversion drift.
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment, instrument: .AUD)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: Decimal(string: "1000.00")!, type: .openingBalance)
      ])
    let usdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .USD,
          quantity: Decimal(string: "100.00")!, type: .openingBalance)
      ])
    TestBackend.seed(transactions: [audTx, usdTx], in: container)

    let conversion = FixedConversionService(rates: [
      "AUD": Decimal(string: "0.67")!,
      "USD": Decimal(string: "1.5")!,
    ])
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: conversion,
      targetInstrument: .USD)
    await store.load()

    let total = try await store.computeConvertedInvestmentTotal(in: .USD)
    #expect(total.instrument == .USD)
    // Single-pass: 100 USD + (1000 AUD * 0.67) = 100 + 670 = 770 USD
    #expect(total.quantity == Decimal(string: "770.00")!)
  }

  /// When an investment account has an externally-supplied value (e.g. from
  /// `InvestmentStore.valuatePositions`), `computeConvertedInvestmentTotal`
  /// must use that value verbatim and convert it *once* to the target —
  /// never re-sum the raw positions, and never double-convert.
  @Test func computeConvertedInvestmentTotalUsesExternalValueWhenProvided()
    async throws
  {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Brokerage", type: .investment, instrument: .AUD)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    // Seed raw positions that would produce a different total than the
    // external value — this makes it provable the external value is used.
    let rawTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: Decimal(string: "100.00")!, type: .openingBalance)
      ])
    TestBackend.seed(transactions: [rawTx], in: container)

    let conversion = FixedConversionService(rates: [
      "AUD": Decimal(string: "0.5")!
    ])
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: conversion,
      targetInstrument: .USD)
    await store.load()

    // External valuation in AUD (e.g. latest InvestmentValue): 2000 AUD.
    let externalValue = InstrumentAmount(
      quantity: Decimal(string: "2000.00")!, instrument: .AUD)
    await store.updateInvestmentValue(accountId: accountId, value: externalValue)

    let total = try await store.computeConvertedInvestmentTotal(in: .USD)
    // 2000 AUD -> USD at 0.5 = 1000 USD (external value converted once)
    #expect(total.instrument == .USD)
    #expect(total.quantity == Decimal(string: "1000.00")!)
  }

  /// Same-instrument positions and target must hit the fast path without
  /// stacking spurious conversions. For a profile where account instrument,
  /// positions, and target all share a currency, the result equals the raw
  /// position sum.
  @Test func computeConvertedInvestmentTotalFastPathSameInstrument()
    async throws
  {
    let accountId = UUID()
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment,
      instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: container)

    let tx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: Decimal(string: "1234.56")!, type: .openingBalance)
      ])
    TestBackend.seed(transactions: [tx], in: container)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    await store.load()

    let total = try await store.computeConvertedInvestmentTotal(
      in: .defaultTestInstrument)
    #expect(total.instrument == .defaultTestInstrument)
    #expect(total.quantity == Decimal(string: "1234.56")!)
  }
}
