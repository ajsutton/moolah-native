# Multi-Instrument Support Design

## Overview

Unify currencies, stocks, and crypto under a single **Instrument** abstraction. Accounts hold **positions** (instrument + quantity pairs) derived from **transaction legs**. A single **InstrumentConversionService** converts any instrument to any other for display and reporting.

This replaces the current single-amount transaction model, the separate Currency/CryptoToken types, and the manual investmentValue approach (which remains as a fallback for simple investment accounts).

## Core Model

### Instrument

Replaces `Currency` and `CryptoToken` as the universal "thing you can hold a quantity of":

```swift
struct Instrument: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case fiatCurrency
        case stock
        case cryptoToken
    }

    let id: String           // "AUD", "ASX:BHP", "1:0xabc..."
    let kind: Kind
    let name: String         // "AUD", "BHP", "ETH"
    let decimals: Int        // 0 for JPY, 2 for AUD/USD, 8 for BTC/ETH

    // Kind-specific metadata (all optional)
    let ticker: String?            // "BHP.AX"
    let exchange: String?          // "ASX"
    let chainId: Int?              // 1 (Ethereum), 10 (OP Mainnet)
    let contractAddress: String?   // nil for native tokens
}
```

- `id` is the canonical identifier. Fiat uses ISO 4217 code, stocks use exchange-prefixed ticker, crypto uses the existing `chainId:address` format.
- Currency symbols (e.g. "$", "€") are derived from system localisation at display time, not stored.
- `decimals` controls display formatting precision.
- `Currency` and `CryptoToken` types are retired over time, with their data folded into `Instrument`.

### InstrumentAmount

Replaces `MonetaryAmount`:

```swift
struct InstrumentAmount: Codable, Hashable, Sendable, Comparable {
    let quantity: Decimal       // Exact base-10: 15.23 for AUD, 0.5 for BTC
    let instrument: Instrument

    var decimalValue: Decimal { quantity }
    var isPositive: Bool { quantity > 0 }
    var isNegative: Bool { quantity < 0 }
    var isZero: Bool { quantity == 0 }

    // Formatting — symbol derived from locale for fiat, omitted for others
    var formatted: String          // "A$1,523.45", "150 BHP", "0.5 BTC"
    var formatNoSymbol: String     // "1,523.45", "150", "0.5"

    // Arithmetic — all exact via Decimal
    static func + (lhs: Self, rhs: Self) -> Self
    static func - (lhs: Self, rhs: Self) -> Self
    prefix static func - (amount: Self) -> Self
}
```

### Storage Precision

All quantities are stored as **Int64 scaled by 10^8** (8 fixed decimal places, universally). This provides:

- Max value: ~92 billion units — exceeds the total supply of any crypto, stock, or fiat currency.
- Efficient aggregate queries (SUM on Int64 column).
- Uniform scaling — no per-instrument storage precision lookup needed.
- `Decimal` in the domain layer, Int64 conversion at the repository boundary only.

Swift's `Decimal` is base-10 with 38 significant digits — exact for all financial arithmetic. No floating-point rounding issues.

## Transaction Legs

A **Transaction** is metadata plus an ordered list of **legs**. All financial meaning — account, amount, instrument, category, earmark — lives on the legs.

```swift
struct Transaction {
    let id: UUID
    var date: Date
    var payee: String?
    var notes: String?
    var recurPeriod: RecurPeriod?
    var recurEvery: Int?

    var legs: [TransactionLeg]
}

struct TransactionLeg: Codable, Hashable, Sendable {
    let accountId: UUID
    let instrument: Instrument
    let quantity: Decimal        // Positive = inflow, negative = outflow
    var type: TransactionType    // income, expense, transfer, openingBalance
    var categoryId: UUID?
    var earmarkId: UUID?
}
```

### Transaction Type Semantics

The existing `TransactionType` enum is unchanged — it moves from Transaction to TransactionLeg. `isUserEditable` continues to prevent editing of `openingBalance` legs.

Type lives on the leg, not the transaction. It determines how the leg is treated in reporting:

- **expense**: counted in expense totals, grouped by category. Positive quantity = refund (reduces category total).
- **income**: counted in income totals.
- **transfer**: balance movement between accounts or instruments, excluded from income/expense reports.
- **openingBalance**: initial balance setup, excluded from reports.

### Leg Configuration Examples

| Scenario | Legs |
|----------|------|
| Grocery expense ($50) | `expense [bank, AUD, -50.00]` |
| Salary income ($5000) | `income [bank, AUD, +5000.00]` |
| Refund | `expense [bank, AUD, +30.00]` |
| Account transfer | `transfer [savings, AUD, +1000]`, `transfer [cheque, AUD, -1000]` |
| Currency conversion | `transfer [revolut, AUD, -1000]`, `transfer [revolut, USD, +680]` |
| Stock purchase + fee | `transfer [sw, AUD, -6345]`, `transfer [sw, BHP, +150]`, `expense [sw, AUD, -9.50, cat:"Brokerage Fees"]` |
| Crypto swap | `transfer [wallet, ETH, -0.5]`, `transfer [wallet, UNI, +1234.56]` |
| Dividend (cash) | `income [sw, AUD, +126.00]` |
| Dividend (reinvested) | `income [sw, BHP, +3]` |
| Gas fee | `expense [wallet, ETH, -0.002]` |

### Balance Calculation

Balance for any (account, instrument) pair: `SUM(quantity) WHERE accountId = ? AND instrumentId = ?` on the legs table. No more accountId-vs-toAccountId branching.

## Accounts & Positions

Accounts remain a named container with a type. An account no longer has a single balance — instead it has **positions** computed from its legs.

```swift
struct Account {
    let id: UUID
    var name: String
    var type: AccountType        // bank, creditCard, asset, investment
    var position: Int
    var isHidden: Bool
}

struct Position: Hashable, Sendable {
    let accountId: UUID
    let instrument: Instrument
    var quantity: Decimal
}
```

### Position Computation

Positions are computed from legs via aggregate queries at query time, cached in-memory by the store layer, not persisted. If aggregate query performance proves insufficient, persistent caching (following the existing `cachedBalance` delta-update pattern) can be added later.

### Display

- **Sidebar**: one balance per account, always total value in profile currency.
- **Account detail view**: lists each instrument position with quantity and value in profile currency where space permits.
- Display patterns:
  - Profile currency fiat: `$1,523.45`
  - Foreign currency fiat: `$1,523.45 USD (A$2,134.83)` — profile currency shown where space permits
  - Stock: `150 BHP (A$6,345.00)` — value shown where space permits
  - Crypto: `0.5 BTC (A$48,230.00)` — value shown where space permits

### Account Types

The current set (`bank`, `creditCard`, `asset`, `investment`) is unchanged. The position model makes accounts flexible regardless of type — a `bank` can hold multiple currencies, an `investment` can hold stocks, crypto, and cash. Type drives UI treatment (sidebar grouping, default display format).

The existing `investmentValue` manual entry approach remains available for simple investment accounts that don't use per-instrument position tracking.

## InstrumentConversionService

A single service encapsulating all pricing backends:

```swift
protocol InstrumentConversionService: Sendable {
    func convert(
        _ quantity: Decimal,
        from: Instrument,
        to: Instrument,
        on date: Date
    ) async throws -> Decimal
}
```

### Routing

| From → To | Path |
|-----------|------|
| Fiat → Fiat | Exchange rate service (Frankfurter) |
| Stock → Fiat | Stock price service → listing currency, then fiat→fiat if needed |
| Crypto → Fiat | Crypto price service (USD), then USD→target fiat if needed |
| Any → Any | Chain through fiat as intermediate |

Replaces the current `MonetaryAmount.converted(to:on:using:)` method and the separate price lookups across investment/crypto code.

## CloudKit/SwiftData Storage

### New CloudKit Container

A new CloudKit container replaces the existing one to provide a clean schema without legacy fields. Developer console steps will be documented in the implementation plan.

### Schema

**TransactionRecord:**
```
id: UUID
date: Date
payee: String?
notes: String?
recurPeriod: String?
recurEvery: Int?
```

**TransactionLegRecord:**
```
id: UUID
transactionId: UUID        // Parent reference
accountId: UUID
instrumentId: String        // "AUD", "ASX:BHP", "1:0xabc..."
quantity: Int64             // Actual value × 10^8
type: String                // "income", "expense", "transfer", "openingBalance"
categoryId: UUID?
earmarkId: UUID?
sortOrder: Int              // Preserves leg ordering
```

**InstrumentRecord:**
```
id: String
kind: String                // "fiatCurrency", "stock", "cryptoToken"
name: String
decimals: Int
ticker: String?
exchange: String?
chainId: Int?
contractAddress: String?
```

Index on `(accountId, instrumentId)` on TransactionLegRecord for efficient position queries.

## Migration

### From moolah-server

The existing `RemoteBackend` becomes a read-only migration source. The migration reads from moolah-server and writes to the new CloudKit container:

1. Fetch all accounts, categories, earmarks from moolah-server.
2. Fetch all transactions.
3. Convert each transaction:
   - Simple income/expense → one leg (accountId, profile currency instrument, amount, type, categoryId, earmarkId).
   - Transfer → two legs (source account negative, destination account positive, same instrument, type = transfer).
4. Write to new CloudKit container using the leg-based schema.
5. Investment values migrate as-is.

### Server Backend

`RemoteBackend` is retained only as a migration data source. It does not need to support the leg-based model, write operations, or UI display/editing. It can be removed once migration is no longer needed.

## Analysis & Reporting

### Straightforward (same approach as today, operating on legs)

- **Expense breakdown**: SUM leg quantities where `type = expense`, group by `categoryId` and month. Refunds (positive expense legs) naturally reduce category totals.
- **Income & expense summaries**: SUM legs by type and month. Transfer legs excluded.
- **Category balances**: SUM leg quantities by categoryId within date range.
- **Earmark tracking**: SUM leg quantities where earmarkId matches.

### Needs Detailed Investigation

**Net worth / daily balance graph with multiple instruments:**

The current single-currency approach computes daily balance deltas. With multiple instruments, this becomes O(days × instruments) — for each day, every non-zero instrument position must be converted to profile currency using that day's price.

For a 20-year daily graph with multiple instruments, this could be thousands of days × dozens of instruments worth of price lookups.

Potential mitigations to investigate during implementation:
- Reduce graph resolution for longer periods (weekly/monthly points instead of daily).
- Pre-compute and persistently cache daily totals, invalidated on transaction changes.
- Lazy evaluation — only compute visible date range.
- Batch price fetching (the price caches already store full date→price maps, so lookups are local after initial fetch).

**This should be a performance spike task during Phase 5 implementation** — prototype with realistic data volumes before committing to an approach.

## UI Approach

**Principle:** simple by default, powerful when needed. The UI never exposes the raw leg model. Each use case has its own tailored editing flow that produces the right legs behind the scenes.

### Transaction Editing (Common Case)

A single-currency expense/income looks identical to today — account, amount, payee, category, date. Under the hood, saving creates one leg. The user doesn't see or think about "legs".

### Transfers

Default: same amount, same currency, between two accounts (source, destination, amount). If the user changes to an account with a different default instrument, or opts into "amounts differ", the UI reveals a second amount field for the received side.

### Trades (Stock/Crypto)

A dedicated "Trade" entry mode for investment accounts:
- Instrument sold (or cash), quantity
- Instrument bought, quantity
- Optional fee amount and category

Creates a multi-leg transaction. The UI is tailored to trades, not a generic leg editor.

### Display

The UI may show transfer legs involving different instruments as a "trade" — this is a display detail inferred from leg contents, not a domain concept.

## Incremental Delivery Phases

### Phase 1: Foundation
- Introduce `Instrument` type (fiat only initially).
- Rename `MonetaryAmount` → `InstrumentAmount` with `Decimal` quantity.
- Introduce `TransactionLeg` in the domain model.
- Existing single-currency transactions use one leg.
- New CloudKit container with leg-based schema.
- Migration from moolah-server converts transfers to two-leg transactions.
- All existing functionality works as before, just on the new model.
- Drop `accountId`/`toAccountId`/`amount` from the domain `Transaction` type.

### Phase 2: Multi-Currency Accounts
- `InstrumentConversionService` wrapping existing exchange rate service.
- Positions computed from legs (aggregate queries).
- Account detail view shows per-instrument positions.
- Sidebar shows profile-currency total per account.
- Currency conversion transaction UI (two transfer legs, different fiat instruments).

### Phase 3: Stocks
- Extend `Instrument` to support stocks.
- Wire `StockPriceClient` into `InstrumentConversionService`.
- Trade transaction UI for investment accounts.
- Stock positions display with current value.
- Retire `investmentValue` manual entry for accounts using per-instrument tracking (keep as fallback for simple investment accounts).

### Phase 4: Crypto
- Extend `Instrument` for crypto tokens.
- Wire `CryptoPriceClient` into `InstrumentConversionService`.
- Token swap transaction UI.
- Crypto position display.
- Future: wallet sync, exchange import feeds into this model.

### Phase 5: Reporting
- Performance spike on multi-instrument daily balance/net worth calculation.
- Capital gains/loss computation per position.
- Profit/loss reporting per instrument.
- Tax reporting integration.

Each phase is independently shippable. Phase 1 is the largest since it changes the core model, but produces no new user-facing features — the same app on a better foundation.
