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
    #expect(page.priorBalance == .zero)

    let transactions = page.transactions

    // First transaction: expense
    #expect(transactions[0].type == .expense)
    #expect(
      transactions[0].amount == MonetaryAmount(cents: -5023, currency: Currency.defaultCurrency))
    #expect(transactions[0].payee == "Woolworths")
    #expect(transactions[0].notes == "Weekly groceries")
    #expect(transactions[0].categoryId != nil)

    // Second transaction: income
    #expect(transactions[1].type == .income)
    #expect(
      transactions[1].amount == MonetaryAmount(cents: 350000, currency: Currency.defaultCurrency))
    #expect(transactions[1].payee == "Employer Pty Ltd")

    // Third transaction: transfer
    #expect(transactions[2].type == .transfer)
    #expect(transactions[2].toAccountId != nil)
    #expect(
      transactions[2].amount == MonetaryAmount(cents: -100000, currency: Currency.defaultCurrency))

    // Fourth transaction: scheduled expense
    #expect(transactions[3].recurPeriod == .month)
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

  @Test func testDateRangeFilterParam() async throws {
    let emptyResponse = """
      {"transactions": [], "hasMore": false, "priorBalance": 0, "totalNumberOfTransactions": 0}
      """.data(using: .utf8)!

    let (_, client) = makeStubSession(data: emptyResponse)
    let repository = RemoteTransactionRepository(client: client)

    let calendar = Calendar.current
    let startDate = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
    let endDate = calendar.date(from: DateComponents(year: 2024, month: 12, day: 31))!
    let dateRange = startDate...endDate

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
      filter: TransactionFilter(dateRange: dateRange),
      page: 0,
      pageSize: 50
    )

    let components = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)!
    let queryItems = components.queryItems ?? []
    let queryDict = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

    #expect(queryDict["startDate"] == BackendDateFormatter.string(from: startDate))
    #expect(queryDict["endDate"] == BackendDateFormatter.string(from: endDate))
  }

  @Test func testCategoryIdsFilterParam() async throws {
    let emptyResponse = """
      {"transactions": [], "hasMore": false, "priorBalance": 0, "totalNumberOfTransactions": 0}
      """.data(using: .utf8)!

    let (_, client) = makeStubSession(data: emptyResponse)
    let repository = RemoteTransactionRepository(client: client)

    let category1 = UUID()
    let category2 = UUID()
    let categoryIds: Set<UUID> = [category1, category2]

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
      filter: TransactionFilter(categoryIds: categoryIds),
      page: 0,
      pageSize: 50
    )

    let components = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)!
    let queryItems = components.queryItems ?? []
    let categoryParams = queryItems.filter { $0.name == "category" }.compactMap { $0.value }

    #expect(categoryParams.count == 2)
    #expect(categoryParams.contains(category1.uuidString))
    #expect(categoryParams.contains(category2.uuidString))
  }

  @Test func testPayeeFilterParam() async throws {
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
      filter: TransactionFilter(payee: "Woolworths"),
      page: 0,
      pageSize: 50
    )

    let components = URLComponents(url: capturedURL!, resolvingAgainstBaseURL: false)!
    let queryItems = components.queryItems ?? []
    let queryDict = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })

    #expect(queryDict["payee"] == "Woolworths")
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
