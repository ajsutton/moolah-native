import XCTest

/// Verifies that detail-view leaves on macOS embed their top content
/// as a scrolling header inside the transaction list. Smoke-level —
/// asserts presence of the `transactionlist.header` identifier inside
/// the List scroll surface. Post-scroll geometry (header translates
/// off-screen as the user scrolls) is intentionally out of scope; the
/// rendering invariant is already covered by the `mcp__xcode__RenderPreview`
/// validation in the implementation plan.
@MainActor
final class ScrollingDetailHeaderTests: MoolahUITestCase {
  /// Opens the `brokerage` (legacy / recordedValue) investment account
  /// and asserts the `transactionlist.header` identifier resolves —
  /// proves the `topAccessory` slot is wired into the List. Doesn't
  /// assert the accessory has rendered any specific content (spec
  /// always-emit-Section invariant means the identifier resolves even
  /// for an `EmptyView` accessory).
  func testLegacyInvestmentAccountWiresTopAccessorySlotInTransactionList() {
    let app = launch(seed: .tradeBaseline)
    app.sidebar.switchToAccount(.brokerage)
    app.transactionList.expectHeaderVisible()
  }
}
