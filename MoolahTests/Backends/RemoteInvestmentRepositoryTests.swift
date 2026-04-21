import Foundation
import Testing

@testable import Moolah

@Suite("RemoteInvestmentRepository")
struct RemoteInvestmentRepositoryTests {

  private func makeClient(fixtureData: Data) -> (APIClient, RemoteInvestmentRepository) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: session)
    let repository = RemoteInvestmentRepository(client: client, instrument: .defaultTestInstrument)

    URLProtocolStub.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, fixtureData)
    }

    return (client, repository)
  }

  @Test("Fetch values decodes fixture JSON correctly")
  func testFetchValues() async throws {
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "investment_values", withExtension: "json") else {
      fatalError("Could not find investment_values.json fixture")
    }
    let data = try Data(contentsOf: url)
    let (_, repository) = makeClient(fixtureData: data)

    let accountId = UUID()
    let page = try await repository.fetchValues(accountId: accountId, page: 0, pageSize: 50)

    #expect(page.values.count == 3)
    #expect(page.hasMore == false)
    #expect(page.values[0].value.quantity == Decimal(string: "125000.00")!)
    #expect(page.values[1].value.quantity == Decimal(string: "123000.00")!)
    #expect(page.values[2].value.quantity == Decimal(string: "121000.00")!)
  }

  @Test("Fetch values sends correct URL with query parameters")
  func testFetchValuesURL() async throws {
    let fixtureData = """
      {"values": [], "hasMore": false}
      """.data(using: .utf8)!

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: session)
    let repository = RemoteInvestmentRepository(client: client, instrument: .defaultTestInstrument)

    var capturedRequest: URLRequest?
    URLProtocolStub.requestHandler = { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, fixtureData)
    }

    let accountId = UUID()
    _ = try await repository.fetchValues(accountId: accountId, page: 2, pageSize: 25)

    let requestURL = capturedRequest?.url?.absoluteString ?? ""
    #expect(requestURL.contains("accounts/\(accountId.uuidString.lowercased())/values/"))
    #expect(requestURL.contains("pageSize=25"))
    #expect(requestURL.contains("offset=50"))
  }

  @Test("Set value sends PUT request")
  func testSetValue() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: session)
    let repository = RemoteInvestmentRepository(client: client, instrument: .defaultTestInstrument)

    var capturedRequest: URLRequest?
    URLProtocolStub.requestHandler = { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 201,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (response, Data())
    }

    let accountId = UUID()
    let date = BackendDateFormatter.date(from: "2024-03-15")!
    let amount = InstrumentAmount(
      quantity: Decimal(string: "125000.00")!, instrument: .defaultTestInstrument)

    try await repository.setValue(accountId: accountId, date: date, value: amount)

    #expect(capturedRequest?.httpMethod == "PUT")
    let requestURL = capturedRequest?.url?.absoluteString ?? ""
    #expect(requestURL.contains("accounts/\(accountId.uuidString.lowercased())/values/2024-03-15"))
  }

  @Test("Fetch daily balances decodes fixture JSON correctly")
  func testFetchDailyBalances() async throws {
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "account_balances", withExtension: "json") else {
      fatalError("Could not find account_balances.json fixture")
    }
    let data = try Data(contentsOf: url)
    let (_, repository) = makeClient(fixtureData: data)

    let accountId = UUID()
    let balances = try await repository.fetchDailyBalances(accountId: accountId)

    #expect(balances.count == 3)
    #expect(balances[0].balance.quantity == Decimal(string: "1000.00")!)
    #expect(balances[1].balance.quantity == Decimal(string: "2000.00")!)
    #expect(balances[2].balance.quantity == Decimal(string: "3000.00")!)
  }

  @Test("Fetch daily balances sends correct URL")
  func testFetchDailyBalancesURL() async throws {
    let fixtureData = "[]".data(using: .utf8)!

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: session)
    let repository = RemoteInvestmentRepository(client: client, instrument: .defaultTestInstrument)

    var capturedRequest: URLRequest?
    URLProtocolStub.requestHandler = { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, fixtureData)
    }

    let accountId = UUID()
    _ = try await repository.fetchDailyBalances(accountId: accountId)

    let requestURL = capturedRequest?.url?.absoluteString ?? ""
    #expect(requestURL.contains("accounts/\(accountId.uuidString.lowercased())/balances"))
  }

  @Test("Remove value sends DELETE request")
  func testRemoveValue() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: session)
    let repository = RemoteInvestmentRepository(client: client, instrument: .defaultTestInstrument)

    var capturedRequest: URLRequest?
    URLProtocolStub.requestHandler = { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: [:]
      )!
      return (response, Data())
    }

    let accountId = UUID()
    let date = BackendDateFormatter.date(from: "2024-03-15")!

    try await repository.removeValue(accountId: accountId, date: date)

    #expect(capturedRequest?.httpMethod == "DELETE")
    let requestURL = capturedRequest?.url?.absoluteString ?? ""
    #expect(requestURL.contains("accounts/\(accountId.uuidString.lowercased())/values/2024-03-15"))
  }
}

private class URLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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
