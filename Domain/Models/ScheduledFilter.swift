import Foundation

/// Tri-state selector for whether scheduled transactions are included in a
/// query. Replaces the previous `Bool?` tri-state where `nil` meant "all",
/// `true` meant "scheduled only", and `false` meant "non-scheduled only".
/// Named cases make intent readable at call sites and keep SwiftLint's
/// `discouraged_optional_boolean` rule quiet.
enum ScheduledFilter: Sendable, Hashable {
  /// Include both scheduled and non-scheduled transactions.
  case all
  /// Include only scheduled transactions (those with a `recurPeriod`).
  case scheduledOnly
  /// Include only non-scheduled transactions.
  case nonScheduledOnly
}
