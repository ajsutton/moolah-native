import XCTest

/// Behaviour tests for the payee autocomplete dropdown on
/// `TransactionDetailView`. Covers: show on typing, hide on clearing,
/// arrow-key highlight + Return commit, and Escape reset. The `.tradeBaseline`
/// seed includes historical expenses with prefix "Wool" (Woolworths ×2,
/// Woolworths Metro ×1) plus a Coles expense and the BHP trade so every
/// prefix has a deterministic result set.
@MainActor
final class TransactionDetailPayeeAutocompleteTests: MoolahUITestCase {
  func testTypingPrefixShowsDropdown() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.clear()
    app.transactionDetail.payee.type("Wool")

    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)
  }

  func testClearingFieldHidesDropdown() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.clear()
    app.transactionDetail.payee.type("Wool")
    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)

    app.transactionDetail.payee.clear()

    app.transactionDetail.payee.expectSuggestionsHidden()
  }

  func testArrowDownThenReturnSelectsFirstSuggestion() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.clear()
    app.transactionDetail.payee.type("Wool")
    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)

    app.transactionDetail.payee.pressArrowDown()
    app.transactionDetail.payee.expectHighlightedSuggestion(at: 0)
    app.transactionDetail.payee.pressEnter()

    app.transactionDetail.payee.expectValue("Woolworths")
    app.transactionDetail.payee.expectSuggestionsHidden()
  }

  func testEscapeClearsPayeeAndClosesDropdown() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.clear()
    app.transactionDetail.payee.type("Wool")
    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)

    app.transactionDetail.payee.pressEscape()

    app.transactionDetail.payee.expectValue("")
    app.transactionDetail.payee.expectSuggestionsHidden()
  }
}
