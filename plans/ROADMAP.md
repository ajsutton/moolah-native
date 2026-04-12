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

### 1b. Test Coverage (UI Testing Plan — Part A)

Extract business logic from views into testable stores and shared utilities. See `UI_TESTING_PLAN.md` for full details.

| Step | What | New Tests |
|------|------|-----------|
| A5 | Deduplicate `parseCurrency` (4 copies) | 6 |
| A8 | Fill store test gaps (CategoryStore, EarmarkStore, AuthStore) | 17 |
| A2 | Extract `TransactionDraft` from duplicated view logic | 14 |
| A9 | Deduplicate earmark sheets (3 copies) | 0 |
| A1 | Extract `createNewTransaction` to store | 4 |
| A6 | Extract `availableFunds` to store | 4 |
| A7 | Extract `hasActiveFilters` to model | 5 |
| A4 | Extract `formatError` to shared utility | 4 |

---

## Phase 2: Per-Profile Data Isolation — Done

Migrated from a single shared SwiftData store (with `profileId` predicates on every query) to one store file per iCloud profile. Database-level isolation, simplified queries, trivial profile deletion, and per-profile CloudKit sync zones.

**Reference:** `per-profile-stores-design.md`, `per-profile-stores-plan.md`

---

## Phase 3: Backup & Export

Two related features that share infrastructure:

1. **Automatic backup** (macOS only) — daily copy of per-profile SwiftData store files as a safety net against data corruption. Keeps 7 daily backups per profile. Not user-visible.
2. **User-facing import/export** — JSON-based export of all profile data via domain models. Export works with any backend type. Import creates a new iCloud profile. Refactors the existing migration code to be reusable.

**Why now:** Depends on per-profile stores (Phase 2) for store file URLs and the simplified importer. Should land before the app goes to TestFlight — users need a data safety net before wider use.

**Reference:** `backup-and-export-design.md`

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
