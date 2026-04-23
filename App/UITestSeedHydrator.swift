import Foundation
import SwiftData

/// Populates an in-memory `ProfileContainerManager` from a named `UITestSeed`.
///
/// Called during `MoolahApp.init` when the process was launched with
/// `--ui-testing`. Deterministic by contract: every invocation produces
/// records with the UUIDs and values declared in `UITestFixtures`, so drivers
/// can reference entities symbolically.
///
/// Idempotent: running twice on the same manager does not double-insert,
/// which keeps re-launches during driver iteration robust.
@MainActor
enum UITestSeedHydrator {
  /// Seeds `manager` from the given seed and returns the resulting `Profile`.
  ///
  /// - Parameter seed: the named data set to hydrate.
  /// - Parameter manager: an in-memory `ProfileContainerManager` (see
  ///   `ProfileContainerManager.forTesting()`).
  /// - Returns: the seeded profile, ready to drive a window.
  @discardableResult
  static func hydrate(
    _ seed: UITestSeed,
    into manager: ProfileContainerManager
  ) throws -> Profile {
    switch seed {
    case .tradeBaseline:
      return try hydrateTradeBaseline(into: manager)
    }
  }

  // MARK: - Seeds

  private static func hydrateTradeBaseline(
    into manager: ProfileContainerManager
  ) throws -> Profile {
    let fixtures = UITestFixtures.TradeBaseline.self

    let profile = Profile(
      id: fixtures.profileId,
      label: fixtures.profileLabel,
      backendType: .cloudKit,
      currencyCode: fixtures.profileCurrencyCode,
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try upsertProfile(profile, into: manager)

    let container = try manager.container(for: profile.id)
    let context = ModelContext(container)
    let instrument = profile.instrument

    try seedTradeBaselineAccounts(instrument: instrument, in: context)
    try seedTradeBaselineTransactions(instrument: instrument, in: context)

    try context.save()
    return profile
  }

  /// Seed the accounts used by the Trade Baseline fixture: AUD checking +
  /// investment + a USD account so the cross-currency test can switch a
  /// transfer leg's counterpart instrument.
  private static func seedTradeBaselineAccounts(
    instrument: Instrument, in context: ModelContext
  ) throws {
    let fixtures = UITestFixtures.TradeBaseline.self
    try upsertInstrument(instrument, in: context)
    try upsertAccount(
      id: fixtures.checkingAccountId,
      name: fixtures.checkingAccountName,
      type: .bank,
      instrumentId: instrument.id,
      position: 0,
      in: context)
    try upsertAccount(
      id: fixtures.brokerageAccountId,
      name: fixtures.brokerageAccountName,
      type: .investment,
      instrumentId: instrument.id,
      position: 1,
      in: context)

    let usd = Instrument.USD
    try upsertInstrument(usd, in: context)
    try upsertAccount(
      id: fixtures.usdAccountId,
      name: fixtures.usdAccountName,
      type: .bank,
      instrumentId: usd.id,
      position: 2,
      in: context)
  }

  /// Seed the transactions used by the Trade Baseline fixture.
  private static func seedTradeBaselineTransactions(
    instrument: Instrument, in context: ModelContext
  ) throws {
    let fixtures = UITestFixtures.TradeBaseline.self
    try upsertTrade(
      id: fixtures.bhpPurchaseId,
      payee: fixtures.bhpPurchasePayee,
      date: fixtures.bhpPurchaseDate,
      amount: InstrumentAmount(
        quantity: Decimal(fixtures.bhpPurchaseAmountCents) / 100,
        instrument: instrument),
      fromAccountId: fixtures.checkingAccountId,
      toAccountId: fixtures.brokerageAccountId,
      in: context)

    let historicalAmount = InstrumentAmount(
      quantity: Decimal(fixtures.historicalExpenseAmountCents) / 100,
      instrument: instrument)
    for historical in fixtures.historicalPayees {
      try upsertHistoricalExpense(
        id: historical.id,
        payee: historical.payee,
        date: historical.date,
        amount: historicalAmount,
        accountId: fixtures.checkingAccountId,
        in: context)
    }

    try upsertCategory(
      id: fixtures.groceriesCategoryId, name: fixtures.groceriesCategoryName, in: context)
    try upsertCategory(
      id: fixtures.gymCategoryId, name: fixtures.gymCategoryName, in: context)

    try upsertCustomExpenseSplit(
      id: fixtures.splitShopId,
      payee: fixtures.splitShopPayee,
      date: fixtures.splitShopDate,
      legAAmount: InstrumentAmount(
        quantity: Decimal(fixtures.splitShopLegAAmountCents) / 100,
        instrument: instrument),
      legBAmount: InstrumentAmount(
        quantity: Decimal(fixtures.splitShopLegBAmountCents) / 100,
        instrument: instrument),
      accountId: fixtures.checkingAccountId,
      in: context)
  }

}
