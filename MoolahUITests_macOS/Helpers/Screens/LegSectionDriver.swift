import XCTest

/// Driver for a single sub-transaction (leg) section inside the
/// multi-leg (`isCustom`) transaction detail view. Returned from
/// `TransactionDetailScreen.leg(_:)` — see `guides/UI_TEST_GUIDE.md` §7.
@MainActor
struct LegSectionDriver {
  let app: MoolahApp
  let legIndex: Int

  /// Category autocomplete field for this leg. Identifiers follow the
  /// `detail.leg.<index>.category` / `autocomplete.leg.<index>.category`
  /// naming — the dropdown identifier reflects whichever leg is active
  /// because `legCategoryOverlay` only renders one dropdown at a time.
  var category: AutocompleteFieldDriver {
    AutocompleteFieldDriver(
      app: app,
      fieldIdentifier: UITestIdentifiers.Detail.legCategory(legIndex),
      dropdownIdentifier: UITestIdentifiers.Autocomplete.legCategory(legIndex),
      suggestionIdentifier: { rowIndex in
        UITestIdentifiers.Autocomplete.legCategorySuggestion(legIndex, rowIndex)
      }
    )
  }
}
