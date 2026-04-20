import XCTest

/// Symbolic reference to a sidebar account. Tests reference accounts by
/// name; the driver maps each case to the seeded UUID.
enum SidebarAccount {
  case checking
  case brokerage

  /// The fixed UUID written to the seeded `ProfileContainerManager` by
  /// `UITestSeedHydrator`.
  var id: UUID {
    switch self {
    case .checking: return UITestFixtures.TradeBaseline.checkingAccountId
    case .brokerage: return UITestFixtures.TradeBaseline.brokerageAccountId
    }
  }
}

/// Driver for the sidebar (left column on macOS): account list, named
/// views (Upcoming, Analysis, etc.), earmarks. Returned from
/// `MoolahApp.sidebar`.
@MainActor
struct SidebarScreen {
  let app: MoolahApp

  /// Switches the centre column to the transactions of the given account.
  /// Returns once the account row has been selected and the transaction
  /// list is on screen for that account.
  func switchToAccount(_ account: SidebarAccount) {
    Trace.record(detail: "account=\(account)")
    let identifier = UITestIdentifiers.Sidebar.account(account.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar row '\(identifier)' did not appear")
      XCTFail("Sidebar row for account \(account) did not appear within 3s")
      return
    }
    row.click()
    expectAccountSelected(account)
  }

  /// Asserts the sidebar currently shows the given account as selected.
  /// Drivers call this from `switchToAccount` as the post-condition; tests
  /// reuse it when validating sidebar state. Polls for up to 3 s because
  /// SwiftUI `List(selection:)` propagation is asynchronous.
  func expectAccountSelected(_ account: SidebarAccount) {
    let identifier = UITestIdentifiers.Sidebar.account(account.id)
    let row = app.element(for: identifier)
    if !row.waitForExistence(timeout: 3) {
      Trace.recordFailure("sidebar account row '\(identifier)' not present")
      XCTFail("Sidebar row for \(account) not present after selection")
      return
    }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if (row.value(forKey: "isSelected") as? Bool) ?? false { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("sidebar row '\(identifier)' did not become selected within 3s")
    XCTFail("Sidebar row for \(account) did not become selected within 3s")
  }
}
