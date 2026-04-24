@preconcurrency import CloudKit
import Foundation
import SwiftData

extension ProfileDataSyncHandler {
  // MARK: - Batch Record Lookup

  /// Looks up records by UUID for a batch of pending changes.
  /// Uses IN-predicate fetches per record type, pruning the remaining set after each type.
  /// Ordered by expected frequency: transactions and legs account for the majority of
  /// pending changes in a typical batch.
  func buildBatchRecordLookup(for uuids: Set<UUID>) -> [UUID: CKRecord] {
    let context = ModelContext(modelContainer)
    var lookup: [UUID: CKRecord] = [:]
    var remaining = uuids

    lookupTransactions(in: &remaining, lookup: &lookup, context: context)
    lookupTransactionLegs(in: &remaining, lookup: &lookup, context: context)
    lookupInvestmentValues(in: &remaining, lookup: &lookup, context: context)
    lookupAccounts(in: &remaining, lookup: &lookup, context: context)
    lookupCategories(in: &remaining, lookup: &lookup, context: context)
    lookupEarmarks(in: &remaining, lookup: &lookup, context: context)
    lookupEarmarkBudgetItems(in: &remaining, lookup: &lookup, context: context)
    lookupCSVImportProfiles(in: &remaining, lookup: &lookup, context: context)
    lookupImportRules(in: &remaining, lookup: &lookup, context: context)

    if !remaining.isEmpty {
      logger.warning(
        "Batch lookup: \(remaining.count) of \(uuids.count) records not found in local store")
    }
    return lookup
  }

  // MARK: - Record Lookup for Upload

  /// Looks up a single record by CKRecord.ID and builds a CKRecord for upload.
  /// Tries InstrumentRecord (string ID) first, then UUID-based types.
  func recordToSave(for recordID: CKRecord.ID) -> CKRecord? {
    let context = ModelContext(modelContainer)
    let recordName = recordID.recordName

    // InstrumentRecord uses String IDs (e.g. "AUD", "ASX:BHP"), not UUIDs.
    // Try it first before UUID-based lookups.
    if let record = fetchInstrument(id: recordName, context: context) {
      return buildCKRecord(for: record)
    }

    guard let uuid = recordID.uuid else {
      logger.warning("Could not find local record for non-UUID ID: \(recordName)")
      return nil
    }

    if let ckRecord = ckRecordForUUID(uuid, context: context) {
      return ckRecord
    }

    logger.warning("Could not find local record for ID: \(recordName)")
    return nil
  }

  /// Tries each UUID-based record type until it finds a matching record, then returns
  /// its CKRecord representation. Returns `nil` if no type matches.
  ///
  /// Each finder closure applies `buildCKRecord` itself so the finder list can be
  /// `[(UUID, ModelContext) -> CKRecord?]` — a single concrete signature — instead of
  /// leaking an existential (`any CloudKitRecordConvertible & SystemFieldsCacheable`)
  /// that Swift can't forward back into the generic `buildCKRecord` parameter.
  private func ckRecordForUUID(_ uuid: UUID, context: ModelContext) -> CKRecord? {
    let finders: [(UUID, ModelContext) -> CKRecord?] = [
      { uuid, context in self.fetchAccount(id: uuid, context: context).map(self.buildCKRecord) },
      { uuid, context in self.fetchTransaction(id: uuid, context: context).map(self.buildCKRecord)
      },
      { uuid, context in
        self.fetchTransactionLeg(id: uuid, context: context).map(self.buildCKRecord)
      },
      { uuid, context in self.fetchCategory(id: uuid, context: context).map(self.buildCKRecord) },
      { uuid, context in self.fetchEarmark(id: uuid, context: context).map(self.buildCKRecord) },
      { uuid, context in
        self.fetchEarmarkBudgetItem(id: uuid, context: context).map(self.buildCKRecord)
      },
      { uuid, context in
        self.fetchInvestmentValue(id: uuid, context: context).map(self.buildCKRecord)
      },
      { uuid, context in
        self.fetchCSVImportProfile(id: uuid, context: context).map(self.buildCKRecord)
      },
      { uuid, context in self.fetchImportRule(id: uuid, context: context).map(self.buildCKRecord) },
    ]
    return finders.lazy.compactMap { $0(uuid, context) }.first
  }

  // MARK: - Per-Type Batch Lookups

  private func lookupTransactions(
    in remaining: inout Set<UUID>, lookup: inout [UUID: CKRecord], context: ModelContext
  ) {
    lookupAndRemove(
      TransactionRecord.self, in: &remaining, lookup: &lookup, context: context
    ) { ids in
      Self.fetchOrLog(
        FetchDescriptor<TransactionRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
    }
  }

  private func lookupTransactionLegs(
    in remaining: inout Set<UUID>, lookup: inout [UUID: CKRecord], context: ModelContext
  ) {
    lookupAndRemove(
      TransactionLegRecord.self, in: &remaining, lookup: &lookup, context: context
    ) { ids in
      Self.fetchOrLog(
        FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
    }
  }

  private func lookupInvestmentValues(
    in remaining: inout Set<UUID>, lookup: inout [UUID: CKRecord], context: ModelContext
  ) {
    lookupAndRemove(
      InvestmentValueRecord.self, in: &remaining, lookup: &lookup, context: context
    ) { ids in
      Self.fetchOrLog(
        FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
    }
  }

  private func lookupAccounts(
    in remaining: inout Set<UUID>, lookup: inout [UUID: CKRecord], context: ModelContext
  ) {
    lookupAndRemove(
      AccountRecord.self, in: &remaining, lookup: &lookup, context: context
    ) { ids in
      Self.fetchOrLog(
        FetchDescriptor<AccountRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
    }
  }

  private func lookupCategories(
    in remaining: inout Set<UUID>, lookup: inout [UUID: CKRecord], context: ModelContext
  ) {
    lookupAndRemove(
      CategoryRecord.self, in: &remaining, lookup: &lookup, context: context
    ) { ids in
      Self.fetchOrLog(
        FetchDescriptor<CategoryRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
    }
  }

  private func lookupEarmarks(
    in remaining: inout Set<UUID>, lookup: inout [UUID: CKRecord], context: ModelContext
  ) {
    lookupAndRemove(
      EarmarkRecord.self, in: &remaining, lookup: &lookup, context: context
    ) { ids in
      Self.fetchOrLog(
        FetchDescriptor<EarmarkRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
    }
  }

  private func lookupEarmarkBudgetItems(
    in remaining: inout Set<UUID>, lookup: inout [UUID: CKRecord], context: ModelContext
  ) {
    lookupAndRemove(
      EarmarkBudgetItemRecord.self, in: &remaining, lookup: &lookup, context: context
    ) { ids in
      Self.fetchOrLog(
        FetchDescriptor<EarmarkBudgetItemRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
    }
  }

  private func lookupCSVImportProfiles(
    in remaining: inout Set<UUID>, lookup: inout [UUID: CKRecord], context: ModelContext
  ) {
    lookupAndRemove(
      CSVImportProfileRecord.self, in: &remaining, lookup: &lookup, context: context
    ) { ids in
      Self.fetchOrLog(
        FetchDescriptor<CSVImportProfileRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
    }
  }

  private func lookupImportRules(
    in remaining: inout Set<UUID>, lookup: inout [UUID: CKRecord], context: ModelContext
  ) {
    lookupAndRemove(
      ImportRuleRecord.self, in: &remaining, lookup: &lookup, context: context
    ) { ids in
      Self.fetchOrLog(
        FetchDescriptor<ImportRuleRecord>(predicate: #Predicate { ids.contains($0.id) }),
        context: context)
    }
  }

  /// Runs the given fetch when `remaining` is non-empty, adds built `CKRecord`s to
  /// `lookup`, and prunes matched IDs from `remaining`.
  private func lookupAndRemove<T>(
    _ type: T.Type,
    in remaining: inout Set<UUID>,
    lookup: inout [UUID: CKRecord],
    context: ModelContext,
    fetch: ([UUID]) -> [T]
  )
  where
    T: PersistentModel & IdentifiableRecord & CloudKitRecordConvertible
      & SystemFieldsCacheable
  {
    guard !remaining.isEmpty else { return }
    let ids = Array(remaining)
    for record in fetch(ids) {
      lookup[record.id] = buildCKRecord(for: record)
      remaining.remove(record.id)
    }
  }

  // MARK: - Per-Type Fetch Methods

  func fetchAccount(id: UUID, context: ModelContext) -> AccountRecord? {
    let descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchTransaction(id: UUID, context: ModelContext) -> TransactionRecord? {
    let descriptor = FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchCategory(id: UUID, context: ModelContext) -> CategoryRecord? {
    let descriptor = FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchEarmark(id: UUID, context: ModelContext) -> EarmarkRecord? {
    let descriptor = FetchDescriptor<EarmarkRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchEarmarkBudgetItem(id: UUID, context: ModelContext) -> EarmarkBudgetItemRecord? {
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchInvestmentValue(id: UUID, context: ModelContext) -> InvestmentValueRecord? {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchInstrument(id: String, context: ModelContext) -> InstrumentRecord? {
    let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchTransactionLeg(id: UUID, context: ModelContext) -> TransactionLegRecord? {
    let descriptor = FetchDescriptor<TransactionLegRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchCSVImportProfile(id: UUID, context: ModelContext) -> CSVImportProfileRecord? {
    let descriptor = FetchDescriptor<CSVImportProfileRecord>(
      predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }

  func fetchImportRule(id: UUID, context: ModelContext) -> ImportRuleRecord? {
    let descriptor = FetchDescriptor<ImportRuleRecord>(predicate: #Predicate { $0.id == id })
    return Self.fetchOrLog(descriptor, context: context).first
  }
}
