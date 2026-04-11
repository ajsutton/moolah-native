import Foundation

enum MigrationError: Error, Sendable {
  case exportFailed(step: String, underlying: Error)
  case importFailed(underlying: Error)
  case verificationFailed(VerificationResult)
  case iCloudUnavailable
  case unexpected(Error)
}

extension MigrationError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .exportFailed(let step, let underlying):
      return "Failed to export \(step): \(Self.detailedDescription(underlying))"
    case .importFailed(let underlying):
      return "Failed to import data: \(Self.detailedDescription(underlying))"
    case .verificationFailed:
      return "Data verification failed after import"
    case .iCloudUnavailable:
      return "iCloud is not available. Please sign in to iCloud in Settings."
    case .unexpected(let error):
      return "Unexpected error: \(Self.detailedDescription(error))"
    }
  }

  /// Extracts detailed information from DecodingError, which localizedDescription hides.
  private static func detailedDescription(_ error: Error) -> String {
    guard let decodingError = error as? DecodingError else {
      return error.localizedDescription
    }
    switch decodingError {
    case .typeMismatch(let type, let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return "Type mismatch for \(type) at \(path): \(context.debugDescription)"
    case .valueNotFound(let type, let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return "Missing value for \(type) at \(path): \(context.debugDescription)"
    case .keyNotFound(let key, let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return "Missing key '\(key.stringValue)' at \(path): \(context.debugDescription)"
    case .dataCorrupted(let context):
      let path = context.codingPath.map(\.stringValue).joined(separator: ".")
      return "Data corrupted at \(path): \(context.debugDescription)"
    @unknown default:
      return error.localizedDescription
    }
  }
}
