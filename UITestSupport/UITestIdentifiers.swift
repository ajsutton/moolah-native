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
  }

  public enum Autocomplete {
    /// Container element of the payee autocomplete dropdown.
    public static let payee = "autocomplete.payee"

    /// Indexed payee suggestion row inside the dropdown.
    public static func payeeSuggestion(_ index: Int) -> String {
      "autocomplete.payee.suggestion.\(index)"
    }
  }
}
