import Foundation
import Testing

@testable import Moolah

@Suite("RemoteServerValidator")
struct RemoteServerValidatorTests {
  private func makeValidator() -> (RemoteServerValidator, URLSession) {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [URLProtocolStub.self]
    let session = URLSession(configuration: config)
    let validator = RemoteServerValidator(session: session)
    return (validator, session)
  }

  @Test("succeeds when server returns loggedIn false")
  func validNotLoggedIn() async throws {
    let (validator, _) = makeValidator()
    URLProtocolStub.requestHandler = { request in
      #expect(request.url?.absoluteString == "https://example.com/api/auth/")
      let json = #"{"loggedIn": false}"#
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, Data(json.utf8))
    }

    try await validator.validate(url: makeURL("https://example.com/api/"))
  }

  @Test("succeeds when server returns loggedIn true with profile")
  func validLoggedIn() async throws {
    let (validator, _) = makeValidator()
    URLProtocolStub.requestHandler = { request in
      let json = """
        {"loggedIn": true, "profile": {"userId": "u1", "givenName": "Ada", "familyName": "Lovelace"}}
        """
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, Data(json.utf8))
    }

    try await validator.validate(url: makeURL("https://example.com/api/"))
  }

  @Test("throws validationFailed for non-JSON response")
  func nonJSON() async {
    let (validator, _) = makeValidator()
    URLProtocolStub.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "text/html"])!
      return (response, Data("<html>Not Found</html>".utf8))
    }

    await #expect(throws: BackendError.self) {
      try await validator.validate(url: makeURL("https://example.com/api/"))
    }
  }

  @Test("throws validationFailed for JSON without loggedIn field")
  func missingLoggedInField() async {
    let (validator, _) = makeValidator()
    URLProtocolStub.requestHandler = { request in
      let json = #"{"status": "ok"}"#
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      return (response, Data(json.utf8))
    }

    await #expect(throws: BackendError.self) {
      try await validator.validate(url: makeURL("https://example.com/api/"))
    }
  }

  @Test("throws validationFailed for HTTP 500")
  func serverError() async {
    let (validator, _) = makeValidator()
    URLProtocolStub.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
      return (response, Data())
    }

    await #expect(throws: BackendError.self) {
      try await validator.validate(url: makeURL("https://example.com/api/"))
    }
  }

  @Test("throws validationFailed for network error")
  func networkError() async {
    let (validator, _) = makeValidator()
    URLProtocolStub.requestHandler = { _ in
      throw URLError(.notConnectedToInternet)
    }

    await #expect(throws: BackendError.self) {
      try await validator.validate(url: makeURL("https://example.com/api/"))
    }
  }
}

// Simple URLProtocol stub for testing
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
