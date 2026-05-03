import XCTest

/// Driver for the trade-mode editor in `TransactionDetailView`. Returned from
/// `MoolahApp.tradeForm`. Covers mode-switching, Paid/Received leg editing,
/// and fee management.
///
/// All action methods start with `Trace.record(#function, …)` and wait for a
/// real post-condition before returning — see `guides/UI_TEST_GUIDE.md` §3.
@MainActor
struct TradeFormDriver {
  let app: MoolahApp

  // MARK: - Mode switching

  /// Taps the Type picker (a macOS popup button) to open the native menu, then
  /// selects "Trade". Returns once the Paid amount field appears, proving the
  /// view re-rendered in trade mode.
  func switchToTradeMode() {
    Trace.record(#function)
    let picker = app.element(for: UITestIdentifiers.Detail.modeTypePicker)
    if !picker.waitForExistence(timeout: 3) {
      Trace.recordFailure("modeTypePicker did not appear")
      XCTFail("Type picker '\(UITestIdentifiers.Detail.modeTypePicker)' did not appear within 3s")
      return
    }
    picker.click()

    // ui-test-review: allow single-resolver — on macOS, SwiftUI Pickers open
    // a native NSMenu whose items attach to the application's menu hierarchy
    // at runtime as descendants of the popUpButton. Their AX labels are
    // empty (the inline `Text(…)` inside the ForEach doesn't propagate to
    // the NSMenuItem), so label-based lookup is unavailable; positional
    // indexing scoped to the picker is the only stable handle. The
    // production picker is built from
    // `[.income, .expense, .transfer, .trade, .custom]`, so Trade is at
    // index 3. Scoping to `picker.menuItems` excludes the static
    // `Transaction > Type ▸ Trade` menu-bar entry, which descends from the
    // app's menu bar, not the popUpButton.
    let tradeItem = picker.menuItems.element(boundBy: 3)
    if !tradeItem.waitForExistence(timeout: 3) {
      Trace.recordFailure("popup menu item at index 3 did not appear after opening type picker")
      XCTFail("Picker popup item at index 3 (Trade) did not appear within 3s of opening")
      return
    }
    tradeItem.click()

    // Post-condition: the Paid amount field must exist, proving the view
    // switched to trade mode.
    let paidField = app.element(for: UITestIdentifiers.Detail.tradePaidAmount)
    if !paidField.waitForExistence(timeout: 3) {
      Trace.recordFailure("tradePaidAmount did not appear after switching to Trade mode")
      XCTFail(
        "Trade mode did not render: '\(UITestIdentifiers.Detail.tradePaidAmount)' "
          + "did not appear within 3s")
    }
  }

  // MARK: - Paid leg

  /// Clears and types `amount` into the Paid amount field, then opens the
  /// instrument picker via the `tradePaidInstrument` container and picks
  /// `instrumentId`. Returns once `instrumentPicker.field.<instrumentId>`
  /// exists, proving the selection propagated.
  func setPaid(amount: String, instrumentId: String) {
    Trace.record(#function, detail: "amount=\(amount) instrument=\(instrumentId)")
    setAmountField(UITestIdentifiers.Detail.tradePaidAmount, to: amount)
    setInstrument(
      containerIdentifier: UITestIdentifiers.Detail.tradePaidInstrument,
      instrumentId: instrumentId)
  }

  // MARK: - Received leg

  /// Clears and types `amount` into the Received amount field, then opens the
  /// instrument picker via the `tradeReceivedInstrument` container and picks
  /// `instrumentId`. Returns once `instrumentPicker.field.<instrumentId>`
  /// exists, proving the selection propagated.
  func setReceived(amount: String, instrumentId: String) {
    Trace.record(#function, detail: "amount=\(amount) instrument=\(instrumentId)")
    setAmountField(UITestIdentifiers.Detail.tradeReceivedAmount, to: amount)
    setInstrument(
      containerIdentifier: UITestIdentifiers.Detail.tradeReceivedInstrument,
      instrumentId: instrumentId)
  }

  // MARK: - Fee management

  /// Taps "+ Add Fee", enters `amount` into the fee amount field (at
  /// `feeDisplayIndex`), changes the fee instrument if it differs from "AUD",
  /// and commits `category` via the fee leg's category autocomplete dropdown.
  ///
  /// - Parameters:
  ///   - feeDisplayIndex: Zero-based index corresponding to
  ///     `UITestIdentifiers.Detail.tradeFeeAmount(_:)`. For the first fee, pass 0.
  ///   - feeLegIndex: Absolute `legDrafts` index of the fee leg. For a fresh
  ///     trade with two `.trade` legs, the first fee lands at index 2.
  func addFee(
    amount: String,
    instrumentId: String,
    category: String,
    feeDisplayIndex: Int = 0,
    feeLegIndex: Int = 2
  ) {
    Trace.record(
      #function,
      detail: "amount=\(amount) instrument=\(instrumentId) category=\(category)")

    // Tap "+ Add Fee".
    let addFeeButton = app.element(for: UITestIdentifiers.Detail.tradeAddFeeButton)
    if !addFeeButton.waitForExistence(timeout: 3) {
      Trace.recordFailure("tradeAddFeeButton did not appear")
      XCTFail(
        "Add Fee button '\(UITestIdentifiers.Detail.tradeAddFeeButton)' did not appear within 3s")
      return
    }
    addFeeButton.click()

    // Wait for the fee amount field (proves the fee row inserted).
    let feeAmountId = UITestIdentifiers.Detail.tradeFeeAmount(feeDisplayIndex)
    let feeAmountField = app.element(for: feeAmountId)
    if !feeAmountField.waitForExistence(timeout: 3) {
      Trace.recordFailure("fee amount field '\(feeAmountId)' did not appear after tapping Add Fee")
      XCTFail("Fee amount field '\(feeAmountId)' did not appear within 3s of tapping Add Fee")
      return
    }

    // Enter the fee amount.
    setAmountField(feeAmountId, to: amount)

    // Change the fee instrument (the fee's InstrumentPickerField shows
    // `instrumentPicker.field.<currentId>` on the inner button; because no
    // separate container identifier is set on the fee's picker, locate the
    // button directly via `instrumentPicker.field.AUD` — the fee always
    // defaults to AUD on a fresh Brokerage account).
    if instrumentId != "AUD" {
      setInstrument(containerIdentifier: nil, fieldId: "AUD", instrumentId: instrumentId)
    }

    // Enter the category via the leg's autocomplete field.
    let categoryDriver = AutocompleteFieldDriver(
      app: app,
      fieldIdentifier: UITestIdentifiers.Detail.legCategory(feeLegIndex),
      dropdownIdentifier: UITestIdentifiers.Autocomplete.legCategory(feeLegIndex),
      suggestionIdentifier: { rowIndex in
        UITestIdentifiers.Autocomplete.legCategorySuggestion(feeLegIndex, rowIndex)
      }
    )
    categoryDriver.tap()
    categoryDriver.type(category)
    categoryDriver.expectSuggestionsVisible(count: 1)
    categoryDriver.pressArrowDown()
    categoryDriver.expectHighlightedSuggestion(at: 0)
    categoryDriver.pressEnter()
  }

  // MARK: - Post-condition waits

  /// Waits for a transaction list row whose accessibility label contains
  /// `marker` to appear, up to `timeout` seconds. Trade rows combine
  /// children so the accessibility label is `"Trade, <title>, <amount>,
  /// <date>"` — the trade-title sentence is in the middle, not at the
  /// start, hence `CONTAINS` rather than `BEGINSWITH`. Routes through
  /// `MoolahApp.staticTexts(matching:)` / `cells(matching:)` — the
  /// documented escape hatch from `element(for:)` for label-substring
  /// scans where no stable per-row identifier exists.
  func waitForTradeRow(containing marker: String, timeout: TimeInterval = 10) {
    Trace.record(#function, detail: "marker=\(marker)")
    let predicate = NSPredicate(format: "label CONTAINS %@", marker)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !app.staticTexts(matching: predicate).isEmpty { return }
      if !app.cells(matching: predicate).isEmpty { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    Trace.recordFailure("no row containing '\(marker)' after \(timeout)s")
    XCTFail("No transaction row containing '\(marker)' appeared within \(timeout)s")
  }

  // MARK: - Private helpers

  /// Clears any existing text in `identifier` and types `text`. Returns once
  /// the field's `value` contains `text`.
  private func setAmountField(_ identifier: String, to text: String) {
    let field = app.element(for: identifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("amount field '\(identifier)' did not appear")
      XCTFail("Amount field '\(identifier)' did not appear within 3s")
      return
    }
    field.click()
    app.pressKeyboardShortcut("a", modifiers: .command)
    field.typeText(text)

    // Post-condition: field reports the typed value. Failure to converge
    // within 3 s is a real driver/product bug — fail loudly so the trace
    // points at the right action, mirroring `AutocompleteFieldDriver.type(_:)`.
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let value = field.value as? String, value.contains(text) { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure(
      "amount field '\(identifier)' did not contain '\(text)' within 3s")
    XCTFail("Amount field '\(identifier)' did not contain '\(text)' within 3s")
  }

  /// Opens the `InstrumentPickerSheet` by clicking either `containerIdentifier`
  /// (when the outer view has an explicit identifier) or the inner field button
  /// `instrumentPicker.field.<fieldId>`. Then searches for and picks `instrumentId`.
  private func setInstrument(
    containerIdentifier: String?,
    fieldId: String = "AUD",
    instrumentId: String
  ) {
    // Tap the picker button to open the sheet.
    let button: XCUIElement
    if let container = containerIdentifier {
      button = app.element(for: container)
    } else {
      button = app.element(for: UITestIdentifiers.InstrumentPicker.field(fieldId))
    }
    if !button.waitForExistence(timeout: 3) {
      Trace.recordFailure("instrument picker button did not appear")
      XCTFail("Instrument picker button did not appear within 3s")
      return
    }
    button.click()

    // Wait for the sheet to appear.
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    if !sheet.waitForExistence(timeout: 3) {
      Trace.recordFailure("instrumentPicker.sheet did not appear after tap")
      XCTFail("InstrumentPickerSheet did not appear within 3s of tapping the picker button")
      return
    }

    // Search and pick.
    let searchField = app.element(for: UITestIdentifiers.InstrumentPicker.searchField)
    if !searchField.waitForExistence(timeout: 3) {
      Trace.recordFailure("instrumentPicker.searchField did not appear")
      XCTFail("InstrumentPickerSheet search field did not appear within 3s")
      return
    }
    searchField.click()
    searchField.typeText(instrumentId)

    let row = app.element(for: UITestIdentifiers.InstrumentPicker.row(instrumentId))
    if !row.waitForExistence(timeout: 5) {
      Trace.recordFailure("instrumentPicker.row.\(instrumentId) did not appear after search")
      XCTFail(
        "InstrumentPickerSheet row for '\(instrumentId)' did not appear within 5s of searching")
      return
    }
    row.click()

    // Post-condition: sheet must dismiss.
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if !sheet.exists { break }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if sheet.exists {
      Trace.recordFailure("instrumentPicker.sheet did not dismiss after picking '\(instrumentId)'")
      XCTFail("InstrumentPickerSheet did not dismiss within 3s of picking '\(instrumentId)'")
    }
  }
}

// MARK: - MoolahApp + TradeFormDriver

extension MoolahApp {
  /// Driver for the trade-mode section of the transaction detail inspector.
  var tradeForm: TradeFormDriver { TradeFormDriver(app: self) }
}
