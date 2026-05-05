import Foundation
import Testing

@testable import Moolah

@Suite("CryptoRegistration")
struct CryptoRegistrationTests {
  @Test
  func presetsDefaultToPriced() {
    for preset in CryptoRegistration.builtInPresets {
      #expect(preset.pricingStatus == .priced)
    }
  }

  @Test
  func legacyRegistrationDecodesAsPriced() throws {
    let json = Data(
      """
      {"instrument":{"id":"1:native","kind":"cryptoToken","name":"Ethereum","decimals":18,"ticker":"ETH","chainId":1},"mapping":{"instrumentId":"1:native","coingeckoId":"ethereum","cryptocompareSymbol":"ETH","binanceSymbol":"ETHUSDT"}}
      """.utf8)
    let decoded = try JSONDecoder().decode(CryptoRegistration.self, from: json)
    #expect(decoded.pricingStatus == .priced)
  }

  @Test
  func explicitStatusRoundTrips() throws {
    let registration = CryptoRegistration(
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: "0x1234567890abcdef1234567890abcdef12345678",
        symbol: "WTF", name: "Spam Token", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0x1234567890abcdef1234567890abcdef12345678",
        coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil),
      pricingStatus: .spam
    )
    let data = try JSONEncoder().encode(registration)
    let decoded = try JSONDecoder().decode(CryptoRegistration.self, from: data)
    #expect(decoded.pricingStatus == .spam)
  }
}
