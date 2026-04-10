import Foundation

struct TransactionDTO: Codable {
  let id: ServerUUID
  let type: String
  let date: String  // "YYYY-MM-DD"
  let accountId: ServerUUID?
  let toAccountId: ServerUUID?
  let amount: Int
  let payee: String?
  let notes: String?
  let categoryId: ServerUUID?
  let earmark: ServerUUID?  // Server uses "earmark", domain uses "earmarkId"
  let recurPeriod: String?
  let recurEvery: Int?

  func toDomain(currency: Currency) -> Transaction {
    let parsedDate = BackendDateFormatter.date(from: date) ?? Date()

    return Transaction(
      id: id.uuid,
      type: TransactionType(rawValue: type) ?? .expense,
      date: parsedDate,
      accountId: accountId?.uuid,
      toAccountId: toAccountId?.uuid,
      amount: MonetaryAmount(cents: amount, currency: currency),
      payee: payee,
      notes: notes,
      categoryId: categoryId?.uuid,
      earmarkId: earmark?.uuid,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery
    )
  }

  static func fromDomain(_ transaction: Transaction) -> TransactionDTO {
    let dateString = BackendDateFormatter.string(from: transaction.date)
    return TransactionDTO(
      id: ServerUUID(transaction.id),
      type: transaction.type.rawValue,
      date: dateString,
      accountId: transaction.accountId.map(ServerUUID.init),
      toAccountId: transaction.toAccountId.map(ServerUUID.init),
      amount: transaction.amount.cents,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: transaction.categoryId.map(ServerUUID.init),
      earmark: transaction.earmarkId.map(ServerUUID.init),
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
  let accountId: ServerUUID?
  let toAccountId: ServerUUID?
  let amount: Int
  let payee: String?
  let notes: String?
  let categoryId: ServerUUID?
  let earmark: ServerUUID?
  let recurPeriod: String?
  let recurEvery: Int?

  static func fromDomain(_ transaction: Transaction) -> CreateTransactionDTO {
    let dateString = BackendDateFormatter.string(from: transaction.date)
    return CreateTransactionDTO(
      type: transaction.type.rawValue,
      date: dateString,
      accountId: transaction.accountId.map(ServerUUID.init),
      toAccountId: transaction.toAccountId.map(ServerUUID.init),
      amount: transaction.amount.cents,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: transaction.categoryId.map(ServerUUID.init),
      earmark: transaction.earmarkId.map(ServerUUID.init),
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }
}
