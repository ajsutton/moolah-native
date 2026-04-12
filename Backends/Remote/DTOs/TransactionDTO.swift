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

  func toDomain(instrument: Instrument) -> Transaction {
    let parsedDate = BackendDateFormatter.date(from: date) ?? Date()
    let parsedType = TransactionType(rawValue: type) ?? .expense
    let quantity = Decimal(amount) / 100

    var legs: [TransactionLeg] = []

    if parsedType == .transfer {
      // Transfer: source leg (negative) and destination leg (positive)
      if let sourceId = accountId?.uuid {
        legs.append(
          TransactionLeg(
            accountId: sourceId, instrument: instrument, quantity: quantity, type: .transfer
          ))
      }
      if let destId = toAccountId?.uuid {
        legs.append(
          TransactionLeg(
            accountId: destId, instrument: instrument, quantity: -quantity, type: .transfer
          ))
      }
    } else {
      // Income/expense/openingBalance: single leg
      if let acctId = accountId?.uuid {
        legs.append(
          TransactionLeg(
            accountId: acctId, instrument: instrument, quantity: quantity, type: parsedType,
            categoryId: categoryId?.uuid, earmarkId: earmark?.uuid
          ))
      }
    }

    return Transaction(
      id: id.uuid,
      date: parsedDate,
      payee: payee,
      notes: notes,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery,
      legs: legs
    )
  }

  static func fromDomain(_ transaction: Transaction) -> TransactionDTO {
    let dateString = BackendDateFormatter.string(from: transaction.date)
    let primaryLeg = transaction.legs.first
    let transferLeg =
      transaction.legs.count > 1
      ? transaction.legs.first(where: { $0.accountId != primaryLeg?.accountId })
      : nil

    // Convert quantity back to cents
    let cents: Int
    if let qty = primaryLeg?.quantity {
      var centValue = qty * 100
      var rounded = Decimal()
      NSDecimalRound(&rounded, &centValue, 0, .bankers)
      cents = Int(truncating: rounded as NSDecimalNumber)
    } else {
      cents = 0
    }

    return TransactionDTO(
      id: ServerUUID(transaction.id),
      type: transaction.type.rawValue,
      date: dateString,
      accountId: transaction.primaryAccountId.map(ServerUUID.init),
      toAccountId: transferLeg.map { ServerUUID($0.accountId) },
      amount: cents,
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
    let primaryLeg = transaction.legs.first
    let transferLeg =
      transaction.legs.count > 1
      ? transaction.legs.first(where: { $0.accountId != primaryLeg?.accountId })
      : nil

    // Convert quantity back to cents
    let cents: Int
    if let qty = primaryLeg?.quantity {
      var centValue = qty * 100
      var rounded = Decimal()
      NSDecimalRound(&rounded, &centValue, 0, .bankers)
      cents = Int(truncating: rounded as NSDecimalNumber)
    } else {
      cents = 0
    }

    return CreateTransactionDTO(
      type: transaction.type.rawValue,
      date: dateString,
      accountId: transaction.primaryAccountId.map(ServerUUID.init),
      toAccountId: transferLeg.map { ServerUUID($0.accountId) },
      amount: cents,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: transaction.categoryId.map(ServerUUID.init),
      earmark: transaction.earmarkId.map(ServerUUID.init),
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }
}
