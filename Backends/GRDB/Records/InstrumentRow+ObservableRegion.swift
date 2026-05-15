// Backends/GRDB/Records/InstrumentRow+ObservableRegion.swift

import Foundation
import GRDB

extension InstrumentRow {
  /// Column-restricted region UI `ValueObservation`s pass to
  /// `tracking(regions:fetch:)`. See
  /// `AccountRow+ObservableRegion.swift` for the shared pattern and
  /// issue #865 for the motivation.
  ///
  /// Retained even though no per-profile `ValueObservation` currently
  /// tracks it: `PerProfileInstrumentMapResolver` and the apply path both
  /// still read the per-profile `instrument` table, and the
  /// `v10_drop_shared_instrument_legacy` migration will drop that table
  /// (and this region) in a future release. Do not remove this property
  /// until that migration lands and all callers have switched to the
  /// shared `GRDBInstrumentRegistryRepository`.
  static var observableRegion: QueryInterfaceRequest<InstrumentRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}
