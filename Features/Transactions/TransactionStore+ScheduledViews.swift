import Foundation

extension TransactionStore {
  /// Scheduled transactions whose date is before today, sorted ascending by
  /// date. Empty when the store's current filter isn't `scheduled: .scheduledOnly`
  /// — views sharing the store ignore stale contents from an unfiltered load in
  /// the frame before their own `.task` reloads the store.
  var scheduledOverdueTransactions: [TransactionWithBalance] {
    let today = Calendar.current.startOfDay(for: Date())
    return scheduledTransactions { $0 < today }
  }

  /// Scheduled transactions due today or later, sorted ascending by date.
  var scheduledUpcomingTransactions: [TransactionWithBalance] {
    let today = Calendar.current.startOfDay(for: Date())
    return scheduledTransactions { $0 >= today }
  }

  /// Scheduled transactions from the past plus the next `daysAhead` days —
  /// the set shown in the Analysis "Upcoming & Overdue" card.
  func scheduledShortTermTransactions(daysAhead: Int = 14) -> [TransactionWithBalance] {
    let ceiling = Calendar.current.date(byAdding: .day, value: daysAhead, to: Date()) ?? Date()
    return scheduledTransactions { $0 <= ceiling }
  }

  private func scheduledTransactions(
    where matches: (Date) -> Bool
  ) -> [TransactionWithBalance] {
    guard currentFilter.scheduled == .scheduledOnly else { return [] }
    return
      transactions
      .filter { matches($0.transaction.date) }
      .sorted { $0.transaction.date < $1.transaction.date }
  }
}
