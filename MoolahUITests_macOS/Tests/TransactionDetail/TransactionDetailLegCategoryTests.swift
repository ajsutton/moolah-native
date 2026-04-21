import XCTest

/// Behaviour tests for the per-leg category autocomplete dropdown on
/// `TransactionDetailView` in multi-leg (`isCustom`) mode. The view must
/// keep each leg's dropdown isolated: typing in one leg only ever shows
/// that leg's dropdown — never another leg's — even when focus moves
/// between fields. The `.tradeBaseline` seed provides a two-leg expense
/// split ("Split Shop") from a single Checking account, plus two
/// categories ("Groceries", "Gym") so the prefix "G" yields two matches.
@MainActor
final class TransactionDetailLegCategoryTests: MoolahUITestCase {
  func testTypingInLegOneHidesLegZeroDropdown() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.splitShop)

    app.transactionDetail.leg(0).category.tap()
    app.transactionDetail.leg(0).category.type("G")
    app.transactionDetail.leg(0).category.expectSuggestionsVisible(count: 2)

    app.transactionDetail.leg(1).category.tap()
    app.transactionDetail.leg(0).category.expectSuggestionsHidden()

    app.transactionDetail.leg(1).category.type("G")
    app.transactionDetail.leg(1).category.expectSuggestionsVisible(count: 2)
    app.transactionDetail.leg(0).category.expectSuggestionsHidden()
  }
}
