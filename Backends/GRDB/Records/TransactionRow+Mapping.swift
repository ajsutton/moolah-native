// Backends/GRDB/Records/TransactionRow+Mapping.swift

import Foundation

extension TransactionRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract.
  static let recordType = "TransactionRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed transaction.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `Transaction`. The legs are NOT
  /// included; the repository persists them separately into the
  /// `transaction_leg` table.
  init(domain: Transaction) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.date = domain.date
    self.payee = domain.payee
    self.notes = domain.notes
    self.recurPeriod = domain.recurPeriod?.rawValue
    self.recurEvery = domain.recurEvery
    // ImportOrigin denormalisation: every required field flips through
    // its own column so the optional struct rebuilds cleanly in the
    // computed `importOrigin` accessor below.
    //
    // Temporary single-only mapping: only the `.single` case projects to
    // the eight columns; a `.merged` value writes nothing extra here and
    // `transferSuggestion` is not persisted yet. Task 6 (next commit,
    // same PR) replaces this with the full enum mapping plus new columns.
    let singleOrigin = domain.importOrigin?.singleOrigin
    self.importOriginRawDescription = singleOrigin?.rawDescription
    self.importOriginBankReference = singleOrigin?.bankReference
    self.importOriginRawAmount = singleOrigin.map {
      NSDecimalNumber(decimal: $0.rawAmount).stringValue
    }
    self.importOriginRawBalance = singleOrigin?.rawBalance.map {
      NSDecimalNumber(decimal: $0).stringValue
    }
    self.importOriginImportedAt = singleOrigin?.importedAt
    self.importOriginImportSessionId = singleOrigin?.importSessionId
    self.importOriginSourceFilename = singleOrigin?.sourceFilename
    self.importOriginParserIdentifier = singleOrigin?.parserIdentifier
    self.encodedSystemFields = nil
  }

  /// Reconstructs `ImportOrigin?` from the eight denormalised columns
  /// iff every required field is present. One missing required field
  /// yields nil — the row was created without an origin. This avoids
  /// surfacing a half-formed origin if a future write partially clears
  /// the columns.
  var importOrigin: ImportOrigin? {
    guard let rawDescription = importOriginRawDescription,
      let rawAmountStr = importOriginRawAmount,
      let rawAmount = Decimal(string: rawAmountStr),
      let importedAt = importOriginImportedAt,
      let sessionId = importOriginImportSessionId,
      let parserId = importOriginParserIdentifier
    else {
      return nil
    }
    return ImportOrigin(
      rawDescription: rawDescription,
      bankReference: importOriginBankReference,
      rawAmount: rawAmount,
      rawBalance: importOriginRawBalance.flatMap { Decimal(string: $0) },
      importedAt: importedAt,
      importSessionId: sessionId,
      sourceFilename: importOriginSourceFilename,
      parserIdentifier: parserId)
  }

  /// Domain projection. Legs come from the repository's join on
  /// `transaction_leg` and are passed through here.
  ///
  /// Throws `BackendError.dataCorrupted` when `recurPeriod` is non-null
  /// but carries a raw value the compiled `RecurPeriod` enum doesn't
  /// recognise. A truly null `recurPeriod` column maps to nil — only
  /// the unrecognised-but-present case is corruption.
  func toDomain(legs: [TransactionLeg]) throws -> Transaction {
    Transaction(
      id: id,
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: try recurPeriod.map { try RecurPeriod.decoded(rawValue: $0) },
      recurEvery: recurEvery,
      legs: legs,
      importOrigin: importOrigin.map(TransactionImportOrigin.single))
  }
}
