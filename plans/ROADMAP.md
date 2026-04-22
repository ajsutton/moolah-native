# Roadmap

**Date:** 2026-04-12

A prioritized development roadmap. Each phase builds on the previous — later phases depend on foundations laid earlier. Feature ideas not yet promoted to the roadmap live in `FEATURE_IDEAS.md`.

---

## Phase 1: Stability & Quality

Fix known bugs and build a test safety net before adding new features.

### 1a. Bug Fixes — Done

All bugs fixed:
- **UI freeze during investment value download** — CloudKit repository now uses `fetchLimit`/`fetchOffset` instead of fetching all records per page. (Migration import save is still synchronous/atomic by design.)
- **Transaction download shows progress bar** — `TransactionPage` now carries `totalCount` from the server; `TransactionStore` exposes `loadedCount`/`totalCount`; view shows determinate `ProgressView`.
- **macOS upcoming transactions use detail sidebar** — `UpcomingTransactionsCard` now uses platform-specific navigation (inline `HStack` detail on macOS, `.sheet()` on iOS).

### 1b. Test Coverage (UI Testing Plan — Part A) — Done

Extracted business logic from views into testable stores and shared utilities. Added 54 new tests (428 → 482 macOS, 424 → 478 iOS).

- **A5:** Deduplicated `parseCurrency` — all call sites use `MonetaryAmount.parseCents(from:)`. Changed return type to `Int?` (nil on invalid input) and added multiple-decimal-point rejection. (+7 tests)
- **A8:** Filled store test gaps — full suites for CategoryStore (9), EarmarkStore create/update (5), AuthStore signIn (3). (+17 tests)
- **A2:** Extracted `TransactionDraft` — shared value type for form-to-Transaction conversion, replacing duplicated amount-signing and validation in TransactionDetailView and TransactionFormView. (+14 tests)
- **A9:** Deduplicated earmark sheets — consolidated 3 CreateEarmarkSheet and 2 EditEarmarkSheet copies into `EarmarkFormSheet.swift`.
- **A1:** Extracted `createNewTransaction` to `TransactionStore.createDefault()`. (+4 tests)
- **A6:** Extracted `availableFunds` — moved earmark-aware computation from SidebarView to `AccountStore.availableFunds(earmarks:)`. (+4 tests)
- **A7:** Extracted `hasActiveFilters` to `TransactionFilter` extension. (+5 tests)
- **A4:** Extracted `formatError` to `BackendError.userMessage` and `Error.userMessage` extensions. (+4 tests)

**Reference:** `completed/UI_TESTING_PLAN.md`

---

## Phase 2: Per-Profile Data Isolation — Done

Migrated from a single shared SwiftData store (with `profileId` predicates on every query) to one store file per iCloud profile. Database-level isolation, simplified queries, trivial profile deletion, and per-profile CloudKit sync zones.

**Reference:** `per-profile-stores-design.md`, `per-profile-stores-plan.md`

---

## Phase 3: Backup & Export — Done

Two features sharing infrastructure:

1. **Automatic backup** (macOS only) — daily copy of per-profile SwiftData store files using `NSPersistentStoreCoordinator.replacePersistentStore` (safe with active CloudKit sync). 7-day retention. Triggered on app launch + daily timer.
2. **User-facing import/export** — JSON-based export via `DataExporter` (refactored from `ServerDataExporter`, backend-agnostic). Import creates a new iCloud profile with verification. macOS File menu commands + profile list buttons on both platforms.

**Reference:** `completed/backup-and-export-design.md`, `completed/backup-and-export-plan.md`

---

## Phase 4: Exchange Rate Infrastructure — Done

Exchange rate fetching, caching, and conversion infrastructure using the Frankfurter API (free, no API key, 161 currencies). Includes gzip-compressed on-disk cache, fallback to most recent prior date on network failure, banker's rounding for conversions, and prefetch on profile load.

**Note:** This covers the infrastructure only. Full multi-currency support (per-account currencies, multi-currency UI, aggregation) is in Phase 6.

**Reference:** `completed/exchange-rate-design.md`, `completed/exchange-rate-implementation-plan.md`

---

## Phase 5: iOS Release via TestFlight — Done

Fastlane + GitHub Actions pipeline for TestFlight distribution. Version tags (`v*`) trigger builds automatically. Monthly cron workflow keeps builds within the 90-day TestFlight expiry via `workflow_call`. CloudKit sync enabled with schema deployed to production.

Key setup: Apple Developer Program (Individual), App Store Connect app "Moolah Rocks", Match certificates in private repo, environment secrets on `testflight` GitHub environment. Entitlements not in project.yml (breaks local dev/CI) — wired via Fastfile `xcargs` for distribution, `ENABLE_ENTITLEMENTS=1` in `.env` for local CloudKit dev.

CloudKit compatibility required: removing `#Unique` constraints, adding default values to all SwiftData model attributes, `remote-notification` background mode, `UILaunchScreen`, `UISupportedInterfaceOrientations`, `ITSAppUsesNonExemptEncryption`.

**Reference:** `IOS_RELEASE_AUTOMATION_PLAN.md`, `APP_STORE_VALIDATION_PLAN.md`

---

## Phase 6: Multi-Currency Support — Done

Full per-account / per-earmark / per-leg currency support, building on the exchange rate infrastructure from Phase 4 and multi-instrument foundation from Phase 8. All aggregation (totals, net worth, available funds, forecast, analysis) converts to the profile currency at read time.

### Done

- `Instrument` model, `Position` type, `TransactionLeg` with per-leg instruments.
- `ExchangeRateService` — Frankfurter API with caching, offline fallback, date-range queries.
- `InstrumentConversionService` protocol with `FiatConversionService` and `FullConversionService`.
- `Account.instrument` field and `AccountRecord.instrumentId` storage — persisted and read back from SwiftData. Legacy `balance`/`investmentValue` fields removed; accounts are fully position-based.
- Aggregation — `AccountStore` converts foreign-currency accounts to profile currency for sidebar totals, net worth, and available funds. `displayBalance` replaces the old sync `balance(for:)`.
- Per-account currency picker in create/edit account UI (gated on `supportsComplexTransactions`).
- Per-earmark currency picker in create/edit earmark UI (`c6eda0d`), with `EarmarkStore` re-running `recomputeConvertedTotals` when the instrument changes.
- Cross-currency transfers — `TransactionDetailView` shows independent Sent/Received amount fields with a derived exchange-rate hint; `TransactionDraft` supports per-leg instrument overrides.
- Analysis views — `CloudKitAnalysisRepository` converts every leg at the transaction's date before aggregating expense breakdown, income/expense totals, and daily balances.
- Forecast — scheduled foreign-currency transactions are pre-converted on `Date()` before entering the forecast accumulator (`c31b6af`).
- Graceful degradation — per-unit isolation + retry for sidebar conversion failures (`61460a1`), transactions still display when conversion fails (`1dc622a`), per-account sidebar rows show the converted balance (`2331571`), `ExchangeRateService` falls back for missing dates and cold caches (`704825b`). Codified as Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
- Import / export round-trip preserves earmark instrument (`b9a084f`).
- Single-instrument backend enforcement — `Remote*Repository` write paths reject foreign-instrument writes with `BackendError.unsupportedInstrument`; UI gates currency pickers and the custom transaction mode on `Profile.supportsComplexTransactions`. Codified as Rule 11a in the guide.

### Known minor follow-ups (not blockers)

- **Instrument override lost on account change** — `TransactionDetailView.swift:561` clears `draft.legDrafts[index].instrumentId` whenever the leg's account changes. If a user explicitly picked a non-account currency for a leg and then switches account, the override is silently dropped (the leg falls back to the new account's instrument via `TransactionDraft.toTransaction`). The resulting transaction is still valid data — UX regression, not a correctness bug.
- **Profile currency change has no migration UX** — `SettingsView` lets a user change `profile.currencyCode` on a live profile with no warning. The conversion pipeline continues to work (existing accounts/earmarks keep their own instruments and are converted to the new profile currency at display time), but there's no confirmation dialog explaining the change or its effect on existing reports. Out of Phase 6 scope; revisit if users hit it.

---

## Phase 7: Australian Tax Reporting

Tax summary and quarterly PAYG instalment estimates for Australian personal and family trust tax returns. Adds Owner entity, TaxCategory classification on categories, TaxYearAdjustments for external data (capital gains, franking credits, PAYG withheld), and a pure-Swift TaxCalculator. Capital gains are summary import from external tools (Sharesight/Koinly), not lot-level tracking.

**Why now:** FY2025-26 ends June 30, 2026. Quarterly PAYG instalments and year-end estimates are time-sensitive. Doesn't require multi-currency (Phase 6) — most tax-relevant accounts are AUD. May be reordered before Phase 6 once designs are more fleshed out.

**Reference:** `2026-04-11-australian-tax-reporting-design.md`

---

## Phase 8: Crypto Price Data — Done

Cryptocurrency price fetching, caching, and conversion using CryptoCompare, Binance, and CoinGecko (optional API key). Multi-provider fallback with gzip-compressed on-disk cache. Token registry persisted via NSUbiquitousKeyValueStore (iCloud sync). Token resolution pipeline resolves contract address + chain ID to provider-specific identifiers. PriceConversionService composes crypto prices with fiat exchange rates for end-to-end TOKEN → USD → profile currency conversion. Date-aware USDT/USD rate for Binance prices. Tabbed settings window on macOS (Mail.app style) with Profiles and Crypto tabs; iOS navigation row to crypto token management.

**Reference:** `completed/crypto-price-data-design.md`, `completed/crypto-phase6-completion-design.md`

---

## Phase 9: CSV Import (SelfWealth)

Import Australian stock holdings and trade history from SelfWealth CSV exports. SelfWealth has no API, so CSV is the only reliable data path. Imported holdings and trades preserve the source currency (typically AUD for SelfWealth, but the importer and resulting legs use per-row instruments so non-AUD-denominated trades import correctly and flow through Phase 6's conversion pipeline).

**Why now:** This unlocks investment tracking for real-world use. The Sharesight API was evaluated (`sharesight-api-research.md`) but requires a paid subscription — CSV import works for any SelfWealth user with zero external dependencies.

**Reference:** `csv-import-design.md`

---

## Phase 10: App Store Readiness

Prepare for Apple App Store Review submission.

**Blockers:** Privacy policy, support/contact info, Sign in with Apple, in-app account deletion. Many blockers go away if shipping iCloud-only (no remote backend) — see the plan for both paths.

**Reference:** `APP_STORE_READINESS.md`
