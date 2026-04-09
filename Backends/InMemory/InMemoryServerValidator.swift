import Foundation

/// Test double for ServerValidator. Configurable success/failure behavior.
final class InMemoryServerValidator: ServerValidator, @unchecked Sendable {
  var shouldSucceed = true
  var errorMessage = "Validation failed"

  func validate(url: URL) async throws {
    guard shouldSucceed else {
      throw BackendError.validationFailed(errorMessage)
    }
  }
}
