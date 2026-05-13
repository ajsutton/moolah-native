import XCTest

/// Symbolic reference to a transaction in the seeded fixture. Tests
/// reference transactions by name; the driver maps each case to the
/// seeded UUID.
enum TransactionListEntry {
  case bhpPurchase
  case splitShop

  /// The fixed UUID written to the seeded `ProfileContainerManager` by
  /// `UITestSeedHydrator`.
  var id: UUID {
    switch self {
    case .bhpPurchase: return UITestFixtures.TradeBaseline.bhpPurchaseId
    case .splitShop: return UITestFixtures.TradeBaseline.splitShopId
    }
  }
}

/// Driver for the transaction list (centre column). Returned from
/// `MoolahApp.transactionList`.
@MainActor
struct TransactionListScreen {
  let app: MoolahApp

  /// Opens the given transaction in the detail view. Returns once the
  /// detail surface for that transaction is visible (i.e. the payee field
  /// has been added to the accessibility tree).
  func openTransaction(_ entry: TransactionListEntry) {
    Trace.record(#function, detail: "entry=\(entry)")
    let identifier = UITestIdentifiers.TransactionList.transaction(entry.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("transaction row '\(identifier)' did not appear")
      XCTFail("Transaction list row for \(entry) did not appear within 3s")
      return
    }
    row.click()
    let payee = app.element(for: UITestIdentifiers.Detail.payee)
    if !payee.waitForExistence(timeout: 3) {
      Trace.recordFailure("detail.payee did not appear after opening \(entry)")
      XCTFail("Transaction detail did not surface payee field after opening \(entry)")
    }
  }

  /// Triggers the "New Transaction" menu command (⌘N) and returns once
  /// the detail surface for the new transaction is visible (i.e. the
  /// payee field exists in the accessibility tree). The caller is
  /// responsible for focus assertions — this method does not assume the
  /// field has been auto-focused.
  func createTransaction() {
    Trace.record(#function)
    app.pressKeyboardShortcut("n", modifiers: .command)
    let payee = app.element(for: UITestIdentifiers.Detail.payee)
    if !payee.waitForExistence(timeout: 3) {
      Trace.recordFailure("detail.payee did not appear after ⌘N")
      XCTFail("Transaction detail did not surface payee field after ⌘N")
    }
  }

  /// Asserts the scrolling header (top accessory) is in the
  /// accessibility tree inside the transaction list. Used by detail
  /// views that pass a `topAccessory` through `TransactionListView`
  /// (macOS standard / crypto / investment / earmark leaves). Fails
  /// loudly via `XCTFail` if the header doesn't appear within 3s.
  func expectHeaderVisible() {
    Trace.record(#function)
    let header = app.element(for: UITestIdentifiers.TransactionList.headerContainer)
    if !header.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "transaction list header '\(UITestIdentifiers.TransactionList.headerContainer)' "
          + "did not appear")
      XCTFail(
        "Transaction list did not surface a scrolling header within 3s "
          + "(expected '\(UITestIdentifiers.TransactionList.headerContainer)' to resolve)."
      )
    }
  }

  /// Asserts the transaction list container is in the accessibility
  /// tree. Useful as a post-condition sentinel after a navigation
  /// action that should land on a leaf rendering a `TransactionListView`
  /// (e.g. `AllTransactionsView`, sidebar account selection).
  /// `SidebarScreen.switchToAccount` already waits on this internally,
  /// so most tests don't need to call it explicitly — but it's
  /// available for the cases that do.
  func expectContainerVisible() {
    Trace.record(#function)
    let container = app.element(for: UITestIdentifiers.TransactionList.container)
    if !container.waitForExistence(timeout: 3) {
      Trace.recordFailure(
        "transaction list container '\(UITestIdentifiers.TransactionList.container)' "
          + "did not appear")
      XCTFail(
        "Transaction list container did not render within 3s "
          + "(expected '\(UITestIdentifiers.TransactionList.container)' to resolve)."
      )
    }
  }
}
