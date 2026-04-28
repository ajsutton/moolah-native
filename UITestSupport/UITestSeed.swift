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

  /// Blank index container — no profiles. Drives the first-run
  /// `WelcomeView` `.heroChecking` / `.heroNoneFound` branches.
  case welcomeEmpty

  /// One `ProfileRecord` seeded in the index. Triggers auto-activation
  /// into `SessionRootView` via `WelcomeView`'s `.autoActivateSingle`
  /// branch.
  case welcomeSingleCloudProfile

  /// Two `ProfileRecord`s seeded in the index. Drives the multi-profile
  /// picker (`WelcomeView` state 5).
  case welcomeMultipleCloudProfiles

  /// Forces the Welcome screen into `.heroDownloading(received: 1234)` so
  /// the new "Found data on iCloud · 1,234 records downloaded" copy and
  /// the de-emphasized "Create a new profile" button can be verified.
  case welcomeDownloading

  /// Drives `SyncProgress` into `.upToDate` with a `lastSettledAt` ~5
  /// minutes in the past so the macOS sidebar footer renders
  /// "Up to date · Updated 5 minutes ago".
  case sidebarFooterUpToDate

  /// Drives `SyncProgress` into `.receiving` with a non-zero count so the
  /// sidebar footer renders the receive label and count.
  case sidebarFooterReceiving

  /// Drives `SyncProgress` into `.sending` with `pendingUploads = 12`.
  case sidebarFooterSending

  /// CloudKit-backed profile (same shape as `tradeBaseline`) plus a
  /// deterministic crypto-token catalogue and resolution stub installed
  /// in place of the live `SQLiteCoinGeckoCatalog` /
  /// `CompositeTokenResolutionClient`. The catalogue contains exactly one
  /// row (Uniswap, ethereum chainId 1) and the stub resolver returns the
  /// matching `(coingeckoId, cryptocompareSymbol, binanceSymbol)` triple.
  /// Drives the Settings → Crypto → Add Token end-to-end test without
  /// touching the network. See `UITestFixtures.CryptoCatalogPreloaded` for
  /// the complete fixture (instrumentId, chainId, contractAddress, provider
  /// IDs) so the `seed.txt` artefact reader can resolve every reference
  /// without cross-file lookup.
  case cryptoCatalogPreloaded

  /// A CloudKit-backed AUD profile with one bank account named "Brokerage",
  /// a registered VGS.AX stock instrument, and a "Brokerage" category.
  /// Drives the `TradeFlowUITests` end-to-end test: switching a transaction
  /// to trade mode, setting paid/received legs and a fee — without any
  /// remote data dependency.
  case tradeReady = "trade-ready"
}

/// Fixtures for the first-run Welcome seeds. Defined here so both the
/// app (hydration) and UI-test drivers reference the same UUIDs.
public enum UITestWelcomeFixtures {
  // Constant UUIDs — `??` fallback keeps SwiftLint's `force_unwrapping`
  // happy; the literal strings above parse successfully so the fallback
  // never fires in practice.
  public static let householdProfileId =
    UUID(uuidString: "B0000000-0000-0000-0000-000000000001") ?? UUID()
  public static let householdProfileLabel = "Household"
  public static let sideBusinessProfileId =
    UUID(uuidString: "B0000000-0000-0000-0000-000000000002") ?? UUID()
  public static let sideBusinessProfileLabel = "Side business"
  public static let profileCurrencyCode = "AUD"
}

/// A past single-leg expense used to seed payee suggestions.
///
/// `categoryId`, when set, is stored on the leg so the autofill flow
/// (`TransactionDetailView.autofillFromPayee(_:)`) can copy it into a new
/// draft. Most entries leave it `nil`; one entry per scenario carries a
/// category so the test asserts both that autofill fires *and* that it
/// does not open the category picker as a side-effect.
public struct UITestHistoricalExpense: Sendable {
  public let id: UUID
  public let payee: String
  public let date: Date
  public let categoryId: UUID?

  public init(id: UUID, payee: String, date: Date, categoryId: UUID? = nil) {
    self.id = id
    self.payee = payee
    self.date = date
    self.categoryId = categoryId
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

    /// A USD-denominated account so the cross-currency test can switch a
    /// transfer's counterpart leg to a different instrument.
    public static let usdAccountId = UUID(uuidString: "A1000000-0000-0000-0000-000000000012")!
    public static let usdAccountName = "USD Savings"
    public static let usdAccountInstrumentCode = "USD"

    public static let bhpPurchaseId = UUID(uuidString: "A1000000-0000-0000-0000-000000000020")!
    public static let bhpPurchasePayee = "BHP Purchase"
    public static let bhpPurchaseAmountCents = 500_000  // 5,000.00 AUD
    /// 2026-04-01 00:00:00 UTC.
    public static let bhpPurchaseDate = Date(timeIntervalSince1970: 1_775_001_600)

    /// Cents moved by every historical expense. Kept identical across the
    /// list so tests that care only about payee text don't encode amounts.
    public static let historicalExpenseAmountCents = 5_000  // 50.00 AUD

    // MARK: - Categories
    //
    // A minimal category set that gives the autocomplete dropdown
    // matches for the prefixes exercised by the multi-leg isolation test:
    //
    //   "G" → [Groceries, Gym]           (count = 2)
    //   "Gr" → [Groceries]                (count = 1)
    //
    // Seeded flat — no parent hierarchy — because the test only asserts
    // dropdown visibility, not label formatting.
    public static let groceriesCategoryId =
      UUID(uuidString: "A1000000-0000-0000-0000-000000000040")!
    public static let groceriesCategoryName = "Groceries"
    public static let gymCategoryId =
      UUID(uuidString: "A1000000-0000-0000-0000-000000000041")!
    public static let gymCategoryName = "Gym"

    // MARK: - Custom (multi-leg) transaction
    //
    // A two-leg expense split from `checking`, both legs with the same
    // account so `Transaction.isSimple == false` → `TransactionDraft.isCustom
    // == true` → the detail view renders per-leg sections with category
    // autocomplete fields.
    public static let splitShopId = UUID(uuidString: "A1000000-0000-0000-0000-000000000050")!
    public static let splitShopPayee = "Split Shop"
    /// 2026-03-23 00:00:00 UTC — between the historical expenses and the
    /// BHP trade.
    public static let splitShopDate = Date(timeIntervalSince1970: 1_774_224_000)
    public static let splitShopLegAAmountCents = 3_000  // 30.00 AUD
    public static let splitShopLegBAmountCents = 2_000  // 20.00 AUD

    /// Four historical expense transactions from `checking`, ordered by
    /// date. Payee frequency is the only axis `fetchPayeeSuggestions` sorts
    /// on; "Woolworths" appears twice so it ranks strictly above
    /// "Woolworths Metro" for the prefix "Wool".
    ///
    /// The most recent "Woolworths" (2026-03-20) carries `groceriesCategoryId`
    /// so the autofill flow has a category to copy when a user selects the
    /// "Woolworths" suggestion. The earlier entries leave the category nil so
    /// the seed still exercises the common "no prior category" path.
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
        date: Date(timeIntervalSince1970: 1_773_964_800),  // 2026-03-20 UTC
        categoryId: groceriesCategoryId
      ),
    ]
  }

  /// Fixtures for the `.cryptoCatalogPreloaded` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — same UUID/label/currency as `TradeBaseline`,
  ///     CloudKit-backed (a CryptoTokenStore is only built for CloudKit
  ///     profiles; the Crypto Settings tab is otherwise hidden).
  ///   - Catalog: a single coin "Uniswap" (UNI) with one platform binding
  ///     `(slug=ethereum, chainId=1, contractAddress=0x1F98…F984)`. The
  ///     contract address is lower-cased by `Instrument.crypto(...)` so the
  ///     resulting Instrument id is
  ///     `1:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984`.
  ///   - Resolution result: the deterministic
  ///     `(coingeckoId="uniswap", cryptocompareSymbol="UNI",
  ///     binanceSymbol="UNIUSDT")` triple returned by the stubbed
  ///     `TokenResolutionClient` for the matching `(chainId, contract)`.
  public enum CryptoCatalogPreloaded {
    public static let profileId = UITestFixtures.TradeBaseline.profileId
    public static let profileLabel = UITestFixtures.TradeBaseline.profileLabel
    public static let profileCurrencyCode = UITestFixtures.TradeBaseline.profileCurrencyCode

    /// The single coin in the catalog snapshot.
    public static let coingeckoId = "uniswap"
    public static let symbol = "UNI"
    public static let name = "Uniswap"
    public static let chainSlug = "ethereum"
    public static let chainId = 1
    /// Mixed-case as in the design spec; lower-cased by `Instrument.crypto`
    /// when the Instrument id is built.
    public static let contractAddress = "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984"

    /// The Instrument id the registered token will carry — built from the
    /// chainId + lower-cased contract address.
    public static let instrumentId = "1:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"

    /// Provider IDs the stubbed `TokenResolutionClient` returns for the
    /// matching `(chainId, contract)` pair.
    public static let coingeckoMappingId = "uniswap"
    public static let cryptocompareSymbol = "UNI"
    public static let binanceSymbol = "UNIUSDT"
  }

  /// Fixtures for the `.tradeReady` seed.
  ///
  /// Entities (all fixed, deterministic):
  ///   - Profile `personal` — label "Personal", currency AUD, CloudKit-backed.
  ///   - Account `brokerage` — "Brokerage", bank, AUD.
  ///   - Instrument `vgsax` — VGS.AX stock on ASX, registered so it appears
  ///     in `InstrumentPickerField`.
  ///   - Category `brokerage` — "Brokerage", so the fee leg can select it.
  public enum TradeReady {
    public static let profileId =
      UUID(uuidString: "A3000000-0000-0000-0000-000000000001") ?? UUID()
    public static let profileLabel = "Personal"
    public static let profileCurrencyCode = "AUD"

    public static let brokerageAccountId =
      UUID(uuidString: "A3000000-0000-0000-0000-000000000010") ?? UUID()
    public static let brokerageAccountName = "Brokerage"

    public static let vgsaxInstrumentId = "ASX:VGS.AX"
    public static let vgsaxTicker = "VGS.AX"
    public static let vgsaxExchange = "ASX"
    public static let vgsaxName = "VGS"

    public static let brokerageCategoryId =
      UUID(uuidString: "A3000000-0000-0000-0000-000000000040") ?? UUID()
    public static let brokerageCategoryName = "Brokerage"

    // MARK: - Trade transactions

    /// 14-Apr-26 buy: −$300 AUD → +20 VGS.AX, $10 brokerage fee.
    public static let trade1Id =
      UUID(uuidString: "A3000000-0000-0000-0000-000000000020") ?? UUID()
    /// 21-Apr-26 buy: −$160 AUD → +10 VGS.AX, no fee.
    public static let trade2Id =
      UUID(uuidString: "A3000000-0000-0000-0000-000000000021") ?? UUID()
    /// 28-Apr-26 sell: +$425 AUD → −10 VGS.AX, $5 brokerage fee.
    public static let trade3Id =
      UUID(uuidString: "A3000000-0000-0000-0000-000000000022") ?? UUID()
  }
}
