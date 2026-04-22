import Foundation
import Testing

@testable import Moolah

@Suite("BalanceDeltaCalculator Account Delta Tests")
struct BalanceDeltaCalculatorAccountTests {

  private let fixtures = BalanceDeltaCalculatorTestFixtures()

  @Test("Create expense produces negative account delta")
  func createExpenseNegativeAccountDelta() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == -50)
  }

  @Test("Create income produces positive account delta")
  func createIncomePositiveAccountDelta() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: 100, type: .income)
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == 100)
  }

  @Test("Delete transaction reverses delta")
  func deleteReverseDelta() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
    ])
    let result = BalanceDeltaCalculator.deltas(old: txn, new: nil)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == 50)
  }

  @Test("Update amount produces difference")
  func updateAmountDifference() {
    let txId = UUID()
    let oldTx = fixtures.transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let newTx = fixtures.transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -80, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    // Old reversed: +50, new applied: -80, net: -30
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == -30)
  }

  @Test("Update account moves balance between accounts")
  func updateAccountMovesBalance() {
    let txId = UUID()
    let oldTx = fixtures.transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let newTx = fixtures.transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountB, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == 50)
    #expect(result.accountDeltas[fixtures.accountB]?[fixtures.aud] == -50)
  }

  @Test("Transfer affects both accounts")
  func transferAffectsBothAccounts() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -200, type: .transfer),
      TransactionLeg(
        accountId: fixtures.accountB, instrument: fixtures.aud, quantity: 200, type: .transfer),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == -200)
    #expect(result.accountDeltas[fixtures.accountB]?[fixtures.aud] == 200)
  }

  @Test("Multi-instrument legs produce separate deltas per instrument")
  func multiInstrumentSeparateDeltas() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense),
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.usd, quantity: -30, type: .expense),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == -50)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.usd] == -30)
  }

  @Test("Three-kind transaction tracks fiat, stock, and crypto deltas separately")
  func threeKindTransactionSeparateDeltas() throws {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
    )
    let ethQuantity = try #require(Decimal(string: "-0.005"))
    // Single transaction spanning three instrument kinds.
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -1000, type: .transfer),
      TransactionLeg(
        accountId: fixtures.accountA, instrument: bhp, quantity: 100, type: .transfer),
      TransactionLeg(
        accountId: fixtures.accountA, instrument: eth,
        quantity: ethQuantity, type: .expense),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == -1000)
    #expect(result.accountDeltas[fixtures.accountA]?[bhp] == 100)
    #expect(result.accountDeltas[fixtures.accountA]?[eth] == ethQuantity)
  }

  @Test("Cross-currency transfer produces deltas in different instruments on different accounts")
  func crossCurrencyTransferDeltasAcrossAccounts() {
    let txn = fixtures.transaction(legs: [
      TransactionLeg(
        accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -1000, type: .transfer),
      TransactionLeg(
        accountId: fixtures.accountB, instrument: fixtures.usd, quantity: 650, type: .transfer),
    ])
    let result = BalanceDeltaCalculator.deltas(old: nil, new: txn)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == -1000)
    #expect(result.accountDeltas[fixtures.accountB]?[fixtures.usd] == 650)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.usd] == nil)
    #expect(result.accountDeltas[fixtures.accountB]?[fixtures.aud] == nil)
  }

  @Test("Updating leg instrument reverses old instrument and applies new instrument")
  func updateChangesInstrument() {
    let txId = UUID()
    let oldTx = fixtures.transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.aud, quantity: -50, type: .expense)
      ])
    let newTx = fixtures.transaction(
      id: txId,
      legs: [
        TransactionLeg(
          accountId: fixtures.accountA, instrument: fixtures.usd, quantity: -50, type: .expense)
      ])
    let result = BalanceDeltaCalculator.deltas(old: oldTx, new: newTx)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.aud] == 50)
    #expect(result.accountDeltas[fixtures.accountA]?[fixtures.usd] == -50)
  }
}
