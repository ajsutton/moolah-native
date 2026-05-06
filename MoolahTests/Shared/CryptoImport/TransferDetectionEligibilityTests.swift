// MoolahTests/Shared/CryptoImport/TransferDetectionEligibilityTests.swift
import Foundation
import Testing

@testable import Moolah

/// Tests for `Transaction.isTransferDetectionEligible` (Extension A from
/// `plans/2026-04-18-transfer-detection-design.md`). The predicate gates
/// the standard amount/instrument/date suggestion pass; eligible
/// transactions surface their value-bearing leg via
/// `Transaction.transferDetectionValueLeg`.
@Suite("Transaction.isTransferDetectionEligible — Extension A")
struct TransferDetectionEligibilityTests {
  private static let accountId = UUID()
  private static let valueInstrument = ChainConfig.ethereum.nativeInstrument
  // A different instrument so fee legs satisfy the cross-instrument predicate.
  private static let feeInstrument = Instrument.fiat(code: "USD")

  // MARK: - Eligible shapes

  @Test("Single transfer leg is eligible")
  func singleTransferLegEligible() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.valueInstrument,
          quantity: -1, type: .transfer)
      ])
    #expect(transaction.isTransferDetectionEligible)
    #expect(transaction.transferDetectionValueLeg?.type == .transfer)
  }

  @Test("Single income leg is eligible (legacy single-leg cash)")
  func singleIncomeLegEligible() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.valueInstrument,
          quantity: 100, type: .income)
      ])
    #expect(transaction.isTransferDetectionEligible)
    #expect(transaction.transferDetectionValueLeg?.type == .income)
  }

  @Test("Transfer leg + cross-instrument expense fee leg is eligible")
  func transferWithFeeLegEligible() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.valueInstrument,
          quantity: -1, type: .transfer),
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.feeInstrument,
          quantity: -2, type: .expense),
      ])
    #expect(transaction.isTransferDetectionEligible)
    let valueLeg = transaction.transferDetectionValueLeg
    #expect(valueLeg?.type == .transfer)
    #expect(valueLeg?.instrument == Self.valueInstrument)
  }

  // MARK: - Ineligible shapes

  @Test("Two trade legs (trade) is ineligible")
  func twoTradeLegsIneligible() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.valueInstrument,
          quantity: -1, type: .trade),
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.feeInstrument,
          quantity: 1000, type: .trade),
      ])
    #expect(!transaction.isTransferDetectionEligible)
    #expect(transaction.transferDetectionValueLeg == nil)
  }

  @Test("Two transfer legs (already-merged transfer) is ineligible")
  func twoTransferLegsIneligible() {
    let other = UUID()
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.valueInstrument,
          quantity: -1, type: .transfer),
        TransactionLeg(
          accountId: other, instrument: Self.valueInstrument,
          quantity: 1, type: .transfer),
      ])
    #expect(!transaction.isTransferDetectionEligible)
  }

  @Test("Transfer leg + same-instrument extra leg is ineligible (fee predicate fails)")
  func transferWithSameInstrumentExtraLegIneligible() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.valueInstrument,
          quantity: -1, type: .transfer),
        // Same instrument as the value leg → not a fee leg.
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.valueInstrument,
          quantity: -2, type: .expense),
      ])
    #expect(!transaction.isTransferDetectionEligible)
  }

  @Test("Opening balance is ineligible")
  func openingBalanceIneligible() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: Self.accountId, instrument: Self.valueInstrument,
          quantity: 100, type: .openingBalance)
      ])
    #expect(!transaction.isTransferDetectionEligible)
  }
}
