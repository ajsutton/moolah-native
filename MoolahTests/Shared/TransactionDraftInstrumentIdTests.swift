import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft LegDraft instrument storage")
struct TransactionDraftInstrumentIdTests {
  private let support = TransactionDraftTestSupport()

  @Test
  func legDraftInstrumentOverridesToTransaction() throws {
    let acctId = UUID()
    let usd = Instrument.fiat(code: "USD")
    let accounts = support.makeAccounts([support.makeAccount(id: acctId, instrument: .AUD)])
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "100.00",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrument: usd)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let transaction = try #require(
      draft.toTransaction(id: UUID(), accounts: accounts))
    #expect(transaction.legs[0].instrument.id == "USD")
  }

  @Test
  func legDraftNilInstrumentReturnsNil() {
    // A leg with no instrument is invalid — the draft cannot be saved.
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
    let transaction = draft.toTransaction(id: UUID(), accounts: accounts)
    #expect(transaction == nil)
  }

  @Test
  func legDraftInstrumentRoundTripsFullObject() throws {
    // The full Instrument value — not just its id — is preserved on the round-trip.
    let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
    let acctId = UUID()
    let accounts = support.makeAccounts([support.makeAccount(id: acctId, instrument: .AUD)])
    let draft = TransactionDraft(
      payee: "", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: true,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctId, amountText: "10",
          categoryId: nil, categoryText: "", earmarkId: nil,
          instrument: vgs)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    let transaction = try #require(
      draft.toTransaction(id: UUID(), accounts: accounts))
    #expect(transaction.legs[0].instrument == vgs)
  }
}
