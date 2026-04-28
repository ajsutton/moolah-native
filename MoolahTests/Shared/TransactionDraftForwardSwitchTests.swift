import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft forward switch to Trade")
struct TransactionDraftForwardSwitchTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let vgs = Instrument.stock(ticker: "VGS.AX", exchange: "ASX", name: "VGS")
  let acctA = UUID()
  let acctB = UUID()

  private func accountsAUD() -> Accounts {
    Accounts(from: [
      Account(id: acctA, name: "A", type: .bank, instrument: aud, positions: []),
      Account(id: acctB, name: "B", type: .bank, instrument: aud, positions: []),
    ])
  }

  @Test("Income → Trade: existing leg becomes Received, Paid added at 0 in account currency")
  func incomeToTrade() throws {
    var draft = TransactionDraft(accountId: acctA, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .income, accountId: acctA, amountText: "3500",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]
    draft.switchToTrade(accounts: accountsAUD())
    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts.allSatisfy { $0.type == .trade })
    let receivedIndex = try #require(draft.receivedLegIndex)
    let received = draft.legDrafts[receivedIndex]
    #expect(received.amountText == "3500")
    #expect(received.instrument == aud)
    let paidIndex = try #require(draft.paidLegIndex)
    let paid = draft.legDrafts[paidIndex]
    #expect(paid.amountText == "0")
    #expect(paid.instrument == aud)
  }

  @Test("Expense → Trade: existing leg becomes Paid; sign re-emitted for trade display")
  func expenseToTrade() throws {
    // Expense's `displaysNegated == true` means amountText "300" represents
    // a stored quantity of -300. `.trade` doesn't negate, so the carried
    // amountText flips to "-300" so the same -300 round-trips through trade.
    var draft = TransactionDraft(accountId: acctA, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: acctA, amountText: "300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]
    draft.switchToTrade(accounts: accountsAUD())
    let paidIndex = try #require(draft.paidLegIndex)
    let receivedIndex = try #require(draft.receivedLegIndex)
    let paid = draft.legDrafts[paidIndex]
    let received = draft.legDrafts[receivedIndex]
    #expect(paid.amountText == "-300")
    #expect(received.amountText == "0")
  }

  @Test("Transfer → Trade: counterpart leg dropped, then Expense flow")
  func transferToTrade() {
    var draft = TransactionDraft(accountId: acctA, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .transfer, accountId: acctA, amountText: "500",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud),
      TransactionDraft.LegDraft(
        type: .transfer, accountId: acctB, amountText: "500",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud),
    ]
    draft.switchToTrade(accounts: accountsAUD())
    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts.allSatisfy { $0.accountId == acctA })
    #expect(draft.legDrafts.allSatisfy { $0.type == .trade })
  }

  @Test("Custom (already trade-shaped) → Trade: no structural change, isCustom flips")
  func customToTrade() {
    var draft = TransactionDraft(accountId: acctA, instrument: aud)
    draft.isCustom = true
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "300",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud),
      TransactionDraft.LegDraft(
        type: .trade, accountId: acctA, amountText: "20",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: vgs),
    ]
    draft.switchToTrade(accounts: accountsAUD())
    #expect(draft.isCustom == false)
    #expect(draft.legDrafts.count == 2)
  }

  @Test("canSwitchToTrade reflects shape compatibility")
  func canSwitch() {
    var draft = TransactionDraft(accountId: acctA, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .income, accountId: acctA, amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]
    #expect(draft.canSwitchToTrade(accounts: accountsAUD()) == true)
  }
}
