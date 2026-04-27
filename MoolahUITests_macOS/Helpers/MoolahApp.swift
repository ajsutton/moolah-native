import XCTest

/// Driver entrypoint for UI tests. Owns the underlying `XCUIApplication`,
/// launches it with the `--ui-testing` argument and the chosen seed, and
/// exposes typed screen drivers as properties.
///
/// Tests interact with the app **only** through this type and the screen
/// drivers it returns — never `XCUIElement` or `XCUIApplication` directly.
/// See `guides/UI_TEST_GUIDE.md` §2 (the screen-driver rule).
@MainActor
final class MoolahApp {
  let application: XCUIApplication
  let seed: UITestSeed
  /// Back-reference set by `MoolahUITestCase.launch(seed:)` so drivers can
  /// request an immediate failure snapshot via
  /// `app.testCase?.captureFailureSnapshot(reason:)` before calling
  /// `XCTFail` — useful when a click silently misses the target and the
  /// regular `tearDown` snapshot fires too late to show what was on
  /// screen at the click.
  weak var testCase: MoolahUITestCase?

  /// The standard launch entrypoint used by tests:
  ///
  ///   let app = MoolahApp.launch(seed: .tradeBaseline)
  ///
  /// Always pair with `MoolahApp` returned to a local — never store on the
  /// test class. The application is terminated automatically by
  /// `MoolahUITestCase.tearDown`.
  static func launch(seed: UITestSeed) -> MoolahApp {
    let application = XCUIApplication()
    application.launchArguments = ["--ui-testing"]
    application.launchEnvironment = ["UI_TESTING_SEED": seed.rawValue]
    application.launch()
    let app = MoolahApp(application: application, seed: seed)
    app.expectMainWindowVisible()
    return app
  }

  init(application: XCUIApplication, seed: UITestSeed) {
    self.application = application
    self.seed = seed
  }

  // MARK: - Screen drivers

  /// Sidebar containing accounts, named views, and earmarks.
  var sidebar: SidebarScreen { SidebarScreen(app: self) }

  /// First-run `WelcomeView` state machine (hero / form / picker).
  var welcome: WelcomeScreen { WelcomeScreen(app: self) }

  /// Centre column listing transactions for the current sidebar selection.
  var transactionList: TransactionListScreen { TransactionListScreen(app: self) }

  /// Right column or sheet showing a single transaction's editable detail.
  var transactionDetail: TransactionDetailScreen { TransactionDetailScreen(app: self) }

  /// System dialogs (alerts, delete confirmations, error sheets).
  var dialogs: DialogScreen { DialogScreen(app: self) }

  /// First-run hero surface (`WelcomeHero`). Available when the app is in
  /// a welcome / first-run state (no active profile yet).
  var welcomeHero: WelcomeHeroScreen { WelcomeHeroScreen(app: self) }

  /// Sidebar sync-progress footer (`SyncProgressFooter`). Available when a
  /// profile is active and the sidebar is visible.
  var syncFooter: SyncFooterScreen { SyncFooterScreen(app: self) }

  /// `CreateAccountView` sheet. Open it by calling `createAccount.open(...)`.
  var createAccount: CreateAccountScreen { CreateAccountScreen(app: self) }

  // MARK: - Single element resolver

  /// All identifier lookups in the driver layer go through this method, by
  /// rule. One place to add logging, change resolution strategy, or
  /// future-proof the lookup mechanism.
  func element(for identifier: String) -> XCUIElement {
    application.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Keyboard shortcut entrypoint for drivers. Drivers must route keyboard
  /// events through this method rather than reaching into `application`
  /// directly — the single seam keeps `MoolahApp` as the only surface the
  /// driver layer talks to (mirrors `element(for:)`).
  func pressKeyboardShortcut(_ key: String, modifiers: XCUIElement.KeyModifierFlags = []) {
    application.typeKey(key, modifierFlags: modifiers)
  }

  // MARK: - Helpers used by drivers and `MoolahUITestCase`

  /// Bounded wait for an element with the given identifier to exist. Used
  /// by drivers and by `MoolahUITestCase.waitForIdentifier(_:timeout:)`.
  /// Default 3 s — see `guides/UI_TEST_GUIDE.md` §3 invariant 1.
  @discardableResult
  func waitForElement(identifier: String, timeout: TimeInterval = 3) -> Bool {
    element(for: identifier).waitForExistence(timeout: timeout)
  }

  /// Waits up to `timeout` seconds for the main profile window to appear,
  /// then ensures the app is the foreground process so subsequent
  /// keyboard / focus assertions reflect a real interactive session
  /// (the launcher → profile-window handoff under `--ui-testing` can
  /// briefly hand activation back to the test runner).
  /// Called automatically from `launch(seed:)`; drivers reuse it after
  /// actions that re-create the window.
  ///
  /// The 30 s default is the standard CI-friendly waiting budget — GitHub-
  /// hosted macos-26 runners are slow on cold start, often taking 15 s+
  /// before SwiftUI's launcher → profile-window handoff completes (issue
  /// #493). The deterministic part of the fix is in
  /// `UITestingLauncherView`: keeping the launcher around eliminates the
  /// open/dismiss race that previously left the app windowless. This
  /// timeout is then the upper bound on launch-plus-render, not on a
  /// race recovery window.
  func expectMainWindowVisible(timeout: TimeInterval = 30) {
    if !application.windows.firstMatch.waitForExistence(timeout: timeout) {
      Trace.recordFailure("main window did not appear within \(timeout)s")
      XCTFail("Moolah main window did not appear within \(timeout)s of launch")
      return
    }
    application.activate()
  }
}
