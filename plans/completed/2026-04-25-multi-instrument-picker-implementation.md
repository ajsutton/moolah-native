# Multi-Instrument Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Shared/Views/CurrencyPicker.swift` and the raw `Picker` constructions in `TransactionDetailView` with a single searchable picker that handles fiat, registered stocks/crypto, and Yahoo-validated stock discovery, gated by a per-call-site `kinds: Set<Instrument.Kind>` filter.

**Architecture:** Three small PRs in dependency order (1) `Instrument` symbol fix + `CurrencyPicker.selection` migrated from `Binding<String>` to `Binding<Instrument>`; (2) `InstrumentSearchService.search` gains a `providerSources` parameter that suppresses CoinGecko fan-out; (3) new `InstrumentPickerStore` + `InstrumentPickerSheet` + `InstrumentPickerField`, sweep all call sites, delete `CurrencyPicker.swift`. Crypto token registration stays gated by the existing `AddTokenSheet` (chain + contract path) — the picker only surfaces *registered* crypto. Stocks auto-register on tap via `InstrumentRegistryRepository.registerStock(_:)`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`#expect`), `@Observable` + `@MainActor`, `OSAllocatedUnfairLock`, XCUITest (one UI test only).

**Source spec:** `plans/2026-04-25-multi-instrument-picker-design.md` — read it before starting; the design doc explains *why* each phase exists.

---

## File Structure

| Path | Action | Phase |
|------|--------|-------|
| `Domain/Models/Instrument.swift` | Modify — add `preferredCurrencySymbol(for:)`, rewrite `currencySymbol`, add `localizedName(for:)` | PR-1 / PR-3 |
| `MoolahTests/Domain/InstrumentSymbolTests.swift` | Create | PR-1 |
| `Shared/Views/CurrencyPicker.swift` | Modify (PR-1: API change) → Delete (PR-3) | PR-1 / PR-3 |
| `Features/Settings/MoolahProfileDetailView.swift` | Modify (3 sub-views) | PR-1 / PR-3 |
| `Features/Profiles/Views/ProfileFormView.swift` | Modify | PR-1 / PR-3 |
| `Features/Profiles/Views/CreateProfileFormView.swift` | Modify | PR-1 / PR-3 |
| `Features/Accounts/Views/CreateAccountView.swift` | Modify | PR-1 / PR-3 |
| `Features/Accounts/Views/EditAccountView.swift` | Modify | PR-1 / PR-3 |
| `Features/Earmarks/Views/CreateEarmarkSheet.swift` | Modify | PR-1 / PR-3 |
| `Features/Earmarks/Views/EditEarmarkSheet.swift` | Modify | PR-1 / PR-3 |
| `Shared/InstrumentSearchService.swift` | Modify — `ProviderSources`, gate CoinGecko branch | PR-2 |
| `MoolahTests/Shared/InstrumentSearchServiceTests.swift` | Modify — add `providerSources: .stocksOnly` cases | PR-2 |
| `Shared/InstrumentPickerStore.swift` | Create | PR-3 |
| `MoolahTests/Shared/InstrumentPickerStoreTests.swift` | Create | PR-3 |
| `Shared/Views/InstrumentPickerSheet.swift` | Create | PR-3 |
| `Shared/Views/InstrumentPickerField.swift` | Create | PR-3 |
| `App/ProfileSession.swift` and `App/ProfileSession+Factories.swift` | Modify — expose `instrumentSearchService` (CloudKit only) | PR-3 |
| `Features/Transactions/Views/TransactionDetailView.swift` | Modify — drop `availableInstruments`, use `InstrumentPickerField` | PR-3 |
| `MoolahUITests_macOS/InstrumentPickerUITests.swift` | Create — one happy-path test | PR-3 |
| `UITestSupport/UITestSeeds.swift` | Modify — add a seed exposing the picker | PR-3 |

---

## Pre-flight

Worktree is already created at `.worktrees/multi-instrument-picker` on branch `feat/multi-instrument-picker`. The design doc and this plan are the only changes on the branch right now.

- [ ] **Pre-flight Step 1: Open the worktree shell context**

All commands below run with `git -C` and absolute paths so no `cd` is needed. Define a shorthand for the worktree path:

```bash
WT=/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/multi-instrument-picker
```

- [ ] **Pre-flight Step 2: Generate the Xcode project**

```bash
just -f "$WT/justfile" -d "$WT" generate
```

Expected: `Moolah.xcodeproj` regenerated; no diff to `project.yml` (this is a no-op regen).

- [ ] **Pre-flight Step 3: Establish a green baseline**

```bash
mkdir -p "$WT/.agent-tmp"
just -f "$WT/justfile" -d "$WT" test 2>&1 | tee "$WT/.agent-tmp/baseline.txt"
grep -i 'failed\|error:' "$WT/.agent-tmp/baseline.txt" | tail -20
```

Expected: zero matches from the grep. If anything fails on `main`, **stop** and report — don't start coding on a broken baseline.

- [ ] **Pre-flight Step 4: Commit and PR the docs**

```bash
git -C "$WT" add plans/2026-04-25-multi-instrument-picker-design.md plans/2026-04-25-multi-instrument-picker-implementation.md
git -C "$WT" commit -m "$(cat <<'EOF'
docs(plans): multi-instrument picker design + implementation plan

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git -C "$WT" push -u origin feat/multi-instrument-picker
gh pr create --repo ajsutton/moolah-native --base main --head feat/multi-instrument-picker \
  --title "docs(plans): multi-instrument picker design + plan" \
  --body "$(cat <<'EOF'
## Summary
- Design spec for the multi-instrument picker
- Implementation plan (three PR rollout)

No source changes. PRs implementing the plan will follow.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Then queue via the merge-queue skill (`merge-queue-ctl.sh`). Once the docs PR is queued, **freeze the `feat/multi-instrument-picker` branch** — every implementation PR opens its own branch off `main`.

---

## PR-1 — Currency binding migration

Branch: `feat/picker-pr1-currency-binding` (new worktree off `main`).

### Task 1.0: Set up PR-1 worktree

- [ ] **Step 1: Create the worktree**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add .worktrees/picker-pr1 -b feat/picker-pr1-currency-binding origin/main
WT1=/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/picker-pr1
just -f "$WT1/justfile" -d "$WT1" generate
```

- [ ] **Step 2: Confirm baseline**

```bash
just -f "$WT1/justfile" -d "$WT1" test-mac 2>&1 | tee "$WT1/.agent-tmp/baseline.txt"
grep -i 'failed\|error:' "$WT1/.agent-tmp/baseline.txt" | tail -10
```

Expected: zero failures.

### Task 1.1: Add `Instrument.preferredCurrencySymbol(for:)` (TDD)

**Files:**
- Test: `MoolahTests/Domain/InstrumentSymbolTests.swift` (new)
- Modify: `Domain/Models/Instrument.swift`

- [ ] **Step 1: Write the failing test**

Create `$WT1/MoolahTests/Domain/InstrumentSymbolTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("Instrument.preferredCurrencySymbol")
struct InstrumentSymbolTests {
  @Test("USD resolves to $ regardless of host locale")
  func usdSymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "USD") == "$")
  }

  @Test("GBP resolves to £")
  func gbpSymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "GBP") == "£")
  }

  @Test("EUR resolves to €")
  func eurSymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "EUR") == "€")
  }

  @Test("AUD resolves to $ via en_AU locale")
  func audSymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "AUD") == "$")
  }

  @Test("JPY resolves to ¥")
  func jpySymbol() {
    #expect(Instrument.preferredCurrencySymbol(for: "JPY") == "¥")
  }

  @Test("Unknown ISO code returns nil")
  func unknownCodeReturnsNil() {
    #expect(Instrument.preferredCurrencySymbol(for: "ZZZ") == nil)
  }

  @Test("Instance currencySymbol delegates to helper for fiat")
  func instanceSymbolDelegatesForFiat() {
    let usd = Instrument.fiat(code: "USD")
    #expect(usd.currencySymbol == "$")
  }

  @Test("Instance currencySymbol returns nil for non-fiat")
  func instanceSymbolNilForStock() {
    let stock = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
    #expect(stock.currencySymbol == nil)
  }
}
```

- [ ] **Step 2: Add the test file to the project**

Open `$WT1/project.yml`, find the `MoolahTests_macOS` and `MoolahTests_iOS` `sources:` blocks (they include `MoolahTests` recursively); the new file is picked up automatically. Run `just -f "$WT1/justfile" -d "$WT1" generate` to confirm no `project.yml` edits needed.

- [ ] **Step 3: Run tests — confirm RED**

```bash
just -f "$WT1/justfile" -d "$WT1" test-mac InstrumentSymbolTests 2>&1 | tee "$WT1/.agent-tmp/red.txt"
```

Expected: every test fails with `error: type 'Instrument' has no member 'preferredCurrencySymbol'` (or similar — `currencySymbol` exists on instances but not as a static helper).

- [ ] **Step 4: Implement the helper**

Modify `$WT1/Domain/Models/Instrument.swift`. At the top, add `import os` so `OSAllocatedUnfairLock` is available. Replace the existing `currencySymbol` block with:

```swift
import Foundation
import os

// (keep existing struct/enum declarations)

extension Instrument {
  /// Currency symbol from the currency's primary locale, not the user's.
  /// Returns nil when no representative locale produces a distinctive
  /// symbol (the result would just echo the ISO code).
  static func preferredCurrencySymbol(for code: String) -> String? {
    Self.symbolCache.withLock { cache in
      if let hit = cache[code] { return hit.value }
      let locale = Locale.availableIdentifiers
        .lazy
        .map(Locale.init(identifier:))
        .first { $0.currency?.identifier == code }
      let symbol = locale?.currencySymbol
      let resolved: String? = (symbol == nil || symbol == code) ? nil : symbol
      cache[code] = SymbolCacheEntry(value: resolved)
      return resolved
    }
  }

  private struct SymbolCacheEntry: Sendable { let value: String? }
  private static let symbolCache = OSAllocatedUnfairLock<[String: SymbolCacheEntry]>(
    initialState: [:]
  )
}
```

Replace the existing instance `currencySymbol` body with:

```swift
var currencySymbol: String? {
  guard kind == .fiatCurrency else { return nil }
  return Self.preferredCurrencySymbol(for: id)
}
```

- [ ] **Step 5: Run tests — confirm GREEN**

```bash
just -f "$WT1/justfile" -d "$WT1" test-mac InstrumentSymbolTests 2>&1 | tee "$WT1/.agent-tmp/green.txt"
grep -i 'failed\|error:' "$WT1/.agent-tmp/green.txt"
```

Expected: zero matches.

- [ ] **Step 6: Format and commit**

```bash
just -f "$WT1/justfile" -d "$WT1" format
just -f "$WT1/justfile" -d "$WT1" format-check
git -C "$WT1" add Domain/Models/Instrument.swift MoolahTests/Domain/InstrumentSymbolTests.swift
git -C "$WT1" commit -m "$(cat <<'EOF'
feat(domain): add Instrument.preferredCurrencySymbol(for:) locale-independent helper

The previous Instrument.currencySymbol used the user's locale, which
returns "USD" instead of "$" on en_AU. The new helper resolves through
the currency's representative locale so symbols are stable across hosts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.2: Migrate `CurrencyPicker.selection` to `Binding<Instrument>`

**Files:**
- Modify: `Shared/Views/CurrencyPicker.swift`
- Modify (call sites): the eight files listed in the design's §4.1 table

This is a mechanical type swap; the existing form-tests cover it via compile + downstream behaviour.

- [ ] **Step 1: Update `CurrencyPicker.swift`**

Replace the body of `$WT1/Shared/Views/CurrencyPicker.swift`:

```swift
import SwiftUI

struct CurrencyPicker: View {
  @Binding var selection: Instrument

  static let commonCurrencyCodes: [String] = [
    "AUD", "CAD", "CHF", "CNY", "EUR", "GBP", "HKD", "INR", "JPY", "KRW",
    "MXN", "NOK", "NZD", "SEK", "SGD", "USD", "ZAR",
  ]

  static func currencyName(for code: String) -> String {
    Locale.current.localizedString(forCurrencyCode: code) ?? code
  }

  private static let sortedCodes: [String] = commonCurrencyCodes.sorted {
    currencyName(for: $0).localizedCaseInsensitiveCompare(currencyName(for: $1))
      == .orderedAscending
  }

  var body: some View {
    Picker(
      "Currency",
      selection: Binding(
        get: { selection.id },
        set: { selection = Instrument.fiat(code: $0) }
      )
    ) {
      ForEach(Self.sortedCodes, id: \.self) { code in
        Text("\(code) — \(Self.currencyName(for: code))").tag(code)
      }
    }
    .pickerStyle(.menu)
  }
}

#Preview {
  @Previewable @State var selection: Instrument = .AUD
  Form {
    CurrencyPicker(selection: $selection)
  }
  .formStyle(.grouped)
}
```

- [ ] **Step 2: Build — confirm call sites break**

```bash
just -f "$WT1/justfile" -d "$WT1" build-mac 2>&1 | tee "$WT1/.agent-tmp/build.txt" | tail -40
```

Expected: 8 call sites fail with type-mismatch errors. Use those errors as a checklist for Step 3.

- [ ] **Step 3: Migrate the three Profile sites**

For each of `Features/Settings/MoolahProfileDetailView.swift` (three sub-views), `Features/Profiles/Views/ProfileFormView.swift`, `Features/Profiles/Views/CreateProfileFormView.swift`:

In each, find the line `@State private var currencyCode: String` (or `cloudCurrencyCode`). Replace with `@State private var currency: Instrument`. The corresponding initialiser/`onAppear` reads `profile.currencyCode` — wrap with `Instrument.fiat(code: profile.currencyCode)`. The save path that writes `updated.currencyCode = currencyCode` becomes `updated.currencyCode = currency.id`.

Pattern (MoolahProfileDetailView one sub-view, illustrative):

```swift
// Before:
@State private var currencyCode: String
init(profile: Profile, ...) {
  _currencyCode = State(initialValue: profile.currencyCode)
}
// in body:
CurrencyPicker(selection: $currencyCode)
  .onChange(of: currencyCode) { _, _ in saveChanges() }
// in saveChanges:
if currencyCode != profile.currencyCode {
  updated.currencyCode = currencyCode
}

// After:
@State private var currency: Instrument
init(profile: Profile, ...) {
  _currency = State(initialValue: Instrument.fiat(code: profile.currencyCode))
}
// in body:
CurrencyPicker(selection: $currency)
  .onChange(of: currency) { _, _ in saveChanges() }
// in saveChanges:
if currency.id != profile.currencyCode {
  updated.currencyCode = currency.id
}
```

There are *three* sub-views in `MoolahProfileDetailView.swift` (lines ~17, ~106, ~230) — apply the same transformation to each.

For the `TextField("Amount", value: $balanceDecimal, format: .currency(code: currencyCode))` in `CreateAccountView` (and any similar formatter call elsewhere), pass `currency.id`.

- [ ] **Step 4: Migrate the four Account/Earmark sites**

For each of `Features/Accounts/Views/CreateAccountView.swift`, `Features/Accounts/Views/EditAccountView.swift`, `Features/Earmarks/Views/CreateEarmarkSheet.swift`, `Features/Earmarks/Views/EditEarmarkSheet.swift`:

These views also currently hold a `@State currencyCode: String`. Two options:

a. **Mirror the Profile pattern** (simpler diff): rename `currencyCode` to `currency`, type as `Instrument`, convert at the boundary as in Step 3. Use this option.

b. Bind directly to the model's `Instrument` field. Defer this for a follow-up — too many side-effects (draft type changes, store signatures).

For option (a) the model boundary is also string-shaped today (these views read/write `.id`-equivalent strings into the draft). For example `CreateAccountView` ends up calling `try await store.create(... currencyCode: currency.id ...)`.

Apply the same `Instrument.fiat(code:)` ↔ `.id` conversion as the Profile sites.

- [ ] **Step 5: Build — confirm clean**

```bash
just -f "$WT1/justfile" -d "$WT1" build-mac 2>&1 | tee "$WT1/.agent-tmp/build2.txt" | tail -20
```

Expected: BUILD SUCCEEDED, zero warnings beyond the previously-baseline warnings.

- [ ] **Step 6: Run tests**

```bash
just -f "$WT1/justfile" -d "$WT1" test 2>&1 | tee "$WT1/.agent-tmp/full.txt"
grep -i 'failed\|error:' "$WT1/.agent-tmp/full.txt" | tail -20
```

Expected: zero matches.

- [ ] **Step 7: Format, review, commit**

```bash
just -f "$WT1/justfile" -d "$WT1" format
just -f "$WT1/justfile" -d "$WT1" format-check
```

Run the `code-review` agent over the diff. Address any non-trivial findings inline before committing.

```bash
git -C "$WT1" add Shared/Views/CurrencyPicker.swift Features/Settings/MoolahProfileDetailView.swift \
  Features/Profiles/Views/ProfileFormView.swift Features/Profiles/Views/CreateProfileFormView.swift \
  Features/Accounts/Views/CreateAccountView.swift Features/Accounts/Views/EditAccountView.swift \
  Features/Earmarks/Views/CreateEarmarkSheet.swift Features/Earmarks/Views/EditEarmarkSheet.swift
git -C "$WT1" commit -m "$(cat <<'EOF'
refactor(views): CurrencyPicker now binds to Instrument; migrate eight call sites

Pure type-level migration. CurrencyPicker.selection is now Binding<Instrument>;
each call site holds @State currency: Instrument and converts at the model
boundary (Instrument.fiat(code:) on read; .id on write). No behaviour change
for users.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.3: Open PR-1 and queue it

- [ ] **Step 1: Push and open PR**

```bash
git -C "$WT1" push -u origin feat/picker-pr1-currency-binding
gh pr create --repo ajsutton/moolah-native --base main \
  --head feat/picker-pr1-currency-binding \
  --title "feat(domain): preferredCurrencySymbol + CurrencyPicker on Instrument" \
  --body "$(cat <<'EOF'
## Summary
- Adds `Instrument.preferredCurrencySymbol(for:)` — locale-independent symbol resolution (fixes AUD/USD glyphing as "USD" on en_AU).
- `CurrencyPicker.selection` migrated from `Binding<String>` to `Binding<Instrument>`.
- All 8 fiat-only call sites migrated to `@State currency: Instrument`.

PR-1 of 3 in the multi-instrument-picker rollout. See `plans/2026-04-25-multi-instrument-picker-design.md`.

## Test plan
- [x] `just test` passes locally
- [x] `just format-check` clean
- [x] No new compiler warnings

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Add to merge queue**

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR_NUMBER>
```

(Get `<PR_NUMBER>` from the `gh pr create` output.)

---

## PR-2 — `providerSources` parameter on `InstrumentSearchService`

Branch: `feat/picker-pr2-provider-sources` (new worktree off `main`, after PR-1 has merged so the migration is in place).

### Task 2.0: Set up PR-2 worktree

- [ ] **Step 1: Sync and branch**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native fetch origin
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add .worktrees/picker-pr2 -b feat/picker-pr2-provider-sources origin/main
WT2=/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/picker-pr2
just -f "$WT2/justfile" -d "$WT2" generate
just -f "$WT2/justfile" -d "$WT2" test-mac 2>&1 | tee "$WT2/.agent-tmp/baseline.txt"
grep -i 'failed\|error:' "$WT2/.agent-tmp/baseline.txt" | tail -10
```

Expected: zero failures.

### Task 2.1: Add the `ProviderSources` parameter (TDD)

**Files:**
- Modify: `Shared/InstrumentSearchService.swift`
- Modify: `MoolahTests/Shared/InstrumentSearchServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `$WT2/MoolahTests/Shared/InstrumentSearchServiceTests.swift` (inside the existing struct):

```swift
@Test("providerSources: .stocksOnly suppresses crypto provider hits")
func stocksOnlyExcludesCryptoHits() async throws {
  let hits = [
    CryptoSearchHit(coingeckoId: "bitcoin", symbol: "BTC", name: "Bitcoin", thumbnail: nil)
  ]
  let service = makeSubject(cryptoHits: hits)
  let results = await service.search(
    query: "bitcoin",
    kinds: [.cryptoToken],
    providerSources: .stocksOnly
  )
  #expect(results.allSatisfy { $0.requiresResolution == false })
  #expect(results.contains { $0.instrument.ticker == "BTC" } == false)
}

@Test("providerSources: .stocksOnly still allows Yahoo stock hits")
func stocksOnlyAllowsStockHits() async throws {
  let validated = ValidatedStockTicker(ticker: "AAPL", exchange: "NASDAQ")
  let service = makeSubject(stockValidated: validated)
  let results = await service.search(
    query: "AAPL",
    kinds: [.stock],
    providerSources: .stocksOnly
  )
  #expect(results.contains { $0.instrument.ticker == "AAPL" })
}

@Test("providerSources: .all preserves existing behaviour")
func allPreservesExistingBehaviour() async throws {
  let hits = [
    CryptoSearchHit(coingeckoId: "ethereum", symbol: "ETH", name: "Ethereum", thumbnail: nil)
  ]
  let service = makeSubject(cryptoHits: hits)
  let results = await service.search(
    query: "ethereum",
    kinds: [.cryptoToken],
    providerSources: .all
  )
  #expect(results.contains { $0.instrument.ticker == "ETH" && $0.requiresResolution })
}
```

- [ ] **Step 2: Run tests — confirm RED**

```bash
just -f "$WT2/justfile" -d "$WT2" test-mac InstrumentSearchServiceTests 2>&1 | tee "$WT2/.agent-tmp/red.txt"
```

Expected: compile error — `extra argument 'providerSources' in call` or `cannot find 'ProviderSources'`.

- [ ] **Step 3: Implement the parameter**

Modify `$WT2/Shared/InstrumentSearchService.swift`:

Add at the top of the file (above the struct):

```swift
/// Controls which provider-search APIs the picker fans out to.
/// `.all` — registry + fiat + Yahoo + CoinGecko (current behaviour).
/// `.stocksOnly` — registry + fiat + Yahoo. Used by the multi-instrument
/// picker so unregistered crypto hits never surface (token registration
/// flows through `AddTokenSheet` instead, which defends against scam
/// tokens that share names with established ones).
enum ProviderSources: Sendable {
  case all
  case stocksOnly
}
```

Update the `search` signature:

```swift
func search(
  query: String,
  kinds: Set<Instrument.Kind> = Set(Instrument.Kind.allCases),
  providerSources: ProviderSources = .all
) async -> [InstrumentSearchResult] {
  // ... existing setup ...

  async let fiatResults: [InstrumentSearchResult] =
    kinds.contains(.fiatCurrency) ? fiatMatches(query: trimmed) : []
  async let cryptoResults: [InstrumentSearchResult] =
    (kinds.contains(.cryptoToken) && providerSources == .all)
      ? cryptoMatches(query: trimmed) : []
  async let stockResults: [InstrumentSearchResult] =
    kinds.contains(.stock) ? stockMatches(query: trimmed) : []

  // ... existing merge ...
}
```

(The only behavioural change is the `&& providerSources == .all` guard on `cryptoResults`. Nothing else moves.)

- [ ] **Step 4: Run tests — confirm GREEN**

```bash
just -f "$WT2/justfile" -d "$WT2" test-mac InstrumentSearchServiceTests 2>&1 | tee "$WT2/.agent-tmp/green.txt"
grep -i 'failed\|error:' "$WT2/.agent-tmp/green.txt"
```

Expected: zero matches.

- [ ] **Step 5: Format, review, commit**

```bash
just -f "$WT2/justfile" -d "$WT2" format
just -f "$WT2/justfile" -d "$WT2" format-check
git -C "$WT2" add Shared/InstrumentSearchService.swift MoolahTests/Shared/InstrumentSearchServiceTests.swift
git -C "$WT2" commit -m "$(cat <<'EOF'
feat(shared): add ProviderSources param to InstrumentSearchService.search

`.all` (default) preserves current behaviour. `.stocksOnly` suppresses
the CoinGecko fan-out and is used by the multi-instrument picker so
unregistered crypto hits never surface (registration flows through
AddTokenSheet, which defends against scam tokens).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 2.2: Open PR-2 and queue it

- [ ] **Step 1: Push and open PR**

```bash
git -C "$WT2" push -u origin feat/picker-pr2-provider-sources
gh pr create --repo ajsutton/moolah-native --base main \
  --head feat/picker-pr2-provider-sources \
  --title "feat(shared): InstrumentSearchService.providerSources" \
  --body "$(cat <<'EOF'
## Summary
- Adds `ProviderSources` enum and `providerSources: ProviderSources = .all` parameter to `InstrumentSearchService.search`.
- `.stocksOnly` suppresses CoinGecko fan-out for the upcoming picker.
- Default is `.all` so no other callers move.

PR-2 of 3 in the multi-instrument-picker rollout.

## Test plan
- [x] `InstrumentSearchServiceTests` extended with three new cases
- [x] Existing tests remain green

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR_NUMBER>
```

---

## PR-3 — Picker + sheet + sweep

Branch: `feat/picker-pr3-sheet-and-sweep` (new worktree off `main`, after PR-2 has merged).

### Task 3.0: Set up PR-3 worktree

- [ ] **Step 1: Sync and branch**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native fetch origin
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add .worktrees/picker-pr3 -b feat/picker-pr3-sheet-and-sweep origin/main
WT3=/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/picker-pr3
just -f "$WT3/justfile" -d "$WT3" generate
just -f "$WT3/justfile" -d "$WT3" test-mac 2>&1 | tee "$WT3/.agent-tmp/baseline.txt"
grep -i 'failed\|error:' "$WT3/.agent-tmp/baseline.txt" | tail -10
```

Expected: zero failures.

### Task 3.1: Add `Instrument.localizedName(for:)` helper (TDD)

**Files:**
- Modify: `Domain/Models/Instrument.swift`
- Modify: `MoolahTests/Domain/InstrumentSymbolTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `$WT3/MoolahTests/Domain/InstrumentSymbolTests.swift`:

```swift
@Test("localizedName falls back to the ISO code for unknown currencies")
func localizedNameFallback() {
  #expect(Instrument.localizedName(for: "ZZZ") == "ZZZ")
}

@Test("localizedName resolves common currencies")
func localizedNameKnown() {
  // Don't assert exact strings — locale-dependent. Just assert non-empty,
  // not equal to the ISO code (a real localised name was returned).
  let name = Instrument.localizedName(for: "USD")
  #expect(!name.isEmpty)
  #expect(name != "USD")
}
```

- [ ] **Step 2: Run — confirm RED**

```bash
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentSymbolTests 2>&1 | tee "$WT3/.agent-tmp/red.txt"
```

Expected: `type 'Instrument' has no member 'localizedName'`.

- [ ] **Step 3: Implement**

In the same `extension Instrument` block in `$WT3/Domain/Models/Instrument.swift`:

```swift
/// Locale-localised currency name for an ISO code, or the code itself
/// if the locale can't resolve it. Replaces `CurrencyPicker.currencyName(for:)`.
static func localizedName(for code: String) -> String {
  Locale.current.localizedString(forCurrencyCode: code) ?? code
}
```

- [ ] **Step 4: Run — confirm GREEN**

```bash
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentSymbolTests 2>&1 | tee "$WT3/.agent-tmp/green.txt"
grep -i 'failed\|error:' "$WT3/.agent-tmp/green.txt"
```

Expected: zero matches.

- [ ] **Step 5: Format, commit**

```bash
just -f "$WT3/justfile" -d "$WT3" format
git -C "$WT3" add Domain/Models/Instrument.swift MoolahTests/Domain/InstrumentSymbolTests.swift
git -C "$WT3" commit -m "$(cat <<'EOF'
feat(domain): add Instrument.localizedName(for:)

Replaces CurrencyPicker.currencyName(for:) ahead of CurrencyPicker's
deletion in the picker sweep.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3.2: Build the `InstrumentPickerStore` test scaffold + empty-query test (TDD)

**Files:**
- Create: `MoolahTests/Shared/InstrumentPickerStoreTests.swift`
- Create: `Shared/InstrumentPickerStore.swift`

The store wraps `InstrumentSearchService`. Tests use a real `InstrumentSearchService` constructed with stub providers for crypto/stock and the `TestBackend` registry. We're not mocking the registry per the project rule.

- [ ] **Step 1: Write the failing test**

Create `$WT3/MoolahTests/Shared/InstrumentPickerStoreTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("InstrumentPickerStore")
@MainActor
struct InstrumentPickerStoreTests {
  @Test("start() yields registered + ambient fiat for fiat-only kinds")
  func startYieldsFiatList() async {
    let backend = TestBackend()
    let service = InstrumentSearchService(
      registry: backend.instrumentRegistry,
      cryptoSearchClient: StubCryptoSearchClient(),
      resolutionClient: StubTokenResolutionClient(),
      stockValidator: StubStockTickerValidator()
    )
    let store = InstrumentPickerStore(
      searchService: service,
      registry: backend.instrumentRegistry,
      kinds: [.fiatCurrency]
    )
    await store.start()
    #expect(store.results.contains { $0.instrument.id == "USD" })
    #expect(store.results.allSatisfy { $0.instrument.kind == .fiatCurrency })
  }
}

private struct StubCryptoSearchClient: CryptoSearchClient {
  func search(query: String) async throws -> [CryptoSearchHit] { [] }
}

private struct StubTokenResolutionClient: TokenResolutionClient {
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    .init()
  }
}

private struct StubStockTickerValidator: StockTickerValidator {
  let validated: ValidatedStockTicker?
  init(validated: ValidatedStockTicker? = nil) { self.validated = validated }
  func validate(query: String) async throws -> ValidatedStockTicker? { validated }
}
```

(Note: `TestBackend` already exposes `instrumentRegistry` for CloudKit-backed test profiles. Verify by reading `MoolahTests/Support/TestBackend.swift`. If it doesn't expose `instrumentRegistry` directly, construct one inline using the existing `CloudKitInstrumentRegistryRepository(modelContainer:)` initialiser pointed at `backend.modelContainer`.)

- [ ] **Step 2: Run — confirm RED**

```bash
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentPickerStoreTests 2>&1 | tee "$WT3/.agent-tmp/red.txt"
```

Expected: `cannot find 'InstrumentPickerStore' in scope`.

- [ ] **Step 3: Create the store with a minimal `start()` only**

Create `$WT3/Shared/InstrumentPickerStore.swift`:

```swift
import Foundation
import OSLog

@MainActor
@Observable
final class InstrumentPickerStore {
  private(set) var query: String = ""
  private(set) var results: [InstrumentSearchResult] = []
  private(set) var isLoading: Bool = false
  private(set) var error: String?

  let kinds: Set<Instrument.Kind>

  private let searchService: InstrumentSearchService
  private let registry: any InstrumentRegistryRepository
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "InstrumentPickerStore")

  init(
    searchService: InstrumentSearchService,
    registry: any InstrumentRegistryRepository,
    kinds: Set<Instrument.Kind>
  ) {
    self.searchService = searchService
    self.registry = registry
    self.kinds = kinds
  }

  func start() async {
    await runSearch()
  }

  private func runSearch() async {
    isLoading = true
    defer { isLoading = false }
    let snapshot = await searchService.search(
      query: query,
      kinds: kinds,
      providerSources: .stocksOnly
    )
    results = snapshot
  }
}
```

- [ ] **Step 4: Run — confirm GREEN**

```bash
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentPickerStoreTests 2>&1 | tee "$WT3/.agent-tmp/green.txt"
grep -i 'failed\|error:' "$WT3/.agent-tmp/green.txt"
```

Expected: zero matches.

- [ ] **Step 5: Commit**

```bash
just -f "$WT3/justfile" -d "$WT3" format
git -C "$WT3" add Shared/InstrumentPickerStore.swift MoolahTests/Shared/InstrumentPickerStoreTests.swift
git -C "$WT3" commit -m "$(cat <<'EOF'
feat(shared): add InstrumentPickerStore (empty-query path)

Backs the new picker sheet. Wraps InstrumentSearchService with
.stocksOnly providerSources so unregistered crypto hits never surface.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3.3: Typed-query path (TDD)

- [ ] **Step 1: Add the failing test**

Append to `InstrumentPickerStoreTests`:

```swift
@Test("typed query narrows to matching ISO codes")
func typedQueryNarrows() async {
  let backend = TestBackend()
  let service = InstrumentSearchService(
    registry: backend.instrumentRegistry,
    cryptoSearchClient: StubCryptoSearchClient(),
    resolutionClient: StubTokenResolutionClient(),
    stockValidator: StubStockTickerValidator()
  )
  let store = InstrumentPickerStore(
    searchService: service,
    registry: backend.instrumentRegistry,
    kinds: [.fiatCurrency]
  )
  await store.start()
  store.updateQuery("usd")
  // Wait one debounce tick.
  try? await Task.sleep(for: .milliseconds(350))
  #expect(store.results.contains { $0.instrument.id == "USD" })
  #expect(store.results.allSatisfy { $0.instrument.id.lowercased().contains("usd") || $0.instrument.name.localizedCaseInsensitiveContains("dollar") })
}
```

- [ ] **Step 2: Run — confirm RED**

```bash
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentPickerStoreTests/typedQueryNarrows 2>&1 | tee "$WT3/.agent-tmp/red.txt"
```

Expected: `value of type 'InstrumentPickerStore' has no member 'updateQuery'`.

- [ ] **Step 3: Implement debounced `updateQuery(_:)`**

Add to `InstrumentPickerStore`:

```swift
private var searchTask: Task<Void, Never>?

func updateQuery(_ s: String) {
  query = s
  searchTask?.cancel()
  searchTask = Task { [weak self] in
    try? await Task.sleep(for: .milliseconds(250))
    if Task.isCancelled { return }
    await self?.runSearch()
  }
}
```

- [ ] **Step 4: Run — confirm GREEN**

```bash
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentPickerStoreTests/typedQueryNarrows 2>&1 | tee "$WT3/.agent-tmp/green.txt"
grep -i 'failed\|error:' "$WT3/.agent-tmp/green.txt"
```

- [ ] **Step 5: Commit**

```bash
just -f "$WT3/justfile" -d "$WT3" format
git -C "$WT3" add Shared/InstrumentPickerStore.swift MoolahTests/Shared/InstrumentPickerStoreTests.swift
git -C "$WT3" commit -m "feat(shared): debounced updateQuery on InstrumentPickerStore"
```

### Task 3.4: Selection — registered + Yahoo auto-register paths (TDD)

- [ ] **Step 1: Add the failing tests**

Append:

```swift
@Test("select of registered fiat returns the instrument without registry write")
func selectRegisteredFiat() async {
  let backend = TestBackend()
  let service = InstrumentSearchService(
    registry: backend.instrumentRegistry,
    cryptoSearchClient: StubCryptoSearchClient(),
    resolutionClient: StubTokenResolutionClient(),
    stockValidator: StubStockTickerValidator()
  )
  let store = InstrumentPickerStore(
    searchService: service,
    registry: backend.instrumentRegistry,
    kinds: [.fiatCurrency]
  )
  await store.start()
  let usd = store.results.first { $0.instrument.id == "USD" }!
  let picked = await store.select(usd)
  #expect(picked?.id == "USD")
  // Registry should be unchanged: no new stock/crypto rows added.
  let registered = try! await backend.instrumentRegistry.all()
  #expect(registered.allSatisfy { $0.kind == .fiatCurrency })
}

@Test("select of unregistered Yahoo stock auto-registers and returns")
func selectStockAutoRegisters() async {
  let backend = TestBackend()
  let validated = ValidatedStockTicker(ticker: "AAPL", exchange: "NASDAQ")
  let service = InstrumentSearchService(
    registry: backend.instrumentRegistry,
    cryptoSearchClient: StubCryptoSearchClient(),
    resolutionClient: StubTokenResolutionClient(),
    stockValidator: StubStockTickerValidator(validated: validated)
  )
  let store = InstrumentPickerStore(
    searchService: service,
    registry: backend.instrumentRegistry,
    kinds: Set(Instrument.Kind.allCases)
  )
  store.updateQuery("AAPL")
  try? await Task.sleep(for: .milliseconds(350))
  let hit = store.results.first { $0.instrument.ticker == "AAPL" }!
  #expect(hit.isRegistered == false)
  let picked = await store.select(hit)
  #expect(picked?.ticker == "AAPL")
  let registered = try! await backend.instrumentRegistry.all()
  #expect(registered.contains { $0.id == "NASDAQ:AAPL" })
}
```

- [ ] **Step 2: Run — confirm RED**

```bash
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentPickerStoreTests 2>&1 | tee "$WT3/.agent-tmp/red.txt"
```

Expected: `value of type 'InstrumentPickerStore' has no member 'select'`.

- [ ] **Step 3: Implement `select(_:)`**

```swift
func select(_ result: InstrumentSearchResult) async -> Instrument? {
  if result.isRegistered { return result.instrument }
  do {
    try await registry.registerStock(result.instrument)
    return result.instrument
  } catch {
    logger.error(
      "Stock registration failed: \(error, privacy: .public)")
    self.error = "Couldn't add \(result.instrument.displayLabel)."
    return nil
  }
}
```

- [ ] **Step 4: Run — confirm GREEN**

```bash
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentPickerStoreTests 2>&1 | tee "$WT3/.agent-tmp/green.txt"
grep -i 'failed\|error:' "$WT3/.agent-tmp/green.txt"
```

- [ ] **Step 5: Commit**

```bash
just -f "$WT3/justfile" -d "$WT3" format
git -C "$WT3" add Shared/InstrumentPickerStore.swift MoolahTests/Shared/InstrumentPickerStoreTests.swift
git -C "$WT3" commit -m "feat(shared): select() on InstrumentPickerStore — auto-registers Yahoo stocks"
```

### Task 3.5: `kinds` filter test (TDD)

- [ ] **Step 1: Add the failing test**

```swift
@Test("kinds: [.fiatCurrency] excludes registered stocks")
func kindsFilterExcludesStocks() async throws {
  let backend = TestBackend()
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  try await backend.instrumentRegistry.registerStock(bhp)
  let service = InstrumentSearchService(
    registry: backend.instrumentRegistry,
    cryptoSearchClient: StubCryptoSearchClient(),
    resolutionClient: StubTokenResolutionClient(),
    stockValidator: StubStockTickerValidator()
  )
  let store = InstrumentPickerStore(
    searchService: service,
    registry: backend.instrumentRegistry,
    kinds: [.fiatCurrency]
  )
  await store.start()
  #expect(store.results.allSatisfy { $0.instrument.kind == .fiatCurrency })
  #expect(store.results.contains { $0.instrument.id == "ASX:BHP.AX" } == false)
}
```

- [ ] **Step 2 — Run, confirm GREEN already**

The `kinds` filter is enforced by `InstrumentSearchService` and we pass it through. So this test should pass without additional code.

```bash
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentPickerStoreTests 2>&1 | tee "$WT3/.agent-tmp/green.txt"
grep -i 'failed\|error:' "$WT3/.agent-tmp/green.txt"
```

Expected: zero. If it fails, fix the store to forward `kinds` correctly to the service.

- [ ] **Step 3: Commit**

```bash
git -C "$WT3" add MoolahTests/Shared/InstrumentPickerStoreTests.swift
git -C "$WT3" commit -m "test(shared): kinds filter excludes registered stocks for fiat-only picker"
```

### Task 3.6: Wire `InstrumentSearchService` into `ProfileSession`

**Files:**
- Modify: `App/ProfileSession.swift`
- Modify: `App/ProfileSession+Factories.swift`

The picker reads `InstrumentSearchService` from `@Environment` via `BackendProvider` or directly from the active `ProfileSession`. Add a `instrumentSearchService: InstrumentSearchService?` property to `ProfileSession`, populated only for CloudKit profiles (others have no registry).

- [ ] **Step 1: Add the property**

In `App/ProfileSession.swift`, add alongside `instrumentRegistry`:

```swift
let instrumentSearchService: InstrumentSearchService?
```

Update the initialiser to accept and assign it.

- [ ] **Step 2: Construct the search service in `makeRegistryWiring`**

In `App/ProfileSession+Factories.swift`, the `RegistryWiring` struct currently bundles `(registry, cryptoTokenStore)`. Add a `searchService: InstrumentSearchService?` field. Inside `makeRegistryWiring`, when the backend is a `CloudKitBackend`, also build the search service. `CoinGeckoSearchClient` and `YahooFinanceStockTickerValidator` are not currently constructed anywhere in the App layer — wire them up here. The token-resolution client `CompositeTokenResolutionClient` is already used in `makeCryptoPriceService` (`App/ProfileSession+Factories.swift:61`); pass the same instance through (lift its construction into a parameter or share via the existing `cryptoPriceService`).

```swift
@MainActor
static func makeRegistryWiring(
  backend: BackendProvider,
  cryptoPriceService: CryptoPriceService,
  yahooPriceFetcher: any YahooFinancePriceFetcher,
  coinGeckoApiKey: String?
) -> RegistryWiring {
  guard let cloudBackend = backend as? CloudKitBackend else {
    return RegistryWiring(registry: nil, cryptoTokenStore: nil, searchService: nil)
  }
  let store = CryptoTokenStore(
    registry: cloudBackend.instrumentRegistry,
    cryptoPriceService: cryptoPriceService)
  let searchService = InstrumentSearchService(
    registry: cloudBackend.instrumentRegistry,
    cryptoSearchClient: CoinGeckoSearchClient(apiKey: coinGeckoApiKey),
    resolutionClient: CompositeTokenResolutionClient(coinGeckoApiKey: coinGeckoApiKey),
    stockValidator: YahooFinanceStockTickerValidator(priceFetcher: yahooPriceFetcher)
  )
  return RegistryWiring(
    registry: cloudBackend.instrumentRegistry,
    cryptoTokenStore: store,
    searchService: searchService
  )
}
```

Update the call site (search for `makeRegistryWiring(`) to pass the existing `yahooPriceFetcher` and `coinGeckoApiKey` already in scope. `cryptoPriceService` already has these dependencies, so they are reachable from the same factory. If `yahooPriceFetcher` isn't currently lifted to a parameter, extract it from `StockPriceService` or whatever service holds it (grep `YahooFinancePriceFetcher\b`).

For non-CloudKit profiles, the `searchService` is `nil`.

- [ ] **Step 3: Pass the service into `ProfileSession`**

The `ProfileSession.init` (or its caller) reads `RegistryWiring.searchService` and assigns to `self.instrumentSearchService`.

- [ ] **Step 2: Build, no test changes**

```bash
just -f "$WT3/justfile" -d "$WT3" build-mac 2>&1 | tee "$WT3/.agent-tmp/build.txt" | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
just -f "$WT3/justfile" -d "$WT3" format
git -C "$WT3" add App/ProfileSession.swift App/ProfileSession+Factories.swift
git -C "$WT3" commit -m "feat(app): expose InstrumentSearchService on CloudKit ProfileSession"
```

### Task 3.7: Build `InstrumentPickerSheet`

**Files:**
- Create: `Shared/Views/InstrumentPickerSheet.swift`

Thin SwiftUI view; UI test in 3.10 covers the user-visible behaviour.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct InstrumentPickerSheet: View {
  @Bindable var store: InstrumentPickerStore
  let label: LocalizedStringResource
  @Binding var selection: Instrument
  @Binding var isPresented: Bool

  var body: some View {
    NavigationStack {
      List {
        if let error = store.error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
        ForEach(store.results) { result in
          row(for: result)
        }
        if store.results.isEmpty && !store.query.isEmpty {
          ContentUnavailableView(
            "No matches",
            systemImage: "magnifyingglass",
            description: Text(
              "No matching currencies, stocks, or registered tokens for \"\(store.query)\".")
          )
        }
        if store.kinds.contains(.cryptoToken) {
          Section {
            Text("Add a crypto token in Settings → Crypto Tokens.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      .searchable(
        text: Binding(
          get: { store.query },
          set: { store.updateQuery($0) }
        )
      )
      .navigationTitle("Choose \(String(localized: label))")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { isPresented = false }
        }
      }
    }
    .accessibilityIdentifier("instrumentPicker.sheet")
    #if os(macOS)
      .frame(minWidth: 400, minHeight: 480)
    #endif
    .task { await store.start() }
  }

  @ViewBuilder
  private func row(for result: InstrumentSearchResult) -> some View {
    Button {
      Task {
        if let chosen = await store.select(result) {
          selection = chosen
          isPresented = false
        }
      }
    } label: {
      HStack(spacing: 10) {
        glyph(for: result.instrument)
        VStack(alignment: .leading, spacing: 1) {
          Text(result.instrument.id).fontWeight(.medium)
          Text(result.instrument.name)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !result.isRegistered {
          Text("Add")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
        }
        if result.instrument == selection {
          Image(systemName: "checkmark").foregroundStyle(.tint)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("instrumentPicker.row.\(result.instrument.id)")
  }

  private func glyph(for instrument: Instrument) -> some View {
    let label: String =
      instrument.kind == .fiatCurrency
      ? (Instrument.preferredCurrencySymbol(for: instrument.id) ?? instrument.id)
      : (instrument.ticker ?? instrument.id)
    return Text(label)
      .font(.system(size: 12, weight: .semibold))
      .frame(width: 28, height: 28)
      .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
  }
}
```

(`store.kinds` needs to be exposed — already public per the store.)

- [ ] **Step 2: Build**

```bash
just -f "$WT3/justfile" -d "$WT3" build-mac 2>&1 | tee "$WT3/.agent-tmp/build.txt" | tail -20
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
just -f "$WT3/justfile" -d "$WT3" format
git -C "$WT3" add Shared/Views/InstrumentPickerSheet.swift
git -C "$WT3" commit -m "feat(views): add InstrumentPickerSheet"
```

### Task 3.8: Build `InstrumentPickerField`

**Files:**
- Create: `Shared/Views/InstrumentPickerField.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct InstrumentPickerField: View {
  let label: LocalizedStringResource
  let kinds: Set<Instrument.Kind>
  @Binding var selection: Instrument

  @Environment(ProfileSession.self) private var session
  @State private var isPresented = false
  @State private var store: InstrumentPickerStore?

  var body: some View {
    Button {
      ensureStore()
      isPresented = true
    } label: {
      LabeledContent(String(localized: label)) {
        HStack(spacing: 6) {
          glyph
          Text(selection.id).fontWeight(.medium)
          Image(systemName: "chevron.right")
            .foregroundStyle(.tertiary)
            .font(.caption)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("instrumentPicker.field.\(selection.id)")
    .sheet(isPresented: $isPresented) {
      if let store {
        InstrumentPickerSheet(
          store: store, label: label,
          selection: $selection, isPresented: $isPresented)
      }
    }
  }

  private var glyph: some View {
    let labelText: String =
      selection.kind == .fiatCurrency
      ? (Instrument.preferredCurrencySymbol(for: selection.id) ?? selection.id)
      : (selection.ticker ?? selection.id)
    return Text(labelText)
      .font(.system(size: 11, weight: .semibold))
      .frame(width: 22, height: 22)
      .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
  }

  private func ensureStore() {
    guard store == nil,
      let service = session.instrumentSearchService,
      let registry = session.instrumentRegistry
    else { return }
    store = InstrumentPickerStore(
      searchService: service,
      registry: registry,
      kinds: kinds
    )
  }
}
```

(Verify the environment injection pattern: `@Environment(ProfileSession.self)` works because `ProfileSession` is `@Observable` and injected at the root. If a different injection key is used in this codebase — e.g. `@Environment(\.profileSession)` — adapt.)

- [ ] **Step 2: Build**

```bash
just -f "$WT3/justfile" -d "$WT3" build-mac 2>&1 | tee "$WT3/.agent-tmp/build.txt" | tail -20
```

- [ ] **Step 3: Commit**

```bash
just -f "$WT3/justfile" -d "$WT3" format
git -C "$WT3" add Shared/Views/InstrumentPickerField.swift
git -C "$WT3" commit -m "feat(views): add InstrumentPickerField"
```

### Task 3.9: Sweep — replace CurrencyPicker, replace TransactionDetailView Pickers, delete CurrencyPicker.swift

**Files:**
- Modify: 8 fiat call sites (same set as Task 1.2)
- Modify: `Features/Transactions/Views/TransactionDetailView.swift`
- Delete: `Shared/Views/CurrencyPicker.swift`

- [ ] **Step 1: Replace 8 fiat-only sites**

In each of the eight files migrated in Task 1.2, change `CurrencyPicker(selection: $currency)` to:

```swift
InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)
```

The `@State currency: Instrument` declaration stays as-is (already migrated in PR-1).

- [ ] **Step 2: Migrate `TransactionDetailView.swift`**

a. Remove the `availableInstruments` parameter from the public initialiser. Update all callers (search for `TransactionDetailView(`) — most callers don't pass it, relying on the default. Any caller that does pass an explicit list: drop the argument; the new picker covers all kinds.

b. Replace the top-level currency picker (where the transaction's instrument is bound) with:

```swift
InstrumentPickerField(
  label: "Asset",
  kinds: Set(Instrument.Kind.allCases),
  selection: $draft.instrument  // adapt to the actual binding
)
```

c. Replace `legCurrencyPicker(at:)` with the same field bound to the leg's instrument. The leg's binding currently uses `instrumentId` (a String); add a `@State private var knownInstruments: [Instrument] = []` to the view and a `.task` that loads from `session.instrumentRegistry?.all()` on appear:

```swift
@State private var knownInstruments: [Instrument] = []

private func resolveInstrument(_ id: String) -> Instrument {
  // Any registered (stock/crypto) id is in `knownInstruments`. Unknown ids
  // are fiat ISO codes — the picker only writes back ids that resolve to
  // a real instrument, so this fallback is safe.
  knownInstruments.first { $0.id == id } ?? Instrument.fiat(code: id)
}

@ViewBuilder
private func legCurrencyPicker(at index: Int) -> some View {
  let binding = Binding<Instrument>(
    get: {
      let id = draft.legDrafts[index].instrumentId ?? legInstrumentId(at: index)
      return resolveInstrument(id)
    },
    set: { draft.legDrafts[index].instrumentId = $0.id }
  )
  InstrumentPickerField(
    label: "Asset",
    kinds: Set(Instrument.Kind.allCases),
    selection: binding
  )
}
```

Attach the loader once at the view level:

```swift
.task {
  knownInstruments = (try? await session.instrumentRegistry?.all()) ?? []
}
```

d. Drop any remaining references to `CurrencyPicker.commonCurrencyCodes` and `CurrencyPicker.currencyName(for:)` — replace with `Instrument.localizedName(for:)`.

- [ ] **Step 3: Delete `CurrencyPicker.swift`**

```bash
git -C "$WT3" rm Shared/Views/CurrencyPicker.swift
```

- [ ] **Step 4: Build**

```bash
just -f "$WT3/justfile" -d "$WT3" build-mac 2>&1 | tee "$WT3/.agent-tmp/build.txt" | tail -40
```

Expected: BUILD SUCCEEDED. Any remaining `CurrencyPicker` reference fails the build — use the error list as a checklist.

- [ ] **Step 5: Run all tests**

```bash
just -f "$WT3/justfile" -d "$WT3" test 2>&1 | tee "$WT3/.agent-tmp/full.txt"
grep -i 'failed\|error:' "$WT3/.agent-tmp/full.txt" | tail -20
```

Expected: zero failures.

- [ ] **Step 6: Format, code-review, commit**

```bash
just -f "$WT3/justfile" -d "$WT3" format
just -f "$WT3/justfile" -d "$WT3" format-check
```

Run the `code-review` agent over the diff (it's a substantial change). Then run `ui-review` over the new sheet/field views.

```bash
git -C "$WT3" add -u
git -C "$WT3" add Shared/Views/InstrumentPickerSheet.swift Shared/Views/InstrumentPickerField.swift
git -C "$WT3" commit -m "$(cat <<'EOF'
feat(views): replace CurrencyPicker with InstrumentPickerField across all sites

Eight fiat-only sites and TransactionDetailView (top + per-leg) now use the
new searchable picker. The transaction-detail view loses its static
availableInstruments parameter — the picker covers fiat + registered
stocks/crypto + Yahoo-validated stock discovery.

CurrencyPicker.swift is deleted; CurrencyPicker.currencyName(for:) callers
moved to Instrument.localizedName(for:).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 3.10: UI test (one happy-path)

**Files:**
- Create: `MoolahUITests_macOS/InstrumentPickerUITests.swift`
- Modify: `UITestSupport/UITestSeeds.swift` if a new seed is needed

Per `guides/UI_TEST_GUIDE.md`: tests import only `XCTest`; drivers under `MoolahUITests_macOS` or `UITestSupport`.

- [ ] **Step 1: Add or reuse a seed that opens TransactionDetailView**

Read `$WT3/UITestSupport/UITestSeeds.swift` and find a seed that lands the app on a transaction detail view. If one exists, reuse it; otherwise add a `transactionWithInstrumentPicker` seed.

- [ ] **Step 2: Write the UI test**

Create `$WT3/MoolahUITests_macOS/InstrumentPickerUITests.swift`. Follow the screen-driver pattern of an existing test (e.g. `MoolahUITests_macOS/TransactionDetailUITests.swift` if present; otherwise model on the simplest existing UI test).

The test:
1. Launch with a seed that opens a transaction in detail view.
2. Tap the leg's `instrumentPicker.field.<id>` button.
3. Wait for `instrumentPicker.sheet`.
4. Type "USD" via `.searchable` field.
5. Tap `instrumentPicker.row.USD`.
6. Assert the field now shows `USD`.

- [ ] **Step 3: Build and run**

```bash
just -f "$WT3/justfile" -d "$WT3" generate
just -f "$WT3/justfile" -d "$WT3" test-mac InstrumentPickerUITests 2>&1 | tee "$WT3/.agent-tmp/uitest.txt"
grep -i 'failed\|error:' "$WT3/.agent-tmp/uitest.txt" | tail -20
```

Expected: zero failures.

- [ ] **Step 4: Run `ui-test-review` agent**

This is a UI test under `MoolahUITests_macOS/` — the agent description requires it. Address findings inline.

- [ ] **Step 5: Format and commit**

```bash
just -f "$WT3/justfile" -d "$WT3" format
git -C "$WT3" add MoolahUITests_macOS/InstrumentPickerUITests.swift UITestSupport/UITestSeeds.swift
git -C "$WT3" commit -m "test(ui): InstrumentPicker happy-path UI test"
```

### Task 3.11: Final verification + queue PR-3

- [ ] **Step 1: Full test run**

```bash
just -f "$WT3/justfile" -d "$WT3" test 2>&1 | tee "$WT3/.agent-tmp/final.txt"
grep -i 'failed\|error:' "$WT3/.agent-tmp/final.txt" | tail -20
```

- [ ] **Step 2: Format check**

```bash
just -f "$WT3/justfile" -d "$WT3" format-check
```

- [ ] **Step 3: Compiler warnings**

Use `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` (per CLAUDE.md). Fix anything in user code; ignore `#Preview` macro warnings.

- [ ] **Step 4: Open PR-3**

```bash
git -C "$WT3" push -u origin feat/picker-pr3-sheet-and-sweep
gh pr create --repo ajsutton/moolah-native --base main \
  --head feat/picker-pr3-sheet-and-sweep \
  --title "feat(views): multi-instrument picker (sheet + sweep + delete CurrencyPicker)" \
  --body "$(cat <<'EOF'
## Summary
- New `InstrumentPickerStore`, `InstrumentPickerSheet`, `InstrumentPickerField`.
- Eight fiat-only call sites migrated to `InstrumentPickerField(kinds: [.fiatCurrency])`.
- `TransactionDetailView` (top + per-leg) migrated to `InstrumentPickerField(kinds: <all>)`; `availableInstruments` parameter dropped.
- `CurrencyPicker.swift` deleted; `CurrencyPicker.currencyName(for:)` callers moved to `Instrument.localizedName(for:)`.
- One UI test: search "USD" in a transaction leg picker and confirm selection.

PR-3 of 3 in the multi-instrument-picker rollout. See `plans/2026-04-25-multi-instrument-picker-design.md`.

## Test plan
- [x] `InstrumentPickerStoreTests` covers empty-query, typed-query, select-registered, select-stock-auto-register, kinds filter
- [x] `InstrumentSearchServiceTests` `.stocksOnly` cases stay green (PR-2)
- [x] One UI test: `InstrumentPickerUITests`
- [x] All existing tests still green
- [x] `just format-check` clean
- [x] No new compiler warnings

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR_NUMBER>
```

---

## Post-merge cleanup

After PR-3 merges:

- [ ] **Step 1: Move both planning docs to `plans/completed/`**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add .worktrees/picker-cleanup -b chore/picker-plans-completed origin/main
WTC=/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/picker-cleanup
git -C "$WTC" mv plans/2026-04-25-multi-instrument-picker-design.md plans/completed/
git -C "$WTC" mv plans/2026-04-25-multi-instrument-picker-implementation.md plans/completed/
git -C "$WTC" commit -m "chore(plans): move multi-instrument picker plans to completed"
git -C "$WTC" push -u origin chore/picker-plans-completed
gh pr create --repo ajsutton/moolah-native --base main --head chore/picker-plans-completed \
  --title "chore(plans): move multi-instrument picker plans to completed" \
  --body "Cleanup after PR-3 merge."
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR_NUMBER>
```

- [ ] **Step 2: Tear down worktrees**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/multi-instrument-picker
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/picker-pr1
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/picker-pr2
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/picker-pr3
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/picker-cleanup
```

---

## Spec coverage check

| Design section | Tasks |
|---|---|
| §3.1 `Instrument.preferredCurrencySymbol` | Task 1.1 |
| §3.2 `InstrumentPickerField` | Tasks 3.8, 3.9 |
| §3.3 `InstrumentPickerSheet` | Tasks 3.7, 3.10 |
| §3.4 `InstrumentPickerStore` | Tasks 3.2, 3.3, 3.4, 3.5 |
| §3.5 `providerSources` | Task 2.1 |
| §4.1 8 fiat sites migration | Tasks 1.2, 3.9 |
| §4.2 `TransactionDetailView` migration | Task 3.9 |
| §5 UI / UX (sheet, field, states, accessibility) | Tasks 3.7, 3.8 |
| §6 testing | Tasks 1.1, 2.1, 3.2–3.5, 3.10 |
| §7 rollout (3 PRs in order) | PR-1, PR-2, PR-3 |
