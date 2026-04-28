import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft reverse switch from Trade")
struct TransactionDraftReverseSwitchTests {
  let aud = Instrument.AUD
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let acctA = UUID()
  let acctB = UUID()

  private func accounts() -> Accounts {
    Accounts(from: [
      Account(id: acctA, name: "A", type: .bank, instrument: aud, positions: []),
      Account(id: acctB, name: "B", type: .bank, instrument: aud, positions: []),
    ])
  }

  private func tradeDraft(withFee: Bool = false) -> TransactionDraft {
    // Buy-shaped fixture: cash leg quantity -300 (literal in amountText since
    // `displaysNegated(.trade) == false`), position leg quantity +20.
    var draft = TransactionDraft(accountId: acctA, instrumentId: aud.id)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "-300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id),
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "20",
        categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: vgs.id),
    ]
    if withFee {
      draft.legDrafts.append(
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctA, amountText: "10",
          categoryId: nil, categoryText: "", earmarkId: nil, instrumentId: aud.id))
    }
    return draft
  }

  @Test("Trade → Income: keep Received leg, retype, drop Paid + fees")
  func toIncome() {
    var draft = tradeDraft(withFee: true)
    draft.switchFromTrade(to: .income, accounts: accounts())
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].type == .income)
    #expect(draft.legDrafts[0].amountText == "20")
    #expect(draft.legDrafts[0].instrumentId == vgs.id)
    #expect(draft.legDrafts[0].accountId == acctA)
  }

  @Test("Trade → Expense: keep Paid leg, retype, drop Received + fees")
  func toExpense() {
    var draft = tradeDraft(withFee: true)
    draft.switchFromTrade(to: .expense, accounts: accounts())
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].amountText == "300")
    #expect(draft.legDrafts[0].instrumentId == aud.id)
  }

  @Test("Trade → Transfer: keep Paid leg + add counterpart on a different account")
  func toTransfer() {
    var draft = tradeDraft(withFee: false)
    draft.switchFromTrade(to: .transfer, accounts: accounts())
    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts.allSatisfy { $0.type == .transfer })
    let acctIds = Set(draft.legDrafts.compactMap(\.accountId))
    #expect(acctIds == Set([acctA, acctB]))
  }

  @Test("Trade → Custom: lossless, all legs preserved with .trade types")
  func toCustom() {
    var draft = tradeDraft(withFee: true)
    draft.switchFromTrade(to: nil, accounts: accounts())
    #expect(draft.isCustom == true)
    #expect(draft.legDrafts.count == 3)
    #expect(draft.legDrafts.filter { $0.type == .trade }.count == 2)
    #expect(draft.legDrafts.filter { $0.type == .expense }.count == 1)
  }
}
