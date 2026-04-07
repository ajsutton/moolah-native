import Foundation
import Testing

@testable import Moolah

@Suite("RemoteTransactionRepository")
struct RemoteTransactionRepositoryTests {
  private func makeStubSession(data: Data) -> (URLSession, APIClient) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TransactionURLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com/api/")!, session: session)
    return (session, client)
  }

  @Test func testDecodesFixtureJSON() async throws {
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "transactions", withExtension: "json") else {
      fatalError("Could not find transactions.json fixture")
    }
    let data = try Data(contentsOf: url)

    let (_, client) = makeStubSession(data: data)
    let repository = RemoteTransactionRepository(client: client)

    TransactionURLProtocolStub.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, data)
    }

    let page = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )

    #expect(page.transactions.count == 5)
    #expect(page.priorBalance == 0)

    let transactions = page.transactions

    // First transaction: expense
    #expect(transactions[0].type == .expense)
    #expect(transactions[0].amount == -5023)
    #expect(transactions[0].payee == "Woolworths")
    #expect(transactions[0].notes == "Weekly groceries")
    #expect(transactions[0].categoryId != nil)

    // Second transaction: income
    #expect(transactions[1].type == .income)
    #expect(transactions[1].amount == 350000)
    #expect(transactions[1].payee == "Employer Pty Ltd")

    // Third transaction: transfer
    #expect(transactions[2].type == .transfer)
    #expect(transactions[2].toAccountId != nil)
    #expect(transactions[2].amount == -100000)

    // Fourth transaction: scheduled expense
    #expect(transactions[3].recurPeriod == "MONTH")
    #expect(transactions[3].recurEvery == 1)
    #expect(transactions[3].isScheduled == true)

    // Fifth transaction: regular expense (not scheduled)
    #expect(transactions[4].isScheduled == false)
  }

  @Test func testConstructsCorrectURLParams() async throws {
    let emptyResponse = """
      {"transactions": [], "hasMore": false, "priorBalance": 0, "totalNumberOfTransactions": 0}
      """.data(using: .utf8)!

    let (_, client) = makeStubSession(data: emptyResponse)
    let repository = RemoteTransactionRepository(client: client)
    let accountId = UUID()

    var capturedURL: URL?
    TransactionURLProtocolStub.requestHandler = { request in
      capturedURL = request.url
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, emptyResponse)
    }

    _ = try await repository.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 2,
      pageSize: 25
    )

    let components = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)!
    let queryItems = components.queryItems ?? []
    let queryDict = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

    #expect(queryDict["account"] == accountId.uuidString)
    #expect(queryDict["pageSize"] == "25")
    #expect(queryDict["offset"] == "50")  // page 2 * pageSize 25
  }

  @Test func testScheduledFilterParam() async throws {
    let emptyResponse = """
      {"transactions": [], "hasMore": false, "priorBalance": 0, "totalNumberOfTransactions": 0}
      """.data(using: .utf8)!

    let (_, client) = makeStubSession(data: emptyResponse)
    let repository = RemoteTransactionRepository(client: client)

    var capturedURL: URL?
    TransactionURLProtocolStub.requestHandler = { request in
      capturedURL = request.url
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, emptyResponse)
    }

    _ = try await repository.fetch(
      filter: TransactionFilter(scheduled: true),
      page: 0,
      pageSize: 50
    )

    let components = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)!
    let queryItems = components.queryItems ?? []
    let queryDict = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

    #expect(queryDict["scheduled"] == "true")
  }
}

// URLProtocol stub for transaction tests
private class TransactionURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    guard let handler = TransactionURLProtocolStub.requestHandler else {
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
