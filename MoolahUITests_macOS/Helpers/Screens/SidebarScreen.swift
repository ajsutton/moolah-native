import XCTest

/// Symbolic reference to a sidebar account. Tests reference accounts by
/// name; the driver maps each case to the seeded UUID.
enum SidebarAccount {
  case checking
  case brokerage
  /// The Brokerage account from the `.tradeReady` seed (different UUID from
  /// `.brokerage`, which uses the `.tradeBaseline` seed fixture).
  case tradeReadyBrokerage

  /// The fixed UUID written to the seeded `ProfileContainerManager` by
  /// `UITestSeedHydrator`.
  var id: UUID {
    switch self {
    case .checking: return UITestFixtures.TradeBaseline.checkingAccountId
    case .brokerage: return UITestFixtures.TradeBaseline.brokerageAccountId
    case .tradeReadyBrokerage: return UITestFixtures.TradeReady.brokerageAccountId
    }
  }
}

/// Driver for the sidebar (left column on macOS): account list, named
/// views (Upcoming, Analysis, etc.), earmarks. Returned from
/// `MoolahApp.sidebar`.
@MainActor
struct SidebarScreen {
  let app: MoolahApp

  /// Switches the centre column to the transactions of the given account.
  /// Returns once the transaction-list container is in the accessibility
  /// tree for the new selection — the user-visible "list re-rendered"
  /// post-condition cited as the example for invariant 1 in
  /// `guides/UI_TEST_GUIDE.md`. `exists` (not `isHittable`) is the
  /// correct predicate: on macOS a SwiftUI `List(selection:)` renders as
  /// an `NSTableView`-backed view whose container element is never
  /// reported as hittable — only its rows are — so polling on
  /// `isHittable` would always time out, even when the list has rendered.
  func switchToAccount(_ account: SidebarAccount) {
    Trace.record(detail: "account=\(account)")
    let identifier = UITestIdentifiers.Sidebar.account(account.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(identifier)' did not appear")
      XCTFail("Sidebar row for account \(account) did not appear within 3s")
      return
    }
    row.click()

    let listContainer = app.element(for: UITestIdentifiers.TransactionList.container)
    if !listContainer.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "transaction list container '\(UITestIdentifiers.TransactionList.container)' "
          + "did not appear after switching to \(account)")
      XCTFail(
        "Transaction list did not render within 3s of switching to account \(account)")
    }
  }
}
