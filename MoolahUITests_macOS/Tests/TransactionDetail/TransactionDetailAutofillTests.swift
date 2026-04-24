import XCTest

/// Behaviour tests for the payee-driven autofill on `TransactionDetailView`.
///
/// When the user selects a payee from the autocomplete dropdown on a *new*
/// transaction, the view looks up the most recent transaction for that
/// payee and copies its amount, type, and category into the draft. The
/// category field gets populated silently — the user never asked to
/// browse categories, so the category autocomplete dropdown must stay
/// closed. The previous bug let the background text-binding update fire
/// `onTextChange`, which opened the dropdown on top of whatever the user
/// was about to type next.
///
/// The `.tradeBaseline` seed attaches `groceriesCategoryId` to the most
/// recent "Woolworths" entry so autofill has a category to copy.
@MainActor
final class TransactionDetailAutofillTests: MoolahUITestCase {
  func testSelectingPayeeAutofillsCategoryWithoutOpeningPicker() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.createTransaction()
    app.transactionDetail.payee.tap()
    app.transactionDetail.payee.type("Wool")
    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)

    // Arrow-down highlights "Woolworths" (the more frequent, thus
    // higher-ranked, suggestion), Return accepts it → autofill runs.
    app.transactionDetail.payee.pressArrowDown()
    app.transactionDetail.payee.expectHighlightedSuggestion(at: 0)
    app.transactionDetail.payee.pressEnter()
    app.transactionDetail.payee.expectValue("Woolworths")

    // Post-autofill: category text must reflect the prior "Woolworths"
    // transaction's category. Waiting on the value gates the assertion
    // until autofill completes — it's the only observable signal that
    // the async fetch-and-apply has flowed through the view tree.
    app.transactionDetail.category.expectValue("Groceries")

    // The bug under test: the category dropdown must not have opened as
    // a side-effect of autofill writing to the category text binding.
    app.transactionDetail.category.expectSuggestionsHidden()
  }
}
