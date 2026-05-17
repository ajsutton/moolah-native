import Foundation

// SyncBoundary — the wire discriminator ("single"/"merged") is stored
// in TransactionRecord.importOriginKind; adding a case requires bumping
// DataFormatVersion.current. (Matches the marker on TransactionType /
// RecurPeriod / ExchangeProvider / Account.)

/// The import origin of a transaction: a single-account import
/// (`.single`) or a merged cross-account transfer (`.merged`). Nil for
/// manually-created transactions.
enum TransactionImportOrigin: Codable, Sendable, Hashable {
  case single(ImportOrigin)
  case merged(MergedImportOrigin)

  /// The origin if this is a single-account import, else nil.
  var single: ImportOrigin? {
    if case let .single(value) = self { return value }
    return nil
  }

  /// The merged origins if this is a merged transfer, else nil.
  var merged: MergedImportOrigin? {
    if case let .merged(value) = self { return value }
    return nil
  }
}
