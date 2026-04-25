import XCTest

/// Driver for `InstrumentPickerField` — the button that opens the searchable
/// instrument picker sheet when a CloudKit-backed profile is active.
///
/// Each action method starts with `Trace.record(#function)` and waits for a
/// real post-condition before returning — see
/// `guides/UI_TEST_GUIDE.md` §3 (driver invariants).
///
/// Usage:
///   app.createAccount.currency.tap(currentId: "AUD")
///   app.createAccount.currency.expectSheetVisible()
///   app.createAccount.currency.search("USD")
///   app.createAccount.currency.pickRow("USD")
///   app.createAccount.currency.expectFieldSelection("USD")
@MainActor
struct InstrumentPickerFieldDriver {
  let app: MoolahApp

  // MARK: - Actions

  /// Taps the picker field button (currently showing `currentId`) to open
  /// the instrument picker sheet. Returns once `instrumentPicker.sheet` is
  /// visible in the accessibility tree.
  func tap(currentId: String) {
    Trace.record(#function, detail: "currentId=\(currentId)")
    let button = app.element(for: UITestIdentifiers.InstrumentPicker.field(currentId))
    if !button.waitForExistence(timeout: 3) {
      Trace.recordFailure("field button 'instrumentPicker.field.\(currentId)' did not appear")
      XCTFail(
        "InstrumentPickerField button for '\(currentId)' did not appear within 3s")
      return
    }
    button.click()
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    if !sheet.waitForExistence(timeout: 3) {
      Trace.recordFailure("instrumentPicker.sheet did not appear after tapping field")
      XCTFail("InstrumentPickerSheet did not appear within 3s of tapping the field button")
    }
  }

  /// Types `query` into the sheet's `.searchable` field. Returns once the
  /// row for `query` exists in the list (proving the search result propagated).
  func search(_ query: String) {
    Trace.record(#function, detail: "query=\(query)")
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    if !sheet.waitForExistence(timeout: 3) {
      Trace.recordFailure("instrumentPicker.sheet not present for search")
      XCTFail("InstrumentPickerSheet did not appear before searching")
      return
    }
    // The searchable modifier renders a search field inside the sheet.
    // On macOS the search field is accessible via the sheet's descendants.
    let searchField = sheet.searchFields.firstMatch
    if !searchField.waitForExistence(timeout: 3) {
      Trace.recordFailure("search field inside instrumentPicker.sheet did not appear")
      XCTFail("InstrumentPickerSheet search field did not appear within 3s")
      return
    }
    searchField.click()
    searchField.typeText(query)

    // Post-condition: the row for the searched id must appear in the list.
    let row = app.element(for: UITestIdentifiers.InstrumentPicker.row(query))
    if !row.waitForExistence(timeout: 5) {
      Trace.recordFailure(
        "instrumentPicker.row.\(query) did not appear after searching '\(query)'")
      XCTFail(
        "InstrumentPickerSheet row for '\(query)' did not appear within 5s of searching")
    }
  }

  /// Taps the row for `instrumentId` inside the sheet. Returns once the
  /// sheet has dismissed (proven by `instrumentPicker.sheet` disappearing
  /// from the accessibility tree).
  func pickRow(_ instrumentId: String) {
    Trace.record(#function, detail: "instrumentId=\(instrumentId)")
    let row = app.element(for: UITestIdentifiers.InstrumentPicker.row(instrumentId))
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("instrumentPicker.row.\(instrumentId) not found for pick")
      XCTFail("InstrumentPickerSheet row for '\(instrumentId)' did not appear within 3s")
      return
    }
    row.click()

    // Post-condition: the sheet must dismiss after the pick.
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if !sheet.exists { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("instrumentPicker.sheet did not dismiss after picking '\(instrumentId)'")
    XCTFail("InstrumentPickerSheet did not dismiss within 3s of picking '\(instrumentId)'")
  }

  // MARK: - Expectations (read-only)

  /// Asserts the picker sheet is currently visible.
  func expectSheetVisible() {
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    if !sheet.waitForExistence(timeout: 3) {
      Trace.recordFailure("instrumentPicker.sheet not visible")
      XCTFail("InstrumentPickerSheet was not visible within 3s")
    }
  }

  /// Asserts the field button now shows `instrumentId` as the selection —
  /// i.e. `instrumentPicker.field.<instrumentId>` exists in the tree.
  /// Polls for up to 3 s for the SwiftUI state binding to propagate.
  func expectFieldSelection(_ instrumentId: String) {
    let identifier = UITestIdentifiers.InstrumentPicker.field(instrumentId)
    let button = app.element(for: identifier)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if button.exists { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure(
      "field button 'instrumentPicker.field.\(instrumentId)' did not appear after pick")
    XCTFail(
      "InstrumentPickerField did not update to '\(instrumentId)' within 3s of picking")
  }
}
