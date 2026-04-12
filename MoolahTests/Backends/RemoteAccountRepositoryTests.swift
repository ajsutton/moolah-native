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
    #expect(
      accounts[0].balance
        == InstrumentAmount(
          quantity: Decimal(string: "1234.56")!, instrument: .defaultTestInstrument))
    #expect(accounts[3].name == "Investment Portfolio")
    #expect(accounts[3].type == .investment)
    // balance is the transaction-based invested amount
    #expect(
      accounts[3].balance
        == InstrumentAmount(
          quantity: Decimal(string: "15000.00")!, instrument: .defaultTestInstrument))
    // investmentValue is the market value from the server's 'value' field
    #expect(accounts[3].investmentValue != nil)
    #expect(
      accounts[3].investmentValue
        == InstrumentAmount(
          quantity: Decimal(string: "15500.00")!, instrument: .defaultTestInstrument))
    // displayBalance prefers investmentValue for investment accounts
    #expect(accounts[3].displayBalance.quantity == Decimal(string: "15500.00")!)
  }

  @Test func testCreateAccountCallsCorrectEndpoint() async throws {
    // Given
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "account_create_response", withExtension: "json") else {
      fatalError("Could not find account_create_response.json fixture")
    }
    let data = try Data(contentsOf: url)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: session)
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
      balance: InstrumentAmount(
        quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument)
    )

    // When
    let created = try await repository.create(newAccount)

    // Then
    #expect(capturedRequest?.httpMethod == "POST")
    #expect(capturedRequest?.url?.absoluteString == "https://api.example.com/accounts/")
    #expect(created.name == "Savings Account")
    #expect(created.balance.quantity == Decimal(string: "1000.00")!)
  }

  @Test func testUpdateAccountCallsCorrectEndpoint() async throws {
    // Given
    let bundle = Bundle(for: TestBundleMarker.self)
    guard let url = bundle.url(forResource: "account_update_response", withExtension: "json") else {
      fatalError("Could not find account_update_response.json fixture")
    }
    let data = try Data(contentsOf: url)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: session)
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

    let accountId = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
    let updatedAccount = Account(
      id: accountId,
      name: "Updated Savings",
      type: .bank,
      balance: InstrumentAmount(
        quantity: Decimal(string: "1000.00")!, instrument: .defaultTestInstrument),
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
    #expect(updated.balance.quantity == Decimal(string: "1234.56")!)  // Server's balance, not client's
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
