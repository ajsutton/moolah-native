import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("AccountStore -- Conversion")
@MainActor
struct AccountStoreConversionTestsMore {
  @Test
  func displayBalanceForInvestmentAccountPrefersInvestmentValue() async throws {
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

  @Test
  func displayBalanceForUnknownAccountReturnsZero() async throws {
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
  @Test
  func perAccountBalancePopulatesEvenWhenAnotherAccountFails() async throws {
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
  @Test
  func conversionFailuresAreRetriedAfterDelay() async throws {
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
}
