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
  /// investment account, and one trade transaction with two legs. The
  /// baseline for `TransactionDetailView` tests involving trades.
  case tradeBaseline
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
  }
}
