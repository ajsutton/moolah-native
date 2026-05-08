import Foundation

extension EarmarkStore {
  // The members below are module-internal (not `private`) only because
  // `EarmarkStore.swift` calls them across the file boundary. They are
  // not intended as API for any other type — treat them as `private` to
  // the `EarmarkStore` family.

  /// Per-earmark conversion result: the three position-list totals,
  /// each expressed in the earmark's own instrument.
  struct ConvertedEarmarkTotals {
    let balance: InstrumentAmount
    let saved: InstrumentAmount
    let spent: InstrumentAmount
  }

  /// Sums an earmark's three position lists, each converted to the
  /// earmark's own instrument. `.knownZero` positions (an `.unpriced`
  /// / `.spam` crypto registration) contribute zero rather than
  /// failing the earmark — issue #790. A real provider failure still
  /// throws so the caller treats the whole earmark as failed (we never
  /// display a partial earmark balance under transient outage).
  func convertEarmarkPositions(_ earmark: Earmark) async throws
    -> ConvertedEarmarkTotals
  {
    let date = Date()
    var balance = InstrumentAmount.zero(instrument: earmark.instrument)
    var saved = InstrumentAmount.zero(instrument: earmark.instrument)
    var spent = InstrumentAmount.zero(instrument: earmark.instrument)
    for position in earmark.positions {
      balance += try await convertPositionOrZero(
        position.amount, to: earmark.instrument, on: date)
    }
    for position in earmark.savedPositions {
      saved += try await convertPositionOrZero(
        position.amount, to: earmark.instrument, on: date)
    }
    for position in earmark.spentPositions {
      spent += try await convertPositionOrZero(
        position.amount, to: earmark.instrument, on: date)
    }
    return ConvertedEarmarkTotals(balance: balance, saved: saved, spent: spent)
  }

  /// Convert `amount` to `target` on `date`, folding `.knownZero` (an
  /// `.unpriced` / `.spam` crypto source) to zero in `target`.
  /// Issue #790.
  func convertPositionOrZero(
    _ amount: InstrumentAmount, to target: Instrument, on date: Date
  ) async throws -> InstrumentAmount {
    let result = try await conversionService.convertResult(
      amount, to: target, on: date)
    switch result {
    case .value(let converted): return converted
    case .knownZero: return .zero(instrument: target)
    }
  }
}
