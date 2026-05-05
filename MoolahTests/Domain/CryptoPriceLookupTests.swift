import Foundation
import Testing

@testable import Moolah

@Suite("CryptoPriceLookup")
struct CryptoPriceLookupTests {
  @Test
  func pricedEqualityIsValueBased() {
    #expect(CryptoPriceLookup.priced(dec("123.45")) == .priced(dec("123.45")))
    #expect(CryptoPriceLookup.priced(dec("123.45")) != .priced(dec("123.46")))
  }

  @Test
  func knownZeroEqualsKnownZero() {
    #expect(CryptoPriceLookup.knownZero == .knownZero)
  }

  @Test
  func pricedDoesNotEqualKnownZero() {
    // The whole point of the discriminated type: a `.priced(0)` (which
    // could plausibly happen if a provider reported 0) must remain
    // distinguishable from an intentional `.knownZero`.
    #expect(CryptoPriceLookup.priced(.zero) != .knownZero)
  }

  /// `Sendable` conformance is checked by the compiler; this test is a
  /// runtime smoke that the value can be sent across an actor hop without
  /// requiring `@unchecked` annotations or losing equality.
  @Test
  func sendableRoundTripPreservesValue() async {
    let actor = LookupBox()
    let cases: [CryptoPriceLookup] = [.priced(dec("0.001")), .knownZero]
    for value in cases {
      await actor.set(value)
      let echoed = await actor.value
      #expect(echoed == value)
    }
  }
}

private actor LookupBox {
  var value: CryptoPriceLookup = .knownZero

  func set(_ value: CryptoPriceLookup) {
    self.value = value
  }
}
