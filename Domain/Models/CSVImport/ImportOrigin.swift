import Foundation

/// Metadata a CSV import attaches to every `Transaction` it creates. Populated
/// at parse/persist time; `nil` for manually-created transactions.
///
/// `rawDescription`, `bankReference`, `rawAmount`, and `rawBalance` are the
/// unmodified values from the CSV row — rules operate on these fields so
/// import rules stay stable even after payee cleanup.
///
/// `importSessionId` groups every transaction imported in a single ingest
/// event (one file drop, one scan pass, or one paste). `Recently Added`
/// groups rows by this id.
///
/// Forward-compat note: `plans/2026-04-18-transfer-detection-design.md` will
/// wrap this in an enum `TransactionImportOrigin` with `.single`/`.merged`
/// cases. v1 stores only single values; the upgrade is an enum wrap.
struct ImportOrigin: Codable, Sendable, Hashable {
  var rawDescription: String
  var bankReference: String?
  var rawAmount: Decimal
  var rawBalance: Decimal?
  var importedAt: Date
  var importSessionId: UUID
  var sourceFilename: String?
  var parserIdentifier: String

  init(
    rawDescription: String,
    bankReference: String? = nil,
    rawAmount: Decimal,
    rawBalance: Decimal? = nil,
    importedAt: Date,
    importSessionId: UUID,
    sourceFilename: String? = nil,
    parserIdentifier: String
  ) {
    self.rawDescription = rawDescription
    self.bankReference = bankReference
    self.rawAmount = rawAmount
    self.rawBalance = rawBalance
    self.importedAt = importedAt
    self.importSessionId = importSessionId
    self.sourceFilename = sourceFilename
    self.parserIdentifier = parserIdentifier
  }
}
