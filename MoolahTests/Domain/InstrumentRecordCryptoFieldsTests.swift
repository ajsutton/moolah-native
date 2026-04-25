import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentRecord — Crypto Provider Mapping Fields")
struct InstrumentRecordCryptoFieldsTests {
  @Test
  func initializerAcceptsAllMappingFields() {
    let record = InstrumentRecord(
      id: "1:native",
      kind: "cryptoToken",
      name: "Ethereum",
      decimals: 18,
      ticker: "ETH",
      exchange: nil,
      chainId: 1,
      contractAddress: nil,
      coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT"
    )
    #expect(record.coingeckoId == "ethereum")
    #expect(record.cryptocompareSymbol == "ETH")
    #expect(record.binanceSymbol == "ETHUSDT")
  }

  @Test
  func mappingFieldsDefaultToNil() {
    let record = InstrumentRecord(
      id: "AUD", kind: "fiatCurrency", name: "AUD", decimals: 2)
    #expect(record.coingeckoId == nil)
    #expect(record.cryptocompareSymbol == nil)
    #expect(record.binanceSymbol == nil)
  }

  @Test
  func ckRecordRoundTripWithMapping() throws {
    let original = InstrumentRecord(
      id: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
      kind: "cryptoToken",
      name: "Tether",
      decimals: 6,
      ticker: "USDT",
      chainId: 1,
      contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      coingeckoId: "tether",
      cryptocompareSymbol: "USDT",
      binanceSymbol: "USDTUSDT"
    )
    let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let ckRecord = original.toCKRecord(in: zoneID)

    #expect(ckRecord["coingeckoId"] as? String == "tether")
    #expect(ckRecord["cryptocompareSymbol"] as? String == "USDT")
    #expect(ckRecord["binanceSymbol"] as? String == "USDTUSDT")

    let decoded = try #require(InstrumentRecord.fieldValues(from: ckRecord))
    #expect(decoded.coingeckoId == "tether")
    #expect(decoded.cryptocompareSymbol == "USDT")
    #expect(decoded.binanceSymbol == "USDTUSDT")
  }

  @Test
  func ckRecordNilMappingFieldsAreAbsentNotNull() {
    let record = InstrumentRecord(
      id: "AUD", kind: "fiatCurrency", name: "AUD", decimals: 2)
    let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let ckRecord = record.toCKRecord(in: zoneID)

    #expect(ckRecord["coingeckoId"] == nil)
    #expect(ckRecord["cryptocompareSymbol"] == nil)
    #expect(ckRecord["binanceSymbol"] == nil)
    // Keys must not be present at all — saves record bytes and matches the
    // existing convention for ticker/exchange/chainId/contractAddress.
    #expect(ckRecord.allKeys().contains("coingeckoId") == false)
    #expect(ckRecord.allKeys().contains("cryptocompareSymbol") == false)
    #expect(ckRecord.allKeys().contains("binanceSymbol") == false)
  }

  @Test
  func decodingPreMigrationCKRecordLeavesMappingFieldsNil() throws {
    // Simulate a record saved by an older version that didn't know about
    // the three new fields. Only the legacy keys are present.
    let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let recordID = CKRecord.ID(recordName: "AUD", zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "InstrumentRecord", recordID: recordID)
    ckRecord["kind"] = "fiatCurrency" as CKRecordValue
    ckRecord["name"] = "AUD" as CKRecordValue
    ckRecord["decimals"] = 2 as CKRecordValue

    let decoded = try #require(InstrumentRecord.fieldValues(from: ckRecord))
    #expect(decoded.coingeckoId == nil)
    #expect(decoded.cryptocompareSymbol == nil)
    #expect(decoded.binanceSymbol == nil)
    #expect(decoded.id == "AUD")
    #expect(decoded.kind == "fiatCurrency")
  }
}
