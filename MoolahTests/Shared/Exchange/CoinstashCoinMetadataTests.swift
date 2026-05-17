import Foundation
import Testing
import os

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
    let sut = try makeClient(returning: #"{"errors":[{"message":"boom"}]}"#)
    await #expect(throws: ExchangeClientError.self) {
      _ = try await sut.coinMetadata(symbol: "OP", token: "t")
    }
  }

  @Test
  func avalanceMisspellingMapsToChainId43114() async throws {
    // Coinstash spells it "AVALANCE" (missing the H). The client must still
    // map it to EVM chain id 43114.
    let sut = try makeClient(
      returning: """
        {"data":{"getCoinBySymbol":{"symbol":"AVAX","name":"Avalanche",
        "defiAddresses":[{"chain":"AVALANCE",
        "address":"0x1CE0c2827e2eF14D5C4f29a091d735A204794041","decimals":18}]}}}
        """)
    let meta = try #require(try await sut.coinMetadata(symbol: "AVAX", token: "t"))
    #expect(
      meta.chains == [
        ExchangeAssetChain(
          chainId: 43114,
          contractAddress: "0x1CE0c2827e2eF14D5C4f29a091d735A204794041",
          decimals: 18)
      ])
  }
}

@Suite("CoinstashAssetMetadataResolver")
struct CoinstashAssetMetadataResolverTests {
  private func makeOKResponse() throws -> HTTPURLResponse {
    try #require(
      HTTPURLResponse(
        url: CoinstashGraphQL.endpoint, statusCode: 200,
        httpVersion: nil, headerFields: nil))
  }

  private static let opBody = """
    {"data":{"getCoinBySymbol":{"symbol":"OP","name":"Optimism",
    "defiAddresses":[{"chain":"OPTIMISM",
    "address":"0x4200000000000000000000000000000000000042","decimals":18}]}}}
    """

  @Test
  func forwardsToClientWithBoundToken() async throws {
    let response = try makeOKResponse()
    let client = CoinstashClient(transport: { _ in
      (Data(Self.opBody.utf8), response)
    })
    let resolver: any ExchangeAssetMetadataResolving =
      CoinstashAssetMetadataResolver(client: client, token: "secret")
    let meta = try #require(try await resolver.assetMetadata(forSymbol: "OP"))
    #expect(meta.chains.first?.chainId == 10)
  }

  /// The transport is invoked exactly once for two calls with the same symbol.
  /// Both results must be identical (value returned from cache on second call).
  @Test
  func cachesResultsWithinOneBuildRun() async throws {
    let response = try makeOKResponse()
    let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let client = CoinstashClient(transport: { _ in
      callCount.withLock { $0 += 1 }
      return (Data(Self.opBody.utf8), response)
    })
    let resolver = CoinstashAssetMetadataResolver(client: client, token: "t")

    let first = try await resolver.assetMetadata(forSymbol: "OP")
    let second = try await resolver.assetMetadata(forSymbol: "OP")

    #expect(callCount.withLock { $0 } == 1, "transport should be called once")
    #expect(first == second)
    #expect(first?.symbol == "OP")
  }

  /// Uppercased key: calling with "op" and "OP" hits the transport only once.
  @Test
  func cachesSymbolCaseInsensitively() async throws {
    let response = try makeOKResponse()
    let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let client = CoinstashClient(transport: { _ in
      callCount.withLock { $0 += 1 }
      return (Data(Self.opBody.utf8), response)
    })
    let resolver = CoinstashAssetMetadataResolver(client: client, token: "t")

    _ = try await resolver.assetMetadata(forSymbol: "op")
    _ = try await resolver.assetMetadata(forSymbol: "OP")

    #expect(callCount.withLock { $0 } == 1, "transport should be called once for both cases")
  }

  /// A transient error (thrown by transport) must NOT be cached. The second
  /// call must attempt the transport again and succeed.
  @Test
  func transientErrorIsNotCached() async throws {
    struct TransportError: Error {}
    let response = try makeOKResponse()
    let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
    let client = CoinstashClient(transport: { _ in
      let count = callCount.withLock { count -> Int in
        let current = count
        count += 1
        return current
      }
      if count == 0 { throw ExchangeClientError.providerError("transient") }
      return (Data(Self.opBody.utf8), response)
    })
    let resolver = CoinstashAssetMetadataResolver(client: client, token: "t")

    // First call throws.
    await #expect(throws: ExchangeClientError.self) {
      _ = try await resolver.assetMetadata(forSymbol: "OP")
    }
    // Second call must reach transport again (no poisoned cache entry).
    let second = try await resolver.assetMetadata(forSymbol: "OP")
    #expect(second?.symbol == "OP")
    #expect(callCount.withLock { $0 } == 2, "transport must be called twice (no cached error)")
  }
}
