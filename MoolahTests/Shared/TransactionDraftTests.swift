import Foundation
import Testing

@testable import Moolah

struct TransactionDraftTests {
  private let currency = Currency.defaultTestCurrency
  private let accountA = UUID()
  private let accountB = UUID()

  /// Helper that builds a minimal valid draft with the given type and amount.
  private func makeDraft(
    type: TransactionType = .expense,
    amountText: String = "10.00",
    accountId: UUID? = nil,
    toAccountId: UUID? = nil,
    isRepeating: Bool = false,
    recurPeriod: RecurPeriod? = nil,
    recurEvery: Int = 1
  ) -> TransactionDraft {
    TransactionDraft(
      type: type,
      payee: "Test Payee",
      amountText: amountText,
      date: Date(),
      accountId: accountId,
      toAccountId: toAccountId,
      categoryId: nil,
      earmarkId: nil,
      notes: "",
      isRepeating: isRepeating,
      recurPeriod: recurPeriod,
      recurEvery: recurEvery
    )
  }

  // MARK: - Amount Signing

  @Test func testExpenseAmountIsNegative() {
    let draft = makeDraft(type: .expense, amountText: "25.00")
    let tx = draft.toTransaction(id: UUID(), currency: currency)
    #expect(tx != nil)
    #expect(tx!.amount.cents == -2500)
  }

  @Test func testIncomeAmountIsPositive() {
    let draft = makeDraft(type: .income, amountText: "25.00")
    let tx = draft.toTransaction(id: UUID(), currency: currency)
    #expect(tx != nil)
    #expect(tx!.amount.cents == 2500)
  }

  @Test func testTransferAmountIsNegative() {
    let draft = makeDraft(
      type: .transfer, amountText: "25.00",
      accountId: accountA, toAccountId: accountB)
    let tx = draft.toTransaction(id: UUID(), currency: currency)
    #expect(tx != nil)
    #expect(tx!.amount.cents == -2500)
  }

  @Test func testOpeningBalanceAmountIsPositive() {
    let draft = makeDraft(type: .openingBalance, amountText: "100.00")
    let tx = draft.toTransaction(id: UUID(), currency: currency)
    #expect(tx != nil)
    #expect(tx!.amount.cents == 10000)
  }

  // MARK: - Parsing

  @Test func testParsedCentsFromDecimalString() {
    let draft = makeDraft(amountText: "12.50")
    #expect(draft.parsedCents == 1250)
  }

  @Test func testParsedCentsRejectsZero() {
    let draft = makeDraft(amountText: "0")
    #expect(draft.parsedCents == nil)
  }

  @Test func testParsedCentsRejectsNonNumeric() {
    let draft = makeDraft(amountText: "abc")
    #expect(draft.parsedCents == nil)
  }

  // MARK: - Validation

  @Test func testIsValidRequiresAmount() {
    let draft = makeDraft(amountText: "")
    #expect(draft.isValid == false)
  }

  @Test func testIsValidRequiresTransferToAccount() {
    let draft = makeDraft(
      type: .transfer, amountText: "10.00",
      accountId: accountA, toAccountId: nil)
    #expect(draft.isValid == false)
  }

  @Test func testIsValidRejectsTransferToSameAccount() {
    let draft = makeDraft(
      type: .transfer, amountText: "10.00",
      accountId: accountA, toAccountId: accountA)
    #expect(draft.isValid == false)
  }

  @Test func testIsValidRequiresRecurrenceConfig() {
    // Repeating but no period set
    let draft = makeDraft(
      amountText: "10.00",
      isRepeating: true, recurPeriod: nil, recurEvery: 1)
    #expect(draft.isValid == false)

    // Repeating with period set — valid
    let validDraft = makeDraft(
      amountText: "10.00",
      isRepeating: true, recurPeriod: .month, recurEvery: 1)
    #expect(validDraft.isValid == true)
  }

  // MARK: - Conversion Details

  @Test func testToTransactionClearsToAccountForNonTransfer() {
    let draft = makeDraft(
      type: .expense, amountText: "10.00",
      accountId: accountA, toAccountId: accountB)
    let tx = draft.toTransaction(id: UUID(), currency: currency)
    #expect(tx != nil)
    #expect(tx!.toAccountId == nil)
  }

  @Test func testToTransactionClearsRecurrenceWhenNotRepeating() {
    // Draft has recurPeriod set but isRepeating is false
    let draft = TransactionDraft(
      type: .expense,
      payee: "",
      amountText: "10.00",
      date: Date(),
      accountId: nil,
      toAccountId: nil,
      categoryId: nil,
      earmarkId: nil,
      notes: "",
      isRepeating: false,
      recurPeriod: .month,
      recurEvery: 2
    )
    let tx = draft.toTransaction(id: UUID(), currency: currency)
    #expect(tx != nil)
    #expect(tx!.recurPeriod == nil)
    #expect(tx!.recurEvery == nil)
  }

  @Test func testInitFromExistingTransactionRoundTrips() {
    let id = UUID()
    let original = Transaction(
      id: id,
      type: .expense,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      accountId: accountA,
      toAccountId: nil,
      amount: MonetaryAmount(cents: -4250, currency: currency),
      payee: "Coffee Shop",
      notes: "Morning latte",
      categoryId: UUID(),
      earmarkId: UUID(),
      recurPeriod: .week,
      recurEvery: 2
    )

    let draft = TransactionDraft(from: original)
    let roundTripped = draft.toTransaction(id: id, currency: currency)

    #expect(roundTripped != nil)
    #expect(roundTripped!.id == original.id)
    #expect(roundTripped!.type == original.type)
    #expect(roundTripped!.date == original.date)
    #expect(roundTripped!.accountId == original.accountId)
    #expect(roundTripped!.amount.cents == original.amount.cents)
    #expect(roundTripped!.payee == original.payee)
    #expect(roundTripped!.notes == original.notes)
    #expect(roundTripped!.categoryId == original.categoryId)
    #expect(roundTripped!.earmarkId == original.earmarkId)
    #expect(roundTripped!.recurPeriod == original.recurPeriod)
    #expect(roundTripped!.recurEvery == original.recurEvery)
  }
}
