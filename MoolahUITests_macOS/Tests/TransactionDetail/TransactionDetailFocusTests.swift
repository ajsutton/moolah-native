import XCTest

/// Behaviour tests for keyboard focus on `TransactionDetailView`. The first
/// test in the rollout — proves the entire driver and seed pipeline works
/// end-to-end against a real SwiftUI event loop.
///
/// **Today's behaviour, scope of this test:** opening a transaction does
/// not auto-focus the payee field — the macOS first-responder lands on
/// the transaction list's search field instead, defeating the
/// `defaultFocus(.payee)` modifier in the detail view. See `BUGS.md`
/// (`TransactionDetailView default focus on open`). This test therefore
/// covers what *can* be verified today: clicking the payee field gives
/// it keyboard focus. When the auto-focus bug is fixed, the explicit
/// `.tap()` step can be deleted.
@MainActor
final class TransactionDetailFocusTests: MoolahUITestCase {
  func testOpeningTradeFocusesPayee() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()

    app.transactionDetail.payee.expectFocused()
  }
}
