import Foundation
import GRDB

@testable import Moolah

// Transaction-seeding helpers split out of `BenchmarkFixtures+Seeding.swift`
// so the original file stays under SwiftLint's `file_length` threshold.
extension BenchmarkFixtures {

  static func seedTransactions(
    scale: BenchmarkScale,
    ids: SeedIds,
    database: Database,
    instrument: Instrument
  ) {
    let fiveYearsAgo =
      Calendar.current.date(byAdding: .year, value: -5, to: Date()) ?? Date()
    let timeSpan = Date().timeIntervalSince(fiveYearsAgo)
    let scheduledCount = max(1, Int(Double(scale.transactions) * 0.002))
    let otherAccountIds = Array(ids.accounts.dropFirst(3))

    let inputs = TransactionSpecInputs(
      scale: scale,
      ids: ids,
      otherAccountIds: otherAccountIds,
      fiveYearsAgo: fiveYearsAgo,
      timeSpan: timeSpan,
      scheduledCount: scheduledCount,
      instrument: instrument)
    for i in 0..<scale.transactions {
      let spec = makeTransactionSpec(index: i, inputs: inputs)
      insertTransactionRows(spec, database: database)
    }
  }

  /// Bundles the inputs to `makeTransactionSpec` so the helper stays
  /// under SwiftLint's `function_parameter_count` threshold.
  private struct TransactionSpecInputs {
    let scale: BenchmarkScale
    let ids: SeedIds
    let otherAccountIds: [UUID]
    let fiveYearsAgo: Date
    let timeSpan: TimeInterval
    let scheduledCount: Int
    let instrument: Instrument
  }

  private static func makeTransactionSpec(
    index i: Int,
    inputs: TransactionSpecInputs
  ) -> TransactionSpec {
    let id = deterministicUUID(namespace: 0x05, index: i)
    let accountId = pickAccountId(for: i, otherAccountIds: inputs.otherAccountIds)
    let (txnType, toAccountId) = pickType(
      for: i, accountId: accountId, allIds: inputs.ids.accounts)

    // Spread dates across 5 years deterministically.
    let fraction = Double(i) / Double(max(1, inputs.scale.transactions - 1))
    let date = inputs.fiveYearsAgo.addingTimeInterval(fraction * inputs.timeSpan)
    let quantity = quantityFor(index: i, type: txnType, instrument: inputs.instrument)

    // Assign category to ~70% of transactions.
    let categoryId: UUID? =
      (i % 10 < 7 && !inputs.ids.categories.isEmpty)
      ? inputs.ids.categories[i % inputs.ids.categories.count]
      : nil
    // Assign earmark to ~5% of transactions.
    let earmarkId: UUID? =
      (i.isMultiple(of: 20) && !inputs.ids.earmarks.isEmpty)
      ? inputs.ids.earmarks[i % inputs.ids.earmarks.count]
      : nil
    // ~0.2% are scheduled (recurring).
    let isScheduled = i < inputs.scheduledCount
    return TransactionSpec(
      id: id,
      date: date,
      payee: "Payee \(i % 200)",
      isScheduled: isScheduled,
      accountId: accountId,
      toAccountId: toAccountId,
      instrument: inputs.instrument,
      quantity: quantity,
      txnType: txnType,
      categoryId: categoryId,
      earmarkId: earmarkId)
  }

  struct TransactionSpec {
    let id: UUID
    let date: Date
    let payee: String
    let isScheduled: Bool
    let accountId: UUID
    let toAccountId: UUID?
    let instrument: Instrument
    let quantity: Int64
    let txnType: TransactionType
    let categoryId: UUID?
    let earmarkId: UUID?
  }

  /// Distribute across accounts: 38% heavy0, 32% heavy1, 16% heavy2, 14% others.
  static func pickAccountId(for i: Int, otherAccountIds: [UUID]) -> UUID {
    let bucket = i % 100
    if bucket < 38 { return heavyAccountIds[0] }
    if bucket < 70 { return heavyAccountIds[1] }
    if bucket < 86 { return heavyAccountIds[2] }
    if !otherAccountIds.isEmpty { return otherAccountIds[i % otherAccountIds.count] }
    return heavyAccountIds[0]
  }

  /// Transaction type: 60% expense, 30% income, 10% transfer.
  static func pickType(
    for i: Int, accountId: UUID, allIds: [UUID]
  ) -> (TransactionType, UUID?) {
    let typeBucket = i % 10
    if typeBucket < 6 { return (.expense, nil) }
    if typeBucket < 9 { return (.income, nil) }
    // Transfer: pick a different account for the destination.
    let destIndex = (allIds.firstIndex(of: accountId) ?? 0 + 1) % allIds.count
    return (.transfer, allIds[destIndex])
  }

  /// Quantity: vary between 1 and 500 (whole units).
  static func quantityFor(
    index i: Int, type: TransactionType, instrument: Instrument
  ) -> Int64 {
    switch type {
    case .expense:
      return InstrumentAmount(
        quantity: Decimal(-((i % 500 + 1))), instrument: instrument
      ).storageValue
    case .income:
      return InstrumentAmount(
        quantity: Decimal(i % 800 + 1), instrument: instrument
      ).storageValue
    case .transfer:
      return InstrumentAmount(
        quantity: Decimal(i % 300 + 1), instrument: instrument
      ).storageValue
    default:
      return 0
    }
  }

  static func insertTransactionRows(
    _ spec: TransactionSpec, database: Database
  ) {
    insertPrimaryRow(spec, database: database)
    insertPrimaryLeg(spec, database: database)
    if let toAccountId = spec.toAccountId {
      insertTransferLeg(spec, toAccountId: toAccountId, database: database)
    }
  }

  private static func insertPrimaryRow(_ spec: TransactionSpec, database: Database) {
    let recurPeriod: String? = spec.isScheduled ? RecurPeriod.month.rawValue : nil
    let recurEvery: Int? = spec.isScheduled ? 1 : nil
    let txnRow = TransactionRow(
      id: spec.id,
      recordName: TransactionRow.recordName(for: spec.id),
      date: spec.date,
      payee: spec.payee,
      notes: nil,
      recurPeriod: recurPeriod,
      recurEvery: recurEvery,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
    expecting("benchmark transaction insert failed") {
      try txnRow.insert(database)
    }
  }

  private static func insertPrimaryLeg(_ spec: TransactionSpec, database: Database) {
    let primaryLegId = UUID()
    let primaryLeg = TransactionLegRow(
      id: primaryLegId,
      recordName: TransactionLegRow.recordName(for: primaryLegId),
      transactionId: spec.id,
      accountId: spec.accountId,
      instrumentId: spec.instrument.id,
      quantity: spec.quantity,
      type: spec.txnType.rawValue,
      categoryId: spec.categoryId,
      earmarkId: spec.earmarkId,
      sortOrder: 0,
      encodedSystemFields: nil)
    expecting("benchmark transaction leg insert failed") {
      try primaryLeg.insert(database)
    }
  }

  private static func insertTransferLeg(
    _ spec: TransactionSpec, toAccountId: UUID, database: Database
  ) {
    let toLegId = UUID()
    let toLeg = TransactionLegRow(
      id: toLegId,
      recordName: TransactionLegRow.recordName(for: toLegId),
      transactionId: spec.id,
      accountId: toAccountId,
      instrumentId: spec.instrument.id,
      quantity: -spec.quantity,
      type: TransactionType.transfer.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 1,
      encodedSystemFields: nil)
    expecting("benchmark transfer leg insert failed") {
      try toLeg.insert(database)
    }
  }
}
