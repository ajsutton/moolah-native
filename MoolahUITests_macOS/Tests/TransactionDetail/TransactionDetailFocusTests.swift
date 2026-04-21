import XCTest

/// Behaviour tests for keyboard focus on `TransactionDetailView`.
@MainActor
final class TransactionDetailFocusTests: MoolahUITestCase {
  func testOpeningTradeFocusesPayee() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)

    app.transactionDetail.payee.expectFocused()
  }
}
