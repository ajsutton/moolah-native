import XCTest

/// End-to-end UI tests for transfer detection in Recently Added.
///
/// The `.transferDetectionBaseline` seed writes a `TransferSuggestion`
/// directly onto both sides of two imported pairs, so the passive
/// "possible transfer" pill is deterministic at first launch with no
/// detection-timing dependency.
///
/// These earn their place as UI tests because they exercise the macOS
/// row context-menu actions, the dismiss confirmation dialog, and the
/// app's launch → seed → render pipeline — none of which a store test
/// against `TestBackend` reaches. Persistence (a merged or dismissed
/// pair is not re-suggested) is proven at the store layer by
/// `TransferDetectionScanTests`.
@MainActor
final class TransferDetectionUITests: MoolahUITestCase {
  /// Both sides of a detected pair show the passive transfer pill on
  /// first launch.
  func testTransferSuggestionPillAppearsOnBothRows() {
    let app = launch(seed: .transferDetectionBaseline)
    app.sidebar.switchToNamed(.recentlyAdded)
    app.recentlyAdded.expectVisible()

    app.recentlyAdded.expectPillVisible(
      for: UITestFixtures.TransferDetection.mergeOutgoingId)
    app.recentlyAdded.expectPillVisible(
      for: UITestFixtures.TransferDetection.mergeIncomingId)
    app.recentlyAdded.expectPillVisible(
      for: UITestFixtures.TransferDetection.dismissOutgoingId)
    app.recentlyAdded.expectPillVisible(
      for: UITestFixtures.TransferDetection.dismissIncomingId)
  }

  /// Merging a detected pair removes both source rows from Recently
  /// Added; neither source's pill remains.
  func testMergingRemovesSourceRowsFromRecentlyAdded() {
    let app = launch(seed: .transferDetectionBaseline)
    app.sidebar.switchToNamed(.recentlyAdded)
    app.recentlyAdded.expectVisible()

    app.recentlyAdded.tapMerge(
      for: UITestFixtures.TransferDetection.mergeOutgoingId)

    app.recentlyAdded.expectRowRemoved(
      for: UITestFixtures.TransferDetection.mergeOutgoingId)
    app.recentlyAdded.expectRowRemoved(
      for: UITestFixtures.TransferDetection.mergeIncomingId)
  }

  /// Dismissing a detected pair via the row context menu and the
  /// confirmation dialog clears the pill from both sides.
  func testDismissingRemovesThePill() {
    let app = launch(seed: .transferDetectionBaseline)
    app.sidebar.switchToNamed(.recentlyAdded)
    app.recentlyAdded.expectVisible()

    app.recentlyAdded.tapDismiss(
      for: UITestFixtures.TransferDetection.dismissOutgoingId)

    app.recentlyAdded.expectPillCleared(
      for: UITestFixtures.TransferDetection.dismissOutgoingId)
    app.recentlyAdded.expectPillCleared(
      for: UITestFixtures.TransferDetection.dismissIncomingId)
  }
}
