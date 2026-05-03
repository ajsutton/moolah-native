import XCTest

/// Driver for the first-run `WelcomeView` state machine. Returned from
/// `MoolahApp.welcome`. Covers hero, create-profile form, and the
/// multi-profile picker. Per `guides/UI_TEST_GUIDE.md`, tests never
/// touch `XCUIElement` directly — every UI action routes through this
/// driver.
@MainActor
struct WelcomeScreen {
  let app: MoolahApp

  /// Waits for the hero "Get started" button to be visible. Used at
  /// the start of first-run tests to confirm the state machine landed
  /// in `.heroChecking` / `.heroNoneFound` / `.heroOff` rather than
  /// auto-activating.
  func waitForHero(timeout: TimeInterval = 5) {
    Trace.record()
    let button = app.element(for: UITestIdentifiers.Welcome.heroGetStartedButton)
    if !button.waitForExistence(timeout: timeout) {
      Trace.recordFailure("hero 'Get started' button did not appear")
      XCTFail("Welcome hero did not appear within \(timeout)s")
    }
  }

  /// Post-condition for auto-open paths (single cloud profile, etc.)
  /// where the hero must never appear. Waits up to `timeout` for the
  /// hero CTA to be absent and fails if it ever shows up.
  func expectHeroAbsent(timeout: TimeInterval = 5) {
    Trace.record()
    let hero = app.element(for: UITestIdentifiers.Welcome.heroGetStartedButton)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: hero
    )
    if XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed {
      Trace.recordFailure("hero 'Get started' button appeared unexpectedly")
      XCTFail("Welcome hero appeared within \(timeout)s when it should have stayed hidden")
    }
  }

  /// Waits for the multi-profile picker to be visible. The picker is
  /// identified by its "+ Create a new profile" footer row.
  func waitForPicker(timeout: TimeInterval = 5) {
    Trace.record()
    let row = app.element(for: UITestIdentifiers.Welcome.pickerCreateNewRow)
    if !row.waitForExistence(timeout: timeout) {
      Trace.recordFailure("picker create-new row did not appear")
      XCTFail("Multi-profile picker did not appear within \(timeout)s")
    }
  }

  /// Number of profile rows visible in the picker. Rows are identified
  /// by the `welcome.picker.row.` prefix followed by a UUID.
  func pickerRowCount() -> Int {
    let prefix = "welcome.picker.row."
    let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
    return app.application.buttons.matching(predicate).count
  }

  /// Taps "Get started" and waits for the create-profile Name field to
  /// appear.
  func tapGetStarted() {
    Trace.record()
    app.element(for: UITestIdentifiers.Welcome.heroGetStartedButton).click()
    let nameField = app.element(for: UITestIdentifiers.Welcome.nameField)
    if !nameField.waitForExistence(timeout: 3) {
      Trace.recordFailure("name field did not appear after tapGetStarted")
      XCTFail("Name field did not appear after tapping Get started")
    }
  }

  /// Types `name` into the Name field after giving it keyboard focus.
  func typeName(_ name: String) {
    Trace.record(detail: "name=\(name)")
    let field = app.element(for: UITestIdentifiers.Welcome.nameField)
    field.click()
    field.typeText(name)
  }

  /// Taps "Create Profile" and waits for the hero to disappear — the
  /// post-condition that the session has loaded.
  func tapCreateProfile() {
    Trace.record()
    app.element(for: UITestIdentifiers.Welcome.createProfileButton).click()
    expectHeroAbsent()
  }
}
