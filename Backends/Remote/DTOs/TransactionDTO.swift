import Foundation

struct TransactionDTO: Codable {
  let id: String
  let type: String
  let date: String  // "YYYY-MM-DD"
  let accountId: String?
  let toAccountId: String?
  let amount: Int
  let payee: String?
  let notes: String?
  let categoryId: String?
  let earmark: String?  // Server uses "earmark", domain uses "earmarkId"
  let recurPeriod: String?
  let recurEvery: Int?

  func toDomain() -> Transaction {
    let parsedDate = BackendDateFormatter.date(from: date) ?? Date()

    return Transaction(
      id: FlexibleUUID.parse(id) ?? UUID(),
      type: TransactionType(rawValue: type) ?? .expense,
      date: parsedDate,
      accountId: accountId.flatMap { FlexibleUUID.parse($0) },
      toAccountId: toAccountId.flatMap { FlexibleUUID.parse($0) },
      amount: MonetaryAmount(cents: amount, currency: Currency.defaultCurrency),
      payee: payee,
      notes: notes,
      categoryId: categoryId.flatMap { FlexibleUUID.parse($0) },
      earmarkId: earmark.flatMap { FlexibleUUID.parse($0) },
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery
    )
  }

  static func fromDomain(_ transaction: Transaction) -> TransactionDTO {
    let dateString = BackendDateFormatter.string(from: transaction.date)
    return TransactionDTO(
      id: transaction.id.uuidString,
      type: transaction.type.rawValue,
      date: dateString,
      accountId: transaction.accountId?.uuidString,
      toAccountId: transaction.toAccountId?.uuidString,
      amount: transaction.amount.cents,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: transaction.categoryId?.uuidString,
      earmark: transaction.earmarkId?.uuidString,
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }

  struct ListWrapper: Codable {
    let transactions: [TransactionDTO]
    let hasMore: Bool
    let priorBalance: Int
    let totalNumberOfTransactions: Int
  }
}

/// DTO for creating transactions (omits the id field, which the server generates)
struct CreateTransactionDTO: Codable {
  let type: String
  let date: String  // "YYYY-MM-DD"
  let accountId: String?
  let toAccountId: String?
  let amount: Int
  let payee: String?
  let notes: String?
  let categoryId: String?
  let earmark: String?
  let recurPeriod: String?
  let recurEvery: Int?

  static func fromDomain(_ transaction: Transaction) -> CreateTransactionDTO {
    let dateString = BackendDateFormatter.string(from: transaction.date)
    return CreateTransactionDTO(
      type: transaction.type.rawValue,
      date: dateString,
      accountId: transaction.accountId?.uuidString,
      toAccountId: transaction.toAccountId?.uuidString,
      amount: transaction.amount.cents,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: transaction.categoryId?.uuidString,
      earmark: transaction.earmarkId?.uuidString,
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }
}
