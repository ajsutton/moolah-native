import Foundation
import SwiftData

// Trade-Ready seed helpers split out of `UITestSeedHydrator` so the main enum
// body stays under SwiftLint's `type_body_length` threshold.
extension UITestSeedHydrator {
  // MARK: - Specs

  struct TradeFeeSpec {
    let instrument: Instrument
    let quantity: Decimal
    let categoryId: UUID
  }

  struct TradeTransactionSpec {
    let id: UUID
    let date: Date
    let payee: String?
    let accountId: UUID
    let paid: (instrument: Instrument, quantity: Decimal)
    let received: (instrument: Instrument, quantity: Decimal)
    let fee: TradeFeeSpec?
  }

  // MARK: - Trade-Ready seed

  static func hydrateTradeReady(
    into manager: ProfileContainerManager
  ) throws -> Profile {
    let fixtures = UITestFixtures.TradeReady.self

    let profile = Profile(
      id: fixtures.profileId,
      label: fixtures.profileLabel,
      currencyCode: fixtures.profileCurrencyCode,
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try upsertProfile(profile, into: manager)

    let container = try manager.container(for: profile.id)
    let context = ModelContext(container)
    let audInstrument = profile.instrument

    try upsertInstrument(audInstrument, in: context)
    try upsertAccount(
      AccountSpec(
        id: fixtures.brokerageAccountId,
        name: fixtures.brokerageAccountName,
        type: .bank,
        instrumentId: audInstrument.id,
        position: 0),
      in: context)

    let vgsax = Instrument.stock(
      ticker: fixtures.vgsaxTicker,
      exchange: fixtures.vgsaxExchange,
      name: fixtures.vgsaxName)
    try upsertInstrument(vgsax, in: context)

    try upsertCategory(
      id: fixtures.brokerageCategoryId,
      name: fixtures.brokerageCategoryName,
      in: context)

    try seedTradeReadyTransactions(
      brokerageId: fixtures.brokerageAccountId,
      audInstrument: audInstrument,
      vgsax: vgsax,
      brokerageCategoryId: fixtures.brokerageCategoryId,
      in: context)

    try context.save()
    return profile
  }

  /// Sample trades for the `tradeReady` seed:
  /// - 14-Apr-26 buy: −$300 AUD → +20 VGS.AX with $10 brokerage fee.
  /// - 21-Apr-26 buy: −$160 AUD → +10 VGS.AX (no fee).
  /// - 28-Apr-26 sell: +$425 AUD → −10 VGS.AX with $5 brokerage fee.
  private static func seedTradeReadyTransactions(
    brokerageId: UUID,
    audInstrument: Instrument,
    vgsax: Instrument,
    brokerageCategoryId: UUID,
    in context: ModelContext
  ) throws {
    let day: TimeInterval = 86_400
    let base = Date(timeIntervalSince1970: 1_776_000_000)  // mid-April 2026
    let fixtures = UITestFixtures.TradeReady.self

    try insertTradeTransaction(
      TradeTransactionSpec(
        id: fixtures.trade1Id,
        date: base,
        payee: "SelfWealth",
        accountId: brokerageId,
        paid: (audInstrument, -300),
        received: (vgsax, 20),
        fee: TradeFeeSpec(instrument: audInstrument, quantity: -10, categoryId: brokerageCategoryId)
      ),
      in: context)

    try insertTradeTransaction(
      TradeTransactionSpec(
        id: fixtures.trade2Id,
        date: base.addingTimeInterval(7 * day),
        payee: nil,
        accountId: brokerageId,
        paid: (audInstrument, -160),
        received: (vgsax, 10),
        fee: nil
      ),
      in: context)

    try insertTradeTransaction(
      TradeTransactionSpec(
        id: fixtures.trade3Id,
        date: base.addingTimeInterval(14 * day),
        payee: "SelfWealth",
        accountId: brokerageId,
        paid: (audInstrument, 425),
        received: (vgsax, -10),
        fee: TradeFeeSpec(instrument: audInstrument, quantity: -5, categoryId: brokerageCategoryId)
      ),
      in: context)
  }

  private static func insertTradeTransaction(
    _ spec: TradeTransactionSpec,
    in context: ModelContext
  ) throws {
    let id = spec.id
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == id }
    )
    if try context.fetch(descriptor).first != nil { return }

    context.insert(TransactionRecord(id: spec.id, date: spec.date, payee: spec.payee))

    let paidAmount = InstrumentAmount(
      quantity: spec.paid.quantity, instrument: spec.paid.instrument)
    let receivedAmount = InstrumentAmount(
      quantity: spec.received.quantity, instrument: spec.received.instrument)
    context.insert(
      TransactionLegRecord(
        transactionId: spec.id,
        accountId: spec.accountId,
        instrumentId: spec.paid.instrument.id,
        quantity: paidAmount.storageValue,
        type: TransactionType.trade.rawValue,
        sortOrder: 0
      ))
    context.insert(
      TransactionLegRecord(
        transactionId: spec.id,
        accountId: spec.accountId,
        instrumentId: spec.received.instrument.id,
        quantity: receivedAmount.storageValue,
        type: TransactionType.trade.rawValue,
        sortOrder: 1
      ))
    if let fee = spec.fee {
      let feeAmount = InstrumentAmount(quantity: fee.quantity, instrument: fee.instrument)
      context.insert(
        TransactionLegRecord(
          transactionId: spec.id,
          accountId: spec.accountId,
          instrumentId: fee.instrument.id,
          quantity: feeAmount.storageValue,
          type: TransactionType.expense.rawValue,
          categoryId: fee.categoryId,
          sortOrder: 2
        ))
    }
  }
}
