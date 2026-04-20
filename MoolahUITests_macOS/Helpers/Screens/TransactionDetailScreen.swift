import XCTest

/// Driver for the transaction detail view (right column or sheet).
/// Exposes typed sub-drivers for each editable field; tests never reach
/// `XCUIElement` directly. See `guides/UI_TEST_GUIDE.md` §3 (driver
/// invariants).
@MainActor
struct TransactionDetailScreen {
  let app: MoolahApp

  /// Driver for the payee field — a text field with autocomplete dropdown.
  var payee: AutocompleteFieldDriver {
    AutocompleteFieldDriver(
      app: app,
      fieldIdentifier: UITestIdentifiers.Detail.payee,
      dropdownIdentifier: UITestIdentifiers.Autocomplete.payee,
      suggestionIdentifier: UITestIdentifiers.Autocomplete.payeeSuggestion(_:)
    )
  }
}
