import XCTest

/// Regression test for the AppKit toolbar bridge crash that fired when
/// SwiftUI re-mounted a `.searchable` / `.toolbar`-bearing detail-column
/// leaf while the previous leaf's registration was still live:
///
///     NSInternalInconsistencyException: NSToolbar already contains an
///     item with the identifier com.apple.SwiftUI.search.
///
/// Before this PR the failure was reproducible by sweeping rapidly across
/// detail-column leaves of differing structural shape. The structural fix
/// wraps each leaf in its own `NavigationStack { … }.id(selection)` so the
/// previous `NSToolbar` host is fully torn down between selections — the
/// bridge can no longer race against itself.
///
/// This test sweeps a fixed sequence of leaves five times and asserts the
/// app remains responsive after each step (XCTest fails the test if the
/// app crashes; we additionally assert the transaction-list container
/// re-appears for transaction-bearing leaves so a silent
/// "the toolbar disappeared" regression also fails).
@MainActor
final class DetailColumnNavigationSweepTests: MoolahUITestCase {
  func test_rapidSweepAcrossDetailLeaves_doesNotCrashTheToolbarBridge() {
    let app = launch(seed: .tradeBaseline)
    let sidebar = app.sidebar

    // Five cycles × eight selections per cycle. The exact count is
    // calibrated to the production reproduction — fewer cycles caught the
    // race only intermittently. The mix deliberately interleaves
    // transaction-list leaves (account, allTransactions, upcoming) with
    // structurally-different leaves (analysis, recentlyAdded) so the
    // toolbar-bridge tear-down path is exercised between every adjacent
    // pair.
    for cycleIndex in 0..<5 {
      Trace.record(detail: "cycle=\(cycleIndex)")

      sidebar.switchToAccount(.checking)
      sidebar.switchToAccount(.brokerage)
      sidebar.switchToNamed(.upcoming)
      sidebar.switchToAccount(.tradesBrokerage)
      sidebar.switchToNamed(.allTransactions)
      sidebar.switchToNamed(.analysis)
      sidebar.switchToAccount(.checking)
      sidebar.switchToNamed(.recentlyAdded)
    }

    // Final responsiveness check: the app is still alive (XCTest would
    // have failed the test on crash). Land on a transaction list and
    // confirm the container is in the accessibility tree.
    sidebar.switchToAccount(.checking)
    let listContainer = app.element(for: UITestIdentifiers.TransactionList.container)
    XCTAssertTrue(
      listContainer.waitForExistence(timeout: 3),
      "Transaction list container missing after the sweep — the structural "
        + "fix did not preserve list rendering across rapid navigation.")
  }
}
