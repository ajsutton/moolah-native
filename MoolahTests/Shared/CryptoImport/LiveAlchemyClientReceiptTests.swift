// MoolahTests/Shared/CryptoImport/LiveAlchemyClientReceiptTests.swift
import Foundation
import Testing

@testable import Moolah

/// Request-shape and HTTP-error coverage for the new
/// `getTransactionReceipt` method on `LiveAlchemyClient`. Mirrors the
/// existing `LiveAlchemyClientRequestTests` /
/// `LiveAlchemyClientErrorTests` suites — same stub plumbing, same
/// HTTP-status coverage.
@Suite("LiveAlchemyClient — receipt request and error mapping")
struct LiveAlchemyClientReceiptTests {
  @Test
  func receiptRequestUsesEthGetTransactionReceiptMethodAndPassesHash() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("eth-receipt-simple-send")
    let client = AlchemyTestSupport.makeClient { request in
      AlchemyURLProtocolStub.captureRequest(request)
      return (AlchemyTestSupport.okResponse(for: request), fixture)
    }
    _ = try await client.getTransactionReceipt(
      chain: .ethereum,
      hash: "0xabc"
    )

    let url = try #require(AlchemyURLProtocolStub.lastRequest?.url)
    #expect(url.host == "eth-mainnet.g.alchemy.com")
    #expect(url.path == "/v2/test-key")
    let body = AlchemyURLProtocolStub.lastBodyJSON
    #expect(body["method"] as? String == "eth_getTransactionReceipt")
    let paramsArray = try #require(body["params"] as? [String])
    #expect(paramsArray.first == "0xabc")
  }

  @Test
  func receiptRequestUsesPerChainSlug() async throws {
    let fixture = try AlchemyTestSupport.loadFixture("op-receipt-erc20-transfer")
    let client = AlchemyTestSupport.makeClient { request in
      AlchemyURLProtocolStub.captureRequest(request)
      return (AlchemyTestSupport.okResponse(for: request), fixture)
    }
    _ = try await client.getTransactionReceipt(
      chain: .optimism, hash: "0xfeedface")
    let url = try #require(AlchemyURLProtocolStub.lastRequest?.url)
    #expect(url.host == "opt-mainnet.g.alchemy.com")
  }

  @Test
  func httpUnauthorizedMapsToInvalidApiKey() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 401)
      return (response, Data())
    }
    do {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xabc")
      Issue.record("Expected WalletSyncError.invalidApiKey")
    } catch let error as WalletSyncError {
      #expect(error.kind == .invalidApiKey)
      #expect(error.provider == .alchemy)
    }
  }

  @Test
  func httpForbiddenMapsToInvalidApiKey() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 403)
      return (response, Data())
    }
    do {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xabc")
      Issue.record("Expected WalletSyncError.invalidApiKey")
    } catch let error as WalletSyncError {
      #expect(error.kind == .invalidApiKey)
      #expect(error.provider == .alchemy)
    }
  }

  @Test
  func httpTooManyRequestsMapsToRateLimited() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(
        for: request,
        statusCode: 429,
        headerFields: ["Retry-After": "10"]
      )
      return (response, Data())
    }
    do {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xabc")
      Issue.record("Expected WalletSyncError.rateLimited")
    } catch let error as WalletSyncError {
      guard case .rateLimited(let retryAfter) = error.kind else {
        Issue.record("Expected .rateLimited kind, got \(error.kind)")
        return
      }
      let date = try #require(retryAfter)
      #expect(date.timeIntervalSinceNow > 5)
      #expect(date.timeIntervalSinceNow < 15)
    }
  }

  @Test
  func httpServerErrorMapsToNetworkError() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 503)
      return (response, Data())
    }
    do {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xabc")
      Issue.record("Expected WalletSyncError.network")
    } catch let error as WalletSyncError {
      guard case .network(let description) = error.kind else {
        Issue.record("Expected .network kind, got \(error.kind)")
        return
      }
      #expect(description.contains("503"))
    }
  }

  @Test
  func malformedJSONMapsToProviderMalformedResponse() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.okResponse(for: request)
      return (response, Data("not json".utf8))
    }
    do {
      _ = try await client.getTransactionReceipt(
        chain: .ethereum, hash: "0xabc")
      Issue.record("Expected WalletSyncError.providerMalformedResponse")
    } catch let error as WalletSyncError {
      #expect(error.kind == .providerMalformedResponse(stage: "getTransactionReceipt"))
      #expect(error.provider == .alchemy)
    }
  }
}
