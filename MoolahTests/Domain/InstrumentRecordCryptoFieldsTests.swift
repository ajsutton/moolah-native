import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pins the wire-format contract for the three crypto provider-mapping
/// columns (`coingeckoId`, `cryptocompareSymbol`, `binanceSymbol`) on
/// `InstrumentRow`. Asserts that these fields round-trip through CloudKit,
/// stay absent (not-`nil`-valued) when unset, and survive forward-compat
/// decoding of older payloads that didn't carry them.
@Suite("InstrumentRow — Crypto Provider Mapping Fields")
struct InstrumentRecordCryptoFieldsTests {

  private func makeInstrumentRow(
    id: String,
    kind: String,
    name: String,
    decimals: Int,
    ticker: String? = nil,
    exchange: String? = nil,
    chainId: Int? = nil,
    contractAddress: String? = nil,
    coingeckoId: String? = nil,
    cryptocompareSymbol: String? = nil,
    binanceSymbol: String? = nil
  ) -> InstrumentRow {
    InstrumentRow(
      id: id,
      recordName: id,
      kind: kind,
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: chainId,
      contractAddress: contractAddress,
      coingeckoId: coingeckoId,
      cryptocompareSymbol: cryptocompareSymbol,
      binanceSymbol: binanceSymbol,
      encodedSystemFields: nil)
  }

  @Test
  func initializerAcceptsAllMappingFields() {
    let row = makeInstrumentRow(
      id: "1:native",
      kind: "cryptoToken",
      name: "Ethereum",
      decimals: 18,
      ticker: "ETH",
      chainId: 1,
      coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT")
    #expect(row.coingeckoId == "ethereum")
    #expect(row.cryptocompareSymbol == "ETH")
    #expect(row.binanceSymbol == "ETHUSDT")
  }

  @Test
  func mappingFieldsDefaultToNil() {
    let row = makeInstrumentRow(id: "AUD", kind: "fiatCurrency", name: "AUD", decimals: 2)
    #expect(row.coingeckoId == nil)
    #expect(row.cryptocompareSymbol == nil)
    #expect(row.binanceSymbol == nil)
  }

  @Test
  func ckRecordRoundTripWithMapping() throws {
    let original = makeInstrumentRow(
      id: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
      kind: "cryptoToken",
      name: "Tether",
      decimals: 6,
      ticker: "USDT",
      chainId: 1,
      contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
      coingeckoId: "tether",
      cryptocompareSymbol: "USDT",
      binanceSymbol: "USDTUSDT")
    let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let ckRecord = original.toCKRecord(in: zoneID)

    #expect(ckRecord["coingeckoId"] as? String == "tether")
    #expect(ckRecord["cryptocompareSymbol"] as? String == "USDT")
    #expect(ckRecord["binanceSymbol"] as? String == "USDTUSDT")

    let decoded = try #require(InstrumentRow.fieldValues(from: ckRecord))
    #expect(decoded.coingeckoId == "tether")
    #expect(decoded.cryptocompareSymbol == "USDT")
    #expect(decoded.binanceSymbol == "USDTUSDT")
  }

  @Test
  func ckRecordNilMappingFieldsAreAbsentNotNull() {
    let row = makeInstrumentRow(id: "AUD", kind: "fiatCurrency", name: "AUD", decimals: 2)
    let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let ckRecord = row.toCKRecord(in: zoneID)

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

    let decoded = try #require(InstrumentRow.fieldValues(from: ckRecord))
    #expect(decoded.coingeckoId == nil)
    #expect(decoded.cryptocompareSymbol == nil)
    #expect(decoded.binanceSymbol == nil)
    #expect(decoded.id == "AUD")
    #expect(decoded.kind == "fiatCurrency")
  }
}
