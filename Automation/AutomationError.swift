import Foundation

enum AutomationError: LocalizedError, Sendable {
  case profileNotFound(String)
  case profileNotOpen(String)
  case accountNotFound(String)
  case transactionNotFound(String)
  case earmarkNotFound(String)
  case categoryNotFound(String)
  case invalidParameter(String)
  case operationFailed(String)

  var errorDescription: String? {
    switch self {
    case .profileNotFound(let name): "Profile not found: \(name)"
    case .profileNotOpen(let name): "Profile not open: \(name)"
    case .accountNotFound(let name): "Account not found: \(name)"
    case .transactionNotFound(let id): "Transaction not found: \(id)"
    case .earmarkNotFound(let name): "Earmark not found: \(name)"
    case .categoryNotFound(let name): "Category not found: \(name)"
    case .invalidParameter(let detail): "Invalid parameter: \(detail)"
    case .operationFailed(let detail): "Operation failed: \(detail)"
    }
  }
}
