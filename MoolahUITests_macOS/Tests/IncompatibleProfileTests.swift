import XCTest

/// End-to-end test for the data-format-gate stop-the-world view: the
/// `.incompatibleProfile` seed hydrates one compatible and one
/// incompatible profile so the multi-profile picker renders, the test
/// taps the incompatible row, and `IncompatibleProfileView`'s heading
/// and both buttons must appear. Refs #764.
@MainActor
final class IncompatibleProfileTests: MoolahUITestCase {
  func testShowsUpdateRequiredViewWhenProfileIsIncompatible() throws {
    let app = launch(seed: .incompatibleProfile)

    app.welcome.waitForPicker()
    app.welcome.tapPickerRow(forProfile: UITestIncompatibleProfileFixtures.profileId)

    app.incompatibleProfile.expectVisible()
    app.incompatibleProfile.expectCheckForUpdatesVisible()
    app.incompatibleProfile.expectSwitchProfileVisible()
  }
}
