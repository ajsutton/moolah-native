// MoolahTests/Shared/CryptoImport/LiveAlchemyClientRequestTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveAlchemyClient — request shape")
struct LiveAlchemyClientRequestTests {
  @Test
  func ethereumRequestUsesEthMainnetSlugAndIncludesInternalCategory() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("eth-simple-eth-send")
    let client = AlchemyTestSupport.makeClient { request in
      AlchemyURLProtocolStub.captureRequest(request)
      return (AlchemyTestSupport.okResponse(for: request), fixture)
    }

    _ = try await client.getAssetTransfers(
      chain: .ethereum,
      walletAddress: "0xabc",
      fromBlock: 0
    )

    let url = try #require(AlchemyURLProtocolStub.lastRequest?.url)
    #expect(url.host == "eth-mainnet.g.alchemy.com")
    #expect(url.path == "/v2/test-key")
    #expect(AlchemyURLProtocolStub.lastRequest?.httpMethod == "POST")

    let body = AlchemyURLProtocolStub.lastBodyJSON
    #expect(body["method"] as? String == "alchemy_getAssetTransfers")
    let paramsArray = try #require(body["params"] as? [[String: Any]])
    let params = try #require(paramsArray.first)
    let categories = try #require(params["category"] as? [String])
    #expect(categories.contains("external"))
    #expect(categories.contains("erc20"))
    #expect(categories.contains("internal"))
  }

  @Test
  func optimismRequestExcludesInternalCategory() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("eth-simple-eth-send")
    let client = AlchemyTestSupport.makeClient { request in
      AlchemyURLProtocolStub.captureRequest(request)
      return (AlchemyTestSupport.okResponse(for: request), fixture)
    }
    _ = try await client.getAssetTransfers(
      chain: .optimism, walletAddress: "0xabc", fromBlock: 0
    )

    let url = try #require(AlchemyURLProtocolStub.lastRequest?.url)
    #expect(url.host == "opt-mainnet.g.alchemy.com")
    let body = AlchemyURLProtocolStub.lastBodyJSON
    let paramsArray = try #require(body["params"] as? [[String: Any]])
    let categories = try #require(paramsArray.first?["category"] as? [String])
    #expect(categories.contains("external"))
    #expect(categories.contains("erc20"))
    #expect(categories.contains("internal") == false)
  }

  @Test
  func baseRequestExcludesInternalCategory() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("eth-simple-eth-send")
    let client = AlchemyTestSupport.makeClient { request in
      AlchemyURLProtocolStub.captureRequest(request)
      return (AlchemyTestSupport.okResponse(for: request), fixture)
    }
    _ = try await client.getAssetTransfers(
      chain: .base, walletAddress: "0xabc", fromBlock: 0
    )
    let url = try #require(AlchemyURLProtocolStub.lastRequest?.url)
    #expect(url.host == "base-mainnet.g.alchemy.com")
    let body = AlchemyURLProtocolStub.lastBodyJSON
    let paramsArray = try #require(body["params"] as? [[String: Any]])
    let categories = try #require(paramsArray.first?["category"] as? [String])
    #expect(categories.contains("internal") == false)
  }

  @Test
  func twoPassQueryUsesFromAddressThenToAddress() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("eth-simple-eth-send")
    let calls = TestCallRecorder()
    let client = AlchemyTestSupport.makeClient { request in
      calls.record(request: request)
      return (AlchemyTestSupport.okResponse(for: request), fixture)
    }
    _ = try await client.getAssetTransfers(
      chain: .ethereum, walletAddress: "0xWALLET", fromBlock: 0x100
    )

    let recorded = calls.captured
    #expect(recorded.count == 2)
    let firstParams = try #require((recorded[0]["params"] as? [[String: Any]])?.first)
    let secondParams = try #require((recorded[1]["params"] as? [[String: Any]])?.first)
    #expect(firstParams["fromAddress"] as? String == "0xWALLET")
    #expect(firstParams["toAddress"] == nil)
    #expect(secondParams["toAddress"] as? String == "0xWALLET")
    #expect(secondParams["fromAddress"] == nil)
    #expect(firstParams["fromBlock"] as? String == "0x100")
    #expect(firstParams["withMetadata"] as? Bool == true)
    #expect(firstParams["excludeZeroValue"] as? Bool == true)
  }

  @Test
  func responseDecodesIntoTransfersArray() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("eth-simple-eth-send")
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), fixture)
    }
    let transfers = try await client.getAssetTransfers(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
    )
    // Two-pass query → both passes return the same fixture.
    #expect(transfers.count == 2)
    #expect(transfers[0].asset == "ETH")
  }

  @Test
  func tokenMetadataDecodesUSDC() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("token-metadata-usdc")
    let client = AlchemyTestSupport.makeClient { request in
      AlchemyURLProtocolStub.captureRequest(request)
      return (AlchemyTestSupport.okResponse(for: request), fixture)
    }
    let metadata = try await client.getTokenMetadata(
      chain: .ethereum,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    )
    #expect(metadata.symbol == "USDC")
    #expect(metadata.name == "USD Coin")
    #expect(metadata.decimals == 6)
    #expect(metadata.isSpam == false)

    let body = AlchemyURLProtocolStub.lastBodyJSON
    #expect(body["method"] as? String == "alchemy_getTokenMetadata")
    let paramsArray = try #require(body["params"] as? [String])
    #expect(paramsArray.first == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
  }
}
