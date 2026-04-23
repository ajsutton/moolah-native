import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft LegDraft instrumentId overrides")
struct TransactionDraftInstrumentIdTests {
  private let support = TransactionDraftTestSupport()

  @Test
  func legDraftInstrumentIdOverridesToTransaction() throws {
    let acctId = UUID()
    let accounts = support.makeAccounts([support.makeAccount(id: acctId, instrument: .AUD)])
    let availableInstruments = ["AUD", "USD", "EUR", "GBP"].map { Instrument.fiat(code: $0) }
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "100.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: "USD")
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let transaction = try #require(
      draft.toTransaction(
        id: UUID(), accounts: accounts, availableInstruments: availableInstruments))
    #expect(transaction.legs[0].instrument.id == "USD")
  }

  @Test
  func legDraftNilInstrumentIdReturnsNil() {
    // instrumentId is the canonical source of truth; a leg without one can't
    // resolve to an instrument and the draft is considered invalid-to-save.
    let acctId = UUID()
    let accounts = support.makeAccounts([support.makeAccount(id: acctId, instrument: .AUD)])
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "100.00",
          categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let transaction = draft.toTransaction(
      id: UUID(), accounts: accounts, availableInstruments: [.AUD])
    #expect(transaction == nil)
  }

  @Test
  func legDraftInvalidInstrumentIdReturnsNil() {
    let acctId = UUID()
    let accounts = support.makeAccounts([support.makeAccount(id: acctId, instrument: .AUD)])
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "100.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrumentId: "FAKE_CURRENCY")
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let transaction = draft.toTransaction(
      id: UUID(), accounts: accounts,
      availableInstruments: [Instrument.fiat(code: "AUD")])
    #expect(transaction == nil)
  }
}
