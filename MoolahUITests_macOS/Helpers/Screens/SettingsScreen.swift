import XCTest

/// Driver for the macOS Settings scene. Returned from `MoolahApp.settings`.
///
/// The Settings scene is opened via the system Cmd+, shortcut and presents
/// a `TabView` containing the Profiles, Crypto, Import, and Rules tabs.
/// Each tab is rendered as a toolbar button labelled with its tab title;
/// tab content drivers hang off this screen (e.g. `openCryptoTab()`).
///
/// Each action method starts with `Trace.record(#function)` and waits for
/// a real post-condition before returning — see
/// `guides/UI_TEST_GUIDE.md` §3 (driver invariants).
@MainActor
struct SettingsScreen {
  let app: MoolahApp

  // MARK: - Actions

  /// Opens the Settings scene via the system Cmd+, shortcut and waits
  /// until the Settings window's tab toolbar is visible. The toolbar's
  /// "Crypto" tab button is the post-condition because every UI-testing
  /// launch we exercise has a CloudKit profile active, so the Crypto tab
  /// is always present in this scene.
  func open() {
    Trace.record(#function)
    app.pressKeyboardShortcut(",", modifiers: .command)
    let cryptoTab = app.application.toolbars.buttons["Crypto"]
    if !cryptoTab.waitForExistence(timeout: 5) {
      Trace.recordFailure("Settings 'Crypto' tab toolbar button did not appear")
      XCTFail("Settings window did not appear within 5s of Cmd+,")
    }
  }

  /// Switches the Settings TabView to the Crypto tab and waits for the
  /// `CryptoSettingsView`'s root container to appear in the accessibility
  /// tree.
  func openCryptoTab() {
    Trace.record(#function)
    let tab = app.application.toolbars.buttons["Crypto"]
    if !tab.waitForExistence(timeout: 3) {
      Trace.recordFailure("Settings 'Crypto' tab toolbar button did not appear")
      XCTFail("Crypto tab toolbar button did not appear within 3s")
      return
    }
    tab.click()
    let container = app.element(for: UITestIdentifiers.CryptoSettings.container)
    if !container.waitForExistence(timeout: 3) {
      Trace.recordFailure("crypto.settings.container did not appear after tab click")
      XCTFail("CryptoSettingsView container did not appear within 3s of tab click")
    }
  }
}
