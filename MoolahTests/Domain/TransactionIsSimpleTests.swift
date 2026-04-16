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

  // MARK: - Multi-instrument edge cases

  @Test("Cross-currency transfer is NOT simple (quantities don't negate)")
  func crossCurrencyTransferNotSimple() {
    // Currency conversion: 1000 AUD -> 650 USD. Quantities don't negate,
    // so isSimple must be false even though structurally a 2-leg transfer.
    let fromAccount = UUID()
    let toAccount = UUID()
    let aud100 = TransactionLeg(
      accountId: fromAccount, instrument: Instrument.AUD,
      quantity: Decimal(-1000), type: .transfer)
    let usd65 = TransactionLeg(
      accountId: toAccount, instrument: Instrument.USD,
      quantity: Decimal(650), type: .transfer)
    let tx = makeTransaction(legs: [aud100, usd65])
    #expect(tx.isSimple == false)
  }

  @Test("Single-account cross-instrument swap is a transfer")
  func singleAccountMultiInstrumentIsTransfer() {
    // A single-account conversion (e.g., AUD→USD within Revolut) counts as a transfer
    // per Transaction.isTransfer: uniqueness across instruments triggers transfer.
    let accountId = UUID()
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: Instrument.AUD,
        quantity: Decimal(-1000), type: .transfer),
      TransactionLeg(
        accountId: accountId, instrument: Instrument.USD,
        quantity: Decimal(650), type: .transfer),
    ]
    let tx = makeTransaction(legs: legs)
    #expect(tx.isTransfer == true)
  }

  @Test("Single-account same-instrument legs are NOT a transfer")
  func singleAccountSameInstrumentNotTransfer() {
    // Same account + same instrument means there's no source→destination movement.
    let accountId = UUID()
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(-100), type: .transfer),
      TransactionLeg(
        accountId: accountId, instrument: aud, quantity: Decimal(100), type: .transfer),
    ]
    let tx = makeTransaction(legs: legs)
    #expect(tx.isTransfer == false)
  }

  @Test("Cross-account same-instrument legs are a transfer")
  func crossAccountSameInstrumentIsTransfer() {
    let legs = [
      TransactionLeg(
        accountId: UUID(), instrument: aud, quantity: Decimal(-100), type: .transfer),
      TransactionLeg(
        accountId: UUID(), instrument: aud, quantity: Decimal(100), type: .transfer),
    ]
    let tx = makeTransaction(legs: legs)
    #expect(tx.isTransfer == true)
  }

  @Test("Stock trade (fiat out, stock in) is a transfer")
  func stockTradeIsTransfer() {
    let accountId = UUID()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let legs = [
      TransactionLeg(
        accountId: accountId, instrument: Instrument.AUD,
        quantity: Decimal(-6345), type: .transfer),
      TransactionLeg(
        accountId: accountId, instrument: bhp, quantity: Decimal(150), type: .transfer),
    ]
    let tx = makeTransaction(legs: legs)
    #expect(tx.isTransfer == true)
  }
}
