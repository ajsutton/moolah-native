import Foundation

/// Tri-state selector for whether scheduled transactions are included in a
/// query. Named cases make intent readable at call sites and avoid an
/// ambiguous optional `Bool`.
enum ScheduledFilter: Sendable, Hashable {
  /// Include both scheduled and non-scheduled transactions.
  case all
  /// Include only scheduled transactions (those with a `recurPeriod`).
  case scheduledOnly
  /// Include only non-scheduled transactions.
  case nonScheduledOnly
}
