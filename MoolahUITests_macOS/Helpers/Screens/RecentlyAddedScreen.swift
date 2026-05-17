import XCTest

/// Driver for the Recently Added landing page (`RecentlyAddedView`):
/// the imported-row list, its passive "possible transfer" pill, and the
/// macOS row context-menu merge / dismiss actions. Returned from
/// `MoolahApp.recentlyAdded`.
///
/// Row content is wrapped in `.accessibilityElement(children: .combine)`
/// for VoiceOver, so the per-row handle is the row-level identifier
/// `UITestIdentifiers.RecentlyAdded.row(_:)`; the merge / dismiss
/// actions live in the row's context menu and are opened by
/// right-clicking that row element. Every action method records a trace
/// breadcrumb and waits on a real post-condition; expectation methods
/// are read-only and do not record a breadcrumb. All element lookups go
/// through `MoolahApp.element(for:)`.
@MainActor
struct RecentlyAddedScreen {
  let app: MoolahApp

  /// Asserts the Recently Added container is on screen — the presence
  /// sentinel a subsequent pill-absence assertion relies on so an
  /// absence check cannot pass vacuously when the view failed to render.
  func expectVisible() {
    let container = app.element(for: UITestIdentifiers.RecentlyAdded.container)
    if !container.waitForExistence(timeout: 3) {
      Trace.recordFailure("recentlyadded.container did not appear")
      XCTFail("Recently Added view did not render within 3s")
    }
  }

  /// Asserts the passive transfer pill is present for the given
  /// transaction. The Recently Added row wraps its content in
  /// `.accessibilityElement(children: .combine)` for VoiceOver, which
  /// flattens the pill's own identifier into the combined row element —
  /// so presence is asserted by waiting on the stable row handle and
  /// checking its combined accessibility label carries the pill title
  /// (the title is appended to the row label only when the transaction
  /// has a `TransferSuggestion`).
  func expectPillVisible(for id: UUID) {
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "recently added row '\(UITestIdentifiers.RecentlyAdded.row(id))' did not appear")
      XCTFail("Recently Added row for \(id) did not appear within 3s")
      return
    }
    let prefix = UITestIdentifiers.TransferDetection.pillLabelPrefix
    if !row.label.contains(prefix) {
      Trace.recordFailure(
        "row '\(id)' label '\(row.label)' did not contain pill title '\(prefix)'")
      XCTFail("Transfer pill title absent from row \(id) label: '\(row.label)'")
    }
  }

  /// Asserts no transfer pill exists for the given transaction. After a
  /// merge or dismiss the source row is removed from Recently Added (a
  /// merged transfer has a `.merged` origin and is filtered out; a
  /// dismissed pair clears its suggestion and records a
  /// `DismissedTransferPair`), so the row handle itself disappearing is
  /// the strongest structural signal that the pill is gone. The caller
  /// must have established a presence sentinel (e.g. `expectVisible()`)
  /// so this cannot pass vacuously.
  func expectPillAbsent(for id: UUID) {
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    if !row.waitForNonExistence(timeout: 5) {
      Trace.recordFailure(
        "recently added row '\(UITestIdentifiers.RecentlyAdded.row(id))' "
          + "still present; pill not cleared")
      XCTFail("Transfer pill / row for \(id) was still present after 5s")
    }
  }

  /// Right-clicks the given row to open its macOS context menu and
  /// clicks "Merge as Transfer". Returns once the row has been removed
  /// from Recently Added — the merge replaces the two single-account
  /// sides with one `.merged` transfer that the view filters out, so
  /// the row's disappearance is the post-condition.
  func tapMerge(for id: UUID) {
    Trace.record(#function, detail: "id=\(id)")
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "recently added row '\(UITestIdentifiers.RecentlyAdded.row(id))' did not appear")
      XCTFail("Recently Added row for \(id) did not appear within 3s")
      return
    }
    row.rightClick()

    let mergeItem = app.element(for: UITestIdentifiers.TransferDetection.merge(id))
    if !mergeItem.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "merge menu item '\(UITestIdentifiers.TransferDetection.merge(id))' "
          + "did not appear after right-click")
      XCTFail("'Merge as Transfer' menu item did not appear within 3s")
      return
    }
    mergeItem.click()

    if !row.waitForNonExistence(timeout: 5) {
      Trace.recordFailure("row '\(id)' still present 5s after merge")
      XCTFail("Recently Added row for \(id) did not collapse within 5s of merge")
    }
  }

  /// Right-clicks the given row, clicks "Not a Transfer", and confirms
  /// the destructive button in the "Dismiss Transfer Suggestion"
  /// confirmation dialog. Returns once the row has been removed from
  /// Recently Added — dismiss clears the suggestion and records a
  /// `DismissedTransferPair`, so the row's disappearance is the
  /// post-condition.
  func tapDismiss(for id: UUID) {
    Trace.record(#function, detail: "id=\(id)")
    let row = app.element(for: UITestIdentifiers.RecentlyAdded.row(id))
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "recently added row '\(UITestIdentifiers.RecentlyAdded.row(id))' did not appear")
      XCTFail("Recently Added row for \(id) did not appear within 3s")
      return
    }
    row.rightClick()

    let dismissItem = app.element(for: UITestIdentifiers.TransferDetection.dismiss(id))
    if !dismissItem.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "dismiss menu item '\(UITestIdentifiers.TransferDetection.dismiss(id))' "
          + "did not appear after right-click")
      XCTFail("'Not a Transfer' menu item did not appear within 3s")
      return
    }
    dismissItem.click()

    let confirm = app.element(for: UITestIdentifiers.TransferDetection.dismissConfirm)
    if !confirm.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "dismiss confirm button '\(UITestIdentifiers.TransferDetection.dismissConfirm)' "
          + "did not appear")
      XCTFail("'Dismiss Suggestion' confirm button did not appear within 3s")
      return
    }
    confirm.click()

    if !row.waitForNonExistence(timeout: 5) {
      Trace.recordFailure("row '\(id)' still present 5s after dismiss")
      XCTFail("Recently Added row for \(id) did not clear within 5s of dismiss")
    }
  }
}
