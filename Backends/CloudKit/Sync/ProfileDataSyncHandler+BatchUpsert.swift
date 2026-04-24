@preconcurrency import CloudKit
import Foundation
import SwiftData

extension ProfileDataSyncHandler {
  // MARK: - Per-Type Batch Upsert

  nonisolated static func batchUpsertInstruments(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing = fetchOrLog(FetchDescriptor<InstrumentRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for ckRecord in ckRecords {
      guard let values = InstrumentRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertInstruments", ckRecord)
        continue
      }
      // `InstrumentRecord.id` is the raw `recordName` string (e.g. "AUD", "ASX:BHP"),
      // not a UUID, so `systemFields` is keyed by the bare string here — unlike every
      // other `batchUpsertX` below, which keys by `id.uuidString`.
      let id = values.id
      if let existing = byID[id] {
        existing.kind = values.kind
        existing.name = values.name
        existing.decimals = values.decimals
        existing.ticker = values.ticker
        existing.exchange = values.exchange
        existing.chainId = values.chainId
        existing.contractAddress = values.contractAddress
        existing.encodedSystemFields = systemFields[id]
      } else {
        values.encodedSystemFields = systemFields[id]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated static func batchUpsertAccounts(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing: [AccountRecord]
    do {
      existing = try context.fetch(FetchDescriptor<AccountRecord>())
    } catch {
      batchLogger.error("batchUpsertAccounts: fetch failed: \(error)")
      existing = []
    }
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var insertCount = 0
    var updateCount = 0
    var incomingCount = 0

    for ckRecord in ckRecords {
      guard let values = AccountRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertAccounts", ckRecord)
        continue
      }
      incomingCount += 1
      let id = values.id
      if let existing = byID[id] {
        existing.name = values.name
        existing.type = values.type
        existing.instrumentId = values.instrumentId
        existing.position = values.position
        existing.isHidden = values.isHidden
        existing.encodedSystemFields = systemFields[id.uuidString]
        updateCount += 1
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
        insertCount += 1
      }
    }
    batchLogger.info(
      "batchUpsertAccounts: \(incomingCount) incoming, \(existing.count) existing in store, \(insertCount) inserted, \(updateCount) updated"
    )
  }

  nonisolated static func batchUpsertTransactions(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing = fetchOrLog(FetchDescriptor<TransactionRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for ckRecord in ckRecords {
      guard let values = TransactionRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertTransactions", ckRecord)
        continue
      }
      let id = values.id
      if let existing = byID[id] {
        existing.date = values.date
        existing.payee = values.payee
        existing.notes = values.notes
        existing.recurPeriod = values.recurPeriod
        existing.recurEvery = values.recurEvery
        existing.importOriginRawDescription = values.importOriginRawDescription
        existing.importOriginBankReference = values.importOriginBankReference
        existing.importOriginRawAmount = values.importOriginRawAmount
        existing.importOriginRawBalance = values.importOriginRawBalance
        existing.importOriginImportedAt = values.importOriginImportedAt
        existing.importOriginImportSessionId = values.importOriginImportSessionId
        existing.importOriginSourceFilename = values.importOriginSourceFilename
        existing.importOriginParserIdentifier = values.importOriginParserIdentifier
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated static func batchUpsertTransactionLegs(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing = fetchOrLog(FetchDescriptor<TransactionLegRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for ckRecord in ckRecords {
      guard let values = TransactionLegRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertTransactionLegs", ckRecord)
        continue
      }
      let id = values.id
      if let existing = byID[id] {
        existing.transactionId = values.transactionId
        existing.accountId = values.accountId
        existing.instrumentId = values.instrumentId
        existing.quantity = values.quantity
        existing.type = values.type
        existing.categoryId = values.categoryId
        existing.earmarkId = values.earmarkId
        existing.sortOrder = values.sortOrder
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated static func batchUpsertCategories(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing = fetchOrLog(FetchDescriptor<CategoryRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for ckRecord in ckRecords {
      guard let values = CategoryRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertCategories", ckRecord)
        continue
      }
      let id = values.id
      if let existing = byID[id] {
        existing.name = values.name
        existing.parentId = values.parentId
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated static func batchUpsertEarmarks(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing = fetchOrLog(FetchDescriptor<EarmarkRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for ckRecord in ckRecords {
      guard let values = EarmarkRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertEarmarks", ckRecord)
        continue
      }
      let id = values.id
      if let existing = byID[id] {
        existing.name = values.name
        existing.position = values.position
        existing.isHidden = values.isHidden
        existing.savingsTarget = values.savingsTarget
        existing.savingsTargetInstrumentId = values.savingsTargetInstrumentId
        existing.savingsStartDate = values.savingsStartDate
        existing.savingsEndDate = values.savingsEndDate
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated static func batchUpsertEarmarkBudgetItems(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing = fetchOrLog(FetchDescriptor<EarmarkBudgetItemRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for ckRecord in ckRecords {
      guard let values = EarmarkBudgetItemRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertEarmarkBudgetItems", ckRecord)
        continue
      }
      let id = values.id
      if let existing = byID[id] {
        existing.earmarkId = values.earmarkId
        existing.categoryId = values.categoryId
        existing.amount = values.amount
        existing.instrumentId = values.instrumentId
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated static func batchUpsertInvestmentValues(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing = fetchOrLog(FetchDescriptor<InvestmentValueRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for ckRecord in ckRecords {
      guard let values = InvestmentValueRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertInvestmentValues", ckRecord)
        continue
      }
      let id = values.id
      if let existing = byID[id] {
        existing.accountId = values.accountId
        existing.date = values.date
        existing.value = values.value
        existing.instrumentId = values.instrumentId
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated static func batchUpsertCSVImportProfiles(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing = fetchOrLog(FetchDescriptor<CSVImportProfileRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for ckRecord in ckRecords {
      guard let values = CSVImportProfileRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertCSVImportProfiles", ckRecord)
        continue
      }
      let id = values.id
      if let existing = byID[id] {
        existing.accountId = values.accountId
        existing.parserIdentifier = values.parserIdentifier
        existing.headerSignature = values.headerSignature
        existing.filenamePattern = values.filenamePattern
        existing.deleteAfterImport = values.deleteAfterImport
        existing.createdAt = values.createdAt
        existing.lastUsedAt = values.lastUsedAt
        existing.dateFormatRawValue = values.dateFormatRawValue
        existing.columnRoleRawValuesEncoded = values.columnRoleRawValuesEncoded
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  nonisolated static func batchUpsertImportRules(
    _ ckRecords: [CKRecord], context: ModelContext, systemFields: [String: Data]
  ) {
    let existing = fetchOrLog(FetchDescriptor<ImportRuleRecord>(), context: context)
    var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

    for ckRecord in ckRecords {
      guard let values = ImportRuleRecord.fieldValues(from: ckRecord) else {
        logMalformed("batchUpsertImportRules", ckRecord)
        continue
      }
      let id = values.id
      if let existing = byID[id] {
        existing.name = values.name
        existing.enabled = values.enabled
        existing.position = values.position
        existing.matchMode = values.matchMode
        existing.conditionsJSON = values.conditionsJSON
        existing.actionsJSON = values.actionsJSON
        existing.accountScope = values.accountScope
        existing.encodedSystemFields = systemFields[id.uuidString]
      } else {
        values.encodedSystemFields = systemFields[id.uuidString]
        context.insert(values)
        byID[id] = values
      }
    }
  }

  /// Logs a malformed incoming record (one whose `recordID` does not decode into a valid
  /// id for its record type) at error level so the skip is visible in diagnostics
  /// instead of being silently dropped.
  nonisolated private static func logMalformed(_ site: String, _ ckRecord: CKRecord) {
    batchLogger.error(
      "\(site): malformed recordID '\(ckRecord.recordID.recordName)' (recordType \(ckRecord.recordType)) — skipping"
    )
  }
}
