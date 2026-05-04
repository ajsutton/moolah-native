import Foundation

struct TransactionFilter: Sendable, Equatable {
  var accountId: UUID?
  var earmarkId: UUID?
  var scheduled: ScheduledFilter
  var dateRange: ClosedRange<Date>?
  var categoryIds: Set<UUID>
  var payee: String?

  init(
    accountId: UUID? = nil,
    earmarkId: UUID? = nil,
    scheduled: ScheduledFilter = .all,
    dateRange: ClosedRange<Date>? = nil,
    categoryIds: Set<UUID> = [],
    payee: String? = nil
  ) {
    self.accountId = accountId
    self.earmarkId = earmarkId
    self.scheduled = scheduled
    self.dateRange = dateRange
    self.categoryIds = categoryIds
    self.payee = payee
  }
}

extension TransactionFilter {
  var hasActiveFilters: Bool {
    accountId != nil || earmarkId != nil || scheduled != .all
      || dateRange != nil || !categoryIds.isEmpty || payee != nil
  }
}
