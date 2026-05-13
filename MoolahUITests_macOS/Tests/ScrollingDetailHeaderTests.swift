import XCTest

/// Verifies that detail-view leaves on macOS embed their top content
/// as a scrolling header inside the transaction list. Smoke-level —
/// asserts presence inside the list scroll surface, not the post-scroll
/// geometry (that requires a scroll-heavy seed; current seeds are
/// sparse).
@MainActor
final class ScrollingDetailHeaderTests: MoolahUITestCase {
  /// Opens the `brokerage` (legacy / recordedValue) investment account
  /// and asserts the `transactionlist.header` identifier resolves —
  /// proves the `topAccessory` slot is wired and the summary + chart
  /// block lives inside the List as a row, not above it.
  func testLegacyInvestmentAccountSurfacesScrollingHeader() {
    let app = launch(seed: .tradeBaseline)
    app.sidebar.switchToAccount(.brokerage)
    app.transactionList.expectHeaderVisible()
  }
}
