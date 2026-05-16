import Foundation

@testable import Moolah

/// In-memory `ExchangeClient` for source/store unit tests. Returns a
/// fixed transaction list (optionally a single synthetic deposit) or
/// throws an injected `ExchangeClientError` so the
/// error-mapping/credential paths are exercisable without a network.
struct StubExchangeClient: ExchangeClient, Sendable {
  private let transactions: [ExchangeImportedTransaction]
  private let error: ExchangeClientError?

  /// - Parameters:
  ///   - transactions: Rows returned from `fetchTransactions`.
  ///   - error: When non-nil, `fetchTransactions` throws this instead.
  init(
    transactions: [ExchangeImportedTransaction] = [],
    error: ExchangeClientError? = nil
  ) {
    self.transactions = transactions
    self.error = error
  }

  /// Convenience: a single inbound deposit of `deposit` AUD. Lets the
  /// integration test assert the row survives the shared pipeline.
  init(deposit: Decimal) {
    self.init(transactions: [
      ExchangeImportedTransaction(
        externalId: "dep-\(deposit)",
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
        category: "DEPOSIT",
        direction: .credit,
        assetSymbol: "AUD",
        amount: deposit,
        isFiat: true,
        orderId: nil)
    ])
  }

  func fetchTransactions(token: String) async throws -> [ExchangeImportedTransaction] {
    if let error { throw error }
    return transactions
  }
}
