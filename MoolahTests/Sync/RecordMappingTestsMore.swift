import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("RecordMapping — Part 2")
struct RecordMappingTestsMore {
  let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  @Test
  func earmarkBudgetItemRecordRoundTrip() {
    let earmarkId = UUID()
    let categoryId = UUID()
    let item = EarmarkBudgetItemRecord(
      id: UUID(),
      earmarkId: earmarkId,
      categoryId: categoryId,
      amount: 1_000_000_000,
      instrumentId: "AUD"
    )

    let ckRecord = item.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_EarmarkBudgetItemRecord")
    #expect(ckRecord["earmarkId"] as? String == earmarkId.uuidString)
    #expect(ckRecord["categoryId"] as? String == categoryId.uuidString)
    #expect(ckRecord["amount"] as? Int64 == 1_000_000_000)
    #expect(ckRecord["instrumentId"] as? String == "AUD")

    let restored = EarmarkBudgetItemRecord.fieldValues(from: ckRecord)
    #expect(restored.id == item.id)
    #expect(restored.earmarkId == earmarkId)
    #expect(restored.categoryId == categoryId)
    #expect(restored.amount == 1_000_000_000)
    #expect(restored.instrumentId == "AUD")
  }

  // MARK: - InvestmentValueRecord

  @Test
  func investmentValueRecordRoundTrip() {
    let accountId = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let record = InvestmentValueRecord(
      id: UUID(),
      accountId: accountId,
      date: date,
      value: 25_000_000_000,
      instrumentId: "AUD"
    )

    let ckRecord = record.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_InvestmentValueRecord")
    #expect(ckRecord["accountId"] as? String == accountId.uuidString)
    #expect(ckRecord["date"] as? Date == date)
    #expect(ckRecord["value"] as? Int64 == 25_000_000_000)
    #expect(ckRecord["instrumentId"] as? String == "AUD")

    let restored = InvestmentValueRecord.fieldValues(from: ckRecord)
    #expect(restored.id == record.id)
    #expect(restored.accountId == accountId)
    #expect(restored.date == date)
    #expect(restored.value == 25_000_000_000)
    #expect(restored.instrumentId == "AUD")
  }

  // MARK: - Multi-instrument persistence

  @Test
  func instrumentRecordCryptoFieldsRoundTrip() {
    let instrument = InstrumentRecord(
      id: "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      kind: "cryptoToken",
      name: "USD Coin",
      decimals: 6,
      ticker: "USDC",
      exchange: nil,
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    )

    let ckRecord = instrument.toCKRecord(in: zoneID)
    #expect(ckRecord["kind"] as? String == "cryptoToken")
    #expect(ckRecord["ticker"] as? String == "USDC")
    #expect(ckRecord["chainId"] as? Int == 1)
    #expect(
      ckRecord["contractAddress"] as? String == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(ckRecord["exchange"] == nil)

    let restored = InstrumentRecord.fieldValues(from: ckRecord)
    #expect(restored.id == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(restored.kind == "cryptoToken")
    #expect(restored.decimals == 6)
    #expect(restored.ticker == "USDC")
    #expect(restored.chainId == 1)
    #expect(restored.contractAddress == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
  }

  @Test
  func instrumentRecordNativeCryptoHasNoContractAddress() {
    // Bitcoin uses chainId = 0 and nil contractAddress; ETH native uses chainId = 1.
    let btc = InstrumentRecord(
      id: "0:native",
      kind: "cryptoToken",
      name: "Bitcoin",
      decimals: 8,
      ticker: "BTC",
      chainId: 0,
      contractAddress: nil
    )

    let ckRecord = btc.toCKRecord(in: zoneID)
    #expect(ckRecord["chainId"] as? Int == 0)
    #expect(ckRecord["contractAddress"] == nil)

    let restored = InstrumentRecord.fieldValues(from: ckRecord)
    #expect(restored.chainId == 0)
    #expect(restored.contractAddress == nil)
  }

  @Test
  func instrumentRecordToDomainForStockAndCryptoKinds() {
    let stock = InstrumentRecord(
      id: "ASX:BHP",
      kind: "stock",
      name: "BHP",
      decimals: 0,
      ticker: "BHP.AX",
      exchange: "ASX"
    )
    let stockDomain = stock.toDomain()
    #expect(stockDomain.kind == .stock)
    #expect(stockDomain.ticker == "BHP.AX")
    #expect(stockDomain.exchange == "ASX")

    let crypto = InstrumentRecord(
      id: "1:native",
      kind: "cryptoToken",
      name: "Ethereum",
      decimals: 18,
      ticker: "ETH",
      chainId: 1
    )
    let cryptoDomain = crypto.toDomain()
    #expect(cryptoDomain.kind == .cryptoToken)
    #expect(cryptoDomain.ticker == "ETH")
    #expect(cryptoDomain.chainId == 1)
  }

  @Test
  func instrumentRecordUnknownKindFallsBackToFiat() {
    // Defensive: if a future version writes an unknown kind, Record.toDomain should not crash.
    let record = InstrumentRecord(
      id: "XYZ",
      kind: "notARealKind",
      name: "Bogus",
      decimals: 2
    )
    let domain = record.toDomain()
    #expect(domain.kind == .fiatCurrency)
  }

  @Test
  func accountRecordRoundTripForStockInstrumentId() {
    let account = AccountRecord(
      id: UUID(),
      name: "Sharesight",
      type: "investment",
      instrumentId: "ASX:BHP",
      position: 0,
      isHidden: false
    )

    let ckRecord = account.toCKRecord(in: zoneID)
    #expect(ckRecord["instrumentId"] as? String == "ASX:BHP")

    let restored = AccountRecord.fieldValues(from: ckRecord)
    #expect(restored.instrumentId == "ASX:BHP")
    #expect(restored.type == "investment")
  }

  @Test
  func accountRecordRoundTripForCryptoInstrumentId() {
    let account = AccountRecord(
      id: UUID(),
      name: "Wallet",
      type: "investment",
      instrumentId: "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      position: 0,
      isHidden: false
    )

    let ckRecord = account.toCKRecord(in: zoneID)
    #expect(
      ckRecord["instrumentId"] as? String
        == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")

    let restored = AccountRecord.fieldValues(from: ckRecord)
    #expect(restored.instrumentId == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
  }

  @Test
  func transactionLegRecordRoundTripForStockInstrument() {
    let leg = TransactionLegRecord(
      id: UUID(),
      transactionId: UUID(),
      accountId: UUID(),
      instrumentId: "ASX:BHP",
      // 150 shares × 10^8 scale
      quantity: 15_000_000_000,
      type: "transfer",
      sortOrder: 0
    )

    let ckRecord = leg.toCKRecord(in: zoneID)
    #expect(ckRecord["instrumentId"] as? String == "ASX:BHP")
    #expect(ckRecord["quantity"] as? Int64 == 15_000_000_000)

    let restored = TransactionLegRecord.fieldValues(from: ckRecord)
    #expect(restored.instrumentId == "ASX:BHP")
    #expect(restored.quantity == 15_000_000_000)
  }

  @Test
  func transactionLegRecordRoundTripForCryptoInstrument() {
    let leg = TransactionLegRecord(
      id: UUID(),
      transactionId: UUID(),
      accountId: UUID(),
      instrumentId: "1:native",
      // 0.5 ETH × 10^8 scale
      quantity: 50_000_000,
      type: "transfer",
      sortOrder: 0
    )

    let ckRecord = leg.toCKRecord(in: zoneID)
    #expect(ckRecord["instrumentId"] as? String == "1:native")
    #expect(ckRecord["quantity"] as? Int64 == 50_000_000)

    let restored = TransactionLegRecord.fieldValues(from: ckRecord)
    #expect(restored.instrumentId == "1:native")
    #expect(restored.quantity == 50_000_000)
  }

  @Test
  func earmarkRecordRoundTripForNonFiatSavingsTarget() {
    // Earmark tracking a stock or crypto target for goals like "own 100 BHP".
    let earmark = EarmarkRecord(
      id: UUID(),
      name: "Stock Goal",
      position: 0,
      isHidden: false,
      savingsTarget: 10_000_000_000,
      savingsTargetInstrumentId: "ASX:BHP",
      savingsStartDate: nil,
      savingsEndDate: nil
    )

    let ckRecord = earmark.toCKRecord(in: zoneID)
    #expect(ckRecord["savingsTargetInstrumentId"] as? String == "ASX:BHP")

    let restored = EarmarkRecord.fieldValues(from: ckRecord)
    #expect(restored.savingsTargetInstrumentId == "ASX:BHP")
  }

  @Test
  func earmarkBudgetItemRecordRoundTripForForeignInstrument() {
    let item = EarmarkBudgetItemRecord(
      id: UUID(),
      earmarkId: UUID(),
      categoryId: UUID(),
      amount: 100_000_000_000,
      instrumentId: "USD"
    )

    let ckRecord = item.toCKRecord(in: zoneID)
    #expect(ckRecord["instrumentId"] as? String == "USD")
    #expect(ckRecord["amount"] as? Int64 == 100_000_000_000)

    let restored = EarmarkBudgetItemRecord.fieldValues(from: ckRecord)
    #expect(restored.instrumentId == "USD")
    #expect(restored.amount == 100_000_000_000)
  }

  // MARK: - Record Type Strings

  @Test
  func recordTypeStrings() {
    #expect(ProfileRecord.recordType == "CD_ProfileRecord")
    #expect(AccountRecord.recordType == "CD_AccountRecord")
    #expect(TransactionRecord.recordType == "CD_TransactionRecord")
    #expect(TransactionLegRecord.recordType == "CD_TransactionLegRecord")
    #expect(InstrumentRecord.recordType == "CD_InstrumentRecord")
    #expect(CategoryRecord.recordType == "CD_CategoryRecord")
    #expect(EarmarkRecord.recordType == "CD_EarmarkRecord")
    #expect(EarmarkBudgetItemRecord.recordType == "CD_EarmarkBudgetItemRecord")
    #expect(InvestmentValueRecord.recordType == "CD_InvestmentValueRecord")
  }
}
