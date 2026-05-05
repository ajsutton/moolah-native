import Testing

@testable import Moolah

@Suite("ValuationMode display text")
struct ValuationModeDisplayTextTests {
  @Test("dataSourceHint returns expected string for both modes")
  func dataSourceHint_returnsExpectedString() {
    #expect(
      ValuationMode.recordedValue.dataSourceHint
        == "Balance comes from the value you last recorded")
    #expect(
      ValuationMode.calculatedFromTrades.dataSourceHint
        == "Balance is calculated from your trade history and current prices of your holdings")
  }

  @Test("dataSourceDescription returns expected sentence for both modes")
  func dataSourceDescription_returnsExpectedString() {
    #expect(
      ValuationMode.recordedValue.dataSourceDescription
        == "The balance comes from the value you last recorded manually.")
    #expect(
      ValuationMode.calculatedFromTrades.dataSourceDescription
        == "The balance is calculated from your trade history and the current prices of your holdings."
    )
  }
}
