import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.isSimple")
struct TransactionIsSimpleTests {
  let accountId = UUID()
  let aud = Instrument.defaultTestInstrument

  func makeLeg(
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

  @Test("Two-leg transfer with negated amounts and matching fields is simple")
  func twoLegTransferIsSimple() {
    let catId = UUID()
    let earId = UUID()
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -50, type: .transfer, categoryId: catId, earmarkId: earId),
      makeLeg(quantity: 50, type: .transfer, categoryId: catId, earmarkId: earId),
    ])
    #expect(tx.isSimple == true)
  }

  @Test("Two-leg transfer with nil optional fields is simple")
  func twoLegTransferNilFieldsIsSimple() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -100, type: .expense),
      makeLeg(quantity: 100, type: .expense),
    ])
    #expect(tx.isSimple == true)
  }

  // MARK: - Non-simple cases

  @Test("Two-leg transfer with different amounts is NOT simple")
  func twoLegDifferentAmountsNotSimple() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -50),
      makeLeg(quantity: 60),
    ])
    #expect(tx.isSimple == false)
  }

  @Test("Two-leg transfer with different categories is NOT simple")
  func twoLegDifferentCategoriesNotSimple() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -50, categoryId: UUID()),
      makeLeg(quantity: 50, categoryId: UUID()),
    ])
    #expect(tx.isSimple == false)
  }

  @Test("Two-leg transfer with different earmarks is NOT simple")
  func twoLegDifferentEarmarksNotSimple() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -50, earmarkId: UUID()),
      makeLeg(quantity: 50, earmarkId: UUID()),
    ])
    #expect(tx.isSimple == false)
  }

  @Test("Two-leg transfer with different types is NOT simple")
  func twoLegDifferentTypesNotSimple() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -50, type: .expense),
      makeLeg(quantity: 50, type: .income),
    ])
    #expect(tx.isSimple == false)
  }

  @Test("Three-leg transaction is NOT simple")
  func threeLegNotSimple() {
    let tx = makeTransaction(legs: [
      makeLeg(quantity: -50),
      makeLeg(quantity: 30),
      makeLeg(quantity: 20),
    ])
    #expect(tx.isSimple == false)
  }
}
