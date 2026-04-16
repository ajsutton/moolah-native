import Foundation
import Testing

@testable import Moolah

@Suite("BalanceDeltaCalculator Tests")
struct BalanceDeltaCalculatorTests {

  // MARK: - Test Helpers

  private let accountA = UUID()
  private let accountB = UUID()
  private let earmarkA = UUID()
  private let earmarkB = UUID()
  private let aud = Instrument.AUD
  private let usd = Instrument.USD
  private let date = Date()

  private func transaction(
    id: UUID = UUID(),
    recurPeriod: RecurPeriod? = nil,
    recurEvery: Int? = nil,
    legs: [TransactionLeg]
  ) -> Transaction {
    Transaction(
      id: id, date: date, recurPeriod: recurPeriod, recurEvery: recurEvery, legs: legs)
  }

  private func transaction(
    id: UUID = UUID(),
    scheduled: Bool,
    legs: [TransactionLeg]
  ) -> Transaction {
    Transaction(
      id: id, date: date,
      recurPeriod: scheduled ? .month : nil,
      recurEvery: scheduled ? 1 : nil,
      legs: legs)
  }

  // MARK: - Both nil

  @Test("Both nil returns empty")
  func bothNilReturnsEmpty() {
    let result = BalanceDeltaCalculator.deltas(old: nil, new: nil)
    #expect(result == .empty)
    #expect(result.isEmpty)
  }

  // MARK: - Account Deltas

  @Test("Create expense produces negative account delta")
  func createExpenseNegativeAccountDelta() {
    let tx = transaction(legs: [
      TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.accountDeltas[accountA]?[aud] == -50)
  }

  @Test("Create income produces positive account delta")
  func createIncomePositiveAccountDelta() {
    let tx = transaction(legs: [
      TransactionLeg(accountId: accountA, instrument: aud, quantity: 100, type: .income)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.accountDeltas[accountA]?[aud] == 100)
  }

  @Test("Delete transaction reverses delta")
  func deleteReverseDelta() {
    let tx = transaction(legs: [
      TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
    ])
    let result = BalanceDeltaCalculator.deltas(old: tx, new: nil)
    #expect(result.accountDeltas[accountA]?[aud] == 50)
  }

  @Test("Update amount produces difference")
  func updateAmountDifference() {
    let txId = UUID()
    let oldTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
      ])
    let newTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -80, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    // Old reversed: +50, new applied: -80, net: -30
    #expect(result.accountDeltas[accountA]?[aud] == -30)
  }

  @Test("Update account moves balance between accounts")
  func updateAccountMovesBalance() {
    let txId = UUID()
    let oldTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
      ])
    let newTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(accountId: accountB, instrument: aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(result.accountDeltas[accountA]?[aud] == 50)
    #expect(result.accountDeltas[accountB]?[aud] == -50)
  }

  @Test("Transfer affects both accounts")
  func transferAffectsBothAccounts() {
    let tx = transaction(legs: [
      TransactionLeg(accountId: accountA, instrument: aud, quantity: -200, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: aud, quantity: 200, type: .transfer),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.accountDeltas[accountA]?[aud] == -200)
    #expect(result.accountDeltas[accountB]?[aud] == 200)
  }

  @Test("Multi-instrument legs produce separate deltas per instrument")
  func multiInstrumentSeparateDeltas() {
    let tx = transaction(legs: [
      TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense),
      TransactionLeg(accountId: accountA, instrument: usd, quantity: -30, type: .expense),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.accountDeltas[accountA]?[aud] == -50)
    #expect(result.accountDeltas[accountA]?[usd] == -30)
  }

  @Test("Three-kind transaction tracks fiat, stock, and crypto deltas separately")
  func threeKindTransactionSeparateDeltas() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    // Single transaction spanning three instrument kinds.
    let tx = transaction(legs: [
      TransactionLeg(accountId: accountA, instrument: aud, quantity: -1000, type: .transfer),
      TransactionLeg(accountId: accountA, instrument: bhp, quantity: 100, type: .transfer),
      TransactionLeg(
        accountId: accountA, instrument: eth,
        quantity: Decimal(string: "-0.005")!, type: .expense),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.accountDeltas[accountA]?[aud] == -1000)
    #expect(result.accountDeltas[accountA]?[bhp] == 100)
    #expect(result.accountDeltas[accountA]?[eth] == Decimal(string: "-0.005")!)
  }

  @Test("Cross-currency transfer produces deltas in different instruments on different accounts")
  func crossCurrencyTransferDeltasAcrossAccounts() {
    let tx = transaction(legs: [
      TransactionLeg(accountId: accountA, instrument: aud, quantity: -1000, type: .transfer),
      TransactionLeg(accountId: accountB, instrument: usd, quantity: 650, type: .transfer),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.accountDeltas[accountA]?[aud] == -1000)
    #expect(result.accountDeltas[accountB]?[usd] == 650)
    #expect(result.accountDeltas[accountA]?[usd] == nil)
    #expect(result.accountDeltas[accountB]?[aud] == nil)
  }

  @Test("Updating leg instrument reverses old instrument and applies new instrument")
  func updateChangesInstrument() {
    let txId = UUID()
    let oldTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
      ])
    let newTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(accountId: accountA, instrument: usd, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(result.accountDeltas[accountA]?[aud] == 50)
    #expect(result.accountDeltas[accountA]?[usd] == -50)
  }

  // MARK: - Earmark Deltas

  @Test("Expense with earmark produces earmark delta and spent delta")
  func expenseWithEarmark() {
    let tx = transaction(legs: [
      TransactionLeg(
        accountId: accountA, instrument: aud, quantity: -50, type: .expense,
        earmarkId: earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == -50)
    #expect(result.earmarkSpentDeltas[earmarkA]?[aud] == 50)
    #expect(result.earmarkSavedDeltas.isEmpty)
  }

  @Test("Income with earmark produces earmark delta and saved delta")
  func incomeWithEarmark() {
    let tx = transaction(legs: [
      TransactionLeg(
        accountId: accountA, instrument: aud, quantity: 100, type: .income,
        earmarkId: earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == 100)
    #expect(result.earmarkSavedDeltas[earmarkA]?[aud] == 100)
    #expect(result.earmarkSpentDeltas.isEmpty)
  }

  @Test("Transfer with earmark produces earmark delta and spent delta")
  func transferWithEarmark() {
    let tx = transaction(legs: [
      TransactionLeg(
        accountId: accountA, instrument: aud, quantity: -200, type: .transfer,
        earmarkId: earmarkA),
      TransactionLeg(accountId: accountB, instrument: aud, quantity: 200, type: .transfer),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == -200)
    #expect(result.earmarkSpentDeltas[earmarkA]?[aud] == 200)
  }

  @Test("Opening balance with earmark produces earmark delta and saved delta")
  func openingBalanceWithEarmark() {
    let tx = transaction(legs: [
      TransactionLeg(
        accountId: accountA, instrument: aud, quantity: 500, type: .openingBalance,
        earmarkId: earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == 500)
    #expect(result.earmarkSavedDeltas[earmarkA]?[aud] == 500)
    #expect(result.earmarkSpentDeltas.isEmpty)
  }

  @Test("Earmark-only transaction (no accountId) produces only earmark deltas")
  func earmarkOnlyNoAccountDeltas() {
    let tx = transaction(legs: [
      TransactionLeg(
        accountId: nil, instrument: aud, quantity: 100, type: .income, earmarkId: earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.accountDeltas.isEmpty)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == 100)
    #expect(result.earmarkSavedDeltas[earmarkA]?[aud] == 100)
  }

  @Test("Change earmark moves between earmarks")
  func changeEarmarkMovesBetween() {
    let txId = UUID()
    let oldTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: aud, quantity: -50, type: .expense,
          earmarkId: earmarkA)
      ])
    let newTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: aud, quantity: -50, type: .expense,
          earmarkId: earmarkB)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == 50)
    #expect(result.earmarkDeltas[earmarkB]?[aud] == -50)
    #expect(result.earmarkSpentDeltas[earmarkA]?[aud] == -50)
    #expect(result.earmarkSpentDeltas[earmarkB]?[aud] == 50)
    // Account delta should be zero (same account, same amount) so cleaned up
    #expect(result.accountDeltas.isEmpty)
  }

  @Test("Multi-instrument earmark produces separate deltas per instrument")
  func multiInstrumentEarmark() {
    let tx = transaction(legs: [
      TransactionLeg(
        accountId: accountA, instrument: aud, quantity: 100, type: .income,
        earmarkId: earmarkA),
      TransactionLeg(
        accountId: accountA, instrument: usd, quantity: 50, type: .income,
        earmarkId: earmarkA),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == 100)
    #expect(result.earmarkDeltas[earmarkA]?[usd] == 50)
    #expect(result.earmarkSavedDeltas[earmarkA]?[aud] == 100)
    #expect(result.earmarkSavedDeltas[earmarkA]?[usd] == 50)
  }

  // MARK: - Saved/Spent Reversal

  @Test("Delete income reverses saved delta")
  func deleteIncomeReversesSaved() {
    let tx = transaction(legs: [
      TransactionLeg(
        accountId: accountA, instrument: aud, quantity: 100, type: .income,
        earmarkId: earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: tx, new: nil)
    #expect(result.earmarkSavedDeltas[earmarkA]?[aud] == -100)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == -100)
  }

  @Test("Delete expense reverses spent delta")
  func deleteExpenseReversesSpent() {
    let tx = transaction(legs: [
      TransactionLeg(
        accountId: accountA, instrument: aud, quantity: -50, type: .expense,
        earmarkId: earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: tx, new: nil)
    #expect(result.earmarkSpentDeltas[earmarkA]?[aud] == -50)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == 50)
  }

  // MARK: - Scheduled Transactions

  @Test("Scheduled transaction returns empty delta")
  func scheduledTransactionEmpty() {
    let tx = transaction(
      scheduled: true,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.isEmpty)
  }

  @Test("Scheduled old, non-scheduled new applies only new")
  func scheduledOldNonScheduledNew() {
    let txId = UUID()
    let oldTx = transaction(
      id: txId,
      scheduled: true,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
      ])
    let newTx = transaction(
      id: txId,
      scheduled: false,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    // Old is scheduled so skipped, only new applied
    #expect(result.accountDeltas[accountA]?[aud] == -50)
  }

  @Test("Non-scheduled old, scheduled new reverses only old")
  func nonScheduledOldScheduledNew() {
    let txId = UUID()
    let oldTx = transaction(
      id: txId,
      scheduled: false,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
      ])
    let newTx = transaction(
      id: txId,
      scheduled: true,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    // New is scheduled so skipped, old is reversed
    #expect(result.accountDeltas[accountA]?[aud] == 50)
  }

  // MARK: - Edge Cases

  @Test("Leg with no accountId or earmarkId produces no delta")
  func legWithNoIds() {
    let tx = transaction(legs: [
      TransactionLeg(accountId: nil, instrument: aud, quantity: -50, type: .expense)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.isEmpty)
  }

  @Test("Same transaction unchanged produces empty delta")
  func sameTransactionUnchanged() {
    let txId = UUID()
    let tx = transaction(
      id: txId,
      legs: [
        TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: tx, new: tx)
    #expect(result.isEmpty)
  }

  @Test("Empty delta isEmpty is true")
  func emptyDeltaIsEmpty() {
    #expect(BalanceDelta.empty.isEmpty)
  }

  @Test("Non-empty delta isEmpty is false")
  func nonEmptyDeltaNotEmpty() {
    let tx = transaction(legs: [
      TransactionLeg(accountId: accountA, instrument: aud, quantity: -50, type: .expense)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(!result.isEmpty)
  }

  // MARK: - Complex Scenarios

  @Test("Update expense amount with earmark updates both account and earmark deltas")
  func updateExpenseAmountWithEarmark() {
    let txId = UUID()
    let oldTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: aud, quantity: -50, type: .expense,
          earmarkId: earmarkA)
      ])
    let newTx = transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: aud, quantity: -80, type: .expense,
          earmarkId: earmarkA)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(result.accountDeltas[accountA]?[aud] == -30)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == -30)
    // Spent: old reversed (-50), new applied (+80), net: +30
    #expect(result.earmarkSpentDeltas[earmarkA]?[aud] == 30)
  }

  @Test("Multi-leg transfer with earmark on one leg")
  func multiLegTransferWithEarmarkOnOneLeg() {
    let tx = transaction(legs: [
      TransactionLeg(
        accountId: accountA, instrument: aud, quantity: -200, type: .transfer,
        earmarkId: earmarkA),
      TransactionLeg(accountId: accountB, instrument: aud, quantity: 200, type: .transfer),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: tx)
    #expect(result.accountDeltas[accountA]?[aud] == -200)
    #expect(result.accountDeltas[accountB]?[aud] == 200)
    #expect(result.earmarkDeltas[earmarkA]?[aud] == -200)
    #expect(result.earmarkSpentDeltas[earmarkA]?[aud] == 200)
    // No earmark on accountB leg
    #expect(result.earmarkDeltas[accountB] == nil)
  }
}
