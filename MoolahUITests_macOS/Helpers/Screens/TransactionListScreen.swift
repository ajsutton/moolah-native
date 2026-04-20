import XCTest

/// Symbolic reference to a transaction in the seeded fixture. Tests
/// reference transactions by name; the driver maps each case to the
/// seeded UUID.
enum TransactionListEntry {
  case bhpPurchase

  /// The fixed UUID written to the seeded `ProfileContainerManager` by
  /// `UITestSeedHydrator`.
  var id: UUID {
    switch self {
    case .bhpPurchase: return UITestFixtures.TradeBaseline.bhpPurchaseId
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
    Trace.record(detail: "entry=\(entry)")
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
}
