# Australian Tax Reporting — Design Spec

## Goals

1. Expose the information required to support or fully prepare annual Australian tax returns (personal and family trust)
2. Calculate quarterly PAYG instalment amounts based on estimated actual liability (not stale ATO rates)

## Scope

- **Personal tax** for contractors (income often without PAYG withholding), with investment income (dividends, interest, rental) and capital gains from stocks/crypto
- **Family trust tax returns** tracked in the same profile as personal finances
- **Capital gains**: summary import only (from external tools like Sharesight/Koinly), not individual lot tracking. Future enhancement may add full CGT engine.
- **Tax calculation**: estimated liability with marginal rates, Medicare levy, CGT discount, franking credits, offsets. Not a lodgeable return — data for accountants plus actionable estimates.
- **Rate tables**: bundled per financial year so historical reports stay accurate.
- **iCloud backend**: full support. moolah-server backend: sensible defaults, tax features effectively read-only/inert.

## Non-Goals

- GST / BAS reporting
- Full capital gains lot tracking and cost base calculations (future)
- Percentage splits per category for joint account attribution (future — small amounts, manual adjustment for now)
- Lodgeable ATO return generation

---

## Domain Model Changes

### Owner (new entity)

A managed entity representing a tax-filing person or trust. Avoids freeform strings and typo issues.

```
Owner
  id: String
  name: String           // e.g. "AJ", "Partner", "Smith Family Trust"
  type: OwnerType        // .person | .trust
```

- `OwnerRepository` protocol for CRUD: `fetchAll`, `create`, `update`, `delete`
- iCloud backend: full CRUD
- moolah-server backend: returns a single default person owner (the profile holder); mutations are no-ops
- InMemory backend: full implementation for tests

### Account changes

- New field: `ownerId: String?` — references an Owner. Nil defaults to the profile's default owner.
- iCloud backend stores and syncs this field
- moolah-server backend: always nil (all accounts belong to profile holder)

### Category changes

- New field: `taxCategory: TaxCategory?` — classifies the category for tax reporting
- New field: `ownerId: String?` — overrides attribution (for joint account income split by category)
- Both fields edited inline on the existing category edit screen
- iCloud backend stores and syncs these fields
- moolah-server backend: always nil for both

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

A single record per financial year per owner. Stores values that can't be derived from transactions.

```
TaxYearAdjustments
  id: String
  financialYear: Int              // e.g. 2026 for FY2025-26
  ownerId: String                 // which owner this applies to

  // Capital gains (from external tools)
  shortTermCapitalGains: MonetaryAmount?
  longTermCapitalGains: MonetaryAmount?     // pre-discount amount
  capitalLosses: MonetaryAmount?

  // Credits and offsets
  frankingCredits: MonetaryAmount?
  paygWithheld: MonetaryAmount?             // tax withheld by payers

  // Instalments paid
  q1InstalmentPaid: MonetaryAmount?
  q2InstalmentPaid: MonetaryAmount?
  q3InstalmentPaid: MonetaryAmount?
  q4InstalmentPaid: MonetaryAmount?

  // Other factors
  hasPrivateHealth: Bool?                    // affects Medicare levy surcharge

  // Trust-specific: distributions to beneficiaries
  distributions: [BeneficiaryDistribution]?  // only for trust-type owners

  notes: String?
```

```
BeneficiaryDistribution
  ownerId: String       // must reference a person-type Owner
  percentage: Decimal    // e.g. 50.0 for 50%
```

- CRUD via `TaxRepository` protocol: `fetchAdjustments(financialYear:ownerId:)`, `saveAdjustments(_:)`
- iCloud backend: full CRUD
- moolah-server backend: returns nil; mutations are no-ops
- InMemory backend: full implementation for tests

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
- Income totals grouped by `TaxCategory` (from category balance aggregation)
- Deduction totals grouped by `TaxCategory`
- `TaxYearAdjustments` for the year
- `TaxRateTable` for the year and owner type
- Trust distribution income (for person-type owners who are trust beneficiaries)

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

```
TaxEstimate
  // Income breakdown
  incomeByType: [TaxCategory: MonetaryAmount]
  trustDistributionIncome: MonetaryAmount?
  totalAssessableIncome: MonetaryAmount

  // Deductions
  deductionsByType: [TaxCategory: MonetaryAmount]
  totalDeductions: MonetaryAmount

  // Capital gains
  netCapitalGains: MonetaryAmount

  // Core calculation
  taxableIncome: MonetaryAmount
  taxOnIncome: MonetaryAmount               // from bracket calculation
  medicareLevy: MonetaryAmount
  medicareLevySurcharge: MonetaryAmount?

  // Credits
  frankingCreditOffset: MonetaryAmount?
  paygWithheldCredit: MonetaryAmount?

  // Result
  estimatedLiability: MonetaryAmount         // the headline number

  // Instalments
  quarterlyInstalment: MonetaryAmount?       // recommended payment
  totalInstalmentsPaid: MonetaryAmount
  instalmentShortfall: MonetaryAmount?       // positive = underpaid
```

---

## Repository & Store Layer

### TaxRepository (new protocol)

```swift
protocol TaxRepository {
    func fetchOwners() async throws -> [Owner]
    func createOwner(_ owner: Owner) async throws -> Owner
    func updateOwner(_ owner: Owner) async throws -> Owner
    func deleteOwner(id: String) async throws

    func fetchAdjustments(financialYear: Int, ownerId: String) async throws -> TaxYearAdjustments?
    func saveAdjustments(_ adjustments: TaxYearAdjustments) async throws -> TaxYearAdjustments
}
```

Added to `BackendProvider` alongside existing repositories.

### TaxStore (@MainActor)

Orchestrates data loading and calculation:

- `loadTaxSummary(financialYear:owner:)`:
  1. Load owners, categories (with tax mappings), accounts (with owner assignments)
  2. Determine which categories are attributed to the selected owner (see attribution chain)
  3. Call `AnalysisRepository.fetchCategoryBalances(dateRange:transactionType:)` for income and expenses across the FY
  4. Group results by `TaxCategory`
  5. If person: check for trust beneficiary distributions, run trust calculation first
  6. Load `TaxYearAdjustments`
  7. Load `TaxRateTable`
  8. Run `TaxCalculator` → publish `TaxEstimate`

- `loadInstalmentRecommendation(financialYear:quarter:owner:)`:
  - Same flow but calculator also annualises YTD and computes per-quarter recommendation

### Category attribution priority

When determining which owner a transaction's category belongs to:

1. **Category has explicit `ownerId`** → use that owner
2. **Transaction's account has `ownerId`** → use that owner
3. **Profile default owner** — the owner with the earliest-created person-type record. When the iCloud backend has no owners, the tax UI prompts the user to create one before proceeding.

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

### iCloud backend

- `Owner` stored as a new CKRecord type
- `TaxYearAdjustments` stored as a new CKRecord type (one record per FY per owner)
- `BeneficiaryDistribution` stored as a nested/child record or serialised within adjustments
- Category record gains `taxCategory` (string) and `ownerId` (reference) fields
- Account record gains `ownerId` (reference) field

### moolah-server backend

- `fetchOwners()`: returns `[Owner(id: "default", name: profile.cachedUserName, type: .person)]`
- `createOwner/updateOwner/deleteOwner`: no-op
- Category and Account tax fields: always nil on fetch, ignored on update
- `fetchAdjustments`: returns nil
- `saveAdjustments`: no-op

### InMemory backend

- Full implementation for tests and previews, matching iCloud behaviour

---

## Future Enhancements

- **Percentage splits per category** for joint account attribution (interest, etc.)
- **Full CGT engine** with lot tracking, cost base methods, holding period calculation
- **GST/BAS reporting** for GST-registered entities
- **Export** tax summary as PDF/CSV for accountant submission
- **Rate table auto-update** via remote config (avoid app releases for new FY rates)
