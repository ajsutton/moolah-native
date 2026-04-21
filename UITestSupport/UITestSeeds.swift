import Foundation

/// Named deterministic data sets that the app hydrates from when launched
/// with the `--ui-testing` argument and `UI_TESTING_SEED` set to the seed's
/// raw value.
///
/// Compiled into both the main app and `MoolahUITests_macOS` so:
///   - tests select a seed symbolically via `MoolahApp.launch(seed: .tradeBaseline)`,
///   - the app reads `UI_TESTING_SEED` and hydrates from the matching case,
///   - drivers reference fixtures (e.g. `UITestFixtures.TradeBaseline.checkingAccountId`)
///     by the same UUID the app wrote.
///
/// Every seed is deterministic: all UUIDs are hard-coded literals and every
/// entity's name, amount, and date is a constant. The `seed.txt` failure
/// artefact is generated from this metadata.
public enum UITestSeed: String, CaseIterable, Sendable {
  /// A CloudKit-backed profile with a checking account, a brokerage
  /// investment account, one trade transaction with two legs, and a
  /// handful of historical expenses with repeated payees. The baseline
  /// for `TransactionDetailView` tests covering focus, payee
  /// autocomplete, and cross-currency.
  case tradeBaseline
}

/// A past single-leg expense used to seed payee suggestions.
public struct UITestHistoricalExpense: Sendable {
  public let id: UUID
  public let payee: String
  public let date: Date

  public init(id: UUID, payee: String, date: Date) {
    self.id = id
    self.payee = payee
    self.date = date
  }
}

/// Fixed-UUID fixtures used by both the app (when seeding) and UI-test
/// drivers (when resolving identifiers). Grouping constants by seed family
/// keeps fixtures local to the scenario that needs them.
public enum UITestFixtures {
  /// Fixtures for the `.tradeBaseline` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — label "Personal", currency AUD, CloudKit-backed.
  ///   - Account `checking` — "Checking", bank, AUD.
  ///   - Account `brokerage` — "Brokerage", investment, AUD.
  ///   - Transaction `bhpPurchase` — trade on 2026-04-01 UTC, payee
  ///     "BHP Purchase". Two legs in the profile instrument: −5,000.00 AUD
  ///     from `checking` (expense) and +5,000.00 AUD into `brokerage`
  ///     (income). A simplified stand-in until cross-instrument trades land.
  ///   - `historicalPayees` — four single-leg expenses from `checking` that
  ///     give `fetchPayeeSuggestions` something to match against. "Woolworths"
  ///     occurs twice so it sorts strictly above single-occurrence payees
  ///     regardless of dictionary iteration order.
  public enum TradeBaseline {
    public static let profileId = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
    public static let profileLabel = "Personal"
    public static let profileCurrencyCode = "AUD"

    public static let checkingAccountId = UUID(uuidString: "A1000000-0000-0000-0000-000000000010")!
    public static let checkingAccountName = "Checking"

    public static let brokerageAccountId = UUID(uuidString: "A1000000-0000-0000-0000-000000000011")!
    public static let brokerageAccountName = "Brokerage"

    public static let bhpPurchaseId = UUID(uuidString: "A1000000-0000-0000-0000-000000000020")!
    public static let bhpPurchasePayee = "BHP Purchase"
    public static let bhpPurchaseAmountCents = 500_000  // 5,000.00 AUD
    /// 2026-04-01 00:00:00 UTC.
    public static let bhpPurchaseDate = Date(timeIntervalSince1970: 1_775_001_600)

    /// Cents moved by every historical expense. Kept identical across the
    /// list so tests that care only about payee text don't encode amounts.
    public static let historicalExpenseAmountCents = 5_000  // 50.00 AUD

    /// Four historical expense transactions from `checking`, ordered by
    /// date. Payee frequency is the only axis `fetchPayeeSuggestions` sorts
    /// on; "Woolworths" appears twice so it ranks strictly above
    /// "Woolworths Metro" for the prefix "Wool".
    public static let historicalPayees: [UITestHistoricalExpense] = [
      UITestHistoricalExpense(
        id: UUID(uuidString: "A1000000-0000-0000-0000-000000000030")!,
        payee: "Coles",
        date: Date(timeIntervalSince1970: 1_772_668_800)  // 2026-03-05 UTC
      ),
      UITestHistoricalExpense(
        id: UUID(uuidString: "A1000000-0000-0000-0000-000000000031")!,
        payee: "Woolworths",
        date: Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC
      ),
      UITestHistoricalExpense(
        id: UUID(uuidString: "A1000000-0000-0000-0000-000000000032")!,
        payee: "Woolworths Metro",
        date: Date(timeIntervalSince1970: 1_773_532_800)  // 2026-03-15 UTC
      ),
      UITestHistoricalExpense(
        id: UUID(uuidString: "A1000000-0000-0000-0000-000000000033")!,
        payee: "Woolworths",
        date: Date(timeIntervalSince1970: 1_773_964_800)  // 2026-03-20 UTC
      ),
    ]
  }
}
