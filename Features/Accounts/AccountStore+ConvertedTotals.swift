import Foundation

// On-demand total computations. Hoisted out of `AccountStore.swift` so
// that file stays under `file_length` / `type_body_length`. These are
// pure pass-throughs to the calculator and need no privileged access to
// the store's `private(set)` setters.
extension AccountStore {
  /// Total value of `accountList` in `target`, summing positions directly.
  func computeConvertedTotal(for accountList: [Account], in target: Instrument) async throws
    -> InstrumentAmount
  {
    try await balanceCalculator.totalConverted(for: accountList, to: target)
  }

  /// Total value of current accounts in `target`.
  func computeConvertedCurrentTotal(in target: Instrument) async throws -> InstrumentAmount {
    try await balanceCalculator.totalConverted(for: currentAccounts, to: target)
  }

  /// Total value of investment accounts in `target`. Uses cached external
  /// values when present; otherwise sums positions. Single-pass to avoid
  /// the double-conversion a two-phase approach would chain.
  func computeConvertedInvestmentTotal(in target: Instrument) async throws -> InstrumentAmount {
    try await balanceCalculator.totalConverted(
      for: investmentAccounts, to: target, using: investmentValueCache)
  }

  /// Net worth (current + investment) in `target`.
  func computeConvertedNetWorth(in target: Instrument) async throws -> InstrumentAmount {
    let current = try await computeConvertedCurrentTotal(in: target)
    let investment = try await computeConvertedInvestmentTotal(in: target)
    return current + investment
  }
}
