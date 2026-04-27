// MoolahTests/Backends/CoinGeckoSearchClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CoinGeckoSearchClient", .serialized)
struct CoinGeckoSearchClientTests {
  @Test
  func searchReturnsHitsFromFixture() async throws {
    let client = try Self.makeStubbedClient()

    let hits = try await client.search(query: "bitcoin")
    #expect(hits.count == 2)
    #expect(hits.first?.coingeckoId == "bitcoin")
    #expect(hits.first?.symbol == "BTC")
    #expect(hits.first?.name == "Bitcoin")
    #expect(hits.first?.thumbnail == URL(string: "https://x/bitcoin.png"))
  }

  @Test
  func searchSendsApiKeyHeaderWhenProvided() async throws {
    let capturedHeader = LockedBox<String?>(nil)
    let client = try Self.makeStubbedClient(apiKey: "secret-key") { request in
      capturedHeader.set(request.value(forHTTPHeaderField: "x-cg-demo-api-key"))
    }

    _ = try await client.search(query: "bitcoin")
    #expect(capturedHeader.get() == "secret-key")
  }

  @Test
  func searchThrowsOnErrorStatus() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CoinGeckoSearchURLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = CoinGeckoSearchClient(apiKey: nil, session: session)

    CoinGeckoSearchURLProtocolStub.requestHandler = { request in
      let requestURL = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: requestURL,
          statusCode: 500,
          httpVersion: nil,
          headerFields: nil
        ))
      return (response, Data())
    }

    await #expect(throws: Error.self) {
      _ = try await client.search(query: "x")
    }
  }

  // MARK: - Helpers

  private static func bitcoinFixtureData() throws -> Data {
    let bundle = Bundle(for: TestBundleMarker.self)
    let url = try #require(
      bundle.url(forResource: "coingecko-search-bitcoin", withExtension: "json"))
    return try Data(contentsOf: url)
  }

  private static func makeStubbedClient(
    statusCode: Int = 200,
    apiKey: String? = nil,
    inspectRequest: (@Sendable (URLRequest) -> Void)? = nil
  ) throws -> CoinGeckoSearchClient {
    let data = try bitcoinFixtureData()

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CoinGeckoSearchURLProtocolStub.self]
    let session = URLSession(configuration: config)

    CoinGeckoSearchURLProtocolStub.requestHandler = { request in
      inspectRequest?(request)
      let requestURL = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: requestURL,
          statusCode: statusCode,
          httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        ))
      return (response, data)
    }

    return CoinGeckoSearchClient(apiKey: apiKey, session: session)
  }
}

// Simple URLProtocol stub for CoinGecko search tests. Intentionally non-final
// so the SwiftLint `static_over_final_class` rule doesn't apply to the
// overridden `class func` members.
private class CoinGeckoSearchURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = CoinGeckoSearchURLProtocolStub.requestHandler else {
      fatalError("Handler is not set.")
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
