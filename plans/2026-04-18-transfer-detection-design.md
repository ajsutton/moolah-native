# Transfer Detection & Merge — Design Spec

**Status:** Draft · 2026-04-18
**Depends on:** `plans/2026-04-18-csv-import-design.md` (CSV import pipeline, `ImportOrigin` on each transaction).

---

## Goal

When a user imports activity from multiple accounts that they own, Moolah should surface opposing pairs (money out of account A, money in to account B) as candidate transfers, let the user merge them into a single transfer transaction with one tap, and let them unmerge a transfer if the detection or a manual merge was wrong. The user should also be able to manually select any two transactions on different accounts and merge them into a transfer.

This is explicitly a **follow-up** to CSV import. The main import pipeline ships without auto-detection; this spec adds it later without changing the import pipeline's shape.

## Success criteria

- After an import session that touches two or more of the user's accounts, candidate transfers are flagged in the Recently Added view without prompting the user — they see a "Possible transfer →" affordance on the two matching rows.
- One tap merges a candidate pair into a two-leg transfer transaction, removing the two single-leg transactions.
- One tap on "Not a transfer" dismisses the suggestion permanently for that specific pair so it doesn't resurface.
- User can multi-select two transactions on different accounts from the Transactions view and merge them into a transfer via a command.
- User can unmerge any transfer transaction back into two separate single-leg transactions, preserving each leg's `ImportOrigin`.
- No user-visible duplicates: after a merge, the two source transactions are gone; after an unmerge, the transfer is gone.

## Scope

**In scope:**
- Automatic detection of candidate transfer pairs across Moolah accounts after any import session or on-demand scan.
- Per-pair suggestion flag stored on both transactions.
- Merge one pair into a two-leg transfer (preserves date, amount, notes; chooses the cash-out leg's date as canonical; combines notes).
- Manual merge of two user-selected transactions on different accounts.
- Unmerge a transfer back into two single-leg transactions.
- Per-pair "dismiss forever" so a rejected suggestion doesn't come back.
- Rules-driven transfers (the `markAsTransfer` action in the CSV import spec) remain the preferred path for known recurring transfers; this feature handles the long tail.

**Out of scope:**
- Matching against external (non-Moolah) accounts.
- Cross-currency transfers (both legs must be in the same instrument; detection skips mismatched-currency pairs in v1).
- Fuzzy-amount matching (e.g., "±1 cent" for bank rounding differences). Exact amount match only in v1.
- Multi-leg transfers (a single incoming leg matched to multiple outgoing legs or vice versa). v1 is strictly 1-to-1 pair matching.

## User experience

### Automatic detection

Runs at the end of every import session — once all files in the session have been parsed, deduped, and persisted, the detection pass scans the just-imported set for candidate pairs.

**Candidate criteria (all must hold):**
- Two transactions on **different** Moolah accounts.
- Each transaction is **single-leg** (cash only). Multi-leg transactions — trades, existing transfers — are never candidates. (This excludes brokerage buy/sell from accidentally pairing with a coincidental same-amount cash flow elsewhere.)
- Same **instrument** on both single legs.
- **Leg quantities opposite and equal** (`tx.legs[0].quantity == -counterpart.legs[0].quantity`).
- **Dates within ±3 days** of each other.
- Neither is already a transfer.
- Neither already has a dismissed-pair marker against the other.

When a candidate pair is found, each transaction gets a lightweight annotation referencing the other:

```swift
struct TransferSuggestion: Codable, Sendable, Hashable {
    let counterpartTransactionId: UUID
    let suggestedAt: Date
}

// New field on Transaction:
var transferSuggestion: TransferSuggestion?
```

The annotation is synced via the existing transaction sync path; both devices see the suggestion consistently.

### Surface: Recently Added and transaction detail

- In the **Recently Added** view, rows with a `transferSuggestion` render a subtle inline pill: `↔ Possible transfer to <Account Name>`. Tapping the pill expands an inline action bar: *Merge as transfer* · *Not a transfer*.
- In the **transaction detail** view, a banner at the top surfaces the suggestion with the same two actions.
- The sidebar badge on Recently Added is unchanged in v1 (it counts uncategorised transactions; transfer suggestions do not contribute to the badge — rationale: suggestions are ambient, not a review backlog).

### Merge (auto or manual)

A merge produces a single `Transaction` with:
- `date`: the *earlier* of the two source dates (typically the outgoing/cash-out date).
- `legs`: two `TransactionLeg` values, one per source account, each carrying the source leg's `accountId`, `instrument`, and `quantity`. Each leg's type becomes `.transfer`.
- `payee`: the counterpart account's name ("Transfer to Savings" for the outgoing-perspective) — or, if both sides had identical payees, that shared payee.
- `notes`: concatenation of the two source notes separated by `\n`, with duplicates collapsed.
- `importOrigin`: the two source `ImportOrigin` values collapsed into a pair stored on the merged transaction so the bank-side detail is still available for audit and dedup against future re-imports.

**Data shape** — the simplest approach: store two `ImportOrigin` values on the transfer transaction:

```swift
struct MergedImportOrigin: Codable, Sendable, Hashable {
    let outgoing: ImportOrigin?
    let incoming: ImportOrigin?
}
```

`Transaction.importOrigin` is upgraded from a single optional to a union that can hold either a single `ImportOrigin` (for single-account imports) or a `MergedImportOrigin` (for merged transfers). Details in Data Model Changes below.

The merge is atomic: the two source transactions are deleted and the merged transfer is inserted in a single repository operation. If the operation fails, neither state change persists.

### Manual merge

- From the main **Transactions** view, select two transactions on different accounts (multi-select). A "Merge as transfer" command appears in the toolbar and context menu.
- Validation: amounts must be opposite and equal, instruments must match, dates within ±14 days (looser than auto-detection — the user is asserting intent). If validation fails, show a sheet explaining which rule failed.
- The merged result is identical to auto-merge.

### Dismiss suggestion

Tapping "Not a transfer" on a suggestion stores a `DismissedTransferPair` record:

```swift
struct DismissedTransferPair: Codable, Sendable, Hashable {
    let transactionIds: Set<UUID>   // always two ids, unordered
    let dismissedAt: Date
}
```

The dismissal is checked during detection — any candidate pair whose two ids match an existing dismissal is skipped. Stored in a repository, synced.

If the user later deletes one of the two transactions, its dismissal record becomes irrelevant and can be pruned. Pruning isn't critical (records are small) and can be handled opportunistically.

### Unmerge

On a transfer transaction, a context action **Split back into separate transactions** reverses the merge:

- Produces two new `Transaction` values, one per leg, each a single-leg transaction on the original account.
- Each restored transaction's `importOrigin` is the corresponding `MergedImportOrigin.outgoing` / `.incoming`.
- The original transfer transaction is deleted.
- The newly-split transactions **do not** get a `transferSuggestion` auto-created against each other — otherwise the user who just unmerged would be immediately nagged to remerge. Instead, a dismissal record is created covering the new ids.

If the unmerge atomically fails (e.g., repository error), the transfer is preserved and no split happens.

## Detection trigger points

1. **End of import session.** Detection runs after every completed import (folder watch, file picker, paste, drag-drop). Scoped to the import session's transactions *plus* recent transactions from other accounts (sliding window of the session's date range ±3 days on all other accounts that the user owns).
2. **On-demand scan.** A "Scan for transfer candidates" command in Settings or Recently Added runs the detection across all accounts for a user-chosen date range. Useful after a large migration.

Detection is not triggered on every manual transaction edit — that would be noisy. Users who add transactions manually can run the on-demand scan if they want.

## Data model changes

1. **`Transaction.transferSuggestion: TransferSuggestion?`** — new field, synced. Populated by detection, cleared by merge or dismiss.

2. **`Transaction.importOrigin`** — changes from `ImportOrigin?` to a sum type:

    ```swift
    enum TransactionImportOrigin: Codable, Sendable, Hashable {
        case single(ImportOrigin)
        case merged(MergedImportOrigin)
    }

    // on Transaction:
    var importOrigin: TransactionImportOrigin?
    ```

    The CSV import spec stores `.single(...)` for every imported transaction; merges produce `.merged(...)`; unmerges restore `.single(...)` on each resulting transaction. Sync encodes the enum discriminator.

3. **New model: `DismissedTransferPair`** with a repository (CRUD + query by id pair). Synced.

4. **No new "import session" model** — this spec continues to use the CSV import spec's `importSessionId` on `ImportOrigin` to identify the session whose transactions should participate in detection.

## Algorithm

**Detection, scoped to a session's transactions plus a ±3-day window on other accounts:**

```text
newlyImported = transactions created in this session
existingNearby = transactions on accounts ≠ newlyImported's accounts
                 whose date is within ±3 days of newlyImported's min…max

for each tx in newlyImported where tx.legs.count == 1:
    let leg = tx.legs[0]

    for each counterpart in (newlyImported ∪ existingNearby) where counterpart.legs.count == 1:
        let other = counterpart.legs[0]
        if other.accountId == leg.accountId: continue
        if other.instrument != leg.instrument: continue
        if other.quantity != -leg.quantity: continue
        if abs(counterpart.date - tx.date) > 3 days: continue
        if tx or counterpart is already a transfer: continue
        if DismissedTransferPair exists for {tx.id, counterpart.id}: continue

        if either already has a transferSuggestion to another tx:
            prefer the closer-dated one (break ties deterministically by id)

        write transferSuggestion on both tx and counterpart referencing each other
```

**Manual merge:** the user supplies the pair explicitly; we skip the window/date constraint (still enforce opposite amounts, matching instrument, different accounts, neither already a transfer).

**Unmerge:** read the transfer's two legs; construct two new single-leg transactions using the stored `MergedImportOrigin` values; delete the transfer; atomically persist the result; record a dismissal covering the new pair to prevent immediate re-suggestion.

## Interaction with rules

- The CSV import spec's `RuleAction.markAsTransfer(toAccountId:)` is the *preferred* path for recurring, known transfers (e.g., mortgage payment from Everyday to Home Loan). Rules run before detection, so a rule-produced transfer is never considered a candidate for pairing — it's already a transfer.
- Detection therefore fills the long tail: one-off transfers, transfers between accounts the user hasn't encoded a rule for, and transfers detected across a freshly imported multi-file session.
- Users who find themselves dismissing the same pair shape repeatedly can promote it to a `markAsTransfer` rule via the standard "Create a rule from this…" affordance (starting from either source transaction).

## Testing

1. **Detection unit tests** — happy-path pair identification across accounts; same-account rejection; amount mismatch; instrument mismatch; date-window boundaries; already-transfer skip; dismissal-aware skip.
2. **Merge tests** — correct two-leg shape; merged `importOrigin`; date selection; notes concatenation; atomicity (simulate failure mid-merge, verify rollback).
3. **Unmerge tests** — round-trip correctness (merge → unmerge yields two transactions with original import origins); atomicity; automatic dismissal to prevent immediate re-suggestion.
4. **Manual merge tests** — validation errors; looser ±14-day window; cross-account requirement.
5. **End-to-end tests** (`TestBackend`) — import two files from different accounts with matching opposing rows; verify suggestions surface; tap merge; verify final state; tap dismiss on another pair; verify it stays dismissed after a re-scan.
6. **Sync tests** — a merge on one device is reflected on another; a dismissal on one device is respected by a later on-demand scan on another device.

Fixture files live alongside the CSV import fixtures; the tests use paired CSVs (e.g., `cba-everyday.csv` + `cba-savings.csv` with a known internal transfer on 2026-03-10).

## Open questions

1. **Currency mismatch handling.** If the user has accounts in different currencies, the transfer still happens (convert-on-debit) but the amounts aren't numerically opposite. v1 explicitly skips currency-mismatched pairs. A future v2 could attempt to pair using FX-rate heuristics, but it's noisy — easy to skip in v1 and revisit if users ask.
2. **Detection window beyond ±3 days.** Some pending transfers (Friday outgoing, Tuesday incoming because of weekends + public holiday) might exceed ±3 days. If this comes up, we widen; v1 errs tight because false positives annoy more than false negatives.
3. **UI for bulk dismissal.** If a user has lots of suggestions from a large migration, we may want a "Dismiss all in this session" affordance. Punt until data shows it matters.
