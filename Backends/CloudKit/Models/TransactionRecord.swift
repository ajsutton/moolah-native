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

  func toDomain(legs: [TransactionLeg]) -> Transaction {
    Transaction(
      id: id,
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery,
      legs: legs
    )
  }

  static func from(_ transaction: Transaction) -> TransactionRecord {
    TransactionRecord(
      id: transaction.id,
      date: transaction.date,
      payee: transaction.payee,
      notes: transaction.notes,
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }
}
