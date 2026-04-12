import Foundation
import OSLog
import Observation

enum TradeError: Error, LocalizedError {
  case invalidDraft

  var errorDescription: String? {
    switch self {
    case .invalidDraft: return "Trade details are incomplete or invalid"
    }
  }
}

@Observable
@MainActor
final class TradeStore {
  private(set) var error: Error?

  private let transactions: TransactionRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "TradeStore")

  init(transactions: TransactionRepository) {
    self.transactions = transactions
  }

  func clearError() {
    error = nil
  }

  /// Execute a trade from a draft, creating the multi-leg transaction.
  /// Returns the created transaction, or throws on failure.
  @discardableResult
  func executeTrade(_ draft: TradeDraft) async throws -> Transaction {
    error = nil

    guard let transaction = draft.toTransaction(id: UUID()) else {
      let tradeError = TradeError.invalidDraft
      self.error = tradeError
      throw tradeError
    }

    do {
      let created = try await transactions.create(transaction)
      logger.info("Trade executed: \(created.id) with \(created.legs.count) legs")
      return created
    } catch {
      logger.error("Failed to execute trade: \(error.localizedDescription)")
      self.error = error
      throw error
    }
  }
}
