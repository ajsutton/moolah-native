import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.isSimple")
struct TransactionIsSimpleTests {
  let aud = Instrument.defaultTestInstrument

  func makeLeg(
    accountId: UUID = UUID(),
    quantity: Decimal,
    type: TransactionType = .expense,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId,
      instrument: aud,
      quantity: quantity,
      type: type,
      categoryId: categoryId,
      earmarkId: earmarkId
    )
  }

  func makeTransaction(legs: [TransactionLeg]) -> Transaction {
    Transaction(date: Date(), legs: legs)
  }

  // MARK: - Simple cases

  @Test("Single leg is simple")
  func singleLegIsSimple() {
    let tx = makeTransaction(legs: [makeLeg(quantity: -50)])
    #expect(tx.isSimple == true)
  }

  @Test("Empty legs is simple")
  func emptyLegsIsSimple() {
    let tx = makeTransaction(legs: [])
    #expect(tx.isSimple == true)
  }

  @Test("Two-leg transfer with negated amounts and nil optional fields is simple")
  func twoLegTransferNilFieldsIsSimple() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -100, type: .transfer),
      makeLeg(quantity: 100, type: .transfer),
    ])
    #expect(tx.isSimple == true)
  }

  @Test("Category on first leg only is simple")
  func isSimpleAllowsCategoryOnFirstLegOnly() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -100, type: .transfer, categoryId: UUID()),
      makeLeg(quantity: 100, type: .transfer),
    ])
    #expect(tx.isSimple == true)
  }

  @Test("Earmark on first leg only is simple")
  func isSimpleAllowsEarmarkOnFirstLegOnly() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -100, type: .transfer, earmarkId: UUID()),
      makeLeg(quantity: 100, type: .transfer),
    ])
    #expect(tx.isSimple == true)
  }

  // MARK: - Non-simple cases

  @Test("Category on second leg is NOT simple")
  func isSimpleRejectsCategoryOnSecondLeg() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -100, type: .transfer),
      makeLeg(quantity: 100, type: .transfer, categoryId: UUID()),
    ])
    #expect(tx.isSimple == false)
  }

  @Test("Earmark on second leg is NOT simple")
  func isSimpleRejectsEarmarkOnSecondLeg() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -100, type: .transfer),
      makeLeg(quantity: 100, type: .transfer, earmarkId: UUID()),
    ])
    #expect(tx.isSimple == false)
  }

  @Test("Same-account transfer is NOT simple")
  func isSimpleRejectsSameAccountTransfer() {
    let acctId = UUID()
    let tx = makeTransaction(legs: [
      makeLeg(accountId: acctId, quantity: -100, type: .transfer),
      makeLeg(accountId: acctId, quantity: 100, type: .transfer),
    ])
    #expect(tx.isSimple == false)
  }

  @Test("Two-leg transfer with different amounts is NOT simple")
  func isSimpleRejectsNonNegatedAmounts() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -100, type: .transfer),
      makeLeg(quantity: 50, type: .transfer),
    ])
    #expect(tx.isSimple == false)
  }

  @Test("Two-leg transfer with different types is NOT simple")
  func isSimpleRejectsMixedTypes() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -100, type: .expense),
      makeLeg(quantity: 100, type: .income),
    ])
    #expect(tx.isSimple == false)
  }

  @Test("Three-leg transaction is NOT simple")
  func isSimpleRejectsThreeLegs() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -50, type: .expense),
      makeLeg(quantity: -30, type: .expense),
      makeLeg(quantity: 80, type: .income),
    ])
    #expect(tx.isSimple == false)
  }
}
