import Foundation

// MARK: - Recurrence Utilities

extension Transaction {
  /// Calculates the next due date for a recurring transaction.
  /// Returns nil if the transaction is not recurring (period is nil or .once).
  func nextDueDate() -> Date? {
    guard let period = recurPeriod, let every = recurEvery, period != .once else {
      return nil
    }

    let calendar = Calendar.current
    var components = DateComponents()

    switch period {
    case .day:
      components.day = every
    case .week:
      components.weekOfYear = every
    case .month:
      components.month = every
    case .year:
      components.year = every
    case .once:
      return nil
    }

    return calendar.date(byAdding: components, to: date)
  }

  /// Validates the transaction's fields.
  func validate() throws {
    // If either recurPeriod or recurEvery is set, both must be set
    if (recurPeriod != nil) != (recurEvery != nil) {
      throw ValidationError.incompleteRecurrence
    }

    // If recurring, recurEvery must be at least 1
    if let every = recurEvery, every < 1 {
      throw ValidationError.invalidRecurEvery
    }

    if legs.isEmpty {
      throw ValidationError.noLegs
    }
  }

  enum ValidationError: LocalizedError {
    case incompleteRecurrence
    case invalidRecurEvery
    case noLegs

    var errorDescription: String? {
      switch self {
      case .incompleteRecurrence:
        return "Recurrence must have both period and frequency set"
      case .invalidRecurEvery:
        return "Recurrence frequency must be at least 1"
      case .noLegs:
        return "Transaction must have at least one leg"
      }
    }
  }
}
