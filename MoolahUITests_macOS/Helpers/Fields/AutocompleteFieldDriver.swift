import XCTest

/// Reusable driver for any text field whose accessibility identifier
/// matches `<area>.<element>` and whose autocomplete dropdown matches
/// `autocomplete.<element>`. Use one for each autocomplete-bearing field
/// (payee, category, etc.).
///
/// Each action method starts with `Trace.record(#function)` and waits
/// for a real post-condition before returning — see
/// `guides/UI_TEST_GUIDE.md` §3 (driver invariants).
@MainActor
struct AutocompleteFieldDriver {
  let app: MoolahApp
  let fieldIdentifier: String
  let dropdownIdentifier: String
  let suggestionIdentifier: (Int) -> String

  // MARK: - Actions

  /// Types `text` into the field. Returns once the field's reported value
  /// reflects the typed text.
  func type(_ text: String) {
    Trace.record(detail: "field=\(fieldIdentifier) text=\"\(text)\"")
    let field = app.element(for: fieldIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("field '\(fieldIdentifier)' did not appear")
      XCTFail("Autocomplete field '\(fieldIdentifier)' did not appear within 3s")
      return
    }
    field.click()
    field.typeText(text)

    // Post-condition: the field reports back a value containing the typed
    // text. (`SwiftUI` text field values are exposed via the `value`
    // accessor.)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let value = field.value as? String, value.contains(text) { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("field value did not propagate after typing")
    XCTFail("Autocomplete field value did not contain '\(text)' within 3s")
  }

  /// Sends a single arrow-down key press to the field.
  func pressArrowDown() {
    Trace.record(detail: "field=\(fieldIdentifier)")
    app.application.typeKey(.downArrow, modifierFlags: [])
  }

  /// Sends a single Return key press to the field.
  func pressEnter() {
    Trace.record(detail: "field=\(fieldIdentifier)")
    app.application.typeKey(.return, modifierFlags: [])
  }

  /// Sends a single Escape key press to the field.
  func pressEscape() {
    Trace.record(detail: "field=\(fieldIdentifier)")
    app.application.typeKey(.escape, modifierFlags: [])
  }

  // MARK: - Expectations (read-only)

  /// Asserts the field currently holds keyboard focus.
  func expectFocused() {
    let field = app.element(for: fieldIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("field '\(fieldIdentifier)' not present for focus check")
      XCTFail("Autocomplete field '\(fieldIdentifier)' did not appear within 3s")
      return
    }
    let hasFocus = (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    if !hasFocus {
      Trace.recordFailure("field '\(fieldIdentifier)' is not focused")
      XCTFail("Autocomplete field '\(fieldIdentifier)' did not have keyboard focus")
    }
  }

  /// Asserts the field's current value equals `expected`.
  func expectValue(_ expected: String) {
    let field = app.element(for: fieldIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("field '\(fieldIdentifier)' not present for value check")
      XCTFail("Autocomplete field '\(fieldIdentifier)' did not appear within 3s")
      return
    }
    let actual = (field.value as? String) ?? ""
    if actual != expected {
      Trace.recordFailure("field value '\(actual)' != '\(expected)'")
      XCTFail("Autocomplete field expected value '\(expected)', got '\(actual)'")
    }
  }

  /// Asserts the autocomplete dropdown is currently visible and contains
  /// the given number of suggestions. Polls until the count matches and
  /// stays stable, because suggestions render asynchronously after the
  /// dropdown appears.
  func expectSuggestionsVisible(count: Int) {
    let dropdown = app.element(for: dropdownIdentifier)
    if !dropdown.waitForExistence(timeout: 3) {
      Trace.recordFailure("dropdown '\(dropdownIdentifier)' did not appear")
      XCTFail("Autocomplete dropdown '\(dropdownIdentifier)' did not appear within 3s")
      return
    }
    let deadline = Date().addingTimeInterval(3)
    var lastFound = -1
    while Date() < deadline {
      var found = 0
      while app.element(for: suggestionIdentifier(found)).exists {
        found += 1
        if found > 200 { break }  // safety cap; suggestions are bounded by view
      }
      if found == count { return }
      lastFound = found
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("expected \(count) suggestions, last seen \(lastFound)")
    XCTFail("Autocomplete dropdown had \(lastFound) suggestions, expected \(count)")
  }

  /// Asserts the autocomplete dropdown is hidden.
  func expectSuggestionsHidden() {
    // Wait briefly for hide to settle, then assert.
    let dropdown = app.element(for: dropdownIdentifier)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if !dropdown.exists { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("dropdown '\(dropdownIdentifier)' still visible after 3s")
    XCTFail("Autocomplete dropdown '\(dropdownIdentifier)' did not hide within 3s")
  }

  /// Asserts the suggestion at `index` is currently highlighted.
  func expectHighlightedSuggestion(at index: Int) {
    let identifier = suggestionIdentifier(index)
    let suggestion = app.element(for: identifier)
    if !suggestion.waitForExistence(timeout: 3) {
      Trace.recordFailure("suggestion '\(identifier)' not present")
      XCTFail("Autocomplete suggestion at index \(index) did not appear within 3s")
      return
    }
    let isSelected = (suggestion.value(forKey: "isSelected") as? Bool) ?? false
    if !isSelected {
      Trace.recordFailure("suggestion '\(identifier)' is not highlighted")
      XCTFail("Autocomplete suggestion at index \(index) is not highlighted")
    }
  }
}
