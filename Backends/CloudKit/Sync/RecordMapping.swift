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
    record["position"] = position as CKRecordValue
    record["isHidden"] = (isHidden ? 1 : 0) as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    if let cachedBalance {
      record["cachedBalance"] = cachedBalance as CKRecordValue
    }
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountRecord {
    AccountRecord(
      id: UUID(uuidString: ckRecord.recordID.recordName) ?? UUID(),
      name: ckRecord["name"] as? String ?? "",
      type: ckRecord["type"] as? String ?? "bank",
      position: ckRecord["position"] as? Int ?? 0,
      isHidden: (ckRecord["isHidden"] as? Int ?? 0) != 0,
      currencyCode: ckRecord["currencyCode"] as? String ?? "",
      cachedBalance: ckRecord["cachedBalance"] as? Int
    )
  }
}

// MARK: - TransactionRecord + CloudKitRecordConvertible

extension TransactionRecord: CloudKitRecordConvertible {
  static let recordType = "CD_TransactionRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
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
    return record
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
    record["position"] = position as CKRecordValue
    record["isHidden"] = (isHidden ? 1 : 0) as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    if let savingsTarget { record["savingsTarget"] = savingsTarget as CKRecordValue }
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
    record["earmarkId"] = earmarkId.uuidString as CKRecordValue
    record["categoryId"] = categoryId.uuidString as CKRecordValue
    record["amount"] = amount as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    return record
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
    record["accountId"] = accountId.uuidString as CKRecordValue
    record["date"] = date as CKRecordValue
    record["value"] = value as CKRecordValue
    record["currencyCode"] = currencyCode as CKRecordValue
    return record
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
