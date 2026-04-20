import Foundation
import OSLog

/// Pure, async, throws-never helper that builds `[ValuedPosition]` for
/// `PositionsView` from a list of raw `Position`s plus an optional cost-basis
/// snapshot keyed by `Instrument.id`.
///
/// Per `guides/INSTRUMENT_CONVERSION_GUIDE.md`:
/// - Rule 8 (single-instrument fast path): rows whose instrument equals
///   `hostCurrency` skip the conversion service entirely.
/// - Rule 11 (per-row failure): a thrown conversion is logged and emitted as
///   a row with `value == nil`. Sibling rows still receive their successful
///   values. The aggregate visibility of the total / chart is the caller's
///   responsibility (see `PositionsViewInput.totalValue`).
struct PositionsValuator: Sendable {
  let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "PositionsValuator")

  /// Build one `ValuedPosition` per input position.
  ///
  /// - Parameters:
  ///   - positions: raw quantities per instrument (zeroes filtered upstream).
  ///   - hostCurrency: target instrument for value/unitPrice/costBasis.
  ///   - costBasis: remaining cost basis per instrument id, expressed in
  ///     `hostCurrency`. Use `[:]` when no cost basis is known (flow context).
  ///   - on: valuation date.
  /// - Returns: rows in input order. Never throws — failures map to
  ///   `value == nil` per row.
  func valuate(
    positions: [Position],
    hostCurrency: Instrument,
    costBasis: [String: Decimal],
    on date: Date
  ) async -> [ValuedPosition] {
    var rows: [ValuedPosition] = []
    rows.reserveCapacity(positions.count)
    // Sequential await per row, not a TaskGroup: rows are independent, but the
    // conversion service caches per (instrument, date), so warm-cache loads are
    // O(1) per row. Cold-cache loads pay O(N * RTT) — acceptable for the dozens
    // of positions per account this view targets. If profiling later shows cold
    // loads are user-visible, switching to withTaskGroup is a self-contained change.
    for position in positions {
      rows.append(
        await row(for: position, hostCurrency: hostCurrency, costBasis: costBasis, on: date))
    }
    return rows
  }

  private func row(
    for position: Position,
    hostCurrency: Instrument,
    costBasis: [String: Decimal],
    on date: Date
  ) async -> ValuedPosition {
    let cost: InstrumentAmount? = costBasis[position.instrument.id].map {
      InstrumentAmount(quantity: $0, instrument: hostCurrency)
    }

    if position.instrument == hostCurrency {
      return ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: nil,
        costBasis: cost,
        value: InstrumentAmount(quantity: position.quantity, instrument: hostCurrency)
      )
    }

    do {
      let total = try await conversionService.convert(
        position.quantity, from: position.instrument, to: hostCurrency, on: date
      )
      // For short positions (negative quantity), `total` and `position.quantity`
      // share the negative sign, so the quotient yields a positive per-unit price
      // — the natural reading of "what one share is worth right now". The zero
      // guard prevents NaN from propagating into the rendered amount; we accept
      // that a service returning total == 0 yields unitPrice == 0 (which is rare
      // and visually obvious as "free", which is correct for the data we have).
      let unit: InstrumentAmount? =
        position.quantity == 0
        ? nil
        : InstrumentAmount(quantity: total / position.quantity, instrument: hostCurrency)
      return ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: unit,
        costBasis: cost,
        value: InstrumentAmount(quantity: total, instrument: hostCurrency)
      )
    } catch {
      logger.warning(
        "Failed to valuate position \(position.instrument.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: nil,
        costBasis: cost,
        value: nil
      )
    }
  }
}
