import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("DismissedTransferPairRow ⇄ DismissedTransferPair")
struct DismissedTransferPairRowTests {
  private let idLow = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
  private let idHigh = UUID(
    uuid: (255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
  private let dismissedAt = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("init(domain:).toDomain() round-trips id, transactionIds, dismissedAt")
  func roundTripsDomain() {
    let pair = DismissedTransferPair(
      transactionIds: [idLow, idHigh], dismissedAt: dismissedAt)
    let back = DismissedTransferPairRow(domain: pair).toDomain()
    #expect(back.id == pair.id)
    #expect(back.transactionIds == pair.transactionIds)
    #expect(back.dismissedAt == pair.dismissedAt)
  }

  @Test("init(domain:) sorts the two ids so transactionIdA < transactionIdB")
  func sortsIdPair() {
    let ascending = DismissedTransferPair(
      transactionIds: [idLow, idHigh], dismissedAt: dismissedAt)
    let descending = DismissedTransferPair(
      transactionIds: [idHigh, idLow], dismissedAt: dismissedAt)
    let rowAsc = DismissedTransferPairRow(domain: ascending)
    let rowDesc = DismissedTransferPairRow(domain: descending)

    #expect(rowAsc.transactionIdA.uuidString < rowAsc.transactionIdB.uuidString)
    #expect(rowAsc.transactionIdA == rowDesc.transactionIdA)
    #expect(rowAsc.transactionIdB == rowDesc.transactionIdB)
    #expect(rowAsc.recordName == rowDesc.recordName)
    #expect(rowAsc.id == rowDesc.id)
  }

  @Test("toCKRecord(in:) → fieldValues(from:) round-trips the row columns")
  func roundTripsThroughCKRecord() throws {
    let pair = DismissedTransferPair(
      transactionIds: [idLow, idHigh], dismissedAt: dismissedAt)
    let row = DismissedTransferPairRow(domain: pair)
    let zoneID = CKRecordZone.ID(zoneName: "test-zone")
    let ckRecord = row.toCKRecord(in: zoneID)
    let back = try #require(DismissedTransferPairRow.fieldValues(from: ckRecord))

    #expect(back.id == row.id)
    #expect(back.recordName == row.recordName)
    #expect(back.transactionIdA == row.transactionIdA)
    #expect(back.transactionIdB == row.transactionIdB)
    #expect(back.dismissedAt == row.dismissedAt)
  }
}
