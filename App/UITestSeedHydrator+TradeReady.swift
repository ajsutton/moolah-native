import Foundation
import GRDB

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

    let database = try manager.database(for: profile.id)
    let audInstrument = profile.instrument
    let vgsax = Instrument.stock(
      ticker: fixtures.vgsaxTicker,
      exchange: fixtures.vgsaxExchange,
      name: fixtures.vgsaxName)

    try database.write { database in
      try upsertInstrument(audInstrument, in: database)
      try upsertAccount(
        AccountSpec(
          id: fixtures.brokerageAccountId,
          name: fixtures.brokerageAccountName,
          type: .bank,
          instrumentId: audInstrument.id,
          position: 0),
        in: database)

      try upsertInstrument(vgsax, in: database)
      try upsertCategory(
        id: fixtures.brokerageCategoryId,
        name: fixtures.brokerageCategoryName,
        in: database)

      try seedTradeReadyTransactions(
        brokerageId: fixtures.brokerageAccountId,
        audInstrument: audInstrument,
        vgsax: vgsax,
        brokerageCategoryId: fixtures.brokerageCategoryId,
        in: database)
    }
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
    in database: Database
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
      in: database)

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
      in: database)

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
      in: database)
  }

  /// Inserts a `.trade` transaction with paired `.trade` legs and an
  /// optional `.expense` fee leg. Idempotent via the parent-existence
  /// guard — on a re-hydration the transaction is left intact.
  private static func insertTradeTransaction(
    _ spec: TradeTransactionSpec,
    in database: Database
  ) throws {
    if try TransactionRow.fetchOne(database, key: spec.id) != nil { return }

    let txn = Transaction(id: spec.id, date: spec.date, payee: spec.payee, legs: [])
    try TransactionRow(domain: txn).insert(database)

    let paidLeg = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.paid.instrument,
      quantity: spec.paid.quantity,
      type: .trade)
    let receivedLeg = TransactionLeg(
      accountId: spec.accountId,
      instrument: spec.received.instrument,
      quantity: spec.received.quantity,
      type: .trade)
    try TransactionLegRow(domain: paidLeg, transactionId: spec.id, sortOrder: 0)
      .insert(database)
    try TransactionLegRow(domain: receivedLeg, transactionId: spec.id, sortOrder: 1)
      .insert(database)

    if let fee = spec.fee {
      let feeLeg = TransactionLeg(
        accountId: spec.accountId,
        instrument: fee.instrument,
        quantity: fee.quantity,
        type: .expense,
        categoryId: fee.categoryId)
      try TransactionLegRow(domain: feeLeg, transactionId: spec.id, sortOrder: 2)
        .insert(database)
    }
  }
}
