import Foundation
import Testing

@testable import Moolah

@Suite("BalanceDeltaCalculator Earmark Delta Tests")
struct BalanceDeltaCalculatorEarmarkTests {

  private let fixtures = BalanceDeltaCalculatorTestFixtures()

  // MARK: - Earmark Deltas

  @Test("Expense with earmark produces earmark delta and spent delta")
  func expenseWithEarmark() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense,
        earmarkId: fixtures.earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == -50)
    #expect(result.earmarkSpentDeltas[fixtures.earmarkA]?[fixtures.aud] == 50)
    #expect(result.earmarkSavedDeltas.isEmpty)
  }

  @Test("Income with earmark produces earmark delta and saved delta")
  func incomeWithEarmark() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: 100, type: .income,
        earmarkId: fixtures.earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == 100)
    #expect(result.earmarkSavedDeltas[fixtures.earmarkA]?[fixtures.aud] == 100)
    #expect(result.earmarkSpentDeltas.isEmpty)
  }

  @Test("Transfer with earmark produces earmark delta and spent delta")
  func transferWithEarmark() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -200, type: .transfer,
        earmarkId: fixtures.earmarkA),
      TransactionLeg(
        accountId: fixtures.accountB, instrument: fixtures.aud, quantity: 200, type: .transfer),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == -200)
    #expect(result.earmarkSpentDeltas[fixtures.earmarkA]?[fixtures.aud] == 200)
  }

  @Test("Opening balance with earmark produces earmark delta and saved delta")
  func openingBalanceWithEarmark() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: 500,
        type: .openingBalance,
        earmarkId: fixtures.earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == 500)
    #expect(result.earmarkSavedDeltas[fixtures.earmarkA]?[fixtures.aud] == 500)
    #expect(result.earmarkSpentDeltas.isEmpty)
  }

  @Test("Earmark-only transaction (no accountId) produces only earmark deltas")
  func earmarkOnlyNoAccountDeltas() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: nil, instrument: fixtures.aud, quantity: 100, type: .income,
        earmarkId: fixtures.earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.accountDeltas.isEmpty)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == 100)
    #expect(result.earmarkSavedDeltas[fixtures.earmarkA]?[fixtures.aud] == 100)
  }

  @Test("Change earmark moves between earmarks")
  func changeEarmarkMovesBetween() {
    let txId = UUID()
    let oldTx = fixtures.transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense,
          earmarkId: fixtures.earmarkA)
      ])
    let newTx = fixtures.transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense,
          earmarkId: fixtures.earmarkB)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == 50)
    #expect(result.earmarkDeltas[fixtures.earmarkB]?[fixtures.aud] == -50)
    #expect(result.earmarkSpentDeltas[fixtures.earmarkA]?[fixtures.aud] == -50)
    #expect(result.earmarkSpentDeltas[fixtures.earmarkB]?[fixtures.aud] == 50)
    // Account delta should be zero (same account, same amount) so cleaned up
    #expect(result.accountDeltas.isEmpty)
  }

  @Test("Multi-instrument earmark produces separate deltas per instrument")
  func multiInstrumentEarmark() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: 100, type: .income,
        earmarkId: fixtures.earmarkA),
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.usd, quantity: 50, type: .income,
        earmarkId: fixtures.earmarkA),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == 100)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.usd] == 50)
    #expect(result.earmarkSavedDeltas[fixtures.earmarkA]?[fixtures.aud] == 100)
    #expect(result.earmarkSavedDeltas[fixtures.earmarkA]?[fixtures.usd] == 50)
  }

  // MARK: - Saved/Spent Reversal

  @Test("Delete income reverses saved delta")
  func deleteIncomeReversesSaved() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: 100, type: .income,
        earmarkId: fixtures.earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: txn, new: nil)
    #expect(result.earmarkSavedDeltas[fixtures.earmarkA]?[fixtures.aud] == -100)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == -100)
  }

  @Test("Delete expense reverses spent delta")
  func deleteExpenseReversesSpent() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense,
        earmarkId: fixtures.earmarkA)
    ])
    let result = BalanceDeltaCalculator.deltas(old: txn, new: nil)
    #expect(result.earmarkSpentDeltas[fixtures.earmarkA]?[fixtures.aud] == -50)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == 50)
  }
}
