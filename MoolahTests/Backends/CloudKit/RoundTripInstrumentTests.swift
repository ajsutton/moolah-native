import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CloudKit record round trip — InstrumentRecord (recordName-keyed)")
struct RoundTripInstrumentTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("InstrumentRecord round-trips with all optional fields populated")
  func instrumentRoundTripFull() throws {
    let original = InstrumentRecord(
      id: "ASX:BHP",
      kind: "stock",
      name: "BHP",
      decimals: 4,
      ticker: "BHP",
      exchange: "ASX",
      chainId: 1,
      contractAddress: "0xabc",
      coingeckoId: "bhp",
      cryptocompareSymbol: "BHP",
      binanceSymbol: "BHPUSDT"
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(InstrumentRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.kind == original.kind)
    #expect(decoded.name == original.name)
    #expect(decoded.decimals == original.decimals)
    #expect(decoded.ticker == original.ticker)
    #expect(decoded.exchange == original.exchange)
    #expect(decoded.chainId == original.chainId)
    #expect(decoded.contractAddress == original.contractAddress)
  }

  @Test("InstrumentRecord round-trips with optional fields nil")
  func instrumentRoundTripMinimal() throws {
    let original = InstrumentRecord(
      id: "AUD",
      kind: "fiatCurrency",
      name: "Australian Dollar",
      decimals: 2,
      ticker: nil,
      exchange: nil,
      chainId: nil,
      contractAddress: nil,
      coingeckoId: nil,
      cryptocompareSymbol: nil,
      binanceSymbol: nil
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(InstrumentRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.ticker == nil)
    #expect(decoded.chainId == nil)
  }
}
