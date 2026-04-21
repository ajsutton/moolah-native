import XCTest

/// Read-only driver for the counterpart amount field that only renders
/// when a transfer is cross-currency. Exposes visibility and
/// instrument-label expectations — no typing action is needed by the
/// v1 test suite.
@MainActor
struct CounterpartAmountDriver {
  let app: MoolahApp

  /// Waits up to `timeout` seconds for the counterpart amount field to
  /// appear, then asserts the adjacent instrument label matches.
  func expectVisible(instrumentCode: String, timeout: TimeInterval = 3) {
    let field = app.element(for: UITestIdentifiers.Detail.counterpartAmount)
    if !field.waitForExistence(timeout: timeout) {
      Trace.recordFailure("counterpart amount field did not appear")
      XCTFail(
        "Counterpart amount field '\(UITestIdentifiers.Detail.counterpartAmount)' "
          + "did not appear within \(timeout)s")
      return
    }
    let instrumentLabel = app.element(
      for: UITestIdentifiers.Detail.counterpartAmountInstrument)
    if !instrumentLabel.waitForExistence(timeout: timeout) {
      Trace.recordFailure("counterpart instrument label did not appear")
      XCTFail(
        "Counterpart instrument label '\(UITestIdentifiers.Detail.counterpartAmountInstrument)' "
          + "did not appear within \(timeout)s")
      return
    }
    // Poll — the Text's content is exposed via `value` (not `label`) once
    // an `.accessibilityIdentifier` is attached, and it updates via
    // `.onChange` after the account picker selection propagates.
    let deadline = Date().addingTimeInterval(timeout)
    var lastValue = ""
    while Date() < deadline {
      lastValue = (instrumentLabel.value as? String) ?? ""
      if lastValue == instrumentCode { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure(
      "counterpart instrument label was '\(lastValue)' (expected '\(instrumentCode)')")
    XCTFail(
      "Counterpart instrument label expected '\(instrumentCode)', got '\(lastValue)' within \(timeout)s"
    )
  }

  /// Asserts the counterpart amount field is not in the accessibility
  /// tree (same-currency transfer — field is conditionally compiled out).
  func expectHidden(timeout: TimeInterval = 3) {
    let field = app.element(for: UITestIdentifiers.Detail.counterpartAmount)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !field.exists { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("counterpart amount field still visible after \(timeout)s")
    XCTFail("Counterpart amount field should be hidden but was visible within \(timeout)s")
  }
}
