# CSV Import for Stock Holdings & Trade History — Design Spec

> **Superseded** by `plans/2026-04-18-csv-import-design.md`, which folds SelfWealth support into a unified CSV import pipeline shared with bank transactions and future crypto exchanges. This file is kept for historical reference; the new spec is the source of truth.

## Goal

Import Australian stock holdings and trade history from SelfWealth CSV exports into the app. SelfWealth has no public API, so CSV export is the only reliable data path. The design should handle SelfWealth's format as the primary target while being extensible to other Australian brokers (CommSec, Stake, etc.) in future.

## Scope

- Parse SelfWealth CSV exports (trade history report and portfolio holdings report)
- Create transactions and investment values from imported data
- Map trades to an existing investment-type account (or create one)
- Detect and skip duplicate imports
- Preview imported data before committing

Out of scope:
- Automated syncing with SelfWealth (no API exists)
- Real-time portfolio tracking (covered by `StockPriceService`)
- Tax lot tracking or CGT calculations
- Dividend reinvestment plan (DRP) auto-detection

---

## SelfWealth CSV Formats

SelfWealth exports are generated via **Settings > Trading Account > Reports**. The user selects "Include Trades" and/or "Include Other", picks a date range, and exports as CSV. The export contains multiple record types in a single file — trades, dividends, cash movements, and fees are intermixed.

### Trade History Report

The SelfWealth trade history CSV is a flat report with one row per transaction. Based on analysis of actual exports and third-party import tools (Sharesight, Portseido, Stock Profit), the columns are:

```
Date,Type,Description,Debit,Credit,Balance
```

Where:
- **Date** — Transaction date, format `DD/MM/YYYY` (Australian date format)
- **Type** — Transaction type: `Trade`, `Dividend`, `Cash In`, `Cash Out`, `Fee`, `Interest`, etc.
- **Description** — Free text. For trades, contains the stock code, quantity, price, and direction. Example: `BUY 100 BHP @ $45.50` or `SELL 50 CBA @ $110.25`. For dividends: `DIVIDEND - BHP GROUP LIMITED`. For fees: `Brokerage` or `GST on Brokerage`.
- **Debit** — Amount debited from cash account (positive number or blank)
- **Credit** — Amount credited to cash account (positive number or blank)
- **Balance** — Running cash balance after this transaction

### Portfolio Holdings Report

SelfWealth's portfolio statement (also exportable as CSV) shows current holdings:

```
Stock Code,Stock Name,Quantity,Average Price,Market Price,Market Value,Cost Base,Profit/Loss,Profit/Loss %
```

Where:
- **Stock Code** — ASX ticker (e.g. `BHP`, `CBA`, `VAS`)
- **Stock Name** — Full company/fund name
- **Quantity** — Number of shares/units held
- **Average Price** — Average purchase price per share (dollars, not cents)
- **Market Price** — Current market price per share
- **Market Value** — Current total value (Quantity x Market Price)
- **Cost Base** — Total cost of acquisition
- **Profit/Loss** — Market Value - Cost Base
- **Profit/Loss %** — Percentage gain/loss

### Format Caveats

- SelfWealth may change column names or ordering between versions. The parser should match columns by header name, not by position.
- Dollar amounts use Australian format: no thousands separator, two decimal places (e.g. `4550.00`), possibly with a `$` prefix.
- The trade description field is the richest data source for trades — it contains the buy/sell direction, quantity, stock code, and price, all of which must be extracted via parsing.
- The CSV may include header rows, blank lines, or summary sections at the top/bottom that must be skipped.

---

## Domain Models

### StockTrade

Represents a single buy or sell trade. Lives in `Domain/Models/`.

```swift
struct StockTrade: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let ticker: String           // ASX code, e.g. "BHP"
    let direction: TradeDirection // .buy or .sell
    let quantity: Int            // Number of shares
    let pricePerShare: Decimal   // Price per share in dollars (not cents)
    let brokerage: MonetaryAmount // Brokerage fee for this trade
    let totalCost: MonetaryAmount // Total cash impact (qty * price + brokerage for buys)
    let notes: String?           // Original CSV description for audit trail
}

enum TradeDirection: String, Codable, Sendable {
    case buy = "BUY"
    case sell = "SELL"
}
```

Prices are stored as `Decimal` (not `MonetaryAmount`) because share prices can have sub-cent precision on the ASX (stocks under $2 trade to 3 decimal places, e.g. $0.125). This follows the same rationale as `StockPriceCache` in the stock price design. The `totalCost` and `brokerage` fields are `MonetaryAmount` because they represent actual cash amounts in AUD cents.

### StockHolding

Represents current holdings of a single stock. Computed from trades rather than stored independently — the holdings CSV is used for initial validation, not as the source of truth.

```swift
struct StockHolding: Sendable {
    let ticker: String
    let name: String
    let quantity: Int
    let averagePrice: Decimal    // Cost basis per share
    let costBase: MonetaryAmount // Total cost basis
}
```

This is a computed/transient type, not persisted. Holdings are derived from the trade history. The holdings CSV can be used to validate that the computed holdings match what SelfWealth reports.

### No New Repository

Stock trades do **not** get a new repository protocol. Instead, they map to the existing data model:

- Each trade becomes a **Transaction** on the investment account (buy = expense, sell = income).
- Trade history is imported into investment account daily balances via the existing `InvestmentRepository.setValue()` for market valuations.
- The `StockTrade` model is an intermediate parsing type — it exists during import but is not persisted directly. The persisted data is standard `Transaction` records.

This avoids adding a parallel data model and keeps stock trades visible alongside all other financial activity.

---

## CSV Parsing

### Architecture

A protocol-based parser system allows different broker formats to be handled by swapping the parser implementation.

```swift
/// Domain layer — no external imports
protocol CSVBrokerParser: Sendable {
    /// The broker this parser handles
    var brokerName: String { get }

    /// Validate that the CSV headers match this broker's expected format.
    /// Returns nil if the headers don't match, or the parsed column mapping if they do.
    func recognizes(headers: [String]) -> CSVColumnMapping?

    /// Parse a single row into a trade, dividend, or other record.
    func parseRow(_ row: [String], mapping: CSVColumnMapping) throws -> CSVRecord?
}

/// Describes which CSV column index maps to which field
struct CSVColumnMapping: Sendable {
    let dateIndex: Int
    let typeIndex: Int
    let descriptionIndex: Int
    let debitIndex: Int?
    let creditIndex: Int?
    let balanceIndex: Int?
    // Holdings-specific
    let tickerIndex: Int?
    let quantityIndex: Int?
    let priceIndex: Int?
}

/// A parsed record from any broker CSV
enum CSVRecord: Sendable {
    case trade(StockTrade)
    case dividend(date: Date, ticker: String, amount: MonetaryAmount)
    case cashMovement(date: Date, description: String, amount: MonetaryAmount)
    case fee(date: Date, description: String, amount: MonetaryAmount)
    case holding(StockHolding)
    case unknown(row: [String]) // Unrecognized row type — skip or flag
}
```

### SelfWealthParser

```swift
struct SelfWealthParser: CSVBrokerParser {
    let brokerName = "SelfWealth"

    func recognizes(headers: [String]) -> CSVColumnMapping? {
        // Match by header names, case-insensitive, trimmed
        // Returns nil if required columns are missing
    }

    func parseRow(_ row: [String], mapping: CSVColumnMapping) throws -> CSVRecord? {
        // 1. Read the Type column
        // 2. For "Trade" type: parse Description with regex
        //    Pattern: "(BUY|SELL)\s+(\d+)\s+([A-Z0-9]+)\s+@\s+\$?([\d.]+)"
        // 3. For "Dividend": extract ticker from description
        // 4. For "Brokerage"/"GST on Brokerage": create fee record
        // 5. For "Cash In"/"Cash Out": create cash movement
        // 6. Return nil for summary/blank rows
    }
}
```

### CSV Tokenizer

Use Swift's built-in string processing — no third-party CSV library needed. The tokenizer handles:

- RFC 4180 quoted fields (fields containing commas or newlines wrapped in double quotes)
- Escaped quotes within quoted fields (`""`)
- Blank lines (skip)
- BOM (byte order mark) at start of file (strip)

```swift
struct CSVTokenizer: Sendable {
    /// Parse CSV text into an array of rows, each row being an array of field strings.
    static func parse(_ text: String) -> [[String]]

    /// Parse CSV data, auto-detecting encoding (UTF-8, UTF-16, Windows-1252).
    static func parse(_ data: Data) throws -> [[String]]
}
```

This is a simple, testable utility. SelfWealth CSVs are small (hundreds to low thousands of rows) so performance is not a concern — no streaming needed.

---

## Import Flow

### Step 1: File Selection

The user triggers import from the investment account's detail view (or a dedicated Import section in Settings). A standard file picker (`fileImporter` modifier) opens, filtered to `.csv` and `.txt` files.

```swift
.fileImporter(isPresented: $showingImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
    // Read file data
}
```

This works on both macOS (Finder file picker) and iOS (Files app picker).

### Step 2: Auto-Detection & Parsing

Once the file is loaded:

1. `CSVTokenizer` parses the raw text into rows.
2. The first non-empty row is treated as the header row.
3. Each registered `CSVBrokerParser` is tried against the headers. The first one that returns a non-nil `CSVColumnMapping` is selected.
4. If no parser recognizes the format, show an error: "Unrecognized CSV format. Currently supported: SelfWealth."
5. All rows are parsed into `CSVRecord` values. Rows that fail to parse are collected as errors.

### Step 3: Preview & Mapping

A preview screen shows:

- **Detected broker** (e.g. "SelfWealth")
- **Target account** — defaults to the account the user navigated from, or lets them pick/create an investment account
- **Summary** — "Found 47 trades, 12 dividends, 3 fees, 2 cash movements"
- **Trade list** — scrollable list showing date, ticker, direction, quantity, price, total
- **Warnings** — any unparseable rows, duplicate trades (see Deduplication below)
- **Errors** — rows that failed to parse, with the original text for debugging

The user can:
- Deselect specific records they don't want to import
- Change the target account
- Proceed or cancel

### Step 4: Import Execution

On confirmation, the `CSVImportStore` (see below) executes the import:

1. **Trades** — each trade creates a `Transaction` on the target investment account:
   - Buy: `type: .expense`, amount = negative total cost (cash outflow)
   - Sell: `type: .income`, amount = positive total proceeds (cash inflow)
   - `payee` = ticker (e.g. "BHP")
   - `notes` = original CSV description for audit trail
   - `date` = trade date from CSV

2. **Brokerage fees** — each fee creates a `Transaction`:
   - `type: .expense`, amount = negative fee amount
   - `payee` = "SelfWealth Brokerage" (or similar)

3. **Dividends** — each dividend creates a `Transaction`:
   - `type: .income`, amount = positive dividend amount
   - `payee` = ticker
   - `notes` = "Dividend"

4. **Investment values** — after all trades are imported, compute the portfolio's market value at the import date using the `StockPriceService` (if available) and set it via `InvestmentRepository.setValue()`.

Import is wrapped in a single logical operation. If any step fails, previously-created transactions for this import batch are rolled back (deleted).

### Step 5: Confirmation

Show a success screen with a summary: "Imported 47 trades, 12 dividends, 3 fees into SelfWealth Portfolio."

---

## Store

```swift
@Observable
@MainActor
final class CSVImportStore {
    private(set) var state: ImportState = .idle
    private(set) var parsedRecords: [CSVRecord] = []
    private(set) var errors: [CSVParseError] = []
    private(set) var detectedBroker: String?
    private(set) var duplicateCount: Int = 0

    private let transactionRepository: TransactionRepository
    private let investmentRepository: InvestmentRepository
    private let parsers: [CSVBrokerParser]

    enum ImportState: Sendable {
        case idle
        case parsing
        case preview(summary: ImportSummary)
        case importing(progress: Int, total: Int)
        case complete(ImportResult)
        case failed(Error)
    }

    /// Parse a CSV file and prepare for preview.
    func parseFile(_ data: Data) async

    /// Execute the import after user confirmation.
    func executeImport(
        targetAccountId: UUID,
        selectedRecords: Set<Int>
    ) async

    /// Check for duplicates against existing transactions.
    func checkDuplicates(accountId: UUID) async
}
```

The store follows the project's thin-view/testable-store pattern. All parsing logic, deduplication, and multi-step import orchestration lives here.

---

## Deduplication

Duplicate detection prevents re-importing the same CSV or overlapping date ranges. A trade is considered a duplicate if an existing transaction on the target account matches **all** of:

- Same date (day-level precision)
- Same amount (cents)
- Same payee (ticker)

The duplicate check runs during the preview step. Detected duplicates are shown as warnings and deselected by default (but the user can override and force-import if needed).

This is a heuristic — it won't catch every edge case (e.g. two genuine trades of the same stock at the same price on the same day). But for typical use it prevents the most common mistake: importing the same CSV twice.

---

## Error Handling

| Error | Handling |
|-------|----------|
| File can't be read (encoding, permissions) | Show error with file name. Suggest re-exporting from SelfWealth. |
| Unrecognized CSV format (no parser matches) | "Unrecognized format. Supported: SelfWealth." Show the first few header columns for debugging. |
| Individual row parse failure | Collect into errors list. Show in preview. Don't block the rest of the import. |
| Trade description regex doesn't match | Treat as `CSVRecord.unknown`. Show the raw row text in the warning list. |
| Dollar amount parse failure | Skip the row, add to errors. |
| Date parse failure | Skip the row, add to errors. |
| Network failure during investment value update | Import trades anyway (they're the critical data). Show warning that market values weren't updated. |
| Transaction creation fails mid-import | Roll back all transactions created in this import batch. Show error. |
| Duplicate import detected | Show count in preview. Deselect duplicates by default. |

---

## Integration with Existing Architecture

### Where It Lives

| Layer | Files | Purpose |
|-------|-------|---------|
| Domain/Models | `StockTrade.swift`, `StockHolding.swift` | Intermediate parsing models |
| Domain/Models | `CSVRecord.swift` | Parsed record enum |
| Shared/CSVImport | `CSVTokenizer.swift` | Raw CSV text -> rows |
| Shared/CSVImport | `CSVBrokerParser.swift` | Parser protocol + column mapping |
| Shared/CSVImport | `SelfWealthParser.swift` | SelfWealth-specific parsing |
| Features/Import | `CSVImportStore.swift` | Import orchestration |
| Features/Import/Views | `CSVImportView.swift` | File picker + preview + confirmation |
| Features/Import/Views | `CSVImportPreviewView.swift` | Trade list preview |

### Dependency Graph

```
Domain layer (no imports):
  StockTrade.swift, StockHolding.swift, CSVRecord.swift

Shared layer (imports Foundation):
  CSVTokenizer.swift — pure string processing
  CSVBrokerParser.swift — protocol definition
  SelfWealthParser.swift — uses CSVBrokerParser, regex

Features layer (imports SwiftUI):
  CSVImportStore.swift — uses TransactionRepository, InvestmentRepository, parsers
  CSVImportView.swift — uses CSVImportStore via @Environment(BackendProvider.self)
```

The domain models have no SwiftUI or backend imports. The parser layer has no backend imports. Only the store touches repositories.

### Navigation Entry Point

Import is accessible from:
1. The investment account detail view — a toolbar button or menu item ("Import Trades...")
2. Potentially a top-level Settings > Import section for discoverability

---

## Extensibility: Other Brokers

Adding a new broker requires only:

1. Implement `CSVBrokerParser` for the new format (e.g. `CommSecParser`, `StakeParser`)
2. Register it in the parser list passed to `CSVImportStore`

No changes to the store, views, domain models, or repositories. The auto-detection system tries each parser in order until one matches.

### Known Australian Broker CSV Formats

For future reference:

- **CommSec** — Exports via Portfolio > Transactions > Export. Columns include `Date`, `Reference`, `Type`, `Details`, `Debit ($)`, `Credit ($)`, `Balance ($)`.
- **Stake (AU)** — Exports via Activity > Export. Includes `Date`, `Type`, `Symbol`, `Quantity`, `Price`, `Amount`, `Fee`.
- **Interactive Brokers** — Flex queries export detailed CSVs with well-defined schemas. Most complex but most detailed.

The `CSVBrokerParser` protocol is intentionally simple enough to cover all these formats.

---

## Testing Strategy

### CSVTokenizer Tests

- Standard CSV with commas and newlines
- Quoted fields containing commas
- Escaped quotes within quoted fields (`""`)
- BOM stripping (UTF-8 BOM at start of file)
- Blank line handling
- Windows line endings (`\r\n`)
- Empty file returns empty array

### SelfWealthParser Tests

- Recognizes valid SelfWealth trade history headers (case-insensitive, order-independent)
- Returns nil for unrecognized headers
- Parses buy trade from description: `"BUY 100 BHP @ $45.50"` -> correct `StockTrade`
- Parses sell trade from description: `"SELL 50 CBA @ $110.25"` -> correct `StockTrade`
- Parses dividend record
- Parses brokerage fee record
- Handles missing/blank fields gracefully
- Returns `.unknown` for unrecognized row types
- Handles dollar amounts with `$` prefix
- Handles Australian date format `DD/MM/YYYY`
- Recognizes valid SelfWealth holdings headers
- Parses holdings rows into `StockHolding`

### CSVImportStore Tests

Uses `TestBackend` (CloudKitBackend + in-memory SwiftData), never mocks.

- **Parse and preview**: load fixture CSV, verify parsed record counts and types
- **Execute import**: verify transactions created on target account with correct amounts, dates, payees
- **Buy trade mapping**: buy creates expense transaction with correct negative amount
- **Sell trade mapping**: sell creates income transaction with correct positive amount
- **Brokerage fee mapping**: fee creates expense transaction
- **Dividend mapping**: dividend creates income transaction
- **Duplicate detection**: import same CSV twice, verify duplicates detected and skipped
- **Partial failure rollback**: simulate failure mid-import, verify no partial data persisted
- **Empty CSV**: no error, shows "no records found" in preview
- **Unrecognized format**: error state with helpful message

### Fixture Files

```
MoolahTests/Support/Fixtures/
  selfwealth-trades.csv          — realistic trade history (10-20 rows)
  selfwealth-holdings.csv        — realistic holdings snapshot (5-10 rows)
  selfwealth-trades-empty.csv    — valid headers but no data rows
  selfwealth-trades-malformed.csv — mix of valid and invalid rows
```

---

## Implementation Order

1. `CSVTokenizer` + tests (pure string processing, no dependencies)
2. `StockTrade`, `StockHolding`, `CSVRecord` domain models
3. `CSVBrokerParser` protocol + `SelfWealthParser` + tests
4. `CSVImportStore` + tests (against TestBackend)
5. `CSVImportView` + `CSVImportPreviewView` (UI layer)
6. Wire into navigation (investment account detail view toolbar item)

Each step is independently testable. Steps 1-4 require no UI work and can be validated entirely through unit tests.

---

## Open Questions

1. **Exact SelfWealth CSV format** — The column headers documented above are based on third-party import tools and community reports. The actual format should be verified against a real SelfWealth export before implementation. The parser's header-matching approach means minor differences (column naming, ordering) are easy to accommodate.

2. **Holdings vs. trade history** — Should we import both files, or just trade history? Trade history is the richer data source (individual transactions). Holdings are useful for validation but redundant if the full trade history is available. Recommendation: support both, but treat trade history as primary.

3. **Brokerage association** — SelfWealth brokerage fees appear as separate rows in the CSV, not on the same row as the trade. Should we associate each brokerage fee with its adjacent trade (combine into one transaction) or keep them as separate transactions? Recommendation: keep separate for accuracy, but add the trade reference in the notes field.

4. **Category assignment** — Should imported trades be auto-assigned to a category (e.g. "Investments")? Or left uncategorized for the user to assign? Recommendation: auto-assign to a well-known category if one exists, otherwise leave uncategorized.
