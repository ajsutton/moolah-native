import Foundation
import Testing

@testable import Moolah

@Suite("CryptoPriceError")
struct CryptoPriceErrorTests {
  @Test
  func noPriceAvailableNamesTokenAndDate() {
    let error = CryptoPriceError.noPriceAvailable(tokenId: "ETH", date: "2026-05-17")
    let message = error.localizedDescription
    #expect(message.contains("ETH"))
    #expect(message.contains("2026-05-17"))
    #expect(!message.contains("CryptoPriceError"))
  }

  @Test
  func noProviderMappingNamesTokenAndProvider() {
    let error = CryptoPriceError.noProviderMapping(tokenId: "SPAM", provider: "CryptoCompare")
    let message = error.localizedDescription
    #expect(message.contains("SPAM"))
    #expect(message.contains("CryptoCompare"))
    #expect(!message.contains("CryptoPriceError"))
  }

  @Test
  func allProvidersFailedNamesToken() {
    let error = CryptoPriceError.allProvidersFailed(tokenId: "BTC")
    let message = error.localizedDescription
    #expect(message.contains("BTC"))
    #expect(!message.contains("CryptoPriceError"))
  }
}
