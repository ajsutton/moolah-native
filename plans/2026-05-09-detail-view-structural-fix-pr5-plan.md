# Detail-View Structural Fix — PR-5 (Multi-instrument split move) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the multi-instrument positions split (`shouldShowPositionsSplit` + `PositionsTransactionsSplit` wrap + the positions-valuator `.task(id:)`) out of `TransactionListView` and into the leaves that need it (`StandardAccountView`, `CryptoWalletAccountView`). `TransactionListView`'s body becomes provably uniform — just `transactionsList` (a `List` + sectioning + the standard modifier chain), no conditional wrapper.

**Architecture:** Extract the split logic into a reusable `View` extension (`.multiInstrumentPositionsSplit(positions:hostCurrency:title:conversionService:registrationsVersion:)`) backed by a `MultiInstrumentPositionsSplitModifier` view modifier. The modifier owns its own `@State positionsInput` / `@State positionsRange`, runs the valuator `.task(id:)`, and conditionally wraps its content in `PositionsTransactionsSplit` when the account has positions in non-host instruments. Both `StandardAccountView` and `CryptoWalletAccountView` apply the modifier to their `TransactionListView`. `TransactionListView` drops all five positions-related parameters (`positions`, `positionsHostCurrency`, `positionsTitle`, `conversionService`, `registrationsVersion`), the `shouldShowPositionsSplit` computed, the `listView` wrapper, the `positionsInput` / `positionsRange` state, the `.task(id: PositionsTaskKey)` modifier, and the `PositionsTaskKey` struct. `InvestmentAccountView`'s `positionTrackedLayout` is unaffected — it uses `PositionsTransactionsSplit` directly with chart-specific autosave + initial height, not the modifier.

**Tech Stack:** Swift 6.2, SwiftUI (macOS 26+ / iOS 26+), Xcode 26, `xcodegen`, swift-format, SwiftLint, just.

**Scope:** PR-5 of 5 (the final cleanup). PR-1/2/3/4 are queued. This branch stacks on PR-4's head.

**Spec:** `plans/2026-05-09-detail-view-structural-fix-design.md` §7 PR-5 ("pure refactor; no behaviour change"). The spec only mentions `StandardAccountView`; `CryptoWalletAccountView` is included here because it needs the same wrap (a crypto wallet typically holds multiple instruments).

**Worktree:** `/Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/` on branch `worktree-detail-view-structural-fix-pr5`. Branched off PR-4's head with `--no-track`.

---

## Task 1: Create the `MultiInstrumentPositionsSplitModifier`

**Files:**
- Create: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`

- [ ] **Step 1: Write the modifier**

```swift
import SwiftUI

/// Conditionally wraps a `TransactionListView` (or any other content)
/// in a `PositionsTransactionsSplit` when the account has positions in
/// instruments other than its host currency. Owns the positions
/// valuator `.task(id:)` so the wrapping leaf doesn't need to manage
/// the valuation lifecycle.
///
/// **Decision predicate** — `shouldShow` returns true iff there are
/// positions AND the set of non-zero instruments contains anything
/// other than the host currency. This matches the predicate that used
/// to live inside `TransactionListView.shouldShowPositionsSplit`.
///
/// **Re-fire trigger** — the `.task(id:)` re-fires whenever the
/// positions list changes OR the crypto-registry version bumps (e.g.
/// the user marks a token as `.spam`). Without the version dimension
/// a spam flip in preferences would leave a stale `valuedPositions`
/// on screen — see issue #790 for the original rationale.
struct MultiInstrumentPositionsSplitModifier: ViewModifier {
  let positions: [Position]
  let hostCurrency: Instrument
  let title: String
  let conversionService: (any InstrumentConversionService)?
  let registrationsVersion: Int

  @State private var positionsInput: PositionsViewInput?
  @State private var positionsRange: PositionsTimeRange = .threeMonths

  private var shouldShow: Bool {
    guard !positions.isEmpty else { return false }
    let nonZeroInstruments = Set(
      positions.lazy.filter { $0.quantity != 0 }.map(\.instrument)
    )
    return nonZeroInstruments != [hostCurrency]
  }

  func body(content: Content) -> some View {
    if shouldShow {
      PositionsTransactionsSplit(defaultTab: .transactions) {
        if let positionsInput {
          PositionsView(input: positionsInput, range: $positionsRange)
        } else {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
        }
      } transactions: {
        content
      }
      .task(id: PositionsTaskKey(positions: positions, registrationsVersion: registrationsVersion)) {
        await valuatePositions()
      }
    } else {
      content
    }
  }

  private func valuatePositions() async {
    guard let conversionService, !positions.isEmpty else {
      positionsInput = nil
      return
    }
    let valuator = PositionsValuator(conversionService: conversionService)
    let rows = await valuator.valuate(
      positions: positions,
      hostCurrency: hostCurrency,
      costBasis: [:],
      on: Date()
    )
    // The valuator cooperates with cancellation by breaking out of its
    // per-row loop, but it cannot signal cancellation through the
    // non-throwing return — re-check here so a stale (or partial) `rows`
    // from a superseded task never overwrites the freshly-emitting one.
    guard !Task.isCancelled else { return }
    positionsInput = PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: rows,
      historicalValue: nil
    )
  }
}

/// Composite id for the positions-valuation `.task(id:)`. Re-fires when
/// the positions list changes OR when the crypto-registry version bumps
/// (spam flip in preferences). Issue #790.
private struct PositionsTaskKey: Hashable {
  let positions: [Position]
  let registrationsVersion: Int
}

extension View {
  /// Wraps the view in a `PositionsTransactionsSplit` when the account
  /// has positions in non-host-currency instruments. No-op otherwise.
  /// Owns the positions valuator lifecycle.
  func multiInstrumentPositionsSplit(
    positions: [Position],
    hostCurrency: Instrument,
    title: String,
    conversionService: (any InstrumentConversionService)?,
    registrationsVersion: Int = 0
  ) -> some View {
    modifier(
      MultiInstrumentPositionsSplitModifier(
        positions: positions,
        hostCurrency: hostCurrency,
        title: title,
        conversionService: conversionService,
        registrationsVersion: registrationsVersion))
  }
}
```

- [ ] **Step 2: Regenerate, build, format**

```bash
mkdir -p /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/.agent-tmp

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
     generate 2>&1 | tail -3

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
     format

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
     format-check 2>&1 | tail -3

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
     build-mac 2>&1 | tail -5
```

Expected: clean. The new file is unused so far.

- [ ] **Step 3: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
    add Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
    commit -m "$(cat <<'EOF'
feat(transactions): add MultiInstrumentPositionsSplitModifier

Extracts the multi-instrument positions split logic that currently
lives inside TransactionListView (the `shouldShowPositionsSplit`
predicate, the `PositionsTransactionsSplit` wrap, and the positions-
valuator `.task(id:)`) into a reusable view modifier. The modifier
owns its own `@State positionsInput` / `@State positionsRange` so
callers don't need to thread positions valuation lifecycle.

Public API: `View.multiInstrumentPositionsSplit(positions:hostCurrency:
title:conversionService:registrationsVersion:)`.

The modifier is unused in this commit; the next two commits migrate
StandardAccountView and CryptoWalletAccountView to apply it, and the
fourth commit removes the now-redundant logic from TransactionListView.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Apply the modifier in `StandardAccountView` and `CryptoWalletAccountView`

**Files:**
- Modify: `Features/Accounts/Views/StandardAccountView.swift`
- Modify: `Features/Crypto/CryptoWalletAccountView.swift`

- [ ] **Step 1: Update `StandardAccountView`**

Replace the body's `TransactionListView(...)` call. Drop the `positions`, `positionsHostCurrency`, `positionsTitle`, `conversionService` arguments to `TransactionListView` (they will become unsupported in Task 3). Apply the new modifier instead:

```swift
struct StandardAccountView: View {
  let account: Account
  let positions: [Position]
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let conversionService: any InstrumentConversionService

  var body: some View {
    TransactionListView(
      title: account.name,
      filter: TransactionFilter(accountId: account.id),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore)
    .multiInstrumentPositionsSplit(
      positions: positions,
      hostCurrency: account.instrument,
      title: account.name,
      conversionService: conversionService)
  }
}
```

`AllTransactionsView` (in the same file) doesn't need the modifier — it has no per-account positions.

- [ ] **Step 2: Update `CryptoWalletAccountView`**

Same pattern — drop the positions args from `TransactionListView` and apply the modifier:

```swift
struct CryptoWalletAccountView: View {
  let account: Account
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let positions: [Position]
  let conversionService: any InstrumentConversionService
  let session: ProfileSession

  var body: some View {
    VStack(spacing: 0) {
      walletHeader
      TransactionListView(
        title: account.name,
        filter: TransactionFilter(accountId: account.id),
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore)
      .multiInstrumentPositionsSplit(
        positions: positions,
        hostCurrency: account.instrument,
        title: account.name,
        conversionService: conversionService,
        registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0)
    }
  }

  @ViewBuilder private var walletHeader: some View {
    // … unchanged …
  }
}
```

**Important:** the modifier MUST be applied to the `TransactionListView` call directly (chained on it), NOT to the outer `VStack`. Wrapping the VStack would put the wallet header inside the positions split's transactions slot, which is wrong — the wallet header should remain above both the positions and the transactions.

- [ ] **Step 3: Build (still expecting failures because TransactionListView still has the old parameters)**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
     build-mac 2>&1 | tail -10
```

Expected: build SUCCEEDS. TransactionListView still accepts the dropped parameters as defaults (`positions: [Position] = []`, etc.) so the call sites without them are valid. The new modifier wraps the call. No errors.

- [ ] **Step 4: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
    add Features/Accounts/Views/StandardAccountView.swift Features/Crypto/CryptoWalletAccountView.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
    commit -m "$(cat <<'EOF'
refactor(accounts, crypto): apply multiInstrumentPositionsSplit modifier

StandardAccountView and CryptoWalletAccountView drop the positions /
positionsHostCurrency / positionsTitle / conversionService /
registrationsVersion arguments to TransactionListView and apply the
new `.multiInstrumentPositionsSplit(...)` modifier instead. The leaves
now own the multi-instrument split decision and lifecycle directly.

For CryptoWalletAccountView the modifier chains on the
TransactionListView (NOT the outer VStack) so the wallet header stays
above both the positions panel and the transactions list, matching
the pre-refactor visual.

Build still passes because TransactionListView's positions parameters
remain (with defaults) until the next commit removes them entirely.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Strip the positions surface out of `TransactionListView` + `+List`

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift`
- Modify: `Features/Transactions/Views/TransactionListView+List.swift`

This is the load-bearing cleanup. After this commit, `TransactionListView`'s body shape is provably uniform.

- [ ] **Step 1: Drop parameters from both inits in `TransactionListView.swift`**

Drop these declared properties:
- `var positions: [Position] = []`
- `var positionsHostCurrency: Instrument = .AUD`
- `var positionsTitle: String = "Balances"`
- `var conversionService: (any InstrumentConversionService)?`
- `var registrationsVersion: Int = 0`

Drop these state declarations:
- `@State var positionsInput: PositionsViewInput?`
- `@State var positionsRange: PositionsTimeRange = .threeMonths`

Drop the corresponding parameters from BOTH inits (default + embedded-with-binding):
- `positions: [Position] = []`
- `positionsHostCurrency: Instrument = .AUD`
- `positionsTitle: String = "Balances"`
- `conversionService: (any InstrumentConversionService)? = nil`
- `registrationsVersion: Int = 0`

And drop the `self.positions = positions`, etc. assignments from both inits.

- [ ] **Step 2: Replace `body` with direct `transactionsList` reference**

The current body:
```swift
var body: some View {
  listView
    .modifier(OptionalTransactionInspector(...))
    // … rest of the chain …
}
```

`listView` is the `if shouldShowPositionsSplit { PositionsTransactionsSplit { … } } else { transactionsList }` branch in `+List.swift`. Replace `listView` with `transactionsList`:

```swift
var body: some View {
  transactionsList
    .modifier(OptionalTransactionInspector(...))
    // … rest of the chain unchanged …
}
```

- [ ] **Step 3: Drop `shouldShowPositionsSplit`, `listView`, the positions `.task(id:)`, and `PositionsTaskKey` from `TransactionListView+List.swift`**

In `Features/Transactions/Views/TransactionListView+List.swift`:

- Delete the `shouldShowPositionsSplit` computed property (lines 8-18 of the current file).
- Delete the `listView` `@ViewBuilder` (lines 20-36).
- Inside `transactionsList`'s modifier chain, delete the entire `.task(id: PositionsTaskKey(positions: positions, registrationsVersion: registrationsVersion)) { … }` block (lines 103-132). The `.task(id: activeFilter)` block above it stays.
- Delete the `PositionsTaskKey` private struct at the bottom of the file (line 351 area).

`transactionsList` is now the public entry point (was the only thing inside `listView`'s else branch).

- [ ] **Step 4: Make `transactionsList` accessible to `body`**

`transactionsList` is currently `private var transactionsList: some View { … }` (in `+List.swift`). Since `TransactionListView`'s `body` (in the main `.swift` file) now references it directly, change to `internal` (drop the `private`):

```swift
var transactionsList: some View { … }
```

Or — cleaner — keep it on the extension, and make sure the body in the main file can see it (it's in the same module/type, so visibility-internal is fine).

- [ ] **Step 5: Format + build**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
     format

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
     format-check 2>&1 | tail -3

just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
     build-mac 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/.agent-tmp/build-task3.txt | tail -10
```

Expected: clean build. The `Features/Transactions/Views/TransactionListView+Preview.swift` may still pass dropped parameters — if so, drop them. Same for any other call sites; grep `positions:` after `TransactionListView(` to find them.

- [ ] **Step 6: Run the test suite**

```bash
just --justfile /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/justfile \
     --working-directory /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
     test 2>&1 | tee /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5/.agent-tmp/test.txt | tail -10
```

Expected: full suite (2629 iOS + 2654 macOS) passes. The refactor is behaviour-preserving.

- [ ] **Step 7: Commit**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
    add Features/Transactions/Views/TransactionListView.swift Features/Transactions/Views/TransactionListView+List.swift

git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
    commit -m "$(cat <<'EOF'
refactor(transactions): drop positions surface from TransactionListView

The multi-instrument positions split is now owned by the leaves that
need it (StandardAccountView, CryptoWalletAccountView) via the new
`.multiInstrumentPositionsSplit(...)` modifier added in the previous
commits. TransactionListView no longer has any positions-aware
behaviour — its body is uniformly `transactionsList` (a List + sections
+ the standard modifier chain), with no conditional wrapper.

Removed:
- `positions`, `positionsHostCurrency`, `positionsTitle`,
  `conversionService`, `registrationsVersion` parameters from both
  inits + their property declarations.
- `@State positionsInput`, `@State positionsRange`.
- `shouldShowPositionsSplit` computed property.
- `listView` @ViewBuilder (the if/else wrapper around `transactionsList`).
- The positions-valuator `.task(id: PositionsTaskKey)` modifier.
- The `PositionsTaskKey` private struct.

The body shape is now provably uniform by inspection — closes the
last remaining structural-shape branch in TransactionListView's view
tree. No behaviour change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Pre-PR review pass

- [ ] **Step 1: Run `code-review` agent**

Dispatch with prompt covering: the new `MultiInstrumentPositionsSplitModifier` (Sendable / @MainActor isolation, @State on a ViewModifier semantics, the `.task(id:)` cancellation discipline), the leaf migrations (correct modifier placement on TransactionListView NOT the outer VStack in CryptoWalletAccountView), the TransactionListView strip-down (no orphaned references, body is now uniform).

Fix every Critical and Important finding before pushing.

- [ ] **Step 2: Run `ui-review` agent**

Dispatch with prompt covering: visual equivalence pre/post (split shows when it should, hides when it shouldn't), the wallet header still sits above the split in CryptoWalletAccountView, no regression to InvestmentAccountView's positionTrackedLayout (which uses PositionsTransactionsSplit directly with its own configuration).

Fix every Critical and Important finding before pushing.

---

## Task 5: Push and open PR

- [ ] **Step 1: Push with explicit src:dst**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/detail-view-structural-fix-pr5 \
    push origin worktree-detail-view-structural-fix-pr5:worktree-detail-view-structural-fix-pr5 2>&1 | tail -5
```

- [ ] **Step 2: Open the PR with base=main and merge-queue add**

```bash
gh -R ajsutton/moolah-native pr create \
   --base main \
   --head worktree-detail-view-structural-fix-pr5 \
   --title "refactor(transactions): move multi-instrument positions split into account leaves" \
   --body "..."

PR_NUMBER=$(gh -R ajsutton/moolah-native pr list --head worktree-detail-view-structural-fix-pr5 --json number --jq '.[0].number')
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add "$PR_NUMBER"
```

Body should explain the refactor, the new modifier API, the lack of behaviour change, the InvestmentAccountView non-impact, and the stacking on PR-4 (#834) → PR-3 (#830) → PR-2 (#829) → PR-1 (#827).

---

## Plan complete

PR-5 finishes the structural fix. After PR-5 merges, every transaction-list leaf uses the canonical `TransactionListView` with a uniform body, and the only positions-aware leaves apply the modifier explicitly. Issues #824 and #826 remain as separate follow-ups.
