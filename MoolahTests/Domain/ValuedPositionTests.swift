import Foundation
import Testing

@testable import Moolah

@Suite("ValuedPosition")
struct ValuedPositionTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  @Test("amount returns InstrumentAmount in the position's instrument")
  func amountWrapsInstrument() {
    let row = ValuedPosition(
      instrument: bhp,
      quantity: 250,
      unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: InstrumentAmount(quantity: 11_325, instrument: aud)
    )
    #expect(row.amount == InstrumentAmount(quantity: 250, instrument: bhp))
  }

  @Test("hasCostBasis is true only when costBasis is non-nil")
  func hasCostBasisFlag() {
    let withCost = ValuedPosition(
      instrument: bhp, quantity: 1,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 50, instrument: aud),
      value: InstrumentAmount(quantity: 60, instrument: aud)
    )
    let withoutCost = ValuedPosition(
      instrument: bhp, quantity: 1,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 60, instrument: aud)
    )
    #expect(withCost.hasCostBasis)
    #expect(!withoutCost.hasCostBasis)
  }

  @Test("gainLoss computes value - cost in host currency")
  func gainLossSubtraction() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: InstrumentAmount(quantity: 11_325, instrument: aud)
    )
    #expect(row.gainLoss == InstrumentAmount(quantity: 1200, instrument: aud))
  }

  @Test("gainLoss is nil when value is nil")
  func gainLossNilOnFailure() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: nil
    )
    #expect(row.gainLoss == nil)
  }

  @Test("gainLoss is nil when costBasis is nil (pure flow row)")
  func gainLossNilWithoutCost() {
    let row = ValuedPosition(
      instrument: aud, quantity: 1_000,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 1_000, instrument: aud)
    )
    #expect(row.gainLoss == nil)
  }

  @Test("gainLoss is negative when value is below cost basis")
  func gainLossNegativeOnUnderwater() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 11_325, instrument: aud),
      value: InstrumentAmount(quantity: 10_125, instrument: aud)
    )
    #expect(row.gainLoss == InstrumentAmount(quantity: -1_200, instrument: aud))
  }

  @Test("positive gain renders as positive percent")
  func positiveGain() throws {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 1_000, instrument: aud),
      value: InstrumentAmount(quantity: 1_100, instrument: aud))
    let pct = try #require(row.gainLossPercent)
    #expect(pct == 10)
  }

  @Test("negative gain renders as negative percent")
  func negativeGain() throws {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 1_000, instrument: aud),
      value: InstrumentAmount(quantity: 800, instrument: aud))
    let pct = try #require(row.gainLossPercent)
    #expect(pct == -20)
  }

  @Test("missing cost basis returns nil")
  func missingCostBasisNil() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(row.gainLossPercent == nil)
  }

  @Test("zero cost basis returns nil")
  func zeroCostBasisNil() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 0, instrument: aud),
      value: InstrumentAmount(quantity: 100, instrument: aud))
    #expect(row.gainLossPercent == nil)
  }

  @Test("missing value returns nil")
  func missingValueNil() {
    let row = ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil,
      costBasis: InstrumentAmount(quantity: 1_000, instrument: aud),
      value: nil)
    #expect(row.gainLossPercent == nil)
  }
}
