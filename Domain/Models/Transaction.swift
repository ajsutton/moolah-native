import Foundation

enum TransactionType: String, Codable, Sendable, CaseIterable {
  case income
  case expense
  case transfer
}

struct Transaction: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var type: TransactionType
  var date: Date
  var accountId: UUID?
  var toAccountId: UUID?
  var amount: Int  // Amount in cents
  var payee: String?
  var notes: String?
  var categoryId: UUID?
  var earmarkId: UUID?
  var recurPeriod: String?  // DAY, WEEK, MONTH, YEAR
  var recurEvery: Int?

  var isScheduled: Bool {
    recurPeriod != nil
  }

  init(
    id: UUID = UUID(),
    type: TransactionType,
    date: Date,
    accountId: UUID? = nil,
    toAccountId: UUID? = nil,
    amount: Int,
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
    self.payee = payee
    self.notes = notes
    self.categoryId = categoryId
    self.earmarkId = earmarkId
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
  }
}

struct TransactionFilter: Sendable {
  var accountId: UUID?
  var scheduled: Bool?

  init(accountId: UUID? = nil, scheduled: Bool? = nil) {
    self.accountId = accountId
    self.scheduled = scheduled
  }
}
