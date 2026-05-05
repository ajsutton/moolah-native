import Foundation
import Testing

@testable import Moolah

@Suite("ConversionResult")
struct ConversionResultTests {
  private let usd = Instrument.USD
  private let aud = Instrument.AUD

  @Test
  func valueEqualityIsValueBased() {
    let lhs = ConversionResult.value(InstrumentAmount(quantity: dec("10"), instrument: usd))
    let rhs = ConversionResult.value(InstrumentAmount(quantity: dec("10"), instrument: usd))
    #expect(lhs == rhs)

    let differentQuantity = ConversionResult.value(
      InstrumentAmount(quantity: dec("11"), instrument: usd))
    #expect(lhs != differentQuantity)

    let differentInstrument = ConversionResult.value(
      InstrumentAmount(quantity: dec("10"), instrument: aud))
    #expect(lhs != differentInstrument)
  }

  @Test
  func knownZeroEqualityKeysOnTargetInstrument() {
    #expect(ConversionResult.knownZero(targetInstrument: usd) == .knownZero(targetInstrument: usd))
    #expect(ConversionResult.knownZero(targetInstrument: usd) != .knownZero(targetInstrument: aud))
  }

  /// The whole point of the discriminated type: a `.value(...)` whose
  /// quantity happens to be zero must remain distinguishable from an
  /// intentional `.knownZero(...)`.
  @Test
  func valueZeroDoesNotEqualKnownZero() {
    let zeroValue = ConversionResult.value(.zero(instrument: usd))
    #expect(zeroValue != .knownZero(targetInstrument: usd))
  }
}
