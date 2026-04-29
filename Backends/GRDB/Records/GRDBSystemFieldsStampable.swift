// Backends/GRDB/Records/GRDBSystemFieldsStampable.swift

import Foundation

/// Marker protocol for the per-table row structs. Every row struct in
/// this module has an `encodedSystemFields: Data?` stored property; the
/// protocol just exposes it so `stampSystemFields` can mutate the
/// blob without a per-type helper.
protocol GRDBSystemFieldsStampable {
  var encodedSystemFields: Data? { get set }
}
