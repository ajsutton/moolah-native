import Foundation
import Testing

@testable import Moolah

@Suite("RemoteCategoryRepository")
struct RemoteCategoryRepositoryTests {
  @Test
  func testDecodesFixtureJSON() async throws {
    // Given
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "categories", withExtension: "json") else {
      fatalError("Could not find categories.json fixture")
    }
    let data = try Data(contentsOf: url)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: makeURL("https://api.example.com"), session: session)
    let repository = RemoteCategoryRepository(client: client)

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
    let categories = try await repository.fetchAll()

    // Then
    #expect(categories.count == 5)

    let groceries = categories.first { $0.name == "Groceries" }
    #expect(groceries != nil)
    #expect(groceries?.parentId == nil)

    let fruit = categories.first { $0.name == "Fruit" }
    #expect(fruit != nil)
    #expect(fruit?.parentId == groceries?.id)

    let transport = categories.first { $0.name == "Transport" }
    #expect(transport != nil)
    #expect(transport?.parentId == nil)
  }
}

// Simple URLProtocol stub for testing
private class URLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
