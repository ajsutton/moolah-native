import Foundation
import Testing

@testable import Moolah

@Suite("UnmappedCryptoInstrumentError")
struct UnmappedCryptoInstrumentErrorTests {

  @Test
  func testEqualityByInstrumentId() {
    let first = UnmappedCryptoInstrumentError(instrumentId: "1:0xuni")
    let sameId = UnmappedCryptoInstrumentError(instrumentId: "1:0xuni")
    let differentId = UnmappedCryptoInstrumentError(instrumentId: "1:0xother")
    #expect(first == sameId)
    #expect(first != differentId)
  }

  @Test
  func testLocalizedDescriptionContainsInstrumentId() {
    let error = UnmappedCryptoInstrumentError(instrumentId: "1:0xuni")
    #expect(error.localizedDescription.contains("1:0xuni"))
  }
}
