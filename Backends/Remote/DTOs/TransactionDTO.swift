// swiftlint:disable multiline_arguments

import Foundation

private func centsFromQuantity(_ quantity: Decimal) -> Int {
  var centValue = quantity * 100
  var rounded = Decimal()
  NSDecimalRound(&rounded, &centValue, 0, .bankers)
  return Int(truncating: rounded as NSDecimalNumber)
}

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
      // Earmark attaches to the source leg because the server's earmarkDao.balances uses
      // SUM(t.amount) where t.amount is from the source account's perspective (negative for
      // outgoing transfers). Putting earmark on source leg matches this sign convention.
      if let sourceId = accountId?.uuid {
        legs.append(
          TransactionLeg(
            accountId: sourceId, instrument: instrument, quantity: quantity, type: .transfer,
            earmarkId: earmark?.uuid
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
      // accountId may be nil for earmark-only income transactions
      legs.append(
        TransactionLeg(
          accountId: accountId?.uuid, instrument: instrument, quantity: quantity, type: parsedType,
          categoryId: categoryId?.uuid, earmarkId: earmark?.uuid
        ))
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

  enum MappingError: Error, LocalizedError {
    case complexTransactionNotSupported

    var errorDescription: String? {
      switch self {
      case .complexTransactionNotSupported:
        return
          "Transaction has complex leg structure and cannot be represented in the flat DTO format"
      }
    }
  }

  static func fromDomain(_ transaction: Transaction) throws -> TransactionDTO {
    guard transaction.isSimple else {
      throw MappingError.complexTransactionNotSupported
    }

    let dateString = BackendDateFormatter.string(from: transaction.date)

    let sourceLeg: TransactionLeg?
    let destinationLeg: TransactionLeg?

    if transaction.legs.count == 2 {
      sourceLeg = transaction.legs.first(where: { $0.quantity < 0 })
      destinationLeg = transaction.legs.first(where: { $0.quantity >= 0 })
    } else {
      sourceLeg = transaction.legs.first
      destinationLeg = nil
    }

    let cents = sourceLeg.map { centsFromQuantity($0.quantity) } ?? 0

    return TransactionDTO(
      id: ServerUUID(transaction.id),
      type: (sourceLeg?.type ?? .expense).rawValue,
      date: dateString,
      accountId: sourceLeg?.accountId.map(ServerUUID.init),
      toAccountId: destinationLeg?.accountId.map(ServerUUID.init),
      amount: cents,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: sourceLeg?.categoryId.map(ServerUUID.init),
      earmark: sourceLeg?.earmarkId.map(ServerUUID.init),
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

  static func fromDomain(_ transaction: Transaction) throws -> CreateTransactionDTO {
    guard transaction.isSimple else {
      throw TransactionDTO.MappingError.complexTransactionNotSupported
    }

    let dateString = BackendDateFormatter.string(from: transaction.date)

    let sourceLeg: TransactionLeg?
    let destinationLeg: TransactionLeg?

    if transaction.legs.count == 2 {
      sourceLeg = transaction.legs.first(where: { $0.quantity < 0 })
      destinationLeg = transaction.legs.first(where: { $0.quantity >= 0 })
    } else {
      sourceLeg = transaction.legs.first
      destinationLeg = nil
    }

    let cents = sourceLeg.map { centsFromQuantity($0.quantity) } ?? 0

    return CreateTransactionDTO(
      type: (sourceLeg?.type ?? .expense).rawValue,
      date: dateString,
      accountId: sourceLeg?.accountId.map(ServerUUID.init),
      toAccountId: destinationLeg?.accountId.map(ServerUUID.init),
      amount: cents,
      payee: transaction.payee,
      notes: transaction.notes,
      categoryId: sourceLeg?.categoryId.map(ServerUUID.init),
      earmark: sourceLeg?.earmarkId.map(ServerUUID.init),
      recurPeriod: transaction.recurPeriod?.rawValue,
      recurEvery: transaction.recurEvery
    )
  }
}
