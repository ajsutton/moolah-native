import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft trade accessors")
struct TransactionDraftTradeAccessorsTests {
  let aud = Instrument.AUD
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let account = UUID()

  private func tradeDraft(extraFees: [TransactionDraft.LegDraft] = []) -> TransactionDraft {
    var draft = TransactionDraft(accountId: account, instrument: aud)
    draft.legDrafts =
      [
        TransactionDraft.LegDraft(
          type: .trade, accountId: account, amountText: "300",
          categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud),
        TransactionDraft.LegDraft(
          type: .trade, accountId: account, amountText: "20",
          categoryId: nil, categoryText: "", earmarkId: nil, instrument: vgs),
      ] + extraFees
    return draft
  }

  @Test("paid index is the first .trade leg")
  func paidLegIndex() {
    let draft = tradeDraft()
    #expect(draft.paidLegIndex == 0)
  }

  @Test("received index is the second .trade leg")
  func receivedLegIndex() {
    let draft = tradeDraft()
    #expect(draft.receivedLegIndex == 1)
  }

  @Test("received index is nil when there are three or more .trade legs")
  func receivedLegIndexRejectsExtraTradeLegs() {
    // Trade-shape invariant: exactly two `.trade` legs. A third indicates a
    // malformed or custom-mode draft, so the trade UI should not bind to it.
    var draft = tradeDraft()
    draft.legDrafts.append(
      TransactionDraft.LegDraft(
        type: .trade, accountId: account, amountText: "5",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud))
    #expect(draft.receivedLegIndex == nil)
  }

  @Test("received index is nil when there is only one .trade leg")
  func receivedLegIndexNilForSingleTrade() {
    var draft = TransactionDraft(accountId: account, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: account, amountText: "300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]
    #expect(draft.receivedLegIndex == nil)
  }

  @Test("feeIndices returns the .expense legs in order")
  func feeIndices() {
    let fee1 = TransactionDraft.LegDraft(
      type: .expense, accountId: account, amountText: "10",
      categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    let fee2 = TransactionDraft.LegDraft(
      type: .expense, accountId: account, amountText: "0.5",
      categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    let draft = tradeDraft(extraFees: [fee1, fee2])
    #expect(draft.feeIndices == [2, 3])
  }

  @Test("appendFee adds an expense leg with default 0 amount")
  func appendFee() {
    var draft = tradeDraft()
    draft.appendFee(defaultInstrument: aud)
    #expect(draft.legDrafts.count == 3)
    #expect(draft.legDrafts[2].type == .expense)
    #expect(draft.legDrafts[2].amountText == "0")
    #expect(draft.legDrafts[2].instrument == aud)
    #expect(draft.legDrafts[2].accountId == account)
  }

  @Test("removeFee at index drops only that leg")
  func removeFeeIndex() {
    let fee = TransactionDraft.LegDraft(
      type: .expense, accountId: account, amountText: "10",
      categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    var draft = tradeDraft(extraFees: [fee])
    draft.removeFee(at: 2)
    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts.allSatisfy { $0.type == .trade })
  }
}
