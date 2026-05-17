import Foundation
import Testing

@testable import Moolah

@Suite("ExchangeAssetMetadata value type")
struct CoinstashCoinMetadataTests {
  @Test
  func chainStoresContractAndDecimals() {
    let chain = ExchangeAssetChain(
      chainId: 1, contractAddress: "0xA0B8…", decimals: 6)
    let meta = ExchangeAssetMetadata(symbol: "USDC", name: "USDC", chains: [chain])
    #expect(meta.symbol == "USDC")
    #expect(meta.chains.first?.chainId == 1)
    #expect(meta.chains.first?.decimals == 6)
  }
}

@Suite("CoinstashCoinMetadata decode")
struct CoinstashCoinMetadataDecodeTests {
  private func decode(_ json: String) throws -> CoinstashCoinData {
    let response = try JSONDecoder().decode(
      CoinstashGraphQLResponse<CoinstashCoinData>.self,
      from: Data(json.utf8))
    return try #require(response.data)  // test fixture is always a success shape
  }

  @Test
  func decodesSingleChainToken() throws {
    let json = """
      {"data":{"getCoinBySymbol":{"symbol":"OP","name":"Optimism",
      "defiAddresses":[{"chain":"OPTIMISM",
      "address":"0x4200000000000000000000000000000000000042","decimals":18}]}}}
      """
    let coin = try #require(try decode(json).getCoinBySymbol)
    #expect(coin.symbol == "OP")
    #expect(coin.defiAddresses.count == 1)
    #expect(coin.defiAddresses[0].chain == "OPTIMISM")
    #expect(coin.defiAddresses[0].address == "0x4200000000000000000000000000000000000042")
    #expect(coin.defiAddresses[0].decimals == 18)
  }

  @Test
  func decodesEmptyDefiAddresses() throws {
    let json = """
      {"data":{"getCoinBySymbol":{"symbol":"BTC","name":"Bitcoin","defiAddresses":[]}}}
      """
    let coin = try #require(try decode(json).getCoinBySymbol)
    #expect(coin.defiAddresses.isEmpty)
  }
}
