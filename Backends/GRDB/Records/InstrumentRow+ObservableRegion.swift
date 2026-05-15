// Backends/GRDB/Records/InstrumentRow+ObservableRegion.swift

import Foundation
import GRDB

extension InstrumentRow {
  /// Column-restricted region UI `ValueObservation`s pass to
  /// `tracking(regions:fetch:)`. See
  /// `AccountRow+ObservableRegion.swift` for the shared pattern and
  /// issue #865 for the motivation.
  ///
  /// `InstrumentRow` now maps only the shared profile-index
  /// `instrument` table (the per-profile readers/writers were removed
  /// ahead of the `v10_drop_shared_instrument_legacy` migration). This
  /// region is consumed by the shared `GRDBInstrumentRegistryRepository`
  /// observation; it stays valid against the shared table.
  static var observableRegion: QueryInterfaceRequest<InstrumentRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}
