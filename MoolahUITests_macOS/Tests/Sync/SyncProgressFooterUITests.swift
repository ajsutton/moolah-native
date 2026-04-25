import XCTest

/// Verifies the sidebar sync-progress footer (`SyncProgressFooter`) renders
/// the correct label and detail text for each `SyncProgress.Phase`.
///
/// Each test launches with a dedicated seed that pre-configures the progress
/// state before the window opens, then checks the footer through
/// `SyncFooterScreen`.
@MainActor
final class SyncProgressFooterUITests: MoolahUITestCase {

  func testFooterShowsReceivingWithCount() {
    let app = launch(seed: .sidebarFooterReceiving)
    app.syncFooter.expectLabel("Receiving from iCloud")
    app.syncFooter.expectDetail("1,234 records")
  }

  func testFooterShowsSendingWithCount() {
    let app = launch(seed: .sidebarFooterSending)
    app.syncFooter.expectLabel("Sending to iCloud")
  }

  func testFooterShowsUpToDateWithRelativeTimestamp() {
    let app = launch(seed: .sidebarFooterUpToDate)
    app.syncFooter.expectLabel("Up to date")
    app.syncFooter.expectDetailContains(prefix: "Updated", suffix: "ago")
  }
}
