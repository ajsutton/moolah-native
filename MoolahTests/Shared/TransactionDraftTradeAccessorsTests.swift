import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft trade accessors")
struct TransactionDraftTradeAccessorsTests {
  let aud = Instrument.AUD
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let account = UUID()

  private func tradeDraft(extraFees: [TransactionDraft.LegDraft] = []) -> TransactionDraft {
    var draft = TransactionDraft(accountId: account, instrumentId: aud.id)
    draft.legDrafts =
      [
        TransactionDraft.LegDraft(
          type: .trade, accountId: account, amountText: "300",
          categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id),
        TransactionDraft.LegDraft(
          type: .trade, accountId: account, amountText: "20",
          categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: vgs.id),
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

  @Test("feeIndices returns the .expense legs in order")
  func feeIndices() {
    let fee1 = TransactionDraft.LegDraft(
      type: .expense, accountId: account, amountText: "10",
      categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id)
    let fee2 = TransactionDraft.LegDraft(
      type: .expense, accountId: account, amountText: "0.5",
      categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id)
    let draft = tradeDraft(extraFees: [fee1, fee2])
    #expect(draft.feeIndices == [2, 3])
  }

  @Test("appendFee adds an expense leg with default 0 amount")
  func appendFee() {
    var draft = tradeDraft()
    draft.appendFee(defaultInstrumentId: aud.id)
    #expect(draft.legDrafts.count == 3)
    #expect(draft.legDrafts[2].type == .expense)
    #expect(draft.legDrafts[2].amountText == "0")
    #expect(draft.legDrafts[2].instrumentId == aud.id)
    #expect(draft.legDrafts[2].accountId == account)
  }

  @Test("removeFee at index drops only that leg")
  func removeFeeIndex() {
    let fee = TransactionDraft.LegDraft(
      type: .expense, accountId: account, amountText: "10",
      categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id)
    var draft = tradeDraft(extraFees: [fee])
    draft.removeFee(at: 2)
    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts.allSatisfy { $0.type == .trade })
  }
}
