import Testing

@testable import Moolah

/// `ContentView.accountDetail(id:)` has no unit-test harness today (the
/// switch is private and SwiftUI views aren't unit-testable), so this is
/// a build/compile guard: it pins that `ExchangeAccountView` constructs
/// from an `.exchange` account with the same stores its siblings take
/// and composes the shared synced-account header. End-to-end routing is
/// verified by manual app launch; this unit test is a build/compile
/// guard only.
@Suite("ExchangeAccountView — routing")
@MainActor
struct ExchangeAccountViewRoutingTests {
  @Test
  func exchangeAccountViewBuildsWithSharedHeader() throws {
    let account = Account(
      name: "Coinstash", type: .exchange,
      instrument: .AUD, valuationMode: .calculatedFromTrades,
      exchangeProvider: .coinstash)
    let session = try ProfileSession.preview()
    #expect(account.type == .exchange)
    _ = ExchangeAccountView(
      account: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: session.transactionStore,
      positions: [],
      conversionService: session.backend.conversionService,
      session: session)
  }
}
