import CloudKit
import Foundation

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
