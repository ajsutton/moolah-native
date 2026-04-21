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

  /// ⌘N is the keyboard entry-point for new transactions. The detail
  /// inspector must land first-responder on the payee field so the user
  /// can start typing immediately without clicking.
  func testCreatingTransactionFocusesPayee() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.createTransaction()

    app.transactionDetail.payee.expectFocused()
  }
}
