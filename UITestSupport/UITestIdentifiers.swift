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
/// `guides/UI_TEST_GUIDE.md` §4. The namespaces below are stubs awaiting
/// entries from the first driver PR.
public enum UITestIdentifiers {
  public enum Sidebar {
    /// Sidebar row for a specific account. `id` is the account's UUID, lowercased.
    public static func account(_ id: UUID) -> String {
      "sidebar.account.\(id.uuidString.lowercased())"
    }

    /// Sidebar row for a named top-level view (e.g. `"upcoming"`, `"analysis"`).
    public static func view(_ name: String) -> String {
      "sidebar.view.\(name)"
    }
  }

  public enum Detail {
    // Intentionally empty — populated when TransactionDetailScreen lands.
  }

  public enum Autocomplete {
    // Intentionally empty — populated when AutocompleteFieldDriver lands.
  }
}
