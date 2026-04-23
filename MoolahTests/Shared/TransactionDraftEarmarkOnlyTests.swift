import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft earmark-only legs")
struct TransactionDraftEarmarkOnlyTests {
  private let support = TransactionDraftTestSupport()

  @Test func isEarmarkOnlyWithEarmarkAndNoAccount() {
    let leg = TransactionDraft.LegDraft(
      type: .income, accountId: nil, amountText: "100",
      categoryId: nil, categoryText: "", earmarkId: UUID())
    #expect(leg.isEarmarkOnly == true)
  }

  @Test func isEarmarkOnlyWithAccountAndEarmark() {
    let leg = TransactionDraft.LegDraft(
      type: .income, accountId: UUID(), amountText: "100",
      categoryId: nil, categoryText: "", earmarkId: UUID())
    #expect(leg.isEarmarkOnly == false)
  }

  @Test func isEarmarkOnlyWithAccountNoEarmark() {
    let leg = TransactionDraft.LegDraft(
      type: .expense, accountId: UUID(), amountText: "100",
      categoryId: nil, categoryText: "", earmarkId: nil)
    #expect(leg.isEarmarkOnly == false)
  }

  @Test func isEarmarkOnlyWithNeitherAccountNorEarmark() {
    let leg = TransactionDraft.LegDraft(
      type: .expense, accountId: nil, amountText: "100",
      categoryId: nil, categoryText: "", earmarkId: nil)
    #expect(leg.isEarmarkOnly == false)
  }

  @Test func validEarmarkOnlyLeg() {
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .income, accountId: nil, amountText: "100",
          categoryId: nil, categoryText: "", earmarkId: UUID())
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.isValid == true)
  }

  @Test func invalidLegWithNeitherAccountNorEarmark() {
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: nil, amountText: "100",
          categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.isValid == false)
  }

  @Test func validCustomWithMixedAccountAndEarmarkOnlyLegs() {
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: UUID(), amountText: "50",
          categoryId: nil, categoryText: "", earmarkId: nil),
        TransactionDraft.LegDraft(
          type: .income, accountId: nil, amountText: "50",
          categoryId: nil, categoryText: "", earmarkId: UUID()),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    #expect(draft.isValid == true)
  }

  @Test func toTransactionEarmarkOnlyLeg() throws {
    let emId = UUID()
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .income, accountId: nil, amountText: "500",
          categoryId: nil, categoryText: "", earmarkId: emId,
          instrumentId: Instrument.defaultTestInstrument.id)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let earmarks = Earmarks(from: [
      Earmark(
        id: emId, name: "Holiday",
        instrument: .defaultTestInstrument)
    ])
    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: Accounts(from: []), earmarks: earmarks,
        availableInstruments: [support.instrument]))
    #expect(transaction.legs.count == 1)
    #expect(transaction.legs[0].accountId == nil)
    #expect(transaction.legs[0].earmarkId == emId)
    #expect(transaction.legs[0].quantity == Decimal(string: "500"))
    #expect(transaction.legs[0].type == .income)
    #expect(transaction.legs[0].instrument == .defaultTestInstrument)
  }

  @Test func toTransactionMixedAccountAndEarmarkOnlyLegs() throws {
    let emId = UUID()
    let acctId = UUID()
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "50",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: Instrument.defaultTestInstrument.id),
        TransactionDraft.LegDraft(
          type: .income, accountId: nil, amountText: "50",
          categoryId: nil, categoryText: "", earmarkId: emId,
          instrumentId: Instrument.defaultTestInstrument.id),
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let accounts = Accounts(from: [
      Account(
        id: acctId, name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    ])
    let earmarks = Earmarks(from: [
      Earmark(
        id: emId, name: "Holiday",
        instrument: .defaultTestInstrument)
    ])
    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, earmarks: earmarks,
        availableInstruments: [support.instrument]))
    #expect(transaction.legs.count == 2)
    #expect(transaction.legs[0].accountId == acctId)
    #expect(transaction.legs[1].accountId == nil)
    #expect(transaction.legs[1].earmarkId == emId)
  }

  @Test func earmarkOnlyLegEnforcesIncomeType() {
    var draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: UUID(), amountText: "100",
          categoryId: UUID(), categoryText: "Food", earmarkId: UUID())
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    // Clear the account — should enforce earmark-only invariants
    draft.legDrafts[0].accountId = nil
    draft.enforceEarmarkOnlyInvariants(at: 0)
    #expect(draft.legDrafts[0].type == .income)
    #expect(draft.legDrafts[0].categoryId == nil)
    #expect(draft.legDrafts[0].categoryText.isEmpty)
  }

  @Test func earmarkOnlyInvariantsNoOpWhenNotEarmarkOnly() {
    var draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: UUID(), amountText: "100",
          categoryId: UUID(), categoryText: "Food", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let originalCategoryId = draft.legDrafts[0].categoryId
    draft.enforceEarmarkOnlyInvariants(at: 0)
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].categoryId == originalCategoryId)
  }

  @Test func initBlankEarmarkOnlyDraft() {
    let emId = UUID()
    let draft = TransactionDraft(earmarkId: emId)
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].earmarkId == emId)
    #expect(draft.legDrafts[0].accountId == nil)
    #expect(draft.legDrafts[0].type == .income)
    #expect(draft.legDrafts[0].amountText == "0")
    #expect(draft.legDrafts[0].categoryId == nil)
  }
}
