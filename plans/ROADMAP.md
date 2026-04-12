# Roadmap

**Date:** 2026-04-12

A prioritized development roadmap. Each phase builds on the previous — later phases depend on foundations laid earlier. Feature ideas not yet promoted to the roadmap live in `FEATURE_IDEAS.md`.

---

## Phase 1: Stability & Quality

Fix known bugs and build a test safety net before adding new features.

### 1a. Bug Fixes — Done

All bugs fixed:
- **UI freeze during investment value download** — CloudKit repository now uses `fetchLimit`/`fetchOffset` instead of fetching all records per page. (Migration import save is still synchronous/atomic by design — see `BUGS.md`.)
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

**Note:** This covers the infrastructure only. Full multi-currency support (per-account currencies, multi-currency UI, aggregation) is not yet planned — TestFlight comes first.

**Reference:** `completed/exchange-rate-design.md`, `completed/exchange-rate-implementation-plan.md`

---

## Phase 5: iOS Release via TestFlight

Set up Fastlane + GitHub Actions to archive and upload to TestFlight. Includes monthly auto-tagging to avoid the 90-day TestFlight expiry.

**Why now:** The app has a stable data layer, per-profile isolation, exchange rate infrastructure, and growing test coverage — it's worth getting on real devices before expanding multi-currency support.

**Reference:** `IOS_RELEASE_AUTOMATION_PLAN.md`

---

## Phase 6: Crypto Price Data

Add cryptocurrency price fetching and caching, building on the exchange rate infrastructure patterns from Phase 4.

**Why now:** Crypto holdings are already partially supported in the app. Price data lets them be valued in fiat on any date, completing investment tracking for crypto accounts.

**Reference:** `crypto-price-data-design.md`

---

## Phase 7: CSV Import (SelfWealth)

Import Australian stock holdings and trade history from SelfWealth CSV exports. SelfWealth has no API, so CSV is the only reliable data path.

**Why now:** This unlocks investment tracking for real-world use. The Sharesight API was evaluated (`sharesight-api-research.md`) but requires a paid subscription — CSV import works for any SelfWealth user with zero external dependencies.

**Reference:** `csv-import-design.md`

---

## Phase 8: App Store Readiness

Prepare for Apple App Store Review submission.

**Blockers:** Privacy policy, support/contact info, Sign in with Apple, in-app account deletion. Many blockers go away if shipping iCloud-only (no remote backend) — see the plan for both paths.

**Reference:** `APP_STORE_READINESS.md`
