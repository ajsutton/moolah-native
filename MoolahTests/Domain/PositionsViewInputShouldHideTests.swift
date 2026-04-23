import Foundation
import Testing

@testable import Moolah

/// Tests for `PositionsViewInput.shouldHide`, which suppresses `PositionsView`
/// when it would be redundant with the host surface's already-visible balance.
/// Lives in its own file to keep `PositionsViewInputTests.swift` within the
/// file-length / type-body-length budgets.
@Suite("PositionsViewInput.shouldHide")
struct PositionsViewInputShouldHideTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  private func amount(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: aud)
  }

  @Test("is true when the only non-zero instrument matches hostCurrency")
  func hidesOnSingleMatchingInstrument() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil,
          costBasis: nil, value: amount(1_000))
      ],
      historicalValue: nil
    )
    #expect(input.shouldHide)
  }

  @Test("is false when the only non-zero instrument differs from hostCurrency")
  func showsWhenSingleInstrumentDiffers() {
    // A BTC-denominated investment account reporting in AUD: the conversion /
    // cost / gain columns still add value, so the view must render.
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 10, unitPrice: nil,
          costBasis: nil, value: amount(600))
      ],
      historicalValue: nil
    )
    #expect(!input.shouldHide)
  }

  @Test("is false when multiple non-zero instruments are present")
  func showsWhenMultipleInstruments() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil,
          costBasis: nil, value: amount(1_000)),
        ValuedPosition(
          instrument: bhp, quantity: 10, unitPrice: nil,
          costBasis: nil, value: amount(600)),
      ],
      historicalValue: nil
    )
    #expect(!input.shouldHide)
  }

  @Test("ignores zero-quantity positions when evaluating the instrument set")
  func ignoresZeroQuantityRows() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: aud, quantity: 1_000, unitPrice: nil,
          costBasis: nil, value: amount(1_000)),
        ValuedPosition(
          instrument: bhp, quantity: 0, unitPrice: nil,
          costBasis: nil, value: amount(0)),
      ],
      historicalValue: nil
    )
    #expect(input.shouldHide)
  }

  @Test("is true for empty positions (nothing to show)")
  func hidesWhenEmpty() {
    let input = PositionsViewInput(
      title: "x", hostCurrency: aud, positions: [], historicalValue: nil)
    #expect(input.shouldHide)
  }
}
