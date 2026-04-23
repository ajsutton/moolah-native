import Foundation
import Testing

@testable import Moolah

@Suite("RemoteTransactionRepository — Part 2")
struct RemoteTransactionRepositoryTestsMore {
  private func makeStubSession(data: Data) -> (URLSession, APIClient) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TransactionURLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com/api/")!, session: session)
    return (session, client)
  }

  @Test
  func testScheduledFilterParam() async throws {
    let emptyResponse = Data(
      #"{"transactions": [], "hasMore": false, "priorBalance": 0, "totalNumberOfTransactions": 0}"#
        .utf8)

    let (_, client) = makeStubSession(data: emptyResponse)
    let repository = RemoteTransactionRepository(client: client, instrument: .defaultTestInstrument)

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

  @Test
  func testDateRangeFilterParam() async throws {
    let emptyResponse = Data(
      #"{"transactions": [], "hasMore": false, "priorBalance": 0, "totalNumberOfTransactions": 0}"#
        .utf8)

    let (_, client) = makeStubSession(data: emptyResponse)
    let repository = RemoteTransactionRepository(client: client, instrument: .defaultTestInstrument)

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

    #expect(queryDict["from"] == BackendDateFormatter.string(from: startDate))
    #expect(queryDict["to"] == BackendDateFormatter.string(from: endDate))
  }

  @Test
  func testCategoryIdsFilterParam() async throws {
    let emptyResponse = Data(
      #"{"transactions": [], "hasMore": false, "priorBalance": 0, "totalNumberOfTransactions": 0}"#
        .utf8)

    let (_, client) = makeStubSession(data: emptyResponse)
    let repository = RemoteTransactionRepository(client: client, instrument: .defaultTestInstrument)

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
    #expect(categoryParams.contains(category1.apiString))
    #expect(categoryParams.contains(category2.apiString))
  }

  @Test
  func testPayeeFilterParam() async throws {
    let emptyResponse = Data(
      #"{"transactions": [], "hasMore": false, "priorBalance": 0, "totalNumberOfTransactions": 0}"#
        .utf8)

    let (_, client) = makeStubSession(data: emptyResponse)
    let repository = RemoteTransactionRepository(client: client, instrument: .defaultTestInstrument)

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

  @Test
  func testNullAccountIdEarmarkDTO() {
    let earmarkId = UUID()
    let dto = TransactionDTO(
      id: ServerUUID(UUID()),
      type: "income",
      date: "2026-01-15",
      accountId: nil,
      toAccountId: nil,
      amount: 500,
      payee: nil,
      notes: nil,
      categoryId: nil,
      earmark: ServerUUID(earmarkId),
      recurPeriod: nil,
      recurEvery: nil
    )

    let txn = dto.toDomain(instrument: .defaultTestInstrument)

    #expect(txn.legs.count == 1)
    #expect(txn.legs[0].accountId == nil)
    #expect(txn.legs[0].earmarkId == earmarkId)
    #expect(txn.legs[0].type == .income)
    #expect(txn.legs[0].quantity == 5)
    #expect(txn.legs.contains(where: { $0.earmarkId == earmarkId }))
  }
}

// URLProtocol stub for transaction tests. Intentionally not file-private so
// both `RemoteTransactionRepositoryTests.swift` and
// `RemoteTransactionRepositoryTestsMore.swift` (split from the same suite)
// can register it on their stub URLSessions.
class TransactionURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
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
