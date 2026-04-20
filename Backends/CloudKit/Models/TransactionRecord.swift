import Foundation
import SwiftData

@Model
final class TransactionRecord {

  #Index<TransactionRecord>(
    [\.recurPeriod, \.date],
    [\.date],
    [\.id]
  )

  var id: UUID = UUID()
  var date: Date = Date()
  var payee: String?
  var notes: String?
  var recurPeriod: String?  // Raw value of RecurPeriod
  var recurEvery: Int?
  var encodedSystemFields: Data?

  // MARK: - ImportOrigin (denormalised)
  //
  // One column per field rather than a single JSON blob, to match the
  // per-field CKRecord convention used elsewhere (EarmarkRecord, etc.)
  // and so each field can be indexed/filtered independently later if
  // needed. Decimals are stored as String to preserve precision across
  // the SwiftData / CloudKit / Domain round-trip.
  var importOriginRawDescription: String?
  var importOriginBankReference: String?
  var importOriginRawAmount: String?
  var importOriginRawBalance: String?
  var importOriginImportedAt: Date?
  var importOriginImportSessionId: UUID?
  var importOriginSourceFilename: String?
  var importOriginParserIdentifier: String?

  init(
    id: UUID = UUID(),
    date: Date,
    payee: String? = nil,
    notes: String? = nil,
    recurPeriod: String? = nil,
    recurEvery: Int? = nil
  ) {
    self.id = id
    self.date = date
    self.payee = payee
    self.notes = notes
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
  }

  /// Composed getter — returns a fully-populated `ImportOrigin` only when every
  /// required field is present. A single missing field yields nil (the row
  /// was created without an origin). This avoids persisting a half-formed
  /// origin if a future write partially clears the fields.
  var importOrigin: ImportOrigin? {
    get {
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
    set {
      importOriginRawDescription = newValue?.rawDescription
      importOriginBankReference = newValue?.bankReference
      importOriginRawAmount = newValue.map { NSDecimalNumber(decimal: $0.rawAmount).stringValue }
      importOriginRawBalance = newValue?.rawBalance.map {
        NSDecimalNumber(decimal: $0).stringValue
      }
      importOriginImportedAt = newValue?.importedAt
      importOriginImportSessionId = newValue?.importSessionId
      importOriginSourceFilename = newValue?.sourceFilename
      importOriginParserIdentifier = newValue?.parserIdentifier
    }
  }

  func toDomain(legs: [TransactionLeg]) -> Transaction {
    Transaction(
      id: id,
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery,
      legs: legs,
      importOrigin: importOrigin
    )
  }

  static func from(_ transaction: Transaction) -> TransactionRecord {
    let record = TransactionRecord(
      id: transaction.id,
      date: transaction.date,
      payee: transaction.payee,
      notes: transaction.notes,
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
    record.importOrigin = transaction.importOrigin
    return record
  }
}
