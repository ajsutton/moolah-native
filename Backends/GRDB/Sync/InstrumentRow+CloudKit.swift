// Backends/GRDB/Sync/InstrumentRow+CloudKit.swift

import CloudKit
import Foundation

// MARK: - InstrumentRow + CloudKitRecordConvertible
//
// `InstrumentRow` is the only synced row with a string primary key —
// the recordName is the bare `id` (e.g. `"AUD"`, `"ASX:BHP"`) with no
// `recordType|` prefix.

extension InstrumentRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    InstrumentRecordCloudKitFields(
      binanceSymbol: binanceSymbol,
      chainId: chainId.map(Int64.init),
      coingeckoId: coingeckoId,
      contractAddress: contractAddress,
      cryptocompareSymbol: cryptocompareSymbol,
      decimals: Int64(decimals),
      exchange: exchange,
      kind: kind,
      name: name,
      ticker: ticker
    ).write(to: record)
    return record
  }

  /// `InstrumentRow` is keyed by `recordName` (e.g. `"AUD"`,
  /// `"ASX:BHP"`) rather than a UUID. `recordName` is always non-nil on
  /// a valid `CKRecord.ID`, so this never returns `nil`; the Optional
  /// return type exists to keep the protocol signature uniform with
  /// UUID-keyed conformers.
  static func fieldValues(from ckRecord: CKRecord) -> InstrumentRow? {
    let fields = InstrumentRecordCloudKitFields(from: ckRecord)
    return InstrumentRow(
      id: ckRecord.recordID.recordName,
      recordName: ckRecord.recordID.recordName,
      kind: fields.kind ?? "fiatCurrency",
      name: fields.name ?? "",
      decimals: fields.decimals.map(Int.init) ?? 2,
      ticker: fields.ticker,
      exchange: fields.exchange,
      chainId: fields.chainId.map(Int.init),
      contractAddress: fields.contractAddress,
      coingeckoId: fields.coingeckoId,
      cryptocompareSymbol: fields.cryptocompareSymbol,
      binanceSymbol: fields.binanceSymbol,
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil)
  }
}
