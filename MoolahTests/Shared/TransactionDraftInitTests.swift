import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft init from Transaction")
struct TransactionDraftInitTests {
  private let support = TransactionDraftTestSupport()

  // MARK: - Init from Transaction: Simple Expense

  @Test func initFromSimpleExpense() throws {
    let categoryId = UUID()
    let earmarkId = UUID()
    let quantity = try #require(Decimal(string: "-42.50"))
    let transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      payee: "Coffee",
      notes: "Latte",
      recurPeriod: .week,
      recurEvery: 2,
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: quantity, type: .expense,
          categoryId: categoryId, earmarkId: earmarkId)
      ]
    )

    let draft = TransactionDraft(from: transaction)

    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.payee == "Coffee")
    #expect(draft.notes == "Latte")
    #expect(draft.date == transaction.date)
    #expect(draft.isRepeating == true)
    #expect(draft.recurPeriod == .week)
    #expect(draft.recurEvery == 2)

    // Leg data: amount is negated for display (expense -42.50 -> display "42.50")
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].accountId == support.accountA)
    #expect(draft.legDrafts[0].amountText == "42.50")
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
  }

  @Test func initFromSimpleIncome() throws {
    let quantity = try #require(Decimal(string: "3000.00"))
    let transaction = Transaction(
      date: Date(),
      payee: "Salary",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: quantity, type: .income)
      ]
    )

    let draft = TransactionDraft(from: transaction)

    // Income: display = quantity as-is (positive stays positive)
    #expect(draft.legDrafts[0].type == .income)
    #expect(draft.legDrafts[0].amountText == "3000.00")
  }

  @Test func initFromRefundExpense() throws {
    // Refund: expense with positive quantity
    let quantity = try #require(Decimal(string: "10.00"))
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: quantity, type: .expense)
      ]
    )

    let draft = TransactionDraft(from: transaction)

    // Expense display is negated: -(+10) = -10
    #expect(draft.legDrafts[0].amountText == "-10.00")
  }

  @Test func initFromZeroAmount() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: Decimal.zero, type: .expense)
      ]
    )

    let draft = TransactionDraft(from: transaction)
    #expect(draft.legDrafts[0].amountText == "0")
  }

  // MARK: - Init from Transaction: Simple Transfer

  @Test func initFromSimpleTransferNoContext() {
    let transaction = Transaction(
      date: Date(),
      payee: "Transfer",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: transaction)

    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 2)
    // No context: relevant leg is index 0 (the primary leg)
    #expect(draft.relevantLegIndex == 0)
    // Both legs populated
    #expect(draft.legDrafts[0].accountId == support.accountA)
    #expect(draft.legDrafts[0].amountText == "100.00")  // -(-100) = 100
    #expect(draft.legDrafts[1].accountId == support.accountB)
    #expect(draft.legDrafts[1].amountText == "-100.00")  // -(+100) = -100
  }

  @Test func initFromSimpleTransferViewingFromSource() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: transaction, viewingAccountId: support.accountA)

    // Source account is at index 0, so relevant leg = 0
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.legDrafts[0].amountText == "100.00")
  }

  @Test func initFromSimpleTransferViewingFromDestination() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: transaction, viewingAccountId: support.accountB)

    // Destination account is at index 1, so relevant leg = 1
    #expect(draft.relevantLegIndex == 1)
    // Display: -(+100) = -100
    #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "-100.00")
  }

  @Test func initFromSimpleTransferWithCategoryOnFirstLeg() {
    let categoryId = UUID()
    let earmarkId = UUID()
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer,
          categoryId: categoryId, earmarkId: earmarkId),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )

    #expect(transaction.isSimple == true)
    let draft = TransactionDraft(from: transaction)
    #expect(draft.isCustom == false)
    // Category/earmark on primary leg (index 0)
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
    // Counterpart has nil
    #expect(draft.legDrafts[1].categoryId == nil)
    #expect(draft.legDrafts[1].earmarkId == nil)
  }

  // MARK: - Init from Transaction: Complex

  @Test func initFromComplexTransaction() {
    let catId = UUID()
    let transaction = Transaction(
      date: Date(),
      payee: "Split",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .expense, categoryId: catId),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: -50, type: .expense),
        TransactionLeg(
          accountId: UUID(), instrument: support.instrument,
          quantity: 150, type: .income),
      ]
    )
    #expect(!transaction.isSimple)

    let draft = TransactionDraft(from: transaction)
    #expect(draft.isCustom == true)
    #expect(draft.legDrafts.count == 3)
    // Expense legs: display is negated
    #expect(draft.legDrafts[0].amountText == "100.00")
    #expect(draft.legDrafts[0].categoryId == catId)
    #expect(draft.legDrafts[1].amountText == "50.00")
    // Income leg: display is as-is
    #expect(draft.legDrafts[2].amountText == "150.00")
  }

  // MARK: - Init Blank

  @Test func initBlankTransaction() {
    let draft = TransactionDraft(accountId: support.accountA)

    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.relevantLegIndex == 0)
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].accountId == support.accountA)
    #expect(draft.legDrafts[0].amountText == "0")
    #expect(draft.payee.isEmpty)
    #expect(draft.notes.isEmpty)
    #expect(draft.isRepeating == false)
  }

  // MARK: - Init with Instrument Precision

  @Test func initPreservesCryptoPrecision() throws {
    let btc = Instrument.crypto(
      chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let quantity = try #require(Decimal(string: "-0.00123456"))
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: btc,
          quantity: quantity, type: .expense)
      ]
    )
    let draft = TransactionDraft(from: transaction)
    #expect(draft.legDrafts[0].amountText.contains("0.00123456"))
  }
}
