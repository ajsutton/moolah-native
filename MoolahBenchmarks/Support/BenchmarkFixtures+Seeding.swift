import Foundation
import SwiftData

// Private seeding helpers extracted from `BenchmarkFixtures` so the main
// enum body stays under SwiftLint's `type_body_length` threshold. All
// members are `static` on the enum and remain `internal` to the benchmark
// target (no new public surface — the only entry point is
// `BenchmarkFixtures.seed`).
extension BenchmarkFixtures {

  // MARK: - Private Helpers

  /// Deterministic UUID from a namespace and index.
  static func deterministicUUID(namespace: UInt8, index: Int) -> UUID {
    // Build a UUID with the namespace byte in position 0 and index bytes in positions 12-15.
    let idx = UInt32(index)
    let uuidString = String(
      format: "%02X000000-BE00-4000-A000-%012X",
      namespace, idx
    )
    return UUID(uuidString: uuidString)!
  }

  @MainActor
  static func seedAccounts(
    scale: BenchmarkScale,
    in context: ModelContext
  ) -> [UUID] {
    var ids: [UUID] = []

    // First 3 are the heavy accounts with well-known IDs.
    for i in 0..<min(3, scale.accounts) {
      let id = heavyAccountIds[i]
      ids.append(id)
      let record = AccountRecord(
        id: id,
        name: "Heavy Account \(i)",
        type: AccountType.bank.rawValue,
        position: i
      )
      context.insert(record)
    }

    // Remaining non-investment accounts.
    let nonInvestmentRemaining = scale.accounts - 3 - scale.investmentAccounts
    for i in 0..<nonInvestmentRemaining {
      let id = deterministicUUID(namespace: 0x01, index: i)
      ids.append(id)
      // Alternate between bank, credit card, and asset.
      let accountType: AccountType =
        switch i % 3 {
        case 0: .bank
        case 1: .creditCard
        default: .asset
        }
      let record = AccountRecord(
        id: id,
        name: "Account \(i + 3)",
        type: accountType.rawValue,
        position: i + 3
      )
      context.insert(record)
    }

    // Investment accounts (last N).
    for i in 0..<scale.investmentAccounts {
      let id = deterministicUUID(namespace: 0x02, index: i)
      ids.append(id)
      let record = AccountRecord(
        id: id,
        name: "Investment \(i)",
        type: AccountType.investment.rawValue,
        position: scale.accounts - scale.investmentAccounts + i
      )
      context.insert(record)
    }

    return ids
  }

  @MainActor
  static func seedCategories(
    scale: BenchmarkScale,
    in context: ModelContext
  ) -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<scale.categories {
      let id = deterministicUUID(namespace: 0x03, index: i)
      ids.append(id)
      // ~20% are child categories (have a parent).
      let parentId: UUID? =
        (i >= 10 && i.isMultiple(of: 5))
        ? ids[i / 5]
        : nil
      let record = CategoryRecord(
        id: id,
        name: "Category \(i)",
        parentId: parentId
      )
      context.insert(record)
    }
    return ids
  }

  @MainActor
  static func seedEarmarks(
    scale: BenchmarkScale,
    in context: ModelContext,
    instrument: Instrument
  ) -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<scale.earmarks {
      let id = deterministicUUID(namespace: 0x04, index: i)
      ids.append(id)
      // Half have savings targets.
      let savingsTarget: Int64? =
        i.isMultiple(of: 2)
        ? InstrumentAmount(quantity: Decimal((i + 1) * 100), instrument: instrument).storageValue
        : nil
      let record = EarmarkRecord(
        id: id,
        name: "Earmark \(i)",
        position: i,
        savingsTarget: savingsTarget,
        savingsTargetInstrumentId: savingsTarget != nil ? instrument.id : nil
      )
      context.insert(record)
    }
    return ids
  }

  /// Bundled identifier sets passed to `seedTransactions`. Holds the account,
  /// category, and earmark UUIDs produced by earlier seeding passes so the
  /// transaction seeder can reference them without threading three separate
  /// `[UUID]` parameters through its signature (which would breach
  /// SwiftLint's `function_parameter_count` limit).
  struct SeedIds {
    let accounts: [UUID]
    let categories: [UUID]
    let earmarks: [UUID]
  }

  @MainActor
  static func seedTransactions(
    scale: BenchmarkScale,
    ids: SeedIds,
    in context: ModelContext,
    instrument: Instrument
  ) {
    let fiveYearsAgo = Calendar.current.date(byAdding: .year, value: -5, to: Date())!
    let timeSpan = Date().timeIntervalSince(fiveYearsAgo)
    let scheduledCount = max(1, Int(Double(scale.transactions) * 0.002))
    let otherAccountIds = Array(ids.accounts.dropFirst(3))

    for i in 0..<scale.transactions {
      let id = deterministicUUID(namespace: 0x05, index: i)
      let accountId = pickAccountId(for: i, otherAccountIds: otherAccountIds)
      let (txnType, toAccountId) = pickType(for: i, accountId: accountId, allIds: ids.accounts)

      // Spread dates across 5 years deterministically.
      let fraction = Double(i) / Double(max(1, scale.transactions - 1))
      let date = fiveYearsAgo.addingTimeInterval(fraction * timeSpan)
      let quantity = quantityFor(index: i, type: txnType, instrument: instrument)

      // Assign category to ~70% of transactions.
      let categoryId: UUID? =
        (i % 10 < 7 && !ids.categories.isEmpty)
        ? ids.categories[i % ids.categories.count]
        : nil
      // Assign earmark to ~5% of transactions.
      let earmarkId: UUID? =
        (i.isMultiple(of: 20) && !ids.earmarks.isEmpty)
        ? ids.earmarks[i % ids.earmarks.count]
        : nil
      // ~0.2% are scheduled (recurring).
      let isScheduled = i < scheduledCount
      let spec = TransactionSpec(
        id: id,
        date: date,
        payee: "Payee \(i % 200)",
        isScheduled: isScheduled,
        accountId: accountId,
        toAccountId: toAccountId,
        instrument: instrument,
        quantity: quantity,
        txnType: txnType,
        categoryId: categoryId,
        earmarkId: earmarkId)
      insertTransactionRecords(spec, in: context)
    }
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

  @MainActor
  static func insertTransactionRecords(
    _ spec: TransactionSpec, in context: ModelContext
  ) {
    let recurPeriod: String? = spec.isScheduled ? RecurPeriod.month.rawValue : nil
    let recurEvery: Int? = spec.isScheduled ? 1 : nil
    let record = TransactionRecord(
      id: spec.id,
      date: spec.date,
      payee: spec.payee,
      recurPeriod: recurPeriod,
      recurEvery: recurEvery
    )
    context.insert(record)

    let legRecord = TransactionLegRecord(
      transactionId: spec.id,
      accountId: spec.accountId,
      instrumentId: spec.instrument.id,
      quantity: spec.quantity,
      type: spec.txnType.rawValue,
      categoryId: spec.categoryId,
      earmarkId: spec.earmarkId,
      sortOrder: 0
    )
    context.insert(legRecord)

    // For transfers, create a second leg for the destination account.
    if let toAccountId = spec.toAccountId {
      let toLegRecord = TransactionLegRecord(
        transactionId: spec.id,
        accountId: toAccountId,
        instrumentId: spec.instrument.id,
        quantity: -spec.quantity,
        type: TransactionType.transfer.rawValue,
        sortOrder: 1
      )
      context.insert(toLegRecord)
    }
  }

  @MainActor
  static func seedInvestmentValues(
    scale: BenchmarkScale,
    accountIds: [UUID],
    in context: ModelContext,
    instrument: Instrument
  ) {
    // Investment accounts are the last N in the account list.
    let investmentAccountIds = Array(accountIds.suffix(scale.investmentAccounts))
    guard !investmentAccountIds.isEmpty else { return }

    let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date())!
    let timeSpan = Date().timeIntervalSince(sixMonthsAgo)

    for i in 0..<scale.investmentValues {
      let id = deterministicUUID(namespace: 0x06, index: i)
      let investAccountId = investmentAccountIds[i % investmentAccountIds.count]

      let fraction = Double(i) / Double(max(1, scale.investmentValues - 1))
      let date = sixMonthsAgo.addingTimeInterval(fraction * timeSpan)

      // Value between 100 and 5000 units.
      let value = InstrumentAmount(
        quantity: Decimal((i % 4900 + 100)), instrument: instrument
      ).storageValue

      let record = InvestmentValueRecord(
        id: id,
        accountId: investAccountId,
        date: date,
        value: value,
        instrumentId: instrument.id
      )
      context.insert(record)
    }
  }
}
