import Foundation
import Testing

@testable import Moolah

@Suite("RemoteAccountRepository")
struct RemoteAccountRepositoryTests {
  private func makeRepository(instrument: Instrument = .defaultTestInstrument)
    -> RemoteAccountRepository
  {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: makeURL("https://api.example.com"), session: session)
    // Fail the test if the guard doesn't short-circuit before the network call.
    URLProtocolStub.requestHandler = { _ in
      Issue.record("Network request should not be made when instrument guard fires")
      let response = HTTPURLResponse(
        url: makeURL("https://api.example.com"), statusCode: 500, httpVersion: nil,
        headerFields: nil)!
      return (response, Data())
    }
    return RemoteAccountRepository(client: client, instrument: instrument)
  }

  @Test
  func createRejectsAccountWithNonProfileInstrument() async throws {
    let repo = makeRepository(instrument: .AUD)
    let account = Account(name: "USD Savings", type: .bank, instrument: .USD)
    await #expect(throws: BackendError.self) {
      _ = try await repo.create(account)
    }
  }

  @Test
  func createRejectsOpeningBalanceInForeignInstrument() async throws {
    let repo = makeRepository(instrument: .AUD)
    let account = Account(name: "AUD Savings", type: .bank, instrument: .AUD)
    let foreignOpening = InstrumentAmount(quantity: 100, instrument: .USD)
    await #expect(throws: BackendError.self) {
      _ = try await repo.create(account, openingBalance: foreignOpening)
    }
  }

  @Test
  func updateRejectsAccountWithNonProfileInstrument() async throws {
    let repo = makeRepository(instrument: .AUD)
    let account = Account(name: "USD Savings", type: .bank, instrument: .USD)
    await #expect(throws: BackendError.self) {
      _ = try await repo.update(account)
    }
  }

  @Test
  func testDecodesFixtureJSON() async throws {
    // Given
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "accounts", withExtension: "json") else {
      fatalError("Could not find accounts.json fixture")
    }
    let data = try Data(contentsOf: url)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: makeURL("https://api.example.com"), session: session)
    let repository = RemoteAccountRepository(client: client, instrument: .defaultTestInstrument)

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
    // Balance is now in positions
    let checkingPosition = accounts[0].positions.first(where: {
      $0.instrument == .defaultTestInstrument
    })
    #expect(checkingPosition?.quantity == dec("1234.56"))
    #expect(accounts[3].name == "Investment Portfolio")
    #expect(accounts[3].type == .investment)
    // balance is the transaction-based invested amount, now in positions
    let investmentPosition = accounts[3].positions.first(where: {
      $0.instrument == .defaultTestInstrument
    })
    #expect(investmentPosition?.quantity == dec("15000.00"))
  }

  @Test
  func testCreateAccountCallsCorrectEndpoint() async throws {
    // Given
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "account_create_response", withExtension: "json") else {
      fatalError("Could not find account_create_response.json fixture")
    }
    let data = try Data(contentsOf: url)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: makeURL("https://api.example.com"), session: session)
    let repository = RemoteAccountRepository(client: client, instrument: .defaultTestInstrument)

    var capturedRequest: URLRequest?
    URLProtocolStub.requestHandler = { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 201,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, data)
    }

    let newAccount = Account(
      name: "Savings Account",
      type: .bank,
      instrument: .defaultTestInstrument
    )
    let openingBalance = InstrumentAmount(
      quantity: dec("1000.00"), instrument: .defaultTestInstrument)

    // When
    let created = try await repository.create(newAccount, openingBalance: openingBalance)

    // Then
    #expect(capturedRequest?.httpMethod == "POST")
    #expect(capturedRequest?.url?.absoluteString == "https://api.example.com/accounts/")
    #expect(created.name == "Savings Account")
    let createdPosition = created.positions.first(where: {
      $0.instrument == .defaultTestInstrument
    })
    #expect(createdPosition?.quantity == dec("1000.00"))
  }

  @Test
  func testUpdateAccountCallsCorrectEndpoint() async throws {
    // Given
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "account_update_response", withExtension: "json") else {
      fatalError("Could not find account_update_response.json fixture")
    }
    let data = try Data(contentsOf: url)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: makeURL("https://api.example.com"), session: session)
    let repository = RemoteAccountRepository(client: client, instrument: .defaultTestInstrument)

    var capturedRequest: URLRequest?
    URLProtocolStub.requestHandler = { request in
      capturedRequest = request
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )!
      return (response, data)
    }

    let accountId = makeUUID("550e8400-e29b-41d4-a716-446655440000")
    let updatedAccount = Account(
      id: accountId,
      name: "Updated Savings",
      type: .bank,
      instrument: .defaultTestInstrument,
      position: 2,
      isHidden: true
    )

    // When
    let updated = try await repository.update(updatedAccount)

    // Then
    #expect(capturedRequest?.httpMethod == "PUT")
    #expect(
      capturedRequest?.url?.absoluteString
        == "https://api.example.com/accounts/550e8400-e29b-41d4-a716-446655440000/")
    #expect(updated.name == "Updated Savings")
    // Server's balance, not client's - now reflected in positions
    let updatedPosition = updated.positions.first(where: {
      $0.instrument == .defaultTestInstrument
    })
    #expect(updatedPosition?.quantity == dec("1234.56"))
    #expect(updated.isHidden == true)
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
