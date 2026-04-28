import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft trade leg sign round-trips")
struct TransactionDraftTradeRoundTripTests {
  @Test("trade transaction round-trips signs literally — buy")
  func tradeRoundTripBuy() throws {
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
    // .trade legs preserve sign in amountText (displaysNegated == false).
    // AUD has 2 decimal places; VGS stock has 0.
    #expect(draft.legDrafts[0].amountText == "-300.00")
    #expect(draft.legDrafts[1].amountText == "20")

    let rebuilt = try #require(
      draft.toTransaction(id: original.id))
    #expect(rebuilt.legs[0].quantity == Decimal(-300))
    #expect(rebuilt.legs[1].quantity == Decimal(20))
  }

  @Test("trade transaction round-trips signs literally — reversal with unconventional signs")
  func tradeRoundTripReversal() throws {
    // Trade reversal: both legs flip sign vs a normal buy. The model must
    // preserve user-entered signs verbatim — see CLAUDE.md "Monetary Sign
    // Convention" and feedback_no_abs_on_trade_legs.md.
    let aud = Instrument.AUD
    let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
    let account = UUID()
    let original = Transaction(
      id: UUID(),
      date: Date(),
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: 300, type: .trade),
        TransactionLeg(accountId: account, instrument: vgs, quantity: -20, type: .trade),
      ]
    )

    let draft = TransactionDraft(from: original)
    #expect(draft.legDrafts[0].amountText == "300.00")
    #expect(draft.legDrafts[1].amountText == "-20")

    let rebuilt = try #require(
      draft.toTransaction(id: original.id))
    #expect(rebuilt.legs[0].quantity == Decimal(300))
    #expect(rebuilt.legs[1].quantity == Decimal(-20))
  }

  @Test("trade leg amountText is parsed literally — no abs, no sign-by-position")
  func tradeAmountTextLiteral() throws {
    let aud = Instrument.AUD
    let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
    let account = UUID()
    var draft = TransactionDraft(accountId: account, instrument: aud)
    // First leg literal "+300", second literal "-20" — both signs preserved.
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: account, amountText: "300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud),
      TransactionDraft.LegDraft(
        type: .trade, accountId: account, amountText: "-20",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: vgs),
    ]

    let rebuilt = try #require(
      draft.toTransaction(id: UUID()))
    #expect(rebuilt.legs[0].quantity == Decimal(300))
    #expect(rebuilt.legs[1].quantity == Decimal(-20))
  }
}
