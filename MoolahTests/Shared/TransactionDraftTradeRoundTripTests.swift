import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft trade leg sign round-trips")
struct TransactionDraftTradeRoundTripTests {
  @Test("trade transaction round-trips with paid leg negative, received leg positive")
  func tradeRoundTrip() throws {
    let aud = Instrument.AUD
    let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
    let account = UUID()
    let original = Transaction(
      id: UUID(),
      date: Date(),
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: -300, type: .trade),
        TransactionLeg(accountId: account, instrument: vgs, quantity: 20, type: .trade),
      ]
    )

    let draft = TransactionDraft(from: original)
    // amountText should be positive for both legs.
    // AUD has 2 decimal places; VGS stock has 0 by default.
    #expect(draft.legDrafts[0].amountText == "300.00")
    #expect(draft.legDrafts[1].amountText == "20")

    let rebuilt = try #require(
      draft.toTransaction(
        id: original.id,
        availableInstruments: [aud, vgs]))
    #expect(rebuilt.legs[0].quantity == Decimal(-300))
    #expect(rebuilt.legs[1].quantity == Decimal(20))
  }

  @Test("trade transaction with positive amountText input still serialises Paid as negative")
  func tradePaidStaysNegativeEvenIfUserInput() throws {
    let aud = Instrument.AUD
    let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
    let account = UUID()
    // Construct a draft with positive amountText on both legs — which is
    // what the editor actually stores after Task 14.
    var draft = TransactionDraft(accountId: account, instrumentId: aud.id)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: account, amountText: "300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id),
      TransactionDraft.LegDraft(
        type: .trade, accountId: account, amountText: "20",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: vgs.id),
    ]

    let rebuilt = try #require(
      draft.toTransaction(id: UUID(), availableInstruments: [aud, vgs]))
    #expect(rebuilt.legs[0].quantity == Decimal(-300))  // paid leg negative
    #expect(rebuilt.legs[1].quantity == Decimal(20))  // received leg positive
  }
}
