import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentAmount.accessibilityString")
struct InstrumentAmountAccessibilityTests {
  let aud = Instrument.AUD
  let scam = Instrument.crypto(
    chainId: 1, contractAddress: "0xdeadbeef", symbol: "SCAM",
    name: "Scam Token", decimals: 18)

  @Test("non-spam falls through to .formatted")
  func nonSpamPassesThrough() {
    let amount = InstrumentAmount(quantity: -50.23, instrument: aud)
    #expect(amount.accessibilityString(isSpam: false) == amount.formatted)
  }

  @Test("spam reads as <magnitude> spam token")
  func spamSubstitutes() {
    let amount = InstrumentAmount(quantity: 1_000_000, instrument: scam)
    #expect(
      amount.accessibilityString(isSpam: true)
        == "\(amount.formatNoSymbolVariablePrecision) spam token")
  }

  @Test("spam preserves negative magnitude in VoiceOver string")
  func spamNegativeMagnitudePreserved() {
    let amount = InstrumentAmount(quantity: -50, instrument: scam)
    let result = amount.accessibilityString(isSpam: true)
    #expect(result.contains("-50"))
    #expect(result.hasSuffix("spam token"))
  }

  @Test("spam zero magnitude reads as '0 spam token'")
  func spamZeroMagnitude() {
    let amount = InstrumentAmount(quantity: 0, instrument: scam)
    #expect(amount.accessibilityString(isSpam: true) == "0 spam token")
  }
}
