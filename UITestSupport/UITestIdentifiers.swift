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

    /// "New Account" toolbar button in the sidebar (macOS only).
    public static let newAccountButton = "sidebar.toolbar.newAccount"
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

  public enum SyncFooter {
    public static let container = "sync.footer.container"
    public static let label = "sync.footer.label"
    public static let detail = "sync.footer.detail"
  }

  public enum Welcome {
    /// "Get started" primary CTA on the first-run hero (states 1 and 4).
    public static let heroGetStartedButton = "welcome.hero.getStarted"
    /// "Create a new profile" alternate CTA shown while iCloud data is
    /// downloading (`.heroDownloading` state). De-emphasised relative to the
    /// normal "Get started" button.
    public static let heroCreateNewButton = "welcome.hero.createNew"
    /// Status line under the hero CTA showing iCloud download progress.
    /// Rendered by `ICloudStatusLine` in the `.checkingActive` state.
    public static let heroDownloadingStatus = "welcome.hero.downloadingStatus"
    /// Footnote below the hero CTA in the `.heroDownloading` state.
    public static let heroDownloadFootnote = "welcome.hero.downloadFootnote"
    /// Name text field in the create-profile form.
    public static let nameField = "welcome.create.nameField"
    /// "Create Profile" submit button in the create-profile form.
    public static let createProfileButton = "welcome.create.createButton"
    /// Profile row in the multi-profile picker. Suffix is the profile UUID,
    /// lowercased.
    public static func pickerRow(_ id: UUID) -> String {
      "welcome.picker.row.\(id.uuidString.lowercased())"
    }
    /// "+ Create a new profile" footer row in the multi-profile picker.
    public static let pickerCreateNewRow = "welcome.picker.createNew"
    /// "Open" action on the single-profile arrival banner.
    public static let bannerOpenAction = "welcome.banner.open"
    /// "View" action on the multi-profile arrival banner.
    public static let bannerViewAction = "welcome.banner.view"
    /// "Dismiss" action on any arrival banner.
    public static let bannerDismissAction = "welcome.banner.dismiss"
    /// "Open System Settings" link on the iCloud-off hero chip.
    public static let iCloudOffSystemSettingsLink = "welcome.off.systemSettings"
  }

  public enum InstrumentPicker {
    /// The field button that opens the instrument picker sheet. The qualifier
    /// is the currently selected instrument's id (e.g. `"AUD"`, `"USD"`).
    /// When the selection changes the identifier changes, so the post-condition
    /// check after a pick uses the *new* id.
    public static func field(_ id: String) -> String {
      "instrumentPicker.field.\(id)"
    }

    /// The sheet root presented by `InstrumentPickerSheet`. Appears when the
    /// field button is tapped and the CloudKit-backed picker is active.
    public static let sheet = "instrumentPicker.sheet"

    /// A row inside the sheet for a specific instrument. The qualifier is the
    /// instrument id (e.g. `"USD"`).
    public static func row(_ id: String) -> String {
      "instrumentPicker.row.\(id)"
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
