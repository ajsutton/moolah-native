import Foundation
import Testing

@testable import Moolah

@Suite("LegDraft.resolvedInstrument(accounts:earmarks:)")
struct LegDraftResolvedInstrumentTests {
  private let accountId = UUID()
  private let earmarkId = UUID()

  private func makeLeg(accountId: UUID? = nil, earmarkId: UUID? = nil) -> TransactionDraft.LegDraft
  {
    TransactionDraft.LegDraft(
      type: .expense, accountId: accountId, amountText: "10",
      categoryId: nil, categoryText: "", earmarkId: earmarkId,
      instrument: nil)
  }

  private func makeAccounts(id: UUID, instrument: Instrument) -> Accounts {
    Accounts(from: [Account(id: id, name: "Test Account", type: .bank, instrument: instrument)])
  }

  private func makeEarmarks(id: UUID, instrument: Instrument) -> Earmarks {
    Earmarks(from: [Earmark(id: id, name: "Test Earmark", instrument: instrument)])
  }

  // swiftlint:disable:next attributes
  @Test func accountSetReturnsAccountInstrument() {
    let leg = makeLeg(accountId: accountId)
    let accounts = makeAccounts(id: accountId, instrument: .USD)
    let result = leg.resolvedInstrument(accounts: accounts, earmarks: Earmarks(from: []))
    #expect(result == .USD)
  }

  // swiftlint:disable:next attributes
  @Test func accountNilEarmarkSetReturnsEarmarkInstrument() {
    let leg = makeLeg(earmarkId: earmarkId)
    let earmarks = makeEarmarks(id: earmarkId, instrument: .USD)
    let result = leg.resolvedInstrument(accounts: Accounts(from: []), earmarks: earmarks)
    #expect(result == .USD)
  }

  // swiftlint:disable:next attributes
  @Test func accountWinsOverEarmark() {
    let leg = makeLeg(accountId: accountId, earmarkId: earmarkId)
    let accounts = makeAccounts(id: accountId, instrument: .USD)
    let earmarks = makeEarmarks(id: earmarkId, instrument: .AUD)
    let result = leg.resolvedInstrument(accounts: accounts, earmarks: earmarks)
    #expect(result == .USD)
  }

  // swiftlint:disable:next attributes
  @Test func bothNilFallsToAUD() {
    let leg = makeLeg()
    let result = leg.resolvedInstrument(accounts: Accounts(from: []), earmarks: Earmarks(from: []))
    #expect(result == .AUD)
  }

  // swiftlint:disable:next attributes
  @Test func unknownAccountIdFallsThroughToEarmark() {
    // accountId is set but not present in accounts — should fall through to earmark
    let leg = makeLeg(accountId: accountId, earmarkId: earmarkId)
    let earmarks = makeEarmarks(id: earmarkId, instrument: .USD)
    let result = leg.resolvedInstrument(accounts: Accounts(from: []), earmarks: earmarks)
    #expect(result == .USD)
  }

  @Test("Overload without earmarks returns account instrument when set")
  func overloadWithoutEarmarksReturnsAccountInstrument() {
    let usd = Instrument.fiat(code: "USD")
    let bankAccount = Account(
      id: accountId,
      name: "Bank",
      type: .bank,
      instrument: usd
    )
    let accounts = Accounts(from: [bankAccount])
    let leg = TransactionDraft.LegDraft(
      type: .trade,
      accountId: accountId,
      amountText: "0",
      categoryId: nil,
      categoryText: "",
      earmarkId: nil,
      instrument: nil
    )

    #expect(leg.resolvedInstrument(accounts: accounts) == usd)
    // Sanity check: also returns AUD when accounts is empty.
    #expect(leg.resolvedInstrument(accounts: Accounts(from: [])) == .AUD)
  }
}
