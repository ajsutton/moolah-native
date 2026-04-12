import Foundation
import Testing

@testable import Moolah

@Suite("RemoteEarmarkRepository")
struct RemoteEarmarkRepositoryTests {
  @Test func testDecodesFixtureJSON() async throws {
    // Given
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "earmarks", withExtension: "json") else {
      fatalError("Could not find earmarks.json fixture")
    }
    let data = try Data(contentsOf: url)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: session)
    let repository = RemoteEarmarkRepository(client: client, instrument: .defaultTestInstrument)

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
    let earmarks = try await repository.fetchAll()

    // Then
    #expect(earmarks.count == 3)
    #expect(earmarks[0].name == "Holiday Fund")
    #expect(earmarks[0].position == 1)
    #expect(earmarks[0].isHidden == false)
    #expect(
      earmarks[0].balance
        == InstrumentAmount(
          quantity: Decimal(string: "2500.00")!, instrument: .defaultTestInstrument))
    #expect(
      earmarks[0].saved
        == InstrumentAmount(
          quantity: Decimal(string: "3000.00")!, instrument: .defaultTestInstrument))
    #expect(
      earmarks[0].spent
        == InstrumentAmount(
          quantity: Decimal(string: "-500.00")!, instrument: .defaultTestInstrument))
    #expect(
      earmarks[0].savingsGoal
        == InstrumentAmount(
          quantity: Decimal(string: "5000.00")!, instrument: .defaultTestInstrument))
    #expect(earmarks[0].savingsStartDate != nil)
    #expect(earmarks[0].savingsEndDate != nil)

    #expect(earmarks[1].name == "Emergency Fund")
    #expect(earmarks[1].savingsGoal == nil)
    #expect(earmarks[1].savingsStartDate == nil)
    #expect(earmarks[1].savingsEndDate == nil)

    #expect(earmarks[2].name == "Old Earmark")
    #expect(earmarks[2].isHidden == true)
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
