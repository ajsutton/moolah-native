import XCTest

/// End-to-end tests for `EditAccountView`'s Valuation-mode picker
/// visibility rule:
///
/// - A legacy investment account in `.recordedValue` mode that has at
///   least one `InvestmentValue` snapshot SHOWS the picker (preselected
///   to "Recorded value", with the correct accessibility hint).
/// - A new investment account in `.calculatedFromTrades` mode with no
///   snapshots HIDES the picker entirely.
///
/// Both scenarios are seeded by the `.tradeBaseline` fixture in
/// `UITestFixtures.TradeBaseline` (Stage 4 of the implementation plan).
/// The behaviour under test is in `EditAccountView` and its resolver
/// `EditAccountView.resolvePickerVisibility(...)`. See
/// `plans/2026-05-05-restrict-valuation-picker-design.md` §2.
@MainActor
final class EditAccountValuationPickerTests: MoolahUITestCase {
  func testRecordedValueLegacyAccountShowsValuationPicker() {
    let app = launch(seed: .tradeBaseline)

    app.editAccount.open(account: .brokerage)
    app.editAccount.expectValuationSectionVisible()
    app.editAccount.cancel()
  }

  func testRecordedValueLegacyAccountPreselectsRecordedValue() {
    let app = launch(seed: .tradeBaseline)

    app.editAccount.open(account: .brokerage)
    app.editAccount.expectValuationMode(EditAccountScreen.Mode.recordedValue)
    app.editAccount.cancel()
  }

  // Note: there is no UI test for the picker's `.accessibilityHint`.
  // macOS XCUITest does not surface `accessibilityHint` as a
  // queryable XCUIElement attribute (it is a VoiceOver-only concept
  // that the runtime delivers through speech, not the accessibility
  // tree). The hint copy is pinned by
  // `ValuationModeDisplayTextTests.dataSourceHint_returnsExpectedString`
  // at the model layer; manual VoiceOver verification covers the
  // propagation path.

  func testCalculatedFromTradesAccountWithNoSnapshotsHidesValuationPicker() {
    let app = launch(seed: .tradeBaseline)

    app.editAccount.open(account: .tradesBrokerage)
    app.editAccount.expectVisible()
    app.editAccount.expectValuationSectionAbsent()
    app.editAccount.cancel()
  }

  /// End-to-end coverage for flipping the picker. Brokerage starts in
  /// `.recordedValue` mode (one snapshot in the seed). Flipping it to
  /// `.calculatedFromTrades` and saving must persist — re-opening shows
  /// the new selection. Pairs with `AccountStoreUpdateValuationTests` at
  /// the store layer; this test exercises the picker click path the
  /// store-level test does not cover.
  func testFlippingValuationModePersists() {
    let app = launch(seed: .tradeBaseline)

    app.editAccount.open(account: .brokerage)
    app.editAccount.expectValuationMode(EditAccountScreen.Mode.recordedValue)
    app.editAccount.selectValuationMode(EditAccountScreen.Mode.calculatedFromTrades)
    app.editAccount.save()

    app.editAccount.open(account: .brokerage)
    app.editAccount.expectValuationMode(EditAccountScreen.Mode.calculatedFromTrades)
    app.editAccount.cancel()
  }
}
