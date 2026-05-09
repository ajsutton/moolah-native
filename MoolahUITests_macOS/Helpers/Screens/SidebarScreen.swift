import XCTest

/// Symbolic reference to a sidebar account. Tests reference accounts by
/// name; the driver maps each case to the seeded UUID.
enum SidebarAccount {
  case checking
  case brokerage
  /// `.tradeBaseline`'s second investment account: `.calculatedFromTrades`
  /// mode with no `InvestmentValue` snapshots. Drives the
  /// "picker hidden for new trade-driven accounts" branch in
  /// `EditAccountValuationPickerTests`.
  case tradesBrokerage
  /// The Brokerage account from the `.tradeReady` seed (different UUID from
  /// `.brokerage`, which uses the `.tradeBaseline` seed fixture).
  case tradeReadyBrokerage

  /// The fixed UUID written to the seeded `ProfileContainerManager` by
  /// `UITestSeedHydrator`.
  var id: UUID {
    switch self {
    case .checking: return UITestFixtures.TradeBaseline.checkingAccountId
    case .brokerage: return UITestFixtures.TradeBaseline.brokerageAccountId
    case .tradesBrokerage: return UITestFixtures.TradeBaseline.tradesBrokerageAccountId
    case .tradeReadyBrokerage: return UITestFixtures.TradeReady.brokerageAccountId
    }
  }
}

/// Symbolic reference to a named sidebar leaf (Upcoming, All Transactions,
/// Recently Added, Analysis, Reports, Categories). The `rawValue` is the
/// suffix passed to `UITestIdentifiers.Sidebar.view(_:)`, so it must
/// match the identifier the production view applies in
/// `SidebarView.navigationSection`. `upcoming` deliberately differs from
/// the underlying `SidebarSelection.upcomingTransactions` case — the
/// short identifier mirrors the visible "Upcoming" label.
enum SidebarNamedItem: String {
  case upcoming
  case allTransactions
  case recentlyAdded
  case analysis
  case reports
  case categories
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

  /// Switches the centre column to the named top-level view.
  ///
  /// Returns once the named row's click resolves. For `allTransactions`
  /// — the only named item that renders a `TransactionListView` (via
  /// `AllTransactionsView`) — also waits on
  /// `UITestIdentifiers.TransactionList.container` as a post-condition.
  /// For the others (`upcoming`, `recentlyAdded`, `analysis`, `reports`,
  /// `categories`) the leaf is its own custom surface (e.g.
  /// `RecentlyAddedView`, `UpcomingView`) with no shared identifier, so
  /// the next driver call's `waitForExistence` provides natural
  /// quiescence — per `UI_TEST_GUIDE.md`'s no-sleep rule, no explicit
  /// sleep is added.
  func switchToNamed(_ item: SidebarNamedItem) {
    Trace.record(detail: "named=\(item.rawValue)")
    let identifier = UITestIdentifiers.Sidebar.view(item.rawValue)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(identifier)' did not appear")
      XCTFail("Sidebar row for named item \(item.rawValue) did not appear within 3s")
      return
    }
    row.click()

    // Post-condition for `allTransactions`, the only named leaf that
    // renders a `TransactionListView`: wait on the canonical list
    // container so the test exits this driver call only after the leaf
    // has rendered.
    switch item {
    case .allTransactions:
      let listContainer = app.element(for: UITestIdentifiers.TransactionList.container)
      if !listContainer.waitForExistence(timeout: 3) {
        Trace.recordFailure(
          "transaction list container did not appear after switching to \(item.rawValue)")
        XCTFail("Transaction list did not render within 3s after \(item.rawValue)")
      }
    case .upcoming, .recentlyAdded, .analysis, .reports, .categories:
      // No shared identifier — see docstring.
      break
    }
  }
}
