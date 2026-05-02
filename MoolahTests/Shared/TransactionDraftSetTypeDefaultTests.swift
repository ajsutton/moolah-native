import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft.setType counterpart-account default")
struct TransactionDraftSetTypeDefaultTests {
  private let aud = Instrument.AUD

  private func acct(
    name: String, position: Int, type: AccountType = .bank, isHidden: Bool = false
  ) -> Account {
    Account(
      id: UUID(), name: name, type: type, instrument: aud,
      positions: [], position: position, isHidden: isHidden)
  }

  @Test("Switching to .transfer picks first sidebar-ordered non-from account")
  func picksSidebarFirstNonFromAccount() throws {
    // Insertion order is unsorted; sidebar order is by `position` within
    // each group, with current accounts before investment accounts.
    let chequing = acct(name: "Chequing", position: 0)
    let savings = acct(name: "Savings", position: 1)
    let brokerage = acct(name: "Brokerage", position: 0, type: .investment)
    let accounts = Accounts(from: [brokerage, savings, chequing])

    var draft = TransactionDraft(accountId: chequing.id, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: chequing.id, amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]

    draft.setType(.transfer, accounts: accounts)

    let counterpart = try #require(draft.counterpartLeg)
    #expect(counterpart.accountId == savings.id)
  }

  @Test("From-account being first sidebar account: default falls to second")
  func fromAccountIsFirstSidebarAccount() throws {
    let chequing = acct(name: "Chequing", position: 0)
    let savings = acct(name: "Savings", position: 1)
    let accounts = Accounts(from: [chequing, savings])

    var draft = TransactionDraft(accountId: chequing.id, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: chequing.id, amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]

    draft.setType(.transfer, accounts: accounts)

    let counterpart = try #require(draft.counterpartLeg)
    #expect(counterpart.accountId == savings.id)
  }

  @Test("Hidden accounts are never picked as the default counterpart")
  func skipsHiddenAccounts() throws {
    let chequing = acct(name: "Chequing", position: 0)
    let hiddenSavings = acct(name: "Old Savings", position: 1, isHidden: true)
    let visibleSavings = acct(name: "Savings", position: 2)
    let accounts = Accounts(from: [chequing, hiddenSavings, visibleSavings])

    var draft = TransactionDraft(accountId: chequing.id, instrument: aud)
    draft.legDrafts = [
      TransactionDraft.LegDraft(
        type: .expense, accountId: chequing.id, amountText: "100",
        categoryId: nil, categoryText: "", earmarkId: nil, instrument: aud)
    ]

    draft.setType(.transfer, accounts: accounts)

    let counterpart = try #require(draft.counterpartLeg)
    #expect(counterpart.accountId == visibleSavings.id)
  }
}
