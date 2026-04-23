import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft validation + display/parse edge cases")
struct TransactionDraftValidationTests {
  private let support = TransactionDraftTestSupport()

  // MARK: - Validation

  @Test func validSimpleExpense() {
    let draft = support.makeExpenseDraft(amountText: "10.00", accountId: support.accountA)
    #expect(draft.isValid == true)
  }

  @Test func invalidEmptyAmount() {
    let draft = support.makeExpenseDraft(amountText: "")
    #expect(draft.isValid == false)
  }

  @Test func validZeroAmount() {
    let draft = support.makeExpenseDraft(amountText: "0")
    #expect(draft.isValid == true)
  }

  @Test func validNegativeDisplayAmount() {
    // Refund: user types -10 for an expense
    let draft = support.makeExpenseDraft(amountText: "-10.00")
    #expect(draft.isValid == true)
  }

  @Test func invalidMissingAccount() {
    let draft = TransactionDraft(
      payee: "Test", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: nil, amountText: "10.00",
          categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.isValid == false)
  }

  @Test func invalidRecurrenceWithoutPeriod() {
    var draft = support.makeExpenseDraft(amountText: "10.00")
    draft.isRepeating = true
    draft.recurPeriod = nil
    #expect(draft.isValid == false)
  }

  @Test func validRecurrence() {
    var draft = support.makeExpenseDraft(amountText: "10.00")
    draft.isRepeating = true
    draft.recurPeriod = .month
    draft.recurEvery = 1
    #expect(draft.isValid == true)
  }

  @Test func invalidCustomEmptyLegs() {
    var draft = support.makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts = []
    #expect(draft.isValid == false)
  }

  @Test func invalidCustomLegMissingAccount() {
    var draft = support.makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: nil, amountText: "10.00",
        categoryId: nil, categoryText: "", earmarkId: nil)
    ]
    #expect(draft.isValid == false)
  }

  @Test func invalidCustomLegEmptyAmount() {
    var draft = support.makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: support.accountA, amountText: "",
        categoryId: nil, categoryText: "", earmarkId: nil)
    ]
    #expect(draft.isValid == false)
  }

  @Test func validCustomLegs() {
    var draft = support.makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: support.accountA, amountText: "10.00",
        categoryId: nil, categoryText: "", earmarkId: nil),
      TransactionDraft.LegDraft(
        type: .income, accountId: support.accountB, amountText: "5.00",
        categoryId: nil, categoryText: "", earmarkId: nil),
    ]
    #expect(draft.isValid == true)
  }

  // MARK: - Edge Cases (display / parse round-trips)

  @Test func displayTextForZeroQuantity() {
    let text = TransactionDraft.displayText(quantity: .zero, type: .expense, decimals: 2)
    #expect(text == "0")
  }

  @Test func displayTextForNegativeExpense() throws {
    // Normal expense: quantity -50, display = -(-50) = 50
    let quantity = try #require(Decimal(string: "-50"))
    let text = TransactionDraft.displayText(quantity: quantity, type: .expense, decimals: 2)
    #expect(text == "50.00")
  }

  @Test func displayTextForRefundExpense() throws {
    // Refund: quantity +10, display = -(+10) = -10
    let quantity = try #require(Decimal(string: "10"))
    let text = TransactionDraft.displayText(quantity: quantity, type: .expense, decimals: 2)
    #expect(text == "-10.00")
  }

  @Test func displayTextForIncome() throws {
    let quantity = try #require(Decimal(string: "100"))
    let text = TransactionDraft.displayText(quantity: quantity, type: .income, decimals: 2)
    #expect(text == "100.00")
  }

  @Test func parseDisplayTextRoundTrips() throws {
    let original = try #require(Decimal(string: "-42.50"))
    let display = TransactionDraft.displayText(quantity: original, type: .expense, decimals: 2)
    let parsed = TransactionDraft.parseDisplayText(display, type: .expense, decimals: 2)
    #expect(parsed == original)
  }

  @Test func parseDisplayTextRefundRoundTrips() throws {
    let original = try #require(Decimal(string: "10.00"))  // refund expense
    let display = TransactionDraft.displayText(quantity: original, type: .expense, decimals: 2)
    #expect(display == "-10.00")
    let parsed = TransactionDraft.parseDisplayText(display, type: .expense, decimals: 2)
    #expect(parsed == original)
  }

  @Test func parseDisplayTextIncomeRoundTrips() throws {
    let original = try #require(Decimal(string: "3000.00"))
    let display = TransactionDraft.displayText(quantity: original, type: .income, decimals: 2)
    let parsed = TransactionDraft.parseDisplayText(display, type: .income, decimals: 2)
    #expect(parsed == original)
  }

  @Test func customModeLegTypeChangePreservesDisplayAmount() throws {
    var draft = support.makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts[0].amountText = "50.00"
    draft.legDrafts[0].type = .income
    // Display text unchanged
    #expect(draft.legDrafts[0].amountText == "50.00")
    // But conversion would produce different quantity
    let accounts = support.makeAccounts([support.makeAccount(id: support.accountA)])
    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, availableInstruments: [support.instrument]))
    #expect(transaction.legs[0].quantity == Decimal(string: "50.00"))  // income: as-is
  }
}
