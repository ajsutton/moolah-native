import Foundation
import Testing

@testable import Moolah

@Suite("BalanceDeltaCalculator Edge Case Tests")
struct BalanceDeltaCalculatorEdgeCaseTests {

  private let fixtures = BalanceDeltaCalculatorTestFixtures()

  // MARK: - Both nil

  @Test("Both nil returns empty")
  func bothNilReturnsEmpty() {
    let result = BalanceDeltaCalculator.deltas(old: nil, new: nil)
    #expect(result == .empty)
    #expect(result.isEmpty)
  }

  // MARK: - Edge Cases

  @Test("Leg with no accountId or earmarkId produces no delta")
  func legWithNoIds() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: nil, instrument: fixtures.aud, quantity: -50, type: .expense)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.isEmpty)
  }

  @Test("Same transaction unchanged produces empty delta")
  func sameTransactionUnchanged() {
    let txId = UUID()
    let txn = fixtures.transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: txn, new: txn)
    #expect(result.isEmpty)
  }

  @Test("Empty delta isEmpty is true")
  func emptyDeltaIsEmpty() {
    #expect(BalanceDelta.empty.isEmpty)
  }

  @Test("Non-empty delta isEmpty is false")
  func nonEmptyDeltaNotEmpty() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(!result.isEmpty)
  }

  // MARK: - Complex Scenarios

  @Test("Update expense amount with earmark updates both account and earmark deltas")
  func updateExpenseAmountWithEarmark() {
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
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -80, type: .expense,
          earmarkId: fixtures.earmarkA)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == -30)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == -30)
    // Spent: old reversed (-50), new applied (+80), net: +30
    #expect(result.earmarkSpentDeltas[fixtures.earmarkA]?[fixtures.aud] == 30)
  }

  @Test("Multi-leg transfer with earmark on one leg")
  func multiLegTransferWithEarmarkOnOneLeg() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -200, type: .transfer,
        earmarkId: fixtures.earmarkA),
      TransactionLeg(
        accountId: fixtures.accountB, instrument: fixtures.aud, quantity: 200, type: .transfer),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == -200)
    #expect(result.accountDeltas[fixtures.accountB]?[fixtures.aud] == 200)
    #expect(result.earmarkDeltas[fixtures.earmarkA]?[fixtures.aud] == -200)
    #expect(result.earmarkSpentDeltas[fixtures.earmarkA]?[fixtures.aud] == 200)
    // No earmark on accountB leg
    #expect(result.earmarkDeltas[fixtures.accountB] == nil)
  }
}
