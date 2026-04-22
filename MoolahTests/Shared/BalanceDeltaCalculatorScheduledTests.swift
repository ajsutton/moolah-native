import Foundation
import Testing

@testable import Moolah

@Suite("BalanceDeltaCalculator Scheduled Transaction Tests")
struct BalanceDeltaCalculatorScheduledTests {

  private let fixtures = BalanceDeltaCalculatorTestFixtures()

  @Test("Scheduled transaction returns empty delta")
  func scheduledTransactionEmpty() {
    let txn = fixtures.transaction(
      scheduled: true,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.isEmpty)
  }

  @Test("Scheduled old, non-scheduled new applies only new")
  func scheduledOldNonScheduledNew() {
    let txId = UUID()
    let oldTx = fixtures.transaction(
      id: txId,
      scheduled: true,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let newTx = fixtures.transaction(
      id: txId,
      scheduled: false,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    // Old is scheduled so skipped, only new applied
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == -50)
  }

  @Test("Non-scheduled old, scheduled new reverses only old")
  func nonScheduledOldScheduledNew() {
    let txId = UUID()
    let oldTx = fixtures.transaction(
      id: txId,
      scheduled: false,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let newTx = fixtures.transaction(
      id: txId,
      scheduled: true,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    // New is scheduled so skipped, old is reversed
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == 50)
  }
}
