import Foundation
import Testing

@testable import Moolah

@Suite("Account")
struct AccountTests {
  @Test
  func cryptoAccountRoundTripsViaCodable() throws {
    let account = Account(
      id: UUID(),
      name: "Hardware Wallet — Ethereum",
      type: .crypto,
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      positions: [],
      position: 7,
      isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40),
      chainId: 1
    )
    let data = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(Account.self, from: data)
    #expect(decoded.walletAddress == account.walletAddress)
    #expect(decoded.chainId == account.chainId)
    #expect(decoded.type == .crypto)
  }

  @Test
  func nonCryptoAccountOmitsWalletFields() throws {
    let account = Account(
      id: UUID(),
      name: "Cheque",
      type: .bank,
      instrument: .AUD
    )
    #expect(account.walletAddress == nil)
    #expect(account.chainId == nil)
    let data = try JSONEncoder().encode(account)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["walletAddress"] == nil)
    #expect(json["chainId"] == nil)
  }

  @Test
  func legacyAccountWithoutWalletFieldsDecodesWithNil() throws {
    let json = Data(
      """
      {"id":"\(UUID().uuidString)","name":"Old","type":"bank","instrument":{"id":"AUD","kind":"fiatCurrency","name":"AUD","decimals":2},"position":0,"hidden":false}
      """.utf8)
    let decoded = try JSONDecoder().decode(Account.self, from: json)
    #expect(decoded.walletAddress == nil)
    #expect(decoded.chainId == nil)
  }
}
