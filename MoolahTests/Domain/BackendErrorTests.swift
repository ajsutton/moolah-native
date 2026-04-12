import Foundation
import Testing

@testable import Moolah

@Suite("BackendError.userMessage")
struct BackendErrorTests {

  @Test func testServerErrorMessage() {
    let error = BackendError.serverError(500)
    #expect(error.userMessage == "Server error (500). Please try again.")
  }

  @Test func testNetworkUnavailableMessage() {
    let error = BackendError.networkUnavailable
    #expect(error.userMessage == "Network error. Check your connection.")
  }

  @Test func testUnauthenticatedMessage() {
    let error = BackendError.unauthenticated
    #expect(error.userMessage == "Session expired. Please log in again.")
  }

  @Test func testNonBackendErrorFallback() {
    let error: Error = NSError(
      domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something broke"])
    #expect(error.userMessage == "Operation failed: Something broke")
  }
}
