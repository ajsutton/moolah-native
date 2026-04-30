# SelfWealth Parser Rewrite

**Issue:** [#601](https://github.com/ajsutton/moolah-native/issues/601)
**Supersedes:** existing `Shared/CSVImport/SelfWealthParser.swift`
**Related:** [#558](https://github.com/ajsutton/moolah-native/issues/558) (fee-attach / cost-basis decision — out of scope here)

## Why

`SelfWealthParser` was built against a hypothesised CSV shape that doesn't match what SelfWealth actually exports. Verified against four real export files (two Cash Reports + two Movements reports across two accounts). Every single layer is wrong: headers, date format, type-column dispatch, trade regex, dividend regex. `recognizes(headers:)` rejects every real file, so today the importer silently routes them to `GenericBankCSVParser` and the user lands in the Needs Setup pile.

## Reports

SelfWealth provides two separate exports. Their shapes are unrelated, so we ship two parsers, not one. Together they cover the full account history; each is internally complete for its scope.

### Movements report — positions + trades

Headers (case-insensitive, trimmed):

```
Trade Date, Settlement Date, Action, Reference, Code, Name, Units, Average Price, Consideration, Brokerage, Total
```

Date format: `yyyy-MM-dd HH:mm:ss` (UTC).

Per-`Action` mapping:

| Action | Output |
|---|---|
| `Buy` | Three legs: cash AUD expense (−Consideration), position income on `ASX:<Code>` (+Units), AUD brokerage expense (−Brokerage). Brokerage is broken out as a separate fee leg on the same transaction so #558 can later fold it into cost basis without re-parsing. |
| `Sell` | Three legs: cash AUD income (+Consideration), position expense on `ASX:<Code>` (−Units), AUD brokerage expense (−Brokerage). |
| `In` | One leg: position income on `ASX:<Code>` (+Units), no cash side. May be DRP or off-market transfer in; not distinguishable from CSV alone. Imported as DRP by default; user reclassifies in-app as needed. |
| `Out` | One leg: position expense on `ASX:<Code>` (−Units), no cash side. |
| anything else | `.skip(reason: "unsupported action: <value>")` — file still parses. |

`bankReference` for trades = the `Reference` column verbatim (e.g. `3097711`). For `In`/`Out` legs, also the raw `Reference` (the long zero-padded values for off-market transfers will dedupe correctly against re-imports of the same window).

### Cash Report — pure cash flow

Headers (case-insensitive, trimmed):

```
TransactionDate, Comment, Credit, Debit, Balance * Please note, this is not a bank statement.
```

The trailing `* Please note, this is not a bank statement.` is part of the literal column header — the matcher accepts any header whose trimmed-lowercased prefix is `balance` so it stays robust if SelfWealth tweaks the wording.

Date format: `yyyy-MM-dd HH:mm:ss` (UTC). Some rows have an empty `TransactionDate` (Opening / Closing Balance sentinels) — those are skipped without throwing.

Per-`Comment` dispatch (regex match against the trimmed cell):

| Pattern | Output |
|---|---|
| `^$` (empty `TransactionDate`) | `.skip(reason: "balance sentinel")` |
| `^Order \d+:` (any order-related row — buy fill, sell fill, brokerage) | `.skip(reason: "trade row — represented in Movements report")` |
| `^[A-Z]+ PAYMENT \w+/\d+$` | One leg: AUD income (+Credit). `bankReference` = the raw `Comment` text verbatim (per discussion: format may not be stable, so we don't normalise). `rawDescription` = the same comment. |
| anything else with Credit > 0 | One leg: AUD income (+Credit). `bankReference` = nil. `rawDescription` = the raw `Comment`. |
| anything else with Debit > 0 | One leg: AUD expense (−Debit). `bankReference` = nil. `rawDescription` = the raw `Comment`. |

The "raw `Comment` preserved verbatim" choice is deliberate: SelfWealth passes through whatever narration the user's bank used on the inbound transfer (`PAYMENT FROM <name>`, `Transfer to Shares`, plain `SelfWealth`, etc.). No keyword match is safe; let the user's import rules categorise based on the raw value.

## Why two reports, not one merged parser

- Movements has no cash transfers; Cash Report has no DRP allocations. Each report is self-contained for its scope.
- Movements `Reference` (e.g. `3097711`) and Cash Report `Order N:` (e.g. `Order 1`) are different ID schemes — they cannot be matched as keys. Cross-file dedupe would require fuzzy matching on (date, ticker, qty, total cash), which is fragile.
- Splitting scope (Movements owns positions + trades; Cash Report owns cash flow) sidesteps the dedupe problem cleanly. Users importing both files see no double-counting because Cash Report skips every `Order N:` row.

## Surgery

**Add:**
- `Shared/CSVImport/SelfWealthMovementsParser.swift`
- `Shared/CSVImport/SelfWealthCashReportParser.swift`
- `MoolahTests/Shared/CSVImport/SelfWealthMovementsParserTests.swift`
- `MoolahTests/Shared/CSVImport/SelfWealthCashReportParserTests.swift`
- Synthetic fixtures: `selfwealth-movements.csv`, `selfwealth-movements-empty.csv`, `selfwealth-movements-malformed.csv`, `selfwealth-cash-report.csv`, `selfwealth-cash-report-empty.csv`, `selfwealth-cash-report-malformed.csv`

**Delete:**
- `Shared/CSVImport/SelfWealthParser.swift`
- `MoolahTests/Shared/CSVImport/SelfWealthParserTests.swift`
- `MoolahTests/Support/Fixtures/csv/selfwealth-trades.csv`
- `MoolahTests/Support/Fixtures/csv/selfwealth-trades-empty.csv`
- `MoolahTests/Support/Fixtures/csv/selfwealth-trades-malformed.csv`

**Modify:**
- `Shared/CSVImport/CSVParserRegistry.swift` — register both new parsers ahead of `GenericBankCSVParser`.
- `Domain/Models/CSVImport/CSVParser.swift` — update the example identifier list in the doc comment.
- `MoolahTests/Shared/CSVImport/CSVParserRegistryTests.swift` — replace the SelfWealth-specific tests with movements + cash-report variants.
- `MoolahTests/Shared/CSVImport/CSVImportProfileMatcherTests.swift` — replace the `parser: "selfwealth"` reference (line 220).
- `MoolahTests/Features/Import/ImportStoreTestsMoreSecondHalf.swift` — rewrite the existing end-to-end SelfWealth test (lines 120-177) against the new movements parser + fixture.
- `Shared/TradeEventClassifier.swift` — update the doc-comment reference (line 29) to point at `SelfWealthMovementsParser`.

## Identifiers

- `selfwealth-movements`
- `selfwealth-cash-report`

The legacy `selfwealth` identifier is retired entirely. Stored profiles still using it will route through the registry's fallback (`GenericBankCSVParser`) and need to be re-set up — acceptable because the existing parser was non-functional and no real user has a working profile pointing at it.

## Fixture data discipline

All fixture rows use synthetic data. **No real ticker codes, dates, amounts, references, or names from the user's actual exports.** Suggested synthetic shape:

- Tickers: `WXYZ`, `ABCD`, `MNOP`.
- Dates: `2024-01-15` style.
- Reference numbers: short numeric (`1000001`) for trades and DRP `In`; long zero-padded (`9000000000000001`) for off-market `In` examples.
- Amounts: round numbers (`1000.00`, `9.50` brokerage).
- Bank narrations on cash-report rows: invented strings (`PAYMENT FROM EXAMPLE PERSON`, `Funds in`, `Test withdrawal`).

## Steps

1. **Open issue + worktree** — done. Issue #601, branch `fix/selfwealth-parser-rewrite`.
2. **Movements parser TDD.** Write `SelfWealthMovementsParserTests.swift` first with cases for each `Action` + edge cases (malformed, empty, header mismatch). Synthesise the fixture. Run tests, watch them fail. Implement `SelfWealthMovementsParser.swift`. Iterate until green.
3. **Cash Report parser TDD.** Same loop: tests first, then fixture, then implementation. Cover Order-N skip, balance sentinels, dividend pattern, generic cash in/out, header recognition (incl. the trailing comment).
4. **Registry + cross-file edits.** Update `CSVParserRegistry`, `CSVParser` doc comment, `CSVParserRegistryTests`, `CSVImportProfileMatcherTests`, `ImportStoreTestsMoreSecondHalf`, `TradeEventClassifier` comment. Delete legacy parser, tests, and fixtures.
5. **`just format`, `just build-mac`, `just test`.** Capture output to `.agent-tmp/`. Fix any warnings (warnings are errors per project config). Do not modify the SwiftLint baseline.
6. **PR + queue.** Push with explicit `src:dst`, open PR linking #601, add to merge queue.

## Acceptance criteria

- Both new parser test suites pass.
- `CSVParserRegistry` selects the right parser for each report's headers; `selfwealth-movements` wins over generic for movements headers; `selfwealth-cash-report` wins for cash-report headers.
- The end-to-end test in `ImportStoreTestsMoreSecondHalf` uses the new movements fixture and asserts on the new identifier + the three-leg trade shape.
- No reference to the string `"selfwealth"` (without `-movements` or `-cash-report` suffix) anywhere in `Shared/`, `Domain/`, or `MoolahTests/`.
- `just test` passes on both macOS and iOS targets.
- `just format-check` is clean. SwiftLint baseline unchanged.

## Out of scope

- Whether `TradeEventClassifier` folds brokerage into cost basis (#558).
- Any UX work on Failed Files / Needs Setup panels for the `In`/`Out` rows that the user might want to reclassify.
- Full coverage of every possible SelfWealth comment narration — the design treats unrecognised cash-report rows as opaque transfers with the comment preserved, so there's nothing left to enumerate.
