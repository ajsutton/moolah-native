import XCTest

/// First-run `WelcomeView` state-machine tests. Covers the three
/// cloud-profile-count paths — zero (hero + create), one (auto-open),
/// two (picker). Seeds are deterministic per
/// `UITestSupport/UITestSeed.swift`.
///
/// Design spec §7.4 also calls for `iCloudUnavailable` and mid-form
/// profile-arrival tests; those require additional infrastructure (an
/// iCloud-unavailable launch flag and a DEBUG-only "inject profile"
/// affordance) and are deferred to a follow-up task.
@MainActor
final class WelcomeViewTests: MoolahUITestCase {
  /// First-launch with an empty index container → user sees the
  /// branded hero, taps "Get started", fills in a name, and tapping
  /// "Create Profile" dismisses the hero (session window takes over).
  func testFirstLaunchWithNoCloudProfilesShowsHeroAndCreatesProfile() {
    let app = launch(seed: .welcomeEmpty)

    app.welcome.waitForHero()
    app.welcome.tapGetStarted()
    app.welcome.typeName("Household")
    app.welcome.tapCreateProfile()
  }

  /// One cloud profile present → `.autoActivateSingle` skips the hero
  /// and lands directly in the session. The post-condition is that
  /// the hero never appears.
  func testFirstLaunchWithOneCloudProfile_autoOpens() {
    let app = launch(seed: .welcomeSingleCloudProfile)

    app.welcome.expectHeroAbsent()
  }

  /// Two cloud profiles → the picker (state 5) is shown with both
  /// rows and the "+ Create a new profile" footer.
  func testFirstLaunchWithMultipleCloudProfiles_showsPicker() {
    let app = launch(seed: .welcomeMultipleCloudProfiles)

    app.welcome.waitForPicker()
    XCTAssertEqual(
      app.welcome.pickerRowCount(),
      2,
      "Expected two profile rows in the picker"
    )
  }
}
