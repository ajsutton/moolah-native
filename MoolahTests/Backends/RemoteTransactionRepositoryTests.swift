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

  private func makeGuardOnlyRepository(instrument: Instrument)
    -> RemoteTransactionRepository
  {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TransactionURLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com/api/")!, session: session)
    TransactionURLProtocolStub.requestHandler = { _ in
      Issue.record("Network request should not be made when instrument guard fires")
      let response = HTTPURLResponse(
        url: URL(string: "https://api.example.com")!, statusCode: 500, httpVersion: nil,
        headerFields: nil)!
      return (response, Data())
    }
    return RemoteTransactionRepository(client: client, instrument: instrument)
  }

  @Test
  func createRejectsTransactionWithForeignLeg() async throws {
    let repo = makeGuardOnlyRepository(instrument: .AUD)
    let leg = TransactionLeg(
      accountId: UUID(), instrument: .USD, quantity: 50, type: .expense)
    let txn = Transaction(date: Date(), legs: [leg])
    await #expect(throws: BackendError.self) {
      _ = try await repo.create(txn)
    }
  }

  @Test
  func updateRejectsTransactionWhereAnyLegIsForeign() async throws {
    let repo = makeGuardOnlyRepository(instrument: .AUD)
    let nativeLeg = TransactionLeg(
      accountId: UUID(), instrument: .AUD, quantity: 100, type: .income)
    let foreignLeg = TransactionLeg(
      accountId: UUID(), instrument: .USD, quantity: -100, type: .expense)
    let txn = Transaction(date: Date(), legs: [nativeLeg, foreignLeg])
    await #expect(throws: BackendError.self) {
      _ = try await repo.update(txn)
    }
  }

  @Test
  func testDecodesFixtureJSON() async throws {
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "transactions", withExtension: "json") else {
      fatalError("Could not find transactions.json fixture")
    }
    let data = try Data(contentsOf: url)

    let (_, client) = makeStubSession(data: data)
    let repository = RemoteTransactionRepository(client: client, instrument: .defaultTestInstrument)

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
    let prior = try #require(page.priorBalance)
    #expect(prior == .zero(instrument: .defaultTestInstrument))

    let transactions = page.transactions

    // First transaction: expense
    #expect(transactions[0].legs.first?.type == .expense)
    #expect(transactions[0].legs.first?.quantity == Decimal(string: "-50.23")!)
    #expect(transactions[0].payee == "Woolworths")
    #expect(transactions[0].notes == "Weekly groceries")
    #expect(transactions[0].legs.contains(where: { $0.categoryId != nil }))

    // Second transaction: income
    #expect(transactions[1].legs.first?.type == .income)
    #expect(transactions[1].legs.first?.quantity == Decimal(string: "3500.00")!)
    #expect(transactions[1].payee == "Employer Pty Ltd")

    // Third transaction: transfer
    #expect(transactions[2].legs.first?.type == .transfer)
    #expect(transactions[2].legs.count == 2)
    #expect(transactions[2].legs.first?.quantity == Decimal(string: "-1000.00")!)

    // Fourth transaction: scheduled expense
    #expect(transactions[3].recurPeriod == .month)
    #expect(transactions[3].recurEvery == 1)
    #expect(transactions[3].isScheduled == true)

    // Fifth transaction: regular expense (not scheduled)
    #expect(transactions[4].isScheduled == false)
  }

  @Test
  func testConstructsCorrectURLParams() async throws {
    let emptyResponse = Data(
      #"{"transactions": [], "hasMore": false, "priorBalance": 0, "totalNumberOfTransactions": 0}"#
        .utf8)

    let (_, client) = makeStubSession(data: emptyResponse)
    let repository = RemoteTransactionRepository(client: client, instrument: .defaultTestInstrument)
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

    #expect(queryDict["account"] == accountId.apiString)
    #expect(queryDict["pageSize"] == "25")
    #expect(queryDict["offset"] == "50")  // page 2 * pageSize 25
  }
}
