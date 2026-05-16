import Foundation

enum ExchangeClientError: Error, Sendable, Equatable {
  case unauthorized
  case rateLimited(retryAfter: Date?)
  case http(Int)
  case malformedResponse
  case providerError(String)
}
