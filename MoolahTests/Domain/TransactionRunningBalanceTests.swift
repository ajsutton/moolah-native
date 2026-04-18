import Foundation
import Testing

@testable import Moolah

@Suite("TransactionPage.withRunningBalances")
struct TransactionRunningBalanceTests {
  private let target = Instrument.defaultTestInstrument
  private let foreign = Instrument.USD

  private func date(_ days: Int) -> Date {
    Calendar(identifier: .gregorian)
      .date(byAdding: .day, value: days, to: Date(timeIntervalSince1970: 0))!
  }

  private func tx(
    id: UUID = UUID(),
    daysFromEpoch: Int,
    accountId: UUID,
    quantity: Decimal,
    instrument: Instrument
  ) -> Transaction {
    Transaction(
      id: id,
      date: date(daysFromEpoch),
      payee: "Payee",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: instrument,
          quantity: quantity,
          type: .expense
        )
      ]
    )
  }

  /// All legs convert successfully — every transaction gets a valid balance.
  @Test func allLegsConvertibleYieldsBalancesForEveryTransaction() async {
    let accountId = UUID()
    // Target instrument differs from the default test instrument so make sure
    // we're using the ambient default.
    let transactions = [
      tx(daysFromEpoch: 3, accountId: accountId, quantity: -30, instrument: target),
      tx(daysFromEpoch: 2, accountId: accountId, quantity: -20, instrument: target),
      tx(daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: target),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FixedConversionService()
    )

    #expect(response.rows.count == 3)
    #expect(response.rows.allSatisfy { $0.balance != nil })
    #expect(response.rows.allSatisfy { $0.displayAmount != nil })
    // No conversion errors occurred.
    #expect(response.firstConversionError == nil)
  }

  /// A transaction with an unconvertible leg still appears in the result,
  /// but with a nil balance and nil displayAmount.
  @Test func unconvertibleTransactionStillAppearsWithNilBalance() async {
    let accountId = UUID()
    let transactions = [
      tx(daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: foreign)
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FailingConversionService(failingInstrumentIds: [foreign.id])
    )

    #expect(response.rows.count == 1)
    #expect(response.rows[0].transaction.id == transactions[0].id)
    #expect(response.rows[0].balance == nil)
    #expect(response.rows[0].displayAmount == nil)
    // The error is exposed to callers so they can surface a retry path.
    #expect(response.firstConversionError != nil)
  }

  /// Earlier transactions (older — processed first in the reversed iteration)
  /// keep their balances even when a later (newer) transaction can't convert.
  /// Newer transactions after the failure point have nil balances.
  @Test func conversionFailureBreaksBalanceChainForLaterTransactions() async {
    let accountId = UUID()
    // Oldest first in source → in the newest-first returned list this is
    // the last entry. We list newest-first as the function expects.
    let oldestId = UUID()
    let middleId = UUID()
    let newestId = UUID()
    let transactions = [
      // newest — unconvertible
      tx(id: newestId, daysFromEpoch: 3, accountId: accountId, quantity: -30, instrument: foreign),
      // middle — convertible
      tx(id: middleId, daysFromEpoch: 2, accountId: accountId, quantity: -20, instrument: target),
      // oldest — convertible
      tx(id: oldestId, daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: target),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FailingConversionService(failingInstrumentIds: [foreign.id])
    )

    #expect(response.rows.count == 3)
    // Result is newest-first. Oldest two (middle, oldest) keep their balances.
    let byId = Dictionary(uniqueKeysWithValues: response.rows.map { ($0.transaction.id, $0) })
    #expect(byId[oldestId]?.balance != nil)
    #expect(byId[middleId]?.balance != nil)
    // The unconvertible newest transaction has nil balance.
    #expect(byId[newestId]?.balance == nil)
    #expect(byId[newestId]?.displayAmount == nil)
    // Error propagates out even though other rows convert cleanly.
    #expect(response.firstConversionError != nil)
  }

  /// When the FIRST (oldest) transaction can't convert, every subsequent
  /// (newer) transaction has nil balance — the running total is unrecoverable.
  @Test func conversionFailureAtOldestBreaksAllBalances() async {
    let accountId = UUID()
    let oldestId = UUID()
    let middleId = UUID()
    let newestId = UUID()
    let transactions = [
      tx(id: newestId, daysFromEpoch: 3, accountId: accountId, quantity: -30, instrument: target),
      tx(id: middleId, daysFromEpoch: 2, accountId: accountId, quantity: -20, instrument: target),
      tx(id: oldestId, daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: foreign),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FailingConversionService(failingInstrumentIds: [foreign.id])
    )

    #expect(response.rows.count == 3)
    #expect(response.rows.allSatisfy { $0.balance == nil })
    #expect(response.firstConversionError != nil)
  }

  /// Issue #48: conversion failures must be reported to the caller — no more
  /// silent `try?`-style swallow. Captures the first error encountered so a
  /// store can surface it to the user and log/diagnose in production.
  @Test func conversionFailureReportsFirstError() async throws {
    let accountId = UUID()
    // Oldest fails first so it's the "first" error in chronological processing.
    let oldestFailingId = UUID()
    let newerFailingId = UUID()
    let transactions = [
      tx(id: newerFailingId, daysFromEpoch: 3, accountId: accountId,
        quantity: -30, instrument: foreign),
      tx(id: oldestFailingId, daysFromEpoch: 2, accountId: accountId,
        quantity: -20, instrument: foreign),
    ]

    let response = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FailingConversionService(failingInstrumentIds: [foreign.id])
    )

    let error = try #require(response.firstConversionError)
    // Processing iterates oldest-to-newest (reversed), so the first failure
    // recorded is the oldest transaction.
    #expect(error.transactionId == oldestFailingId)
    #expect(error.targetInstrumentId == target.id)
  }
}
