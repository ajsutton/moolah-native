// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long initialisers / SwiftUI builders across
// multiple lines in a way the multiline_arguments rule disagrees with.

import Foundation
import SwiftData

@Model
final class EarmarkBudgetItemRecord {

  #Index<EarmarkBudgetItemRecord>([\.id], [\.earmarkId])

  var id = UUID()
  var earmarkId = UUID()
  var categoryId = UUID()
  var amount: Int64 = 0  // storageValue (× 10^8)
  var instrumentId: String = ""
  var encodedSystemFields: Data?

  init(
    id: UUID = UUID(),
    earmarkId: UUID,
    categoryId: UUID,
    amount: Int64,
    instrumentId: String
  ) {
    self.id = id
    self.earmarkId = earmarkId
    self.categoryId = categoryId
    self.amount = amount
    self.instrumentId = instrumentId
  }

  /// Domain conversion keyed to the owning earmark's instrument.
  /// Budget items must always share their earmark's instrument (see
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1/2). The stored
  /// `instrumentId` is preserved for backwards compatibility but any drift
  /// is resolved here — the quantity is kept, the instrument is the
  /// earmark's. Pass `nil` to fall back to the stored `instrumentId` (used
  /// only by code paths that cannot resolve the earmark).
  func toDomain(earmarkInstrument: Instrument? = nil) -> EarmarkBudgetItem {
    let instrument = earmarkInstrument ?? Instrument.fiat(code: instrumentId)
    return EarmarkBudgetItem(
      id: id, categoryId: categoryId,
      amount: InstrumentAmount(storageValue: amount, instrument: instrument))
  }
}
