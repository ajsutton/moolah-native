import CloudKit
import Foundation

/// Protocol for bidirectional conversion between SwiftData records and CKRecords.
protocol CloudKitRecordConvertible {
  static var recordType: String { get }

  /// Converts this record to a CKRecord in the given zone.
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord

  /// Applies this record's field values to an existing CKRecord.
  /// Used to write fields directly onto a cached record that preserves system fields,
  /// avoiding creation of a throwaway intermediate CKRecord.
  func applyFields(to record: CKRecord)

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
extension CategoryRecord: IdentifiableRecord {}
extension EarmarkRecord: IdentifiableRecord {}
extension EarmarkBudgetItemRecord: IdentifiableRecord {}
extension InvestmentValueRecord: IdentifiableRecord {}
extension ProfileRecord: IdentifiableRecord {}

/// Protocol for records that can store CKRecord system fields.
protocol SystemFieldsCacheable {
  var encodedSystemFields: Data? { get }
}

extension AccountRecord: SystemFieldsCacheable {}
extension TransactionRecord: SystemFieldsCacheable {}
extension CategoryRecord: SystemFieldsCacheable {}
extension EarmarkRecord: SystemFieldsCacheable {}
extension EarmarkBudgetItemRecord: SystemFieldsCacheable {}
extension InvestmentValueRecord: SystemFieldsCacheable {}

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
    applyFields(to: record)
    return record
  }

  func applyFields(to record: CKRecord) {
    record["label"] = label as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    record["financialYearStartMonth"] = financialYearStartMonth as CKRecordValue
    record["createdAt"] = createdAt as CKRecordValue
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
    applyFields(to: record)
    return record
  }

  func applyFields(to record: CKRecord) {
    record["name"] = name as CKRecordValue
    record["type"] = type as CKRecordValue
    record["position"] = position as CKRecordValue
    record["isHidden"] = (isHidden ? 1 : 0) as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    // cachedBalance is NOT synced — it's derived locally from transactions.
    // Syncing it causes conflicts when transactions change on multiple devices.
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountRecord {
    AccountRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      name: ckRecord["name"] as? String ?? "",
      type: ckRecord["type"] as? String ?? "bank",
      position: ckRecord["position"] as? Int ?? 0,
      isHidden: (ckRecord["isHidden"] as? Int ?? 0) != 0,
      currencyCode: ckRecord["currencyCode"] as? String ?? ""
        // cachedBalance omitted — computed locally from transactions
    )
  }
}

// MARK: - TransactionRecord + CloudKitRecordConvertible

extension TransactionRecord: CloudKitRecordConvertible {
  static let recordType = "CD_TransactionRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    applyFields(to: record)
    return record
  }

  func applyFields(to record: CKRecord) {
    record["type"] = type as CKRecordValue
    record["date"] = date as CKRecordValue
    record["amount"] = amount as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    if let accountId { record["accountId"] = accountId.uuidString as CKRecordValue }
    if let toAccountId { record["toAccountId"] = toAccountId.uuidString as CKRecordValue }
    if let payee { record["payee"] = payee as CKRecordValue }
    if let notes { record["notes"] = notes as CKRecordValue }
    if let categoryId { record["categoryId"] = categoryId.uuidString as CKRecordValue }
    if let earmarkId { record["earmarkId"] = earmarkId.uuidString as CKRecordValue }
    if let recurPeriod { record["recurPeriod"] = recurPeriod as CKRecordValue }
    if let recurEvery { record["recurEvery"] = recurEvery as CKRecordValue }
  }

  static func fieldValues(from ckRecord: CKRecord) -> TransactionRecord {
    TransactionRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      type: ckRecord["type"] as? String ?? "expense",
      date: ckRecord["date"] as? Date ?? Date(),
      accountId: (ckRecord["accountId"] as? String).flatMap { UUID(uuidString: $0) },
      toAccountId: (ckRecord["toAccountId"] as? String).flatMap { UUID(uuidString: $0) },
      amount: ckRecord["amount"] as? Int ?? 0,
      currencyCode: ckRecord["currencyCode"] as? String ?? "",
      payee: ckRecord["payee"] as? String,
      notes: ckRecord["notes"] as? String,
      categoryId: (ckRecord["categoryId"] as? String).flatMap { UUID(uuidString: $0) },
      earmarkId: (ckRecord["earmarkId"] as? String).flatMap { UUID(uuidString: $0) },
      recurPeriod: ckRecord["recurPeriod"] as? String,
      recurEvery: ckRecord["recurEvery"] as? Int
    )
  }
}

// MARK: - CategoryRecord + CloudKitRecordConvertible

extension CategoryRecord: CloudKitRecordConvertible {
  static let recordType = "CD_CategoryRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    applyFields(to: record)
    return record
  }

  func applyFields(to record: CKRecord) {
    record["name"] = name as CKRecordValue
    if let parentId { record["parentId"] = parentId.uuidString as CKRecordValue }
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
    applyFields(to: record)
    return record
  }

  func applyFields(to record: CKRecord) {
    record["name"] = name as CKRecordValue
    record["position"] = position as CKRecordValue
    record["isHidden"] = (isHidden ? 1 : 0) as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    if let savingsTarget { record["savingsTarget"] = savingsTarget as CKRecordValue }
    if let savingsStartDate { record["savingsStartDate"] = savingsStartDate as CKRecordValue }
    if let savingsEndDate { record["savingsEndDate"] = savingsEndDate as CKRecordValue }
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkRecord {
    EarmarkRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      name: ckRecord["name"] as? String ?? "",
      position: ckRecord["position"] as? Int ?? 0,
      isHidden: (ckRecord["isHidden"] as? Int ?? 0) != 0,
      savingsTarget: ckRecord["savingsTarget"] as? Int,
      currencyCode: ckRecord["currencyCode"] as? String ?? "",
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
    applyFields(to: record)
    return record
  }

  func applyFields(to record: CKRecord) {
    record["earmarkId"] = earmarkId.uuidString as CKRecordValue
    record["categoryId"] = categoryId.uuidString as CKRecordValue
    record["amount"] = amount as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
  }

  static func fieldValues(from ckRecord: CKRecord) -> EarmarkBudgetItemRecord {
    EarmarkBudgetItemRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      earmarkId: (ckRecord["earmarkId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      categoryId: (ckRecord["categoryId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      amount: ckRecord["amount"] as? Int ?? 0,
      currencyCode: ckRecord["currencyCode"] as? String ?? ""
    )
  }
}

// MARK: - InvestmentValueRecord + CloudKitRecordConvertible

extension InvestmentValueRecord: CloudKitRecordConvertible {
  static let recordType = "CD_InvestmentValueRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    applyFields(to: record)
    return record
  }

  func applyFields(to record: CKRecord) {
    record["accountId"] = accountId.uuidString as CKRecordValue
    record["date"] = date as CKRecordValue
    record["value"] = value as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
  }

  static func fieldValues(from ckRecord: CKRecord) -> InvestmentValueRecord {
    InvestmentValueRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      accountId: (ckRecord["accountId"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID(),
      date: ckRecord["date"] as? Date ?? Date(),
      value: ckRecord["value"] as? Int ?? 0,
      currencyCode: ckRecord["currencyCode"] as? String ?? ""
    )
  }
}

// MARK: - Lookup Helper

/// Maps CKRecord.recordType strings to the corresponding record types for dispatching.
enum RecordTypeRegistry: Sendable {
  static nonisolated(unsafe) let allTypes: [String: any CloudKitRecordConvertible.Type] = [
    ProfileRecord.recordType: ProfileRecord.self,
    AccountRecord.recordType: AccountRecord.self,
    TransactionRecord.recordType: TransactionRecord.self,
    CategoryRecord.recordType: CategoryRecord.self,
    EarmarkRecord.recordType: EarmarkRecord.self,
    EarmarkBudgetItemRecord.recordType: EarmarkBudgetItemRecord.self,
    InvestmentValueRecord.recordType: InvestmentValueRecord.self,
  ]
}
