import Foundation
import Testing

@testable import Moolah

@Suite("RemoteAccountRepository")
struct RemoteAccountRepositoryTests {
  @Test func testDecodesFixtureJSON() async throws {
    // Given
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "accounts", withExtension: "json") else {
      fatalError("Could not find accounts.json fixture")
    }
    let data = try Data(contentsOf: url)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: session)
    let repository = RemoteAccountRepository(client: client)

    URLProtocolStub.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, data)
    }

    // When
    let accounts = try await repository.fetchAll()

    // Then
    #expect(accounts.count == 5)
    #expect(accounts[0].name == "Checking Account")
    #expect(accounts[0].type == .bank)
    #expect(accounts[0].balance == MonetaryAmount(cents: 123456))
    #expect(accounts[3].name == "Investment Portfolio")
    #expect(accounts[3].type == .investment)
    #expect(accounts[3].balance == MonetaryAmount(cents: 1_550_000))  // Prefers 'value' from JSON
  }
}

// Simple URLProtocol stub for testing
private class URLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  static func register() {
    URLProtocol.registerClass(URLProtocolStub.self)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
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
