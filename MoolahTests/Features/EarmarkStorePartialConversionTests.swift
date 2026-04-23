import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- Partial Conversion Failures")
@MainActor
struct EarmarkStorePartialConversionTests {

  /// When one earmark's positions can't be converted to its own instrument,
  /// other earmarks whose conversions succeed still appear in
  /// `convertedBalances`. The aggregate `convertedTotalBalance` stays nil
  /// because we cannot accurately sum a set with a missing value.
  @Test
  func earmarkBalancePopulatesEvenWhenAnotherFails() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let eur = Instrument.fiat(code: "EUR")
    let accountId = UUID()
    let healthyEarmark = Earmark(name: "Holiday", instrument: aud)
    let mixedEarmark = Earmark(name: "Mixed", instrument: eur)

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank, instrument: aud)],
      in: container)
    TestBackend.seed(earmarks: [healthyEarmark, mixedEarmark], in: container)

    // Healthy earmark: AUD positions only.
    let healthyTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: Decimal(300),
          type: .income, earmarkId: healthyEarmark.id)
      ])
    // Mixed earmark: EUR + USD; USD → EUR conversion will fail.
    let mixedEurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eur, quantity: Decimal(100),
          type: .income, earmarkId: mixedEarmark.id)
      ])
    let mixedUsdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: Decimal(50),
          type: .income, earmarkId: mixedEarmark.id)
      ])
    TestBackend.seed(transactions: [healthyTx, mixedEurTx, mixedUsdTx], in: container)

    let conversion = FailingConversionService(failingInstrumentIds: ["USD"])
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .seconds(60))

    // `load()` awaits the first conversion pass inline, so after it returns
    // the partial-failure state is published deterministically — no polling.
    await store.load()

    #expect(store.convertedBalance(for: healthyEarmark.id)?.quantity == 300)
    #expect(store.convertedBalance(for: mixedEarmark.id) == nil)
    #expect(store.convertedTotalBalance == nil)
  }

  /// After conversion service recovers, retry populates the previously
  /// failing earmark balance and the aggregate total.
  @Test
  func conversionFailuresAreRetriedAfterDelay() async throws {
    let aud = Instrument.AUD
    let eur = Instrument.fiat(code: "EUR")
    let accountId = UUID()
    let audEarmark = Earmark(name: "AUD", instrument: aud)
    let eurEarmark = Earmark(name: "EUR", instrument: eur)

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank, instrument: aud)],
      in: container)
    TestBackend.seed(earmarks: [audEarmark, eurEarmark], in: container)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: Decimal(400),
          type: .income, earmarkId: audEarmark.id)
      ])
    let eurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eur, quantity: Decimal(200),
          type: .income, earmarkId: eurEarmark.id)
      ])
    TestBackend.seed(transactions: [audTx, eurTx], in: container)

    let conversion = FailingConversionService(failingInstrumentIds: ["EUR"])
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .milliseconds(20))

    // `load()` awaits the first pass; since EUR fails we land in the
    // partial-failure state with a retry loop running in the background.
    await store.load()

    // Aggregate cannot be computed (EUR → AUD fails). Per-earmark balances
    // are still displayed in their own currency where no conversion is
    // needed.
    #expect(store.convertedTotalBalance == nil)

    // Recover the conversion service and wait for the retry loop to
    // succeed — `waitForPendingConversions()` returns when the loop
    // terminates on the first successful attempt.
    await conversion.setFailing([])
    await store.waitForPendingConversions()

    // 400 AUD + 200 EUR (1:1 fallback) = 600 AUD
    #expect(store.convertedTotalBalance?.quantity == 600)
    #expect(store.convertedBalance(for: audEarmark.id)?.quantity == 400)
    #expect(store.convertedBalance(for: eurEarmark.id)?.quantity == 200)
  }
}
