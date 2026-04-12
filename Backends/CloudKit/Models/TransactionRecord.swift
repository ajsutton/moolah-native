import Foundation
import SwiftData

@Model
final class TransactionRecord {

  var id: UUID = UUID()
  var type: String = "expense"  // Raw value of TransactionType
  var date: Date = Date()
  var accountId: UUID?
  var toAccountId: UUID?
  var amount: Int = 0  // cents
  var currencyCode: String = ""
  var payee: String?
  var notes: String?
  var categoryId: UUID?
  var earmarkId: UUID?
  var recurPeriod: String?  // Raw value of RecurPeriod
  var recurEvery: Int?

  init(
    id: UUID = UUID(),
    type: String,
    date: Date,
    accountId: UUID? = nil,
    toAccountId: UUID? = nil,
    amount: Int,
    currencyCode: String,
    payee: String? = nil,
    notes: String? = nil,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil,
    recurPeriod: String? = nil,
    recurEvery: Int? = nil
  ) {
    self.id = id
    self.type = type
    self.date = date
    self.accountId = accountId
    self.toAccountId = toAccountId
    self.amount = amount
    self.currencyCode = currencyCode
    self.payee = payee
    self.notes = notes
    self.categoryId = categoryId
    self.earmarkId = earmarkId
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
  }

  func toDomain() -> Transaction {
    let currency = Currency.from(code: currencyCode)
    return Transaction(
      id: id,
      type: TransactionType(rawValue: type) ?? .expense,
      date: date,
      accountId: accountId,
      toAccountId: toAccountId,
      amount: MonetaryAmount(cents: amount, currency: currency),
      payee: payee,
      notes: notes,
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery
    )
  }

  static func from(_ transaction: Transaction) -> TransactionRecord {
    TransactionRecord(
      id: transaction.id,
      type: transaction.type.rawValue,
      date: transaction.date,
      accountId: transaction.accountId,
      toAccountId: transaction.toAccountId,
      amount: transaction.amount.cents,
      currencyCode: transaction.amount.currency.code,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: transaction.categoryId,
      earmarkId: transaction.earmarkId,
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }
}
