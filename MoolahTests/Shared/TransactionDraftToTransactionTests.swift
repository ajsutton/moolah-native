import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft.toTransaction conversion")
struct TransactionDraftToTransactionTests {
  private let support = TransactionDraftTestSupport()

  @Test func toTransactionSimpleExpense() throws {
    let draft = support.makeExpenseDraft(amountText: "25.00", accountId: support.accountA)
    let accounts = support.makeAccounts([support.makeAccount(id: support.accountA)])
    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, availableInstruments: [support.instrument]))

    #expect(transaction.legs.count == 1)
    #expect(transaction.legs[0].quantity == Decimal(string: "-25.00"))  // expense: negated back
    #expect(transaction.legs[0].type == .expense)
    #expect(transaction.legs[0].accountId == support.accountA)
  }

  @Test func toTransactionSimpleIncome() throws {
    let draft = TransactionDraft(
      payee: "Salary", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .income, accountId: support.accountA, amountText: "3000.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: support.instrument.id)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let accounts = support.makeAccounts([support.makeAccount(id: support.accountA)])
    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, availableInstruments: [support.instrument]))

    #expect(transaction.legs[0].quantity == Decimal(string: "3000.00"))  // income: as-is
  }

  @Test func toTransactionRefundExpense() throws {
    // Display value "-10" for expense -> quantity = -(-10) = +10
    let draft = support.makeExpenseDraft(amountText: "-10.00", accountId: support.accountA)
    let accounts = support.makeAccounts([support.makeAccount(id: support.accountA)])
    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, availableInstruments: [support.instrument]))

    #expect(transaction.legs[0].quantity == Decimal(string: "10.00"))
  }

  @Test func toTransactionSimpleTransfer() throws {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    var draft = support.makeExpenseDraft(amountText: "100.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)

    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, availableInstruments: [support.instrument]))
    #expect(transaction.legs.count == 2)
    #expect(transaction.legs[0].quantity == Decimal(string: "-100.00"))
    #expect(transaction.legs[1].quantity == Decimal(string: "100.00"))
  }

  @Test func toTransactionRoundTripsExpense() throws {
    let id = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let quantity = try #require(Decimal(string: "-42.50"))
    let original = Transaction(
      id: id,
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

    let draft = TransactionDraft(from: original)
    let accounts = support.makeAccounts([support.makeAccount(id: support.accountA)])
    let roundTripped = try #require(
      draft.toTransaction(
        id: id, accounts: accounts, availableInstruments: [support.instrument]))

    #expect(roundTripped.id == original.id)
    #expect(roundTripped.date == original.date)
    #expect(roundTripped.payee == original.payee)
    #expect(roundTripped.notes == original.notes)
    #expect(roundTripped.recurPeriod == original.recurPeriod)
    #expect(roundTripped.recurEvery == original.recurEvery)
    #expect(roundTripped.legs.count == original.legs.count)
    #expect(roundTripped.legs[0].quantity == original.legs[0].quantity)
    #expect(roundTripped.legs[0].type == original.legs[0].type)
    #expect(roundTripped.legs[0].categoryId == original.legs[0].categoryId)
    #expect(roundTripped.legs[0].earmarkId == original.legs[0].earmarkId)
  }

  @Test func toTransactionRoundTripsTransfer() throws {
    let id = UUID()
    let categoryId = UUID()
    let original = Transaction(
      id: id,
      date: Date(),
      payee: "Transfer",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer, categoryId: categoryId),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )

    let draft = TransactionDraft(from: original)
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    let roundTripped = try #require(
      draft.toTransaction(
        id: id, accounts: accounts, availableInstruments: [support.instrument]))

    #expect(roundTripped.legs.count == 2)
    #expect(roundTripped.legs[0].quantity == original.legs[0].quantity)
    #expect(roundTripped.legs[1].quantity == original.legs[1].quantity)
    #expect(roundTripped.legs[0].categoryId == categoryId)
    #expect(roundTripped.legs[1].categoryId == nil)
  }

  @Test func toTransactionRoundTripsTransferFromDestination() throws {
    let id = UUID()
    let original = Transaction(
      id: id,
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

    // Edit from destination perspective
    let draft = TransactionDraft(from: original, viewingAccountId: support.accountB)
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    let roundTripped = try #require(
      draft.toTransaction(
        id: id, accounts: accounts, availableInstruments: [support.instrument]))

    // Quantities must be preserved regardless of which leg is "relevant"
    #expect(roundTripped.legs[0].quantity == Decimal(string: "-100"))
    #expect(roundTripped.legs[1].quantity == Decimal(string: "100"))
  }

  @Test func toTransactionCustomModeMultiLeg() throws {
    let catId = UUID()
    let earmarkId = UUID()
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    let draft = TransactionDraft(
      payee: "Split", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: support.accountA, amountText: "100.00",
          categoryId: catId, categoryText: "", earmarkId: nil,
          instrumentId: support.instrument.id),
        TransactionDraft.LegDraft(
          type: .income, accountId: support.accountB, amountText: "50.00",
          categoryId: nil, categoryText: "", earmarkId: earmarkId,
          instrumentId: support.instrument.id),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )

    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, availableInstruments: [support.instrument]))
    #expect(transaction.legs.count == 2)
    #expect(transaction.legs[0].quantity == Decimal(string: "-100.00"))  // expense negated
    #expect(transaction.legs[0].categoryId == catId)
    #expect(transaction.legs[1].quantity == Decimal(string: "50.00"))  // income as-is
    #expect(transaction.legs[1].earmarkId == earmarkId)
  }

  @Test func toTransactionReturnsNilWhenInvalid() {
    let draft = support.makeExpenseDraft(amountText: "")
    let accounts = support.makeAccounts([support.makeAccount(id: support.accountA)])
    #expect(draft.toTransaction(id: UUID(), accounts: accounts) == nil)
  }

  @Test func toTransactionClearsRecurrenceWhenNotRepeating() throws {
    var draft = support.makeExpenseDraft(amountText: "10.00", accountId: support.accountA)
    draft.recurPeriod = .month
    draft.recurEvery = 2
    draft.isRepeating = false

    let accounts = support.makeAccounts([support.makeAccount(id: support.accountA)])
    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, availableInstruments: [support.instrument]))
    #expect(transaction.recurPeriod == nil)
    #expect(transaction.recurEvery == nil)
  }
}
