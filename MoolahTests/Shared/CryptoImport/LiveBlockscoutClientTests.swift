// MoolahTests/Shared/CryptoImport/LiveBlockscoutClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveBlockscoutClient")
struct LiveBlockscoutClientTests {
  private func makeClient(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> LiveBlockscoutClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AlchemyURLProtocolStub.self]
    let session = URLSession(configuration: config)
    AlchemyURLProtocolStub.lastRequest = nil
    AlchemyURLProtocolStub.requestHandler = handler
    return LiveBlockscoutClient(
      session: session, rateLimiter: RateLimiter(permitsPerSecond: 1_000))
  }

  @Test
  func nativeTransactionsHitsCorrectHostAndPath() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("blockscout-tx-value")
    let client = makeClient { req in
      AlchemyURLProtocolStub.captureRequest(req)
      return (AlchemyTestSupport.okResponse(for: req), fixture)
    }
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xABC", fromBlock: 0)
    let url = try #require(AlchemyURLProtocolStub.lastRequest?.url)
    #expect(url.host == "eth.blockscout.com")
    #expect(url.path == "/api/v2/addresses/0xABC/transactions")
    #expect(txs.count == 1)
  }

  @Test
  func internalTransactionsHitsCorrectPath() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("blockscout-internal")
    let client = makeClient { req in
      AlchemyURLProtocolStub.captureRequest(req)
      return (AlchemyTestSupport.okResponse(for: req), fixture)
    }
    _ = try await client.internalTransactions(
      chain: .optimism, walletAddress: "0xABC", fromBlock: 0)
    let url = try #require(AlchemyURLProtocolStub.lastRequest?.url)
    #expect(url.host == "optimism.blockscout.com")
    #expect(url.path == "/api/v2/addresses/0xABC/internal-transactions")
  }

  @Test
  func paginatesUntilCursorAbsentAndStopsBelowFromBlock() async throws {
    // Page 1: one item at block 100, cursor → block 50.
    // Page 2: one item at block 40 (below fromBlock 45) → stop, no page 3.
    let page1 = #"""
      {"items":[{"hash":"0xaa","block_number":100,"timestamp":"2024-01-01T00:00:00.000000Z","from":{"hash":"0xabc"},"to":{"hash":"0xdef"},"value":"10","status":"ok","result":"success"}],"next_page_params":{"block_number":50,"index":1,"items_count":50}}
      """#.data(using: .utf8)!
    let page2 = #"""
      {"items":[{"hash":"0xbb","block_number":40,"timestamp":"2024-01-01T00:00:00.000000Z","from":{"hash":"0xabc"},"to":{"hash":"0xdef"},"value":"10","status":"ok","result":"success"}],"next_page_params":{"block_number":10,"index":1,"items_count":50}}
      """#.data(using: .utf8)!
    let calls = TestCallRecorder()
    let client = makeClient { req in
      calls.record(request: req)
      let hasCursor = req.url?.query?.contains("block_number=50") ?? false
      return (AlchemyTestSupport.okResponse(for: req), hasCursor ? page2 : page1)
    }
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 45)
    #expect(txs.map(\.hash) == ["0xaa", "0xbb"])
    #expect(calls.captured.count == 2)  // stopped: page2's last block 40 < fromBlock 45
  }

  @Test
  func mapsHTTP429ToRateLimited() async throws {
    let client = makeClient { req in
      (AlchemyTestSupport.response(for: req, statusCode: 429), Data())
    }
    await #expect(throws: WalletSyncError.self) {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    }
  }

  @Test
  func malformedJSONThrowsProviderMalformedResponse() async throws {
    let client = makeClient { req in
      (AlchemyTestSupport.okResponse(for: req), Data("not json".utf8))
    }
    await #expect(
      throws: WalletSyncError.providerMalformedResponse(stage: "blockscout.transactions")
    ) {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    }
  }
}
