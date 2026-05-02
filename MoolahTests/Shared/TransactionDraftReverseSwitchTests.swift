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
    var draft = TransactionDraft(accountId: acctA, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "-300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud),
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "20",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: vgs),
    ]
    if withFee {
      draft.legDrafts.append(
        TransactionDraft.LegDraft(
          type: .expense, accountId: acctA, amountText: "10",
          categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud))
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
    #expect(draft.legDrafts[0].instrument == vgs)
    #expect(draft.legDrafts[0].accountId == acctA)
  }

  @Test("Trade → Expense: keep Paid leg, retype, drop Received + fees")
  func toExpense() {
    var draft = tradeDraft(withFee: true)
    draft.switchFromTrade(to: .expense, accounts: accounts())
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].amountText == "300")
    #expect(draft.legDrafts[0].instrument == aud)
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

  // MARK: - Sidebar-order tests for applyTransferLegs

  // Fixture: brokerage (investment, pos 0) is the paid leg's account.
  // accounts.ordered = [brokerage, crypto, chequing]
  //   → ordered.first { != brokerage } = crypto   (the bug)
  // accounts.sidebarOrdered(excluding: brokerage) = [chequing, crypto]
  //   → first = chequing                           (the fix)
  private let brokerageId = UUID()
  private let cryptoId = UUID()
  private let chequingId = UUID()

  private func threeAccounts() -> Accounts {
    Accounts(from: [
      Account(
        id: brokerageId, name: "Brokerage", type: .investment,
        instrument: Instrument.AUD, positions: [], position: 0),
      Account(
        id: cryptoId, name: "Crypto", type: .investment,
        instrument: Instrument.AUD, positions: [], position: 1),
      Account(
        id: chequingId, name: "Chequing", type: .bank,
        instrument: Instrument.AUD, positions: [], position: 5),
    ])
  }

  private func brokerageTradeDraft() -> TransactionDraft {
    var draft = TransactionDraft(accountId: brokerageId, instrument: Instrument.AUD)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: brokerageId, amountText: "-500",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: Instrument.AUD),
      TransactionDraft.LegDraft(
        type: .trade, accountId: brokerageId, amountText: "10",
        categoryId: nil, categoryText: "", earmarkId: nil,
        instrument: Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")),
    ]
    return draft
  }

  @Test("Trade → Transfer counterpart uses sidebar order, not insertion order")
  func toTransferUsesCurrentAccountFirst() {
    var draft = brokerageTradeDraft()
    draft.switchFromTrade(to: .transfer, accounts: threeAccounts())
    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts.allSatisfy { $0.type == .transfer })
    let counterpart = draft.legDrafts.first { $0.accountId != brokerageId }
    // Must pick chequing (sidebar-first current account), not crypto
    // (ordered-first investment account that isn't the paid-leg account).
    #expect(counterpart?.accountId == chequingId)
  }

  @Test("Trade → Transfer counterpart skips hidden accounts")
  func toTransferSkipsHiddenAccount() {
    let hiddenChequingId = UUID()
    let visibleChequingId = UUID()
    let accounts = Accounts(from: [
      Account(
        id: brokerageId, name: "Brokerage", type: .investment,
        instrument: Instrument.AUD, positions: [], position: 0),
      Account(
        id: hiddenChequingId, name: "HiddenChequing", type: .bank,
        instrument: Instrument.AUD, positions: [], position: 5,
        isHidden: true),
      Account(
        id: visibleChequingId, name: "VisibleChequing", type: .bank,
        instrument: Instrument.AUD, positions: [], position: 6),
    ])
    var draft = brokerageTradeDraft()
    draft.switchFromTrade(to: .transfer, accounts: accounts)
    #expect(draft.legDrafts.count == 2)
    let counterpart = draft.legDrafts.first { $0.accountId != brokerageId }
    // Hidden account must be skipped; visible chequing is the correct pick.
    #expect(counterpart?.accountId == visibleChequingId)
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
