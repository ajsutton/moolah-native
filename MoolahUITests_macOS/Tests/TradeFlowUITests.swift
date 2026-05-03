import XCTest

/// End-to-end UI test for the trade transaction creation flow.
///
/// Drives the full create-trade-with-fee path:
///   launch → sidebar account → new transaction → switch to Trade mode →
///   set Paid + Received amounts and instruments → add fee with category →
///   assert the transaction list renders the trade row title.
///
/// This test earns its place as a UI test because the interaction involves
/// multi-step form mode-switching (type picker → trade section reveal),
/// instrument picker sheet open/close sequencing, and the debounced save
/// pipeline that commits the draft to the store — none of which are
/// exercisable in a store test against `TestBackend`.
@MainActor
final class TradeFlowUITests: MoolahUITestCase {
  /// Creates a new trade transaction with a fee and asserts the resulting
  /// row in the transaction list displays the expected trade title.
  func testCreateTradeWithFeeRendersTradeRow() {
    let app = launch(seed: .tradeReady)

    app.sidebar.switchToAccount(.tradeReadyBrokerage)
    app.transactionList.createTransaction()

    app.tradeForm.switchToTradeMode()
    // Buy: user types positive amounts in both Paid and Received. The Paid
    // field flips the sign for storage so the cash leg quantity is `-300`,
    // matching the user's mental model ("I paid $300, balance goes down").
    // Received stores `+20` directly. Fees are entered in the Expense leg's
    // own sign convention (negative = outflow).
    app.tradeForm.setPaid(amount: "300", instrumentId: "AUD")
    app.tradeForm.setReceived(
      amount: "20", instrumentId: UITestFixtures.TradeReady.vgsaxInstrumentId)
    app.tradeForm.addFee(
      amount: "-10",
      instrumentId: "AUD",
      category: UITestFixtures.TradeReady.brokerageCategoryName)

    app.tradeForm.waitForTradeRow(containing: "Bought 20 VGS.AX")
  }
}
