import Foundation

/// String identifiers applied via `.accessibilityIdentifier(_:)` in views and
/// looked up by UI-test drivers via `MoolahApp.element(for:)`.
///
/// Compiled into both the main app and the `MoolahUITests_macOS` target so
/// the two sides reference the same constants — edit in one place.
///
/// Naming format: `area.element[.qualifier]`. Lowercase, dot-separated. New
/// areas extend this enum rather than introducing parallel naming schemes.
///
/// Identifiers are added incrementally as drivers and tests need them — see
/// `guides/UI_TEST_GUIDE.md` §4.
public enum UITestIdentifiers {
  public enum Sidebar {
    /// Sidebar row for a specific account. `id` is the account's UUID, lowercased.
    ///
    /// The same UUID identifier is applied whether the account renders in
    /// the Current Accounts section or the Investments section — `AccountType`
    /// today is mutually exclusive across the two sections (bank/cc/asset
    /// for Current; investment for Investments). If a future account type
    /// can appear in both sections, switch this to a sectioned namespace
    /// (`sidebar.account.current.<uuid>` vs `sidebar.account.investment.<uuid>`)
    /// to avoid duplicates resolving via `firstMatch`.
    public static func account(_ id: UUID) -> String {
      "sidebar.account.\(id.uuidString.lowercased())"
    }

    /// Sidebar row for a named top-level view (e.g. `"upcoming"`, `"analysis"`).
    public static func view(_ name: String) -> String {
      "sidebar.view.\(name)"
    }
  }

  public enum TransactionList {
    /// Centre-column row for a specific transaction. `id` is the
    /// transaction's UUID, lowercased.
    public static func transaction(_ id: UUID) -> String {
      "transactionlist.transaction.\(id.uuidString.lowercased())"
    }
  }

  public enum Detail {
    /// Payee text field on the transaction detail surface.
    public static let payee = "detail.payee"

    /// Picker that sets the counterpart account for a transfer (the "To
    /// Account" or "From Account" picker depending on `showFromAccount`).
    /// Only rendered when `draft.type == .transfer`.
    public static let toAccountPicker = "detail.toAccountPicker"

    /// Counterpart amount text field. Only rendered when the transfer is
    /// cross-currency (primary and counterpart legs' accounts have
    /// different instruments).
    public static let counterpartAmount = "detail.counterpartAmount"

    /// Instrument code label next to the counterpart amount field (e.g.
    /// "USD"). Rendered in the same row as `counterpartAmount`.
    public static let counterpartAmountInstrument = "detail.counterpartAmount.instrument"

    /// Category text field in the simple-mode (single-leg) category section.
    /// Only rendered when the transaction is in simple (`!isCustom`) mode.
    public static let category = "detail.category"

    /// Category text field inside the given leg section. Only rendered when
    /// the transaction is in multi-leg (`isCustom`) mode.
    public static func legCategory(_ index: Int) -> String {
      "detail.leg.\(index).category"
    }
  }

  public enum Autocomplete {
    /// Container element of the payee autocomplete dropdown.
    public static let payee = "autocomplete.payee"

    /// Indexed payee suggestion row inside the dropdown.
    public static func payeeSuggestion(_ index: Int) -> String {
      "autocomplete.payee.suggestion.\(index)"
    }

    /// Container element of the simple-mode category autocomplete dropdown.
    /// Only rendered when the transaction is in simple (`!isCustom`) mode.
    public static let category = "autocomplete.category"

    /// Indexed category suggestion row inside the simple-mode dropdown.
    public static func categorySuggestion(_ index: Int) -> String {
      "autocomplete.category.suggestion.\(index)"
    }

    /// Container element of the category autocomplete dropdown for the given
    /// leg. Only one leg's category dropdown is visible at a time; the
    /// identifier reflects whichever leg is active. Only rendered in multi-leg
    /// (`isCustom`) mode.
    public static func legCategory(_ legIndex: Int) -> String {
      "autocomplete.leg.\(legIndex).category"
    }

    /// Indexed category suggestion row inside the given leg's dropdown.
    public static func legCategorySuggestion(_ legIndex: Int, _ rowIndex: Int) -> String {
      "autocomplete.leg.\(legIndex).category.suggestion.\(rowIndex)"
    }
  }
}
