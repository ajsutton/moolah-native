import XCTest

/// Verifies the `WelcomeHero` surface while iCloud data is actively
/// downloading. Drives the app with the `.welcomeDownloading` seed, which
/// sets `SyncProgress.recordsReceivedThisSession = 1234` before launch so
/// `WelcomeView` resolves to the `.heroDownloading(received: 1234)` state.
@MainActor
final class WelcomeDownloadingUITests: MoolahUITestCase {

  /// Verifies the downloading copy, the de-emphasised CTA, and the
  /// background-download footnote all appear together in the hero.
  func testWelcomeShowsDownloadingMessageAndAlternateButton() {
    let app = launch(seed: .welcomeDownloading)

    app.welcomeHero.expectDownloadingStatus(containing: "1,234")
    app.welcomeHero.expectCreateNewButtonVisible()
    app.welcomeHero.expectDownloadFootnoteVisible()
  }
}
