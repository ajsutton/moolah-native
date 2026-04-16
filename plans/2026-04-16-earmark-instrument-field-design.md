# Earmark Instrument Field & Balance Removal

## Problem

`Earmark` has no explicit `instrument` field. The earmark's currency is inferred from `balance.instrument`, where `balance` is a legacy single-instrument `InstrumentAmount` field. This creates several issues:

- **No stored instrument on the iCloud record** — `EarmarkRecord` doesn't persist the earmark's currency; it's derived from transaction legs at fetch time using the profile's default.
- **`balance`, `saved`, `spent` are redundant** — multi-instrument `positions`, `savedPositions`, `spentPositions` already exist and are the real source of truth.
- **Dual representation** — `Earmarks.adjustingPositions()` must keep legacy fields in sync with positions, adding complexity.
- **~25 call sites** read `.balance.instrument` to get currency context for parsing, display, and transaction creation.

## Approach

Two-step refactor (Approach B — parallel fields, then remove):

1. Add `instrument` field, migrate all `.balance.instrument` references to `.instrument`
2. Remove `balance`, `saved`, `spent` fields; EarmarkStore computes per-earmark totals from positions

## Step 1: Add `instrument` field, migrate references

### Domain Model

- Add `var instrument: Instrument` to `Earmark`.
- All init paths set it explicitly.
- All call sites reading `.balance.instrument` switch to `.instrument`.
- `EarmarkStore.totalBalance` is removed. The one call site (`EarmarksView` create sheet) uses the profile's `targetInstrument` instead.

### Storage — iCloud

- `EarmarkRecord` gets a new `instrumentId: String` field.
- Existing records missing this field default to the profile currency.
- `RecordMapping` reads/writes `instrumentId` on the CKRecord.
- `CloudKitEarmarkRepository.fetchAll()` passes the instrument through to `toDomain()`.

### Storage — Remote Backend

- `RemoteBackend` sets instrument to profile currency when decoding earmarks (remote backend doesn't support per-earmark currencies).

### Tests

- All existing `Earmark` test fixtures updated to include `instrument`.
- `EarmarkStoreTests` updated — `totalBalance` assertions removed, replaced with `instrument` checks.
- Contract tests verify `instrument` round-trips through the repository.

## Step 2: Remove `balance`, `saved`, `spent`

### Domain Model

- Remove stored `balance`, `saved`, `spent` fields from `Earmark`.
- `Earmarks.adjustingPositions()` no longer syncs legacy fields — just updates positions.

### EarmarkStore Owns All Conversion

- `EarmarkStore` computes per-earmark converted balances by converting all positions to the earmark's `instrument` and summing. This is the single source of truth for display.
- Store publishes these pre-computed amounts so views just read them — no async conversion in views.
- `recomputeConvertedTotals()` expands to compute both:
  - Per-earmark totals (positions converted to each earmark's own `instrument`)
  - Grand total (positions converted to the profile's `targetInstrument`)

### Views Are Pure Readers

- Views read the store's pre-computed per-earmark amounts. No conversion logic, no position iteration.
- `EarmarkDetailView` progress calculation reads the store's converted amount for that earmark.

### Storage

- No changes needed — `EarmarkRecord` never stored balance/saved/spent.
- `CloudKitEarmarkRepository.computeEarmarkPositions()` stops computing legacy single-instrument totals; only returns position arrays.
- `toDomain()` signature drops the `balance`/`saved`/`spent` parameters.

### Codable

- `Earmark`'s `CodingKeys`, `init(from:)`, and `encode(to:)` drop balance/saved/spent.
- `RemoteBackend` decoding: if the server sends balance/saved/spent, they're ignored.

### Tests

- All test fixtures drop balance/saved/spent from Earmark construction.
- Store tests assert on positions rather than legacy fields.
- Contract tests verify position-based totals.

## Scope

- **Earmark only** — Account has the same pattern but is out of scope for this plan.
- **Earmarked Total clamping bug** (negative balances) is tracked separately in BUGS.md.
