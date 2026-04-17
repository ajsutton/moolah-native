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

    let result = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FixedConversionService()
    )

    #expect(result.count == 3)
    #expect(result.allSatisfy { $0.balance != nil })
    #expect(result.allSatisfy { $0.displayAmount != nil })
  }

  /// A transaction with an unconvertible leg still appears in the result,
  /// but with a nil balance and nil displayAmount.
  @Test func unconvertibleTransactionStillAppearsWithNilBalance() async {
    let accountId = UUID()
    let transactions = [
      tx(daysFromEpoch: 1, accountId: accountId, quantity: -10, instrument: foreign)
    ]

    let result = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FailingConversionService(failingInstrumentIds: [foreign.id])
    )

    #expect(result.count == 1)
    #expect(result[0].transaction.id == transactions[0].id)
    #expect(result[0].balance == nil)
    #expect(result[0].displayAmount == nil)
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

    let result = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FailingConversionService(failingInstrumentIds: [foreign.id])
    )

    #expect(result.count == 3)
    // Result is newest-first. Oldest two (middle, oldest) keep their balances.
    let byId = Dictionary(uniqueKeysWithValues: result.map { ($0.transaction.id, $0) })
    #expect(byId[oldestId]?.balance != nil)
    #expect(byId[middleId]?.balance != nil)
    // The unconvertible newest transaction has nil balance.
    #expect(byId[newestId]?.balance == nil)
    #expect(byId[newestId]?.displayAmount == nil)
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

    let result = await TransactionPage.withRunningBalances(
      transactions: transactions,
      priorBalance: .zero(instrument: target),
      accountId: accountId,
      targetInstrument: target,
      conversionService: FailingConversionService(failingInstrumentIds: [foreign.id])
    )

    #expect(result.count == 3)
    #expect(result.allSatisfy { $0.balance == nil })
  }
}
