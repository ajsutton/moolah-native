import XCTest

/// The first UI test in the new `MoolahUITests_macOS` target: proves the app
/// can launch with `--ui-testing` and the `UI_TESTING_SEED=tradeBaseline`
/// environment variable, i.e. the whole PR #4 scaffolding works end-to-end.
///
/// Intentionally bare. The proper test-case base class (`MoolahUITestCase`
/// with failure artefacts and screen drivers) lands in PR #5; real behaviour
/// tests land in PR #6 and beyond. Keeping the smoke test here gives CI
/// something to run before the richer infrastructure is in place.
@MainActor
final class UITestingLaunchSmokeTests: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
  }

  func testAppLaunchesWithTradeBaselineSeed() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment = ["UI_TESTING_SEED": UITestSeed.tradeBaseline.rawValue]
    app.launch()

    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 10),
      "Moolah did not reach runningForeground within 10 s of launch"
    )

    // Terminate cleanly so the next test in the queue gets a fresh process.
    app.terminate()
  }
}
