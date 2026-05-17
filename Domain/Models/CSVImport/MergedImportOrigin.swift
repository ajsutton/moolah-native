import Foundation

/// The two source import origins collapsed onto a merged transfer
/// transaction. Either side may be nil (e.g. a manually-created leg had
/// no import origin). Restored onto each split transaction on unmerge.
struct MergedImportOrigin: Codable, Sendable, Hashable {
  let outgoing: ImportOrigin?
  let incoming: ImportOrigin?
}
