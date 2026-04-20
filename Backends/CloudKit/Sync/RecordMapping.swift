import CloudKit
import Foundation

/// Protocol for bidirectional conversion between SwiftData records and CKRecords.
protocol CloudKitRecordConvertible {
  static var recordType: String { get }

  /// Converts this record to a CKRecord in the given zone.
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord

  /// Extracts field values from a CKRecord. Returns a new instance with the extracted values.
  /// Note: This does not create a managed @Model instance — it returns field values only.
  static func fieldValues(from ckRecord: CKRecord) -> Self
}

/// Protocol for records that have a UUID `id` property.
/// Used by `buildCKRecord` to look up cached system fields by record name.
protocol IdentifiableRecord {
  var id: UUID { get }
}

extension AccountRecord: IdentifiableRecord {}
extension TransactionRecord: IdentifiableRecord {}
extension TransactionLegRecord: IdentifiableRecord {}
extension CategoryRecord: IdentifiableRecord {}
extension EarmarkRecord: IdentifiableRecord {}
extension EarmarkBudgetItemRecord: IdentifiableRecord {}
extension InvestmentValueRecord: IdentifiableRecord {}
extension ProfileRecord: IdentifiableRecord {}
extension CSVImportProfileRecord: IdentifiableRecord {}
extension ImportRuleRecord: IdentifiableRecord {}

/// Protocol for records that can store CKRecord system fields.
protocol SystemFieldsCacheable: AnyObject {
  var encodedSystemFields: Data? { get set }
}

extension AccountRecord: SystemFieldsCacheable {}
extension TransactionRecord: SystemFieldsCacheable {}
extension TransactionLegRecord: SystemFieldsCacheable {}
extension CategoryRecord: SystemFieldsCacheable {}
extension EarmarkRecord: SystemFieldsCacheable {}
extension EarmarkBudgetItemRecord: SystemFieldsCacheable {}
extension InvestmentValueRecord: SystemFieldsCacheable {}
extension InstrumentRecord: SystemFieldsCacheable {}
extension ProfileRecord: SystemFieldsCacheable {}
extension CSVImportProfileRecord: SystemFieldsCacheable {}
extension ImportRuleRecord: SystemFieldsCacheable {}

// MARK: - CKRecord System Fields

extension CKRecord {
  /// Encodes the record's system fields (including the change tag) for caching.
  /// Used to preserve change tags across uploads and avoid `.serverRecordChanged` conflicts.
  var encodedSystemFields: Data {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    encodeSystemFields(with: coder)
    coder.finishEncoding()
    return coder.encodedData
  }

  /// Creates a CKRecord from previously cached system fields.
  /// Returns nil if the data is invalid.
  static func fromEncodedSystemFields(_ data: Data) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    coder.requiresSecureCoding = true
    return CKRecord(coder: coder)
  }
}

// MARK: - ProfileRecord + CloudKitRecordConvertible

extension ProfileRecord: CloudKitRecordConvertible {
  static let recordType = "CD_ProfileRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["label"] = label as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    record["financialYearStartMonth"] = financialYearStartMonth as CKRecordValue
    record["createdAt"] = createdAt as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ProfileRecord {
    ProfileRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      label: ckRecord["label"] as? String ?? "",
      currencyCode: ckRecord["currencyCode"] as? String ?? "",
      financialYearStartMonth: ckRecord["financialYearStartMonth"] as? Int ?? 7,
      createdAt: ckRecord["createdAt"] as? Date ?? Date()
    )
  }
}

// MARK: - AccountRecord + CloudKitRecordConvertible

extension AccountRecord: CloudKitRecordConvertible {
  static let recordType = "CD_AccountRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["name"] = name as CKRecordValue
    record["type"] = type as CKRecordValue
    record["instrumentId"] = instrumentId as CKRecordValue
    record["position"] = position as CKRecordValue
    record["isHidden"] = (isHidden ? 1 : 0) as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountRecord {
    AccountRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      name: ckRecord["name"] as? String ?? "",
      type: ckRecord["type"] as? String ?? "bank",
      instrumentId: ckRecord["instrumentId"] as? String ?? "AUD",
      position: ckRecord["position"] as? Int ?? 0,
      isHidden: (ckRecord["isHidden"] as? Int ?? 0) != 0
    )
  }
}

// MARK: - TransactionRecord + CloudKitRecordConvertible

extension TransactionRecord: CloudKitRecordConvertible {
  static let recordType = "CD_TransactionRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["date"] = date as CKRecordValue
    if let payee { record["payee"] = payee as CKRecordValue }
    if let notes { record["notes"] = notes as CKRecordValue }
    if let recurPeriod { record["recurPeriod"] = recurPeriod as CKRecordValue }
    if let recurEvery { record["recurEvery"] = recurEvery as CKRecordValue }
    if let v = importOriginRawDescription {
      record["importOriginRawDescription"] = v as CKRecordValue
    }
    if let v = importOriginBankReference {
      record["importOriginBankReference"] = v as CKRecordValue
    }
    if let v = importOriginRawAmount {
      record["importOriginRawAmount"] = v as CKRecordValue
    }
    if let v = importOriginRawBalance {
      record["importOriginRawBalance"] = v as CKRecordValue
    }
    if let v = importOriginImportedAt {
      record["importOriginImportedAt"] = v as CKRecordValue
    }
    if let v = importOriginImportSessionId {
      record["importOriginImportSessionId"] = v.uuidString as CKRecordValue
    }
    if let v = importOriginSourceFilename {
      record["importOriginSourceFilename"] = v as CKRecordValue
    }
    if let v = importOriginParserIdentifier {
      record["importOriginParserIdentifier"] = v as CKRecordValue
    }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransactionRecord {
    let record = TransactionRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      date: ckRecord["date"] as? Date ?? Date(),
      payee: ckRecord["payee"] as? String,
      notes: ckRecord["notes"] as? String,
      recurPeriod: ckRecord["recurPeriod"] as? String,
      recurEvery: ckRecord["recurEvery"] as? Int
    )
    record.importOriginRawDescription = ckRecord["importOriginRawDescription"] as? String
    record.importOriginBankReference = ckRecord["importOriginBankReference"] as? String
    record.importOriginRawAmount = ckRecord["importOriginRawAmount"] as? String
    record.importOriginRawBalance = ckRecord["importOriginRawBalance"] as? String
    record.importOriginImportedAt = ckRecord["importOriginImportedAt"] as? Date
    record.importOriginImportSessionId = (ckRecord["importOriginImportSessionId"] as? String)
      .flatMap { UUID(uuidString: $0) }
    record.importOriginSourceFilename = ckRecord["importOriginSourceFilename"] as? String
    record.importOriginParserIdentifier = ckRecord["importOriginParserIdentifier"] as? String
    return record
  }
}

// MARK: - TransactionLegRecord + CloudKitRecordConvertible

extension TransactionLegRecord: CloudKitRecordConvertible {
  static let recordType = "CD_TransactionLegRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["transactionId"] = transactionId.uuidString as CKRecordValue
    if let accountId { record["accountId"] = accountId.uuidString as CKRecordValue }
    record["instrumentId"] = instrumentId as CKRecordValue
    record["quantity"] = quantity as CKRecordValue
    record["type"] = type as CKRecordValue
    if let categoryId { record["categoryId"] = categoryId.uuidString as CKRecordValue }
    if let earmarkId { record["earmarkId"] = earmarkId.uuidString as CKRecordValue }
    record["sortOrder"] = sortOrder as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransactionLegRecord {
    TransactionLegRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      transactionId: (ckRecord["transactionId"] as? String).flatMap { UUID(uuidString: $0) }
        ?? UUID(),
      accountId: (ckRecord["accountId"] as? String).flatMap { UUID(uuidString: $0) },
      instrumentId: ckRecord["instrumentId"] as? String ?? "",
      quantity: ckRecord["quantity"] as? Int64 ?? 0,
      type: ckRecord["type"] as? String ?? "expense",
      categoryId: (ckRecord["categoryId"] as? String).flatMap { UUID(uuidString: $0) },
      earmarkId: (ckRecord["earmarkId"] as? String).flatMap { UUID(uuidString: $0) },
      sortOrder: ckRecord["sortOrder"] as? Int ?? 0
    )
  }
}

// MARK: - InstrumentRecord + CloudKitRecordConvertible

extension InstrumentRecord: CloudKitRecordConvertible {
  static let recordType = "CD_InstrumentRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["kind"] = kind as CKRecordValue
    record["name"] = name as CKRecordValue
    record["decimals"] = decimals as CKRecordValue
    if let ticker { record["ticker"] = ticker as CKRecordValue }
    if let exchange { record["exchange"] = exchange as CKRecordValue }
    if let chainId { record["chainId"] = chainId as CKRecordValue }
    if let contractAddress { record["contractAddress"] = contractAddress as CKRecordValue }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> InstrumentRecord {
    InstrumentRecord(
      id: ckRecord.recordID.recordName,
      kind: ckRecord["kind"] as? String ?? "fiatCurrency",
      name: ckRecord["name"] as? String ?? "",
      decimals: ckRecord["decimals"] as? Int ?? 2,
      ticker: ckRecord["ticker"] as? String,
      exchange: ckRecord["exchange"] as? String,
      chainId: ckRecord["chainId"] as? Int,
      contractAddress: ckRecord["contractAddress"] as? String
    )
  }
}

// MARK: - CategoryRecord + CloudKitRecordConvertible

extension CategoryRecord: CloudKitRecordConvertible {
  static let recordType = "CD_CategoryRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["name"] = name as CKRecordValue
    if let parentId { record["parentId"] = parentId.uuidString as CKRecordValue }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> CategoryRecord {
    CategoryRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      name: ckRecord["name"] as? String ?? "",
      parentId: (ckRecord["parentId"] as? String).flatMap { UUID(uuidString: $0) }
    )
  }
}

// MARK: - EarmarkRecord + CloudKitRecordConvertible

extension EarmarkRecord: CloudKitRecordConvertible {
  static let recordType = "CD_EarmarkRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["name"] = name as CKRecordValue
    if let instrumentId { record["instrumentId"] = instrumentId as CKRecordValue }
    record["position"] = position as CKRecordValue
    record["isHidden"] = (isHidden ? 1 : 0) as CKRecordValue
    if let savingsTarget { record["savingsTarget"] = savingsTarget as CKRecordValue }
    if let savingsTargetInstrumentId {
      record["savingsTargetInstrumentId"] = savingsTargetInstrumentId as CKRecordValue
    }
    if let savingsStartDate { record["savingsStartDate"] = savingsStartDate as CKRecordValue }
    if let savingsEndDate { record["savingsEndDate"] = savingsEndDate as CKRecordValue }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkRecord {
    EarmarkRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      name: ckRecord["name"] as? String ?? "",
      position: ckRecord["position"] as? Int ?? 0,
      isHidden: (ckRecord["isHidden"] as? Int ?? 0) != 0,
      instrumentId: ckRecord["instrumentId"] as? String,
      savingsTarget: ckRecord["savingsTarget"] as? Int64,
      savingsTargetInstrumentId: ckRecord["savingsTargetInstrumentId"] as? String,
      savingsStartDate: ckRecord["savingsStartDate"] as? Date,
      savingsEndDate: ckRecord["savingsEndDate"] as? Date
    )
  }
}

// MARK: - EarmarkBudgetItemRecord + CloudKitRecordConvertible

extension EarmarkBudgetItemRecord: CloudKitRecordConvertible {
  static let recordType = "CD_EarmarkBudgetItemRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["earmarkId"] = earmarkId.uuidString as CKRecordValue
    record["categoryId"] = categoryId.uuidString as CKRecordValue
    record["amount"] = amount as CKRecordValue
    record["instrumentId"] = instrumentId as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkBudgetItemRecord {
    EarmarkBudgetItemRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      earmarkId: (ckRecord["earmarkId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      categoryId: (ckRecord["categoryId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      amount: ckRecord["amount"] as? Int64 ?? 0,
      instrumentId: ckRecord["instrumentId"] as? String ?? ""
    )
  }
}

// MARK: - InvestmentValueRecord + CloudKitRecordConvertible

extension InvestmentValueRecord: CloudKitRecordConvertible {
  static let recordType = "CD_InvestmentValueRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["accountId"] = accountId.uuidString as CKRecordValue
    record["date"] = date as CKRecordValue
    record["value"] = value as CKRecordValue
    record["instrumentId"] = instrumentId as CKRecordValue
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> InvestmentValueRecord {
    InvestmentValueRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      accountId: (ckRecord["accountId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      date: ckRecord["date"] as? Date ?? Date(),
      value: ckRecord["value"] as? Int64 ?? 0,
      instrumentId: ckRecord["instrumentId"] as? String ?? ""
    )
  }
}

// MARK: - CSVImportProfileRecord + CloudKitRecordConvertible

extension CSVImportProfileRecord: CloudKitRecordConvertible {
  static let recordType = "CD_CSVImportProfileRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["accountId"] = accountId.uuidString as CKRecordValue
    record["parserIdentifier"] = parserIdentifier as CKRecordValue
    record["headerSignature"] = headerSignature as CKRecordValue
    if let v = filenamePattern { record["filenamePattern"] = v as CKRecordValue }
    record["deleteAfterImport"] = (deleteAfterImport ? 1 : 0) as CKRecordValue
    record["createdAt"] = createdAt as CKRecordValue
    if let v = lastUsedAt { record["lastUsedAt"] = v as CKRecordValue }
    if let v = dateFormatRawValue { record["dateFormatRawValue"] = v as CKRecordValue }
    if let v = columnRoleRawValuesEncoded {
      record["columnRoleRawValuesEncoded"] = v as CKRecordValue
    }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> CSVImportProfileRecord {
    let record = CSVImportProfileRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      accountId: (ckRecord["accountId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      parserIdentifier: ckRecord["parserIdentifier"] as? String ?? "",
      headerSignature: [],
      filenamePattern: ckRecord["filenamePattern"] as? String,
      deleteAfterImport: (ckRecord["deleteAfterImport"] as? Int ?? 0) != 0,
      createdAt: ckRecord["createdAt"] as? Date ?? Date(),
      lastUsedAt: ckRecord["lastUsedAt"] as? Date,
      dateFormatRawValue: ckRecord["dateFormatRawValue"] as? String,
      columnRoleRawValuesEncoded: ckRecord["columnRoleRawValuesEncoded"] as? String)
    // Store the joined headerSignature directly (init normalises via joining,
    // but the CK value already arrives pre-joined).
    record.headerSignature = ckRecord["headerSignature"] as? String ?? ""
    return record
  }
}

// MARK: - ImportRuleRecord + CloudKitRecordConvertible

extension ImportRuleRecord: CloudKitRecordConvertible {
  static let recordType = "CD_ImportRuleRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record["name"] = name as CKRecordValue
    record["enabled"] = (enabled ? 1 : 0) as CKRecordValue
    record["position"] = position as CKRecordValue
    record["matchMode"] = matchMode as CKRecordValue
    record["conditionsJSON"] = conditionsJSON as CKRecordValue
    record["actionsJSON"] = actionsJSON as CKRecordValue
    if let v = accountScope { record["accountScope"] = v.uuidString as CKRecordValue }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> ImportRuleRecord {
    let id = UUID(uuidString: ckRecord.recordID.recordName) ?? UUID()
    // The convenience initializer re-encodes the conditions/actions arrays,
    // so to avoid a decode-then-re-encode round trip we go through the
    // synthesised property setters on a fresh record.
    let record = ImportRuleRecord(
      id: id,
      name: ckRecord["name"] as? String ?? "",
      enabled: (ckRecord["enabled"] as? Int ?? 0) != 0,
      position: ckRecord["position"] as? Int ?? 0,
      matchMode: MatchMode(rawValue: ckRecord["matchMode"] as? String ?? "all") ?? .all,
      conditions: [],
      actions: [],
      accountScope: (ckRecord["accountScope"] as? String).flatMap { UUID(uuidString: $0) })
    record.conditionsJSON = ckRecord["conditionsJSON"] as? Data ?? Data()
    record.actionsJSON = ckRecord["actionsJSON"] as? Data ?? Data()
    return record
  }
}

// MARK: - Lookup Helper

/// Maps CKRecord.recordType strings to the corresponding record types for dispatching.
enum RecordTypeRegistry: Sendable {
  static nonisolated(unsafe) let allTypes: [String: any CloudKitRecordConvertible.Type] = [
    ProfileRecord.recordType: ProfileRecord.self,
    InstrumentRecord.recordType: InstrumentRecord.self,
    AccountRecord.recordType: AccountRecord.self,
    TransactionRecord.recordType: TransactionRecord.self,
    TransactionLegRecord.recordType: TransactionLegRecord.self,
    CategoryRecord.recordType: CategoryRecord.self,
    EarmarkRecord.recordType: EarmarkRecord.self,
    EarmarkBudgetItemRecord.recordType: EarmarkBudgetItemRecord.self,
    InvestmentValueRecord.recordType: InvestmentValueRecord.self,
    CSVImportProfileRecord.recordType: CSVImportProfileRecord.self,
    ImportRuleRecord.recordType: ImportRuleRecord.self,
  ]
}
