import Foundation

@testable import Moolah

/// Shared fixtures and helpers for the `BalanceDeltaCalculator` test suites.
///
/// Access level is `internal` (the default) so the sibling test files in
/// `MoolahTests/Shared/BalanceDeltaCalculator*Tests.swift` can reuse the same
/// UUIDs, instruments, and `Transaction` factory helpers. `fileprivate` would
/// be narrower but SwiftLint's `strict_fileprivate` rule forbids it, so
/// `internal` is the smallest legal scope.
struct BalanceDeltaCalculatorTestFixtures {
  let accountA = UUID()
  let accountB = UUID()
  let earmarkA = UUID()
  let earmarkB = UUID()
  let aud = Instrument.AUD
  let usd = Instrument.USD
  let date = Date()

  func transaction(
    id: UUID = UUID(),
    recurPeriod: RecurPeriod? = nil,
    recurEvery: Int? = nil,
    legs: [TransactionLeg]
  ) -> Transaction {
    Transaction(
      id: id, date: date, recurPeriod: recurPeriod, recurEvery: recurEvery, legs: legs)
  }

  func transaction(
    id: UUID = UUID(),
    scheduled: Bool,
    legs: [TransactionLeg]
  ) -> Transaction {
    Transaction(
      id: id, date: date,
      recurPeriod: scheduled ? .month : nil,
      recurEvery: scheduled ? 1 : nil,
      legs: legs)
  }
}
