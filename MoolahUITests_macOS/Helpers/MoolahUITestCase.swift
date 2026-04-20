import XCTest

/// Base class for every UI test in `MoolahUITests_macOS`. Wires up the
/// failure-artefact regime defined in `guides/UI_TEST_GUIDE.md` §5:
///
///   tree.txt        accessibility-tree dump (one element per line, columns)
///   screenshot.png  full window snapshot
///   seed.txt        seed name + fixture metadata
///   trace.txt       breadcrumb of driver actions, with ✓/✗ outcome marks
///
/// Each artefact is attached to the `XCTestCase` result *and* mirrored to
/// `.agent-tmp/ui-fail-<TestName>/` under the repo root so an agent can
/// debug a failure without spelunking `.xcresult` bundles.
///
/// Tests inherit this class directly:
///
///   @MainActor
///   final class MyTests: MoolahUITestCase { ... }
@MainActor
class MoolahUITestCase: XCTestCase {
  /// The most recently launched `MoolahApp`, captured by `launch(seed:)`
  /// so `tearDown` can collect artefacts and terminate the process.
  fileprivate(set) var lastApp: MoolahApp?

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
    Trace.reset()
  }

  /// Launches the Moolah app under `--ui-testing` with the given seed and
  /// registers it with this test case so the failure-artefact regime
  /// (`tree.txt`, `screenshot.png`, `seed.txt`, `trace.txt`) fires on
  /// failure.
  ///
  /// Tests use this exclusively rather than constructing a `MoolahApp`
  /// directly:
  ///
  ///   let app = launch(seed: .tradeBaseline)
  func launch(seed: UITestSeed) -> MoolahApp {
    let app = MoolahApp.launch(seed: seed)
    lastApp = app
    return app
  }

  override func tearDown() async throws {
    if let app = lastApp {
      let succeeded = (testRun?.failureCount ?? 0) == 0
      collectFailureArtefacts(for: app, succeeded: succeeded)
      app.application.terminate()
    }
    lastApp = nil
    try await super.tearDown()
  }

  // MARK: - Driver-internal primitives
  //
  // These are intentionally `internal` so screen drivers in this target can
  // call them. **Tests must not call them directly** — see
  // `guides/UI_TEST_GUIDE.md` §2 (the screen-driver rule). The
  // `ui-test-review` agent flags any test that does.

  /// Bounded wait for an element to appear in the accessibility tree.
  /// Default 3 s. Returns `true` on success; on failure, fails the test
  /// and records the trace before returning `false`.
  @discardableResult
  func waitForIdentifier(_ identifier: String, timeout: TimeInterval = 3) -> Bool {
    guard let app = lastApp else {
      XCTFail("waitForIdentifier called before MoolahApp.launch(seed:)")
      return false
    }
    if app.waitForElement(identifier: identifier, timeout: timeout) { return true }
    Trace.recordFailure("waitForIdentifier '\(identifier)' timed out")
    XCTFail("Identifier '\(identifier)' did not appear within \(timeout)s")
    return false
  }

  /// Asserts that the element with the given identifier currently has
  /// keyboard focus. Drivers use this to back `expectFocused()`.
  func assertFocused(_ identifier: String) {
    guard let app = lastApp else {
      XCTFail("assertFocused called before MoolahApp.launch(seed:)")
      return
    }
    let element = app.element(for: identifier)
    if !element.exists {
      Trace.recordFailure("assertFocused: identifier '\(identifier)' not found")
      XCTFail("assertFocused: element '\(identifier)' not in accessibility tree")
      return
    }
    let hasFocus = (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    if !hasFocus {
      Trace.recordFailure("assertFocused: '\(identifier)' is not focused")
      XCTFail("Element '\(identifier)' did not have keyboard focus")
    }
  }

  /// Types text into the element with the given identifier. Drivers wrap
  /// this with their own action method (e.g. `AutocompleteFieldDriver.type`).
  func typeInto(_ identifier: String, text: String) {
    guard let app = lastApp else {
      XCTFail("typeInto called before MoolahApp.launch(seed:)")
      return
    }
    let element = app.element(for: identifier)
    if !element.waitForExistence(timeout: 3) {
      Trace.recordFailure("typeInto: '\(identifier)' not found")
      XCTFail("typeInto: element '\(identifier)' did not appear within 3s")
      return
    }
    element.click()
    element.typeText(text)
  }

  /// Sends a keyboard key press to the focused element with optional
  /// modifiers. Drivers use this to back `pressArrowDown()`, `pressEnter()`,
  /// etc.
  func pressKey(_ key: XCUIKeyboardKey, modifiers: XCUIElement.KeyModifierFlags = []) {
    guard let app = lastApp else {
      XCTFail("pressKey called before MoolahApp.launch(seed:)")
      return
    }
    app.application.typeKey(key, modifierFlags: modifiers)
  }

  // MARK: - Internal: artefact collection

  private func collectFailureArtefacts(for app: MoolahApp, succeeded: Bool) {
    if succeeded { return }

    let dir = artefactDirectory(for: name)
    do {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    } catch {
      // Recording the failure to attach is itself best-effort; keep going.
      add(XCTAttachment(string: "Failed to create artefact dir: \(error)"))
      return
    }

    // Print the path so `scripts/test-ui.sh` can grep it out and copy the
    // artefacts back into `.agent-tmp/`, and attach an XCTAttachment so the
    // test navigator surfaces it.
    print("[MoolahUITestCase] ARTEFACT_DIR \(dir.path)")
    add(XCTAttachment(string: "ui-fail artefacts written to: \(dir.path)\n"))

    write(treeText(for: app), to: dir.appendingPathComponent("tree.txt"))
    write(seedText(for: app), to: dir.appendingPathComponent("seed.txt"))
    write(Trace.render(succeeded: false), to: dir.appendingPathComponent("trace.txt"))
    captureScreenshot(for: app, to: dir.appendingPathComponent("screenshot.png"))

    attachArtefacts(in: dir)
  }

  /// Resolves `/private/tmp/MoolahUITests/ui-fail-<TestName>/`.
  ///
  /// The XCUITest runner is sandboxed and cannot write to the developer's
  /// `Documents` folder; `NSTemporaryDirectory()` returns the runner's
  /// container-private tmp dir, which the host shell can only read with
  /// extra TCC prompts. `/private/tmp/` is the system-wide tmp folder,
  /// readable and writable by both the sandboxed runner and the host
  /// shell without any TCC interaction. `scripts/test-ui.sh` greps the
  /// `[MoolahUITestCase] ARTEFACT_DIR` lines out of xcodebuild's stdout
  /// and copies each artefact dir back into `<repo-root>/.agent-tmp/`
  /// after `xcodebuild test` exits.
  private func artefactDirectory(for testName: String) -> URL {
    let cleanName =
      testName
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: "[", with: "")
      .replacingOccurrences(of: "]", with: "")
      .replacingOccurrences(of: " ", with: "_")
    return URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("MoolahUITests", isDirectory: true)
      .appendingPathComponent("ui-fail-\(cleanName)", isDirectory: true)
  }

  // MARK: - Artefact contents

  private func treeText(for app: MoolahApp) -> String {
    var lines: [String] = []
    lines.append("# accessibility tree (identifier | type | label | value | frame)")
    if let focusedIdentifier = currentFocusedIdentifier(in: app) {
      lines.append("# focused element: \(focusedIdentifier)")
    } else {
      lines.append("# focused element: (none — no element has keyboard focus)")
    }
    lines.append(
      "# (per-element focus is omitted — `XCUIElementSnapshot` does not expose it.)")
    lines.append("")
    let snapshot = try? app.application.snapshot()
    if let snapshot { appendTreeSnapshot(snapshot: snapshot, depth: 0, into: &lines) }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Walks the live element tree once to find the currently focused
  /// element, returning its identifier (or label / type if no identifier
  /// is set). At most one element has keyboard focus at a time.
  private func currentFocusedIdentifier(in app: MoolahApp) -> String? {
    let elements = app.application.descendants(matching: .any).allElementsBoundByIndex
    for element in elements where (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false {
      if !element.identifier.isEmpty { return element.identifier }
      if !element.label.isEmpty { return "(label: \(element.label))" }
      return "(\(element.elementType))"
    }
    return nil
  }

  private func appendTreeSnapshot(
    snapshot: XCUIElementSnapshot, depth: Int, into lines: inout [String]
  ) {
    let indent = String(repeating: "  ", count: depth)
    let identifier = snapshot.identifier.isEmpty ? "—" : snapshot.identifier
    let type = String(describing: snapshot.elementType)
    let label =
      snapshot.label.isEmpty ? "—" : snapshot.label.replacingOccurrences(of: "\n", with: " ")
    let value = (snapshot.value as? String).map { $0.isEmpty ? "—" : $0 } ?? "—"
    let frame = snapshot.frame
    let frameStr =
      "(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.size.width))x\(Int(frame.size.height)))"
    lines.append(
      "\(indent)\(identifier) | \(type) | \(label) | \(value) | \(frameStr)"
    )
    for child in snapshot.children {
      appendTreeSnapshot(snapshot: child, depth: depth + 1, into: &lines)
    }
  }

  private func seedText(for app: MoolahApp) -> String {
    var lines: [String] = []
    lines.append("seed: \(app.seed.rawValue)")
    lines.append("")
    switch app.seed {
    case .tradeBaseline:
      let f = UITestFixtures.TradeBaseline.self
      lines.append("# fixtures")
      lines.append("profile.id      = \(f.profileId)")
      lines.append("profile.label   = \(f.profileLabel)")
      lines.append("profile.currency = \(f.profileCurrencyCode)")
      lines.append("checking.id     = \(f.checkingAccountId)")
      lines.append("checking.name   = \(f.checkingAccountName)")
      lines.append("brokerage.id    = \(f.brokerageAccountId)")
      lines.append("brokerage.name  = \(f.brokerageAccountName)")
      lines.append("trade.id        = \(f.bhpPurchaseId)")
      lines.append("trade.payee     = \(f.bhpPurchasePayee)")
      lines.append("trade.cents     = \(f.bhpPurchaseAmountCents)")
      lines.append("trade.date      = \(f.bhpPurchaseDate)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func captureScreenshot(for app: MoolahApp, to url: URL) {
    let screenshot = app.application.screenshot()
    do {
      try screenshot.pngRepresentation.write(to: url)
    } catch {
      add(XCTAttachment(string: "Failed to write screenshot: \(error)"))
    }
  }

  private func write(_ text: String, to url: URL) {
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      add(XCTAttachment(string: "Failed to write \(url.lastPathComponent): \(error)"))
    }
  }

  private func attachArtefacts(in dir: URL) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    else { return }
    for url in entries {
      let attachment = XCTAttachment(contentsOfFile: url)
      attachment.lifetime = .keepAlways
      attachment.name = url.lastPathComponent
      add(attachment)
    }
  }
}
