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

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  func toDomain() -> Transaction {
    let parsedDate = TransactionDTO.dateFormatter.date(from: date) ?? Date()

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
      recurPeriod: recurPeriod,
      recurEvery: recurEvery
    )
  }

  struct ListWrapper: Codable {
    let transactions: [TransactionDTO]
    let hasMore: Bool
    let priorBalance: Int
    let totalNumberOfTransactions: Int
  }
}
