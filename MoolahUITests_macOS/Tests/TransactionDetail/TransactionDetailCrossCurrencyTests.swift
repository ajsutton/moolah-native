import XCTest

/// Behaviour test for the cross-currency branch of the transfer detail
/// view. Switching the "To Account" picker to an account in a different
/// instrument flips `isCrossCurrency` to true, which reveals the
/// counterpart amount field and its instrument label. The
/// `.tradeBaseline` seed provides an AUD transfer (BHP Purchase:
/// Checking → Brokerage) and a USD Savings account the picker can
/// switch to.
@MainActor
final class TransactionDetailCrossCurrencyTests: MoolahUITestCase {
  func testSwitchingTransferToCrossCurrencyRevealsCounterpartField() {
    let app = launch(seed: .tradeBaseline)

    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.bhpPurchase)
    app.transactionDetail.counterpartAmount.expectHidden()

    app.transactionDetail.selectToAccount(named: "USD Savings")

    app.transactionDetail.counterpartAmount.expectVisible(instrumentCode: "USD")
  }
}
