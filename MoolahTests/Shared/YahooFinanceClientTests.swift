// MoolahTests/Shared/YahooFinanceClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("YahooFinanceClient")
struct YahooFinanceClientTests {
  private func loadFixture(_ name: String) throws -> Data {
    guard
      let url = Bundle(for: TestBundleMarker.self)
        .url(forResource: name, withExtension: "json")
    else {
      fatalError("Could not find \(name).json fixture")
    }
    return try Data(contentsOf: url)
  }

  private func makeClient(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> (YahooFinanceClient, URLSession) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = YahooFinanceClient(session: session)
    URLProtocolStub.lastRequest = nil
    URLProtocolStub.requestHandler = handler
    return (client, session)
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.date(from: string)!
  }

  @Test
  func requestURLContainsTickerAndDateRange() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      URLProtocolStub.lastRequest = request
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    _ = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    let url = URLProtocolStub.lastRequest!.url!
    #expect(url.path().contains("BHP.AX"))
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let queryItems = components.queryItems ?? []
    #expect(queryItems.contains { $0.name == "interval" && $0.value == "1d" })
    #expect(queryItems.contains { $0.name == "period1" })
    #expect(queryItems.contains { $0.name == "period2" })
  }

  @Test
  func requestIncludesUserAgentHeader() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      URLProtocolStub.lastRequest = request
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    _ = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    let userAgent = URLProtocolStub.lastRequest!.value(forHTTPHeaderField: "User-Agent")
    #expect(userAgent != nil)
    #expect(userAgent!.isEmpty == false)
  }

  @Test
  func parsesAdjustedCloseAndCurrency() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    let result = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    #expect(result.instrument == .AUD)
    // Two entries (third has null adjclose and should be skipped)
    #expect(result.prices.count == 2)
    #expect(result.prices["2022-04-05"] == dec("37.80"))
    #expect(result.prices["2022-04-06"] == dec("38.10"))
  }

  @Test
  func skipsNullAdjcloseValues() async throws {
    let fixtureData = try loadFixture("yahoo-finance-chart-response")

    let (client, _) = makeClient { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    let result = try await client.fetchDailyPrices(
      ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))

    // Third timestamp has null adjclose — should not appear
    #expect(result.prices["2022-04-07"] == nil)
  }

  @Test
  func errorResponseThrows() async throws {
    let fixtureData = try loadFixture("yahoo-finance-error-response")

    let (client, _) = makeClient { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, fixtureData)
    }

    await #expect(throws: (any Error).self) {
      try await client.fetchDailyPrices(
        ticker: "INVALID.AX", from: date("2022-04-05"), to: date("2022-04-07"))
    }
  }

  @Test
  func httpErrorThrows() async throws {
    let (client, _) = makeClient { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 404, httpVersion: nil,
        headerFields: nil)!
      return (response, Data())
    }

    await #expect(throws: (any Error).self) {
      try await client.fetchDailyPrices(
        ticker: "BHP.AX", from: date("2022-04-05"), to: date("2022-04-07"))
    }
  }
}

// MARK: - URLProtocol stub (same pattern as RemoteAccountRepositoryTests)

private class URLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var lastRequest: URLRequest?

  static func register() {
    URLProtocol.registerClass(URLProtocolStub.self)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = URLProtocolStub.requestHandler else {
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
