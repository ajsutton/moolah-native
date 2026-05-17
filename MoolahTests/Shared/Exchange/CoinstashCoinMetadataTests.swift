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

@Suite("CoinstashClient.coinMetadata mapping")
struct CoinstashClientCoinMetadataTests {
  private func makeOKResponse() throws -> HTTPURLResponse {
    try #require(
      HTTPURLResponse(
        url: CoinstashGraphQL.endpoint, statusCode: 200,
        httpVersion: nil, headerFields: nil))
  }

  private func makeClient(returning body: String) throws -> CoinstashClient {
    let response = try makeOKResponse()
    return CoinstashClient(transport: { _ in (Data(body.utf8), response) })
  }

  @Test
  func mapsSingleChainOptimismToken() async throws {
    let sut = try makeClient(
      returning: """
        {"data":{"getCoinBySymbol":{"symbol":"OP","name":"Optimism",
        "defiAddresses":[{"chain":"OPTIMISM",
        "address":"0x4200000000000000000000000000000000000042","decimals":18}]}}}
        """)
    let meta = try #require(try await sut.coinMetadata(symbol: "OP", token: "t"))
    #expect(meta.symbol == "OP")
    #expect(
      meta.chains == [
        ExchangeAssetChain(
          chainId: 10,
          contractAddress: "0x4200000000000000000000000000000000000042",
          decimals: 18)
      ])
  }

  @Test
  func collapsesNativeSentinelToNilContract() async throws {
    let sut = try makeClient(
      returning: """
        {"data":{"getCoinBySymbol":{"symbol":"ETH","name":"Ethereum",
        "defiAddresses":[
        {"chain":"ETHEREUM","address":"0xEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE","decimals":18},
        {"chain":"SOLANA","address":"So111","decimals":9}]}}}
        """)
    let meta = try #require(try await sut.coinMetadata(symbol: "ETH", token: "t"))
    #expect(
      meta.chains == [
        ExchangeAssetChain(chainId: 1, contractAddress: nil, decimals: 18)
      ])
  }

  @Test
  func unknownSymbolReturnsNil() async throws {
    let sut = try makeClient(returning: #"{"data":{"getCoinBySymbol":null}}"#)
    #expect(try await sut.coinMetadata(symbol: "ZZZ", token: "t") == nil)
  }

  @Test
  func emptyDefiAddressesReturnsMetadataWithNoChains() async throws {
    let sut = try makeClient(
      returning: """
        {"data":{"getCoinBySymbol":{"symbol":"BTC","name":"Bitcoin","defiAddresses":[]}}}
        """)
    let meta = try #require(try await sut.coinMetadata(symbol: "BTC", token: "t"))
    #expect(meta.chains.isEmpty)
  }

  @Test
  func providerErrorThrows() async throws {
    let response = try makeOKResponse()
    let sut = CoinstashClient(transport: { _ in
      (Data(#"{"errors":[{"message":"boom"}]}"#.utf8), response)
    })
    await #expect(throws: ExchangeClientError.self) {
      _ = try await sut.coinMetadata(symbol: "OP", token: "t")
    }
  }
}
