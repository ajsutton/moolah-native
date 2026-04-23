import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("RecordMapping")
struct RecordMappingTests {

  let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  // MARK: - ProfileRecord

  @Test
  func profileRecordRoundTrip() {
    let profile = ProfileRecord(
      id: UUID(),
      label: "My Budget",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let ckRecord = profile.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_ProfileRecord")
    #expect(ckRecord.recordID.recordName == profile.id.uuidString)
    #expect(ckRecord.recordID.zoneID == zoneID)
    #expect(ckRecord["label"] as? String == "My Budget")
    #expect(ckRecord["currencyCode"] as? String == "AUD")
    #expect(ckRecord["financialYearStartMonth"] as? Int == 7)
    #expect(ckRecord["createdAt"] as? Date == profile.createdAt)

    let restored = ProfileRecord.fieldValues(from: ckRecord)
    #expect(restored.id == profile.id)
    #expect(restored.label == "My Budget")
    #expect(restored.currencyCode == "AUD")
    #expect(restored.financialYearStartMonth == 7)
    #expect(restored.createdAt == profile.createdAt)
  }

  // MARK: - AccountRecord

  @Test
  func accountRecordRoundTrip() {
    let account = AccountRecord(
      id: UUID(),
      name: "Savings",
      type: "bank",
      instrumentId: "USD",
      position: 2,
      isHidden: true
    )

    let ckRecord = account.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_AccountRecord")
    #expect(ckRecord.recordID.recordName == account.id.uuidString)
    #expect(ckRecord["name"] as? String == "Savings")
    #expect(ckRecord["type"] as? String == "bank")
    #expect(ckRecord["instrumentId"] as? String == "USD")
    #expect(ckRecord["position"] as? Int == 2)
    #expect(ckRecord["isHidden"] as? Int == 1)

    let restored = AccountRecord.fieldValues(from: ckRecord)
    #expect(restored.id == account.id)
    #expect(restored.name == "Savings")
    #expect(restored.type == "bank")
    #expect(restored.instrumentId == "USD")
    #expect(restored.position == 2)
    #expect(restored.isHidden == true)
  }

  @Test
  func accountRecordFieldValuesDefaultsInstrumentId() {
    // When instrumentId is missing from CKRecord, default to "AUD"
    let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "CD_AccountRecord", recordID: recordID)
    ckRecord["name"] = "Test" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    // No instrumentId set

    let restored = AccountRecord.fieldValues(from: ckRecord)
    #expect(restored.instrumentId == "AUD")
  }

  // MARK: - TransactionRecord

  @Test
  func transactionRecordRoundTrip() {
    let txnDate = Date(timeIntervalSince1970: 1_700_000_000)

    let txn = TransactionRecord(
      id: UUID(),
      date: txnDate,
      payee: "Rent",
      notes: "Monthly rent",
      recurPeriod: "monthly",
      recurEvery: 1
    )

    let ckRecord = txn.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_TransactionRecord")
    #expect(ckRecord.recordID.recordName == txn.id.uuidString)
    #expect(ckRecord["date"] as? Date == txnDate)
    #expect(ckRecord["payee"] as? String == "Rent")
    #expect(ckRecord["notes"] as? String == "Monthly rent")
    #expect(ckRecord["recurPeriod"] as? String == "monthly")
    #expect(ckRecord["recurEvery"] as? Int == 1)

    let restored = TransactionRecord.fieldValues(from: ckRecord)
    #expect(restored.id == txn.id)
    #expect(restored.date == txnDate)
    #expect(restored.payee == "Rent")
    #expect(restored.notes == "Monthly rent")
    #expect(restored.recurPeriod == "monthly")
    #expect(restored.recurEvery == 1)
  }

  @Test
  func transactionRecordNilOptionals() {
    let txn = TransactionRecord(
      id: UUID(),
      date: Date()
    )

    let ckRecord = txn.toCKRecord(in: zoneID)
    #expect(ckRecord["payee"] == nil)
    #expect(ckRecord["notes"] == nil)
    #expect(ckRecord["recurPeriod"] == nil)
    #expect(ckRecord["recurEvery"] == nil)

    let restored = TransactionRecord.fieldValues(from: ckRecord)
    #expect(restored.payee == nil)
    #expect(restored.notes == nil)
    #expect(restored.recurPeriod == nil)
    #expect(restored.recurEvery == nil)
  }

  // MARK: - TransactionLegRecord

  @Test
  func transactionLegRecordRoundTrip() {
    let transactionId = UUID()
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()

    let leg = TransactionLegRecord(
      id: UUID(),
      transactionId: transactionId,
      accountId: accountId,
      instrumentId: "AUD",
      quantity: 500_000_000,
      type: "expense",
      categoryId: categoryId,
      earmarkId: earmarkId,
      sortOrder: 0
    )

    let ckRecord = leg.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_TransactionLegRecord")
    #expect(ckRecord.recordID.recordName == leg.id.uuidString)
    #expect(ckRecord["transactionId"] as? String == transactionId.uuidString)
    #expect(ckRecord["accountId"] as? String == accountId.uuidString)
    #expect(ckRecord["instrumentId"] as? String == "AUD")
    #expect(ckRecord["quantity"] as? Int64 == 500_000_000)
    #expect(ckRecord["type"] as? String == "expense")
    #expect(ckRecord["categoryId"] as? String == categoryId.uuidString)
    #expect(ckRecord["earmarkId"] as? String == earmarkId.uuidString)
    #expect(ckRecord["sortOrder"] as? Int == 0)

    let restored = TransactionLegRecord.fieldValues(from: ckRecord)
    #expect(restored.id == leg.id)
    #expect(restored.transactionId == transactionId)
    #expect(restored.accountId == accountId)
    #expect(restored.instrumentId == "AUD")
    #expect(restored.quantity == 500_000_000)
    #expect(restored.type == "expense")
    #expect(restored.categoryId == categoryId)
    #expect(restored.earmarkId == earmarkId)
    #expect(restored.sortOrder == 0)
  }

  @Test
  func transactionLegRecordNilOptionals() {
    let leg = TransactionLegRecord(
      transactionId: UUID(),
      accountId: UUID(),
      instrumentId: "AUD",
      quantity: 100_000_000,
      type: "expense"
    )

    let ckRecord = leg.toCKRecord(in: zoneID)
    #expect(ckRecord["categoryId"] == nil)
    #expect(ckRecord["earmarkId"] == nil)

    let restored = TransactionLegRecord.fieldValues(from: ckRecord)
    #expect(restored.categoryId == nil)
    #expect(restored.earmarkId == nil)
  }

  // MARK: - InstrumentRecord

  @Test
  func instrumentRecordRoundTrip() {
    let instrument = InstrumentRecord(
      id: "AUD",
      kind: "fiatCurrency",
      name: "Australian Dollar",
      decimals: 2
    )

    let ckRecord = instrument.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_InstrumentRecord")
    #expect(ckRecord.recordID.recordName == "AUD")
    #expect(ckRecord["kind"] as? String == "fiatCurrency")
    #expect(ckRecord["name"] as? String == "Australian Dollar")
    #expect(ckRecord["decimals"] as? Int == 2)
    #expect(ckRecord["ticker"] == nil)
    #expect(ckRecord["exchange"] == nil)

    let restored = InstrumentRecord.fieldValues(from: ckRecord)
    #expect(restored.id == "AUD")
    #expect(restored.kind == "fiatCurrency")
    #expect(restored.name == "Australian Dollar")
    #expect(restored.decimals == 2)
    #expect(restored.ticker == nil)
    #expect(restored.exchange == nil)
  }

  @Test
  func instrumentRecordWithStockFields() {
    let instrument = InstrumentRecord(
      id: "ASX:BHP",
      kind: "stock",
      name: "BHP Group",
      decimals: 2,
      ticker: "BHP",
      exchange: "ASX"
    )

    let ckRecord = instrument.toCKRecord(in: zoneID)
    #expect(ckRecord["ticker"] as? String == "BHP")
    #expect(ckRecord["exchange"] as? String == "ASX")

    let restored = InstrumentRecord.fieldValues(from: ckRecord)
    #expect(restored.ticker == "BHP")
    #expect(restored.exchange == "ASX")
  }

  // MARK: - CategoryRecord

  @Test
  func categoryRecordRoundTrip() {
    let parentId = UUID()
    let category = CategoryRecord(id: UUID(), name: "Food", parentId: parentId)

    let ckRecord = category.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_CategoryRecord")
    #expect(ckRecord["name"] as? String == "Food")
    #expect(ckRecord["parentId"] as? String == parentId.uuidString)

    let restored = CategoryRecord.fieldValues(from: ckRecord)
    #expect(restored.id == category.id)
    #expect(restored.name == "Food")
    #expect(restored.parentId == parentId)
  }

  @Test
  func categoryRecordNilParent() {
    let category = CategoryRecord(id: UUID(), name: "Root", parentId: nil)

    let ckRecord = category.toCKRecord(in: zoneID)
    #expect(ckRecord["parentId"] == nil)

    let restored = CategoryRecord.fieldValues(from: ckRecord)
    #expect(restored.parentId == nil)
  }

  // MARK: - EarmarkRecord

  @Test
  func earmarkRecordRoundTrip() {
    let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    let endDate = Date(timeIntervalSince1970: 1_710_000_000)
    let earmark = EarmarkRecord(
      id: UUID(),
      name: "Holiday Fund",
      position: 3,
      isHidden: false,
      savingsTarget: 50_000_000_000,
      savingsTargetInstrumentId: "AUD",
      savingsStartDate: startDate,
      savingsEndDate: endDate
    )

    let ckRecord = earmark.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_EarmarkRecord")
    #expect(ckRecord["name"] as? String == "Holiday Fund")
    #expect(ckRecord["position"] as? Int == 3)
    #expect(ckRecord["isHidden"] as? Int == 0)
    #expect(ckRecord["savingsTarget"] as? Int64 == 50_000_000_000)
    #expect(ckRecord["savingsTargetInstrumentId"] as? String == "AUD")
    #expect(ckRecord["savingsStartDate"] as? Date == startDate)
    #expect(ckRecord["savingsEndDate"] as? Date == endDate)

    let restored = EarmarkRecord.fieldValues(from: ckRecord)
    #expect(restored.id == earmark.id)
    #expect(restored.name == "Holiday Fund")
    #expect(restored.position == 3)
    #expect(restored.isHidden == false)
    #expect(restored.savingsTarget == 50_000_000_000)
    #expect(restored.savingsTargetInstrumentId == "AUD")
    #expect(restored.savingsStartDate == startDate)
    #expect(restored.savingsEndDate == endDate)
  }

  @Test
  func earmarkRecordNilOptionals() {
    let earmark = EarmarkRecord(
      id: UUID(),
      name: "Basic",
      position: 0,
      isHidden: false
    )

    let ckRecord = earmark.toCKRecord(in: zoneID)
    #expect(ckRecord["savingsTarget"] == nil)
    #expect(ckRecord["savingsTargetInstrumentId"] == nil)
    #expect(ckRecord["savingsStartDate"] == nil)
    #expect(ckRecord["savingsEndDate"] == nil)

    let restored = EarmarkRecord.fieldValues(from: ckRecord)
    #expect(restored.savingsTarget == nil)
    #expect(restored.savingsTargetInstrumentId == nil)
    #expect(restored.savingsStartDate == nil)
    #expect(restored.savingsEndDate == nil)
  }

  // MARK: - EarmarkBudgetItemRecord

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
