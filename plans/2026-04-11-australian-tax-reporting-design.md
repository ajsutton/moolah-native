# Australian Tax Reporting — Design Spec

## Goals

1. Expose the information required to support or fully prepare annual Australian tax returns (personal and family trust)
2. Calculate quarterly PAYG instalment amounts based on estimated actual liability (not stale ATO rates)

## Scope

- **Personal tax** for contractors (income often without PAYG withholding), with investment income (dividends, interest, rental) and capital gains from stocks/crypto
- **Family trust tax returns** tracked in the same profile as personal finances
- **Capital gains**: computed from transaction legs via FIFO lot tracking in `CostBasisEngine` (Phase 5, shipped 2026-04-12). `CapitalGainsSummary.asTaxAdjustmentValues(currency:)` auto-populates `shortTermCapitalGains`, `longTermCapitalGains`, and `capitalLosses` on `TaxYearAdjustments`. Manual override still available for external adjustments.
- **Tax calculation**: estimated liability with marginal rates, Medicare levy, CGT discount, franking credits, offsets. Not a lodgeable return — data for accountants plus actionable estimates.
- **Rate tables**: bundled per financial year so historical reports stay accurate.
- **Multi-instrument**: all tax totals roll up to the profile's reporting instrument (`Profile.instrument`, derived from `Profile.currencyCode` — typically AUD for Australian tax). Per-instrument amounts are converted via `InstrumentConversionService` following `guides/INSTRUMENT_CONVERSION_GUIDE.md`. Rule 11 applies: if any conversion fails, the dependent total is marked unavailable — never show partial sums or native-instrument fallbacks.
- **CloudKit backend**: full support. All profiles are multi-instrument (`CloudKitBackend` is the only production backend).

## Non-Goals

- GST / BAS reporting
- ~~Full capital gains lot tracking and cost base calculations~~ — Now implemented via FIFO in `CostBasisEngine` + `CapitalGainsCalculator` (Phase 5)
- Percentage splits per category for joint account attribution (future — small amounts, manual adjustment for now)
- Lodgeable ATO return generation

---

## Domain Model Changes

### Owner (new entity)

A managed entity representing a tax-filing person or trust. Avoids freeform strings and typo issues.

```
Owner
  id: UUID
  name: String           // e.g. "AJ", "Partner", "Smith Family Trust"
  type: OwnerType        // .person | .trust
```

- `OwnerRepository` protocol (or grouped under `TaxRepository` — see below) for CRUD: `fetchAll`, `create`, `update`, `delete`
- CloudKit backend: full CRUD
- InMemory backend: full implementation for tests

### Account changes

- `Account` already has an `instrument: Instrument` field (used for multi-instrument support). No change needed for currency handling.
- New field: `ownerId: UUID?` — references an Owner. Nil defaults to the profile's default owner.
- CloudKit backend stores and syncs this field

### Category changes

Current `Category` model has only `id: UUID`, `name: String`, `parentId: UUID?`. Two new fields are required:

- New field: `taxCategory: TaxCategory?` — classifies the category for tax reporting
- New field: `ownerId: UUID?` — overrides attribution (for joint account income split by category)
- Both fields edited inline on the existing category edit screen
- CloudKit backend stores and syncs these fields
- Remote backend: always nil for both

### TaxCategory enum

Classifies categories into tax-relevant groupings:

**Income types:**
- `.contractorIncome` — business/contractor income
- `.salaryIncome` — employment income (PAYG withholding applies)
- `.interestIncome` — bank/term deposit interest
- `.dividendIncome` — share dividends (franking handled via adjustments)
- `.rentalIncome` — rental property income
- `.trustDistribution` — income received from a trust
- `.otherIncome` — assessable income not covered above

**Deduction types:**
- `.workDeduction` — work-related expenses
- `.rentalDeduction` — rental property expenses
- `.otherDeduction` — other allowable deductions

**Excluded:**
- Categories with no `taxCategory` are excluded from tax reports

### TaxYearAdjustments (new entity)

A single record per financial year per owner. Stores values that can't be derived from transactions. All monetary fields are `InstrumentAmount` in the profile's reporting instrument (`profile.instrument`).

```
TaxYearAdjustments
  id: UUID
  financialYear: Int              // e.g. 2026 for FY2025-26
  ownerId: UUID                   // which owner this applies to

  // Capital gains — auto-populated from ReportingStore.capitalGainsSummary via
  // asTaxAdjustmentValues(currency:), with manual override still available.
  // Values are already in profile.instrument (the summary is computed by
  // CapitalGainsCalculator.computeWithConversion using profile currency as target).
  shortTermCapitalGains: InstrumentAmount?
  longTermCapitalGains: InstrumentAmount?     // pre-discount amount
  capitalLosses: InstrumentAmount?

  // Credits and offsets (stored in profile.instrument)
  frankingCredits: InstrumentAmount?
  paygWithheld: InstrumentAmount?             // tax withheld by payers

  // Instalments paid
  q1InstalmentPaid: InstrumentAmount?
  q2InstalmentPaid: InstrumentAmount?
  q3InstalmentPaid: InstrumentAmount?
  q4InstalmentPaid: InstrumentAmount?

  // Other factors
  hasPrivateHealth: Bool?                    // affects Medicare levy surcharge

  // Trust-specific: distributions to beneficiaries
  distributions: [BeneficiaryDistribution]?  // only for trust-type owners

  notes: String?
```

```
BeneficiaryDistribution
  ownerId: UUID         // must reference a person-type Owner
  percentage: Decimal   // e.g. 50.0 for 50%
```

**Persisted instrument:** adjustment values are stored as `InstrumentAmount`, so the instrument travels with the value. If a user ever switches `profile.currencyCode` after entering adjustments, older records remain interpretable at their original instrument (display/recalculation can convert on read).

- CRUD via `TaxRepository` protocol: `fetchAdjustments(financialYear:ownerId:)`, `saveAdjustments(_:)`
- CloudKit backend: full CRUD
- Remote backend: returns nil; mutations are no-ops
- InMemory backend: full implementation for tests

### Bridge from ReportingStore (already implemented)

`CapitalGainsSummary.asTaxAdjustmentValues(currency: Instrument)` in `Features/Reports/ReportingStore.swift` returns:

```swift
(shortTerm: InstrumentAmount, longTerm: InstrumentAmount, losses: InstrumentAmount)
```

where `losses` is the absolute value of the net loss (if `totalGain < 0`). `TaxStore.loadTaxSummary` calls `ReportingStore.loadCapitalGains(financialYear:)`, passes `profile.instrument` to the bridge, and fills the three capital gains fields on `TaxYearAdjustments` unless the user has manually overridden them.

### TaxRateTable (bundled data, not server-stored)

```
TaxRateTable
  financialYear: Int
  ownerType: OwnerType                    // rates differ for persons vs trusts

  // Person rates
  incomeBrackets: [(threshold: Int, rate: Decimal)]   // marginal rate brackets
  medicareLevy: Decimal                                // e.g. 0.02
  medicareLevySurchargeThresholds: [...]               // income thresholds + rates
  medicareLevyLowIncomeThreshold: Int                  // phase-in threshold
  cgtDiscount: Decimal                                 // e.g. 0.50

  // Trust rates
  undistributedIncomeRate: Decimal                     // top marginal rate for trusts
```

- Shipped as a Swift data file with entries per FY
- The app selects the correct table based on the FY being viewed and the owner type
- Adding a new year = adding a new entry; no code changes needed

---

## Tax Calculation Engine

### TaxCalculator

A pure Swift struct with no async calls or repository dependencies. All inputs passed in, `TaxEstimate` returned. Highly unit-testable.

**Inputs:**
- Income totals grouped by `TaxCategory` (from category balance aggregation), already in `profile.instrument`
- Deduction totals grouped by `TaxCategory`, already in `profile.instrument`
- `TaxYearAdjustments` for the year (all values in `profile.instrument`)
- `TaxRateTable` for the year and owner type
- Trust distribution income (for person-type owners who are trust beneficiaries)

**Instrument invariant:** the calculator does no conversion. All input `InstrumentAmount` values must be in the same instrument (the profile's reporting instrument). `InstrumentAmount` arithmetic traps on mismatched instruments, so a misconfigured caller fails loudly rather than silently producing a wrong total. Conversion happens upstream in `AnalysisRepository.fetchCategoryBalances(...)` (see below) and in `CapitalGainsCalculator.computeWithConversion(...)`.

**Calculation steps (person):**

1. **Assessable income** = sum of all income by tax category + trust distribution income + franking credits grossed-up
2. **Deductions** = sum of all deduction tax categories
3. **Taxable income** = assessable income - deductions + net capital gains
4. **Net capital gains** = (long-term gains x (1 - CGT discount)) + short-term gains - capital losses (net gain cannot go below zero)
5. **Tax on taxable income** = apply marginal rate brackets
6. **Medicare levy** = taxable income x levy rate (with low-income phase-in)
7. **Medicare levy surcharge** = if no private health and income above threshold, apply surcharge
8. **Credits** = franking credits + PAYG withheld
9. **Estimated net liability** = tax + Medicare levy + surcharge - credits

**Calculation steps (trust):**

1. **Trust net income** = trust assessable income - trust deductions + trust net capital gains
2. **Distributed income** = trust net income x sum of distribution percentages (should total 100% if fully distributed)
3. **Undistributed income** = trust net income - distributed income
4. **Trust tax** = undistributed income x top marginal rate
5. Per-beneficiary distribution amounts calculated by income type (character preserved)

**Quarterly instalment calculation:**

1. Estimate full-year liability (using YTD actuals, annualised for remaining quarters)
2. Subtract PAYG withheld and instalments already paid
3. Divide remaining liability by remaining quarters
4. Output: recommended payment for current quarter

### TaxEstimate (output model)

All amounts are `InstrumentAmount` in the profile's reporting instrument. Optional-unavailable fields are used for values whose source conversion failed (per Rule 11 of `INSTRUMENT_CONVERSION_GUIDE.md`): the specific figure and any total that depends on it become `nil`, while independent sibling figures keep rendering.

```
TaxEstimate
  instrument: Instrument                     // profile.instrument at calculation time

  // Income breakdown
  incomeByType: [TaxCategory: InstrumentAmount]
  trustDistributionIncome: InstrumentAmount?
  totalAssessableIncome: InstrumentAmount?   // nil if any contributing conversion failed

  // Deductions
  deductionsByType: [TaxCategory: InstrumentAmount]
  totalDeductions: InstrumentAmount?

  // Capital gains
  netCapitalGains: InstrumentAmount?

  // Core calculation
  taxableIncome: InstrumentAmount?
  taxOnIncome: InstrumentAmount?             // from bracket calculation
  medicareLevy: InstrumentAmount?
  medicareLevySurcharge: InstrumentAmount?

  // Credits
  frankingCreditOffset: InstrumentAmount?
  paygWithheldCredit: InstrumentAmount?

  // Result
  estimatedLiability: InstrumentAmount?      // the headline number; nil if any input unavailable

  // Instalments
  quarterlyInstalment: InstrumentAmount?     // recommended payment
  totalInstalmentsPaid: InstrumentAmount
  instalmentShortfall: InstrumentAmount?     // positive = underpaid
```

---

## Repository & Store Layer

### TaxRepository (new protocol)

```swift
protocol TaxRepository: Sendable {
    func fetchOwners() async throws -> [Owner]
    func createOwner(_ owner: Owner) async throws -> Owner
    func updateOwner(_ owner: Owner) async throws -> Owner
    func deleteOwner(id: UUID) async throws

    func fetchAdjustments(financialYear: Int, ownerId: UUID) async throws -> TaxYearAdjustments?
    func saveAdjustments(_ adjustments: TaxYearAdjustments) async throws -> TaxYearAdjustments
}
```

Added to `BackendProvider` alongside existing repositories (`accounts`, `transactions`, `categories`, `earmarks`, `analysis`, `investments`, `conversionService`).

### TaxStore (@MainActor)

Orchestrates data loading and calculation. Reads `profile.instrument` and threads it through every aggregation call so all values arrive in the reporting instrument.

- `loadTaxSummary(financialYear:owner:)`:
  1. Load owners, categories (with tax mappings), accounts (with owner assignments)
  2. Determine which categories are attributed to the selected owner (see attribution chain)
  3. Call `AnalysisRepository.fetchCategoryBalancesByType(dateRange:filters:targetInstrument:)` with `targetInstrument: profile.instrument` for the FY. This returns `(income: [UUID: InstrumentAmount], expense: [UUID: InstrumentAmount])` with all values converted to the reporting instrument.
  4. Group results by `TaxCategory`
  5. If person: check for trust beneficiary distributions, run trust calculation first
  6. Load `TaxYearAdjustments` (or use defaults if none saved)
  7. Pull capital gains by calling `ReportingStore.loadCapitalGains(financialYear:)` and `CapitalGainsSummary.asTaxAdjustmentValues(currency: profile.instrument)`; populate adjustments unless the user has saved overrides
  8. Load `TaxRateTable` for (financialYear, ownerType)
  9. Run `TaxCalculator` → publish `TaxEstimate`
  10. On any `BackendError.conversionFailed` (or equivalent) from step 3 or 7, mark the affected categories/fields unavailable and propagate `nil` through dependent totals per Rule 11

- `loadInstalmentRecommendation(financialYear:quarter:owner:)`:
  - Same flow but calculator also annualises YTD and computes per-quarter recommendation

### Category attribution priority

When determining which owner a transaction's category belongs to:

1. **Category has explicit `ownerId`** → use that owner
2. **Transaction's account has `ownerId`** → use that owner
3. **Profile default owner** — the owner with the earliest-created person-type record. When the CloudKit backend has no owners, the tax UI prompts the user to create one before proceeding.

---

## UI

### Tax Summary screen

- Financial year picker (defaults to current FY)
- Owner picker (if multiple owners exist)
- Sections matching `TaxEstimate` breakdown:
  - Income by type (contractor, salary, interest, dividends, rental, trust distributions)
  - Deductions by type
  - Capital gains summary
  - Taxable income
  - Tax on taxable income (with bracket breakdown visible)
  - Medicare levy / surcharge
  - Credits and offsets
  - **Estimated net liability** (headline)
- Drill-down: tapping an income/deduction line navigates to filtered transaction list (reuse existing transaction list with category + date range filter)
- **Unavailable values**: any line whose source conversion failed renders as an "Unavailable" state (not zero, not a partial sum). The estimated liability is hidden with an explanation when any required input is unavailable. Sibling lines whose data is complete still render normally.

### Quarterly Instalments screen

- All 4 quarters for selected FY and owner
- Per quarter: recommended payment, amount paid (from adjustments), difference
- Running totals: estimated liability, total paid, shortfall/surplus
- Visual indicator for on-track / underpaid / overpaid

### Tax Settings screen

- **Owners**: list, create, edit, delete. Each has name and type (person/trust).
- **Adjustments**: form-style UI for `TaxYearAdjustments` per FY per owner. Capital gains, franking credits, PAYG withheld, instalments paid, private health, trust distributions.

### Category tax fields

- Edited inline on the existing category edit screen
- `taxCategory` picker (optional — nil means excluded from tax)
- `ownerId` picker (optional — nil means inherit from account/profile)

### Account owner field

- Owner picker on account edit screen
- Shows existing owners with option to create new

### Navigation

- New top-level "Tax" section alongside Reports and Analysis

---

## Backend Implementation

### CloudKit backend

- `Owner` stored as a new CKRecord type (must be added to `guides/SYNC_GUIDE.md` compliant sync flow)
- `TaxYearAdjustments` stored as a new CKRecord type (one record per FY per owner). `InstrumentAmount` fields are persisted as (decimal quantity, instrument code) pairs, consistent with how amounts are stored elsewhere.
- `BeneficiaryDistribution` stored as a nested/child record or serialised within adjustments
- Category record gains `taxCategory` (string) and `ownerId` (reference) fields
- Account record gains `ownerId` (reference) field; its existing `instrument` field is untouched

### InMemory backend

- Full implementation for tests and previews, matching CloudKit behaviour

---

## Future Enhancements

- **Percentage splits per category** for joint account attribution (interest, etc.)
- **Full CGT engine** with lot tracking, cost base methods, holding period calculation
- **GST/BAS reporting** for GST-registered entities
- **Export** tax summary as PDF/CSV for accountant submission
- **Rate table auto-update** via remote config (avoid app releases for new FY rates)
