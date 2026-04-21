# Transaction Detail Focus — Implementation Plan

Companion to `2026-04-21-transaction-detail-focus-design.md`. Sequences the
work so that each step either advances the fix or *resolves an open
question*, and the work bails out early if a lesser change proves sufficient.

The design doc lists four open questions. This plan treats them as gating
experiments rather than post-hoc concerns: the implementation order below
is structured to answer them while the minimum code is in flight.

## Phase 0 — Prep

Single worktree off `main`. Implementation ships as one PR but in visible
commits so any phase can be kept / reverted independently.

```
git -C <repo> worktree add .worktrees/proper-focus-fix -b fix/focus-proper main
just generate
```

Exit: worktree builds clean (`just build-mac`), existing tests pass.

## Phase 1 — Audit write sites of `selectedTransaction` (answers Q1)

**Question answered:** "Does every writer of `selectedTransaction` feed a
UUID that already lives in the store, or do any write paths mint a fresh
UUID and thus re-create the same ⌘N race?"

**Steps**

1. Grep for every write site:
   ```
   git grep -n 'selectedTransaction\s*=' Features/ App/
   ```
   Expected sites (current knowledge — verify with the grep):
   - `TransactionListView.openTransaction` (row click)
   - `TransactionListView.createNewTransaction` (⌘N, account-attached and
     earmark-only branches)
   - `TransactionListView.onReceive(NotificationCenter ...)` for
     `.requestTransactionEdit`
   - `focusedSceneValue(\.selectedTransaction, ...)` consumers in
     `ProfileWindowView` / menu-command plumbing
   - Any URL-scheme handler in `App/` that routes `moolah://.../transaction/<uuid>`
2. For each site, classify:
   - **Safe** — the `Transaction` already exists in the store's
     `rawTransactions` and carries a UUID from there.
   - **At-risk** — the site manufactures a new UUID via `UUID()` or
     `Transaction(id: UUID(), ...)`.
3. Write findings to a short note on the PR / in the plan's "Findings"
   section below. For each at-risk site, propose whether it should be
   migrated to the UUID-preserving pattern or left alone (e.g. not a
   ⌘N-equivalent entry point).

**Exit criteria**

- A concrete list of at-risk write sites (may be empty).
- For each, a decision: migrate in this PR / out of scope / not actually
  a problem.

**If exit shows no at-risk sites other than `createNewTransaction`:**
Phases 3–4 already cover it. Proceed.
**If new at-risk sites surface:** fold their migration into Phase 4 or
split to a follow-up PR if they're independent flows.

## Phase 2 — Backend field-diff audit (answers Q3)

**Question answered:** "Does `CloudKitTransactionRepository.create` return
a transaction whose fields differ from the input? If yes, the detail
view's `draft` (initialised once in `init`) could go stale when Change 2
prevents the view recreation that currently re-derives it."

**Steps**

1. Read `CloudKitTransactionRepository.create` end to end (already know
   it `return transaction` at the end — verify nothing mutates
   `transaction` before that line).
2. Check whether any fields are populated lazily in `TransactionRecord`
   but not reflected on the returned `Transaction` domain object.
3. Check `TransactionStore.create` (the optimistic-insert wrapper) for
   any fields it sets or mutates between the input and the stored entry.
4. Document the diff (fields that change, or confirmed "no diff").

**Exit criteria**

- Explicit note in the plan / commit message:
  - **No diff** → Phase 6 is a no-op; `draft` is safely re-used across
    the swap.
  - **Diff exists** → Phase 6 adds a guarded `.onChange(of: transaction)`
    draft refresh.

## Phase 3 — Minimal fix: Change 1 only (answers Q4)

**Question answered:** "Is blurring `.searchable` on inspector open
sufficient on its own, or do we also need Change 2 (UUID preservation)
to land the focus reliably?"

**Steps**

1. In `TransactionListView.swift`, add near the existing `searchFocused`
   modifier:
   ```swift
   .onChange(of: selectedTransaction) { _, new in
     if new != nil { searchFieldFocused = false }
   }
   ```
2. In `TransactionDetailView.swift`, simplify `.task(id:)` to one
   assignment — remove the retry loop introduced by PR #241:
   ```swift
   .task(id: transaction.id) {
     focusedField = isSimpleEarmarkOnly ? .amount : .payee
   }
   ```
3. Run `just test-ui TransactionDetailFocusTests` 20 times. Capture each
   run's result in `.agent-tmp/test-ui-run-<i>.txt`.

**Exit criteria**

- **20 / 20 pass** → Change 1 alone carries the focus win. Skip Phase 4;
  Change 2 becomes an optional cleanup (either land here or as a
  follow-up per discretion, but it is no longer blocking).
- **Any failure** → proceed to Phase 4. Do not bump the retry delays or
  add any other timing; the next step is Change 2, not more timers.

## Phase 4 — Change 2: UUID preservation (only if Phase 3 insufficient)

**Steps**

1. Rework `TransactionListView.createNewTransaction` (both branches) to
   build the placeholder once with an explicit `id: UUID()` and pass it
   to `store.create(placeholder)` instead of `store.createDefault(...)`.
   Drop the `selectedTransaction = created` reassignment.
2. Apply the same change to the earmark-only branch.
3. Run the UI tests 20× again. Expect to go from "some failures" in
   Phase 3 to 20 / 20.

**Exit criteria**

- 20 / 20 pass.

**If still flaky:** stop. The plan's assumption that the two races
are separable is wrong and the design needs revisiting. Escalate before
attempting a third mechanism.

## Phase 5 — iOS `sheet(item:)` smoke test (answers Q2)

**Question answered:** "Does the UUID-preserving create flow cause a
visible glitch in the iOS sheet presentation?"

**Steps**

1. `just test-ios` — ensure the iOS build compiles and unit tests pass
   after the changes. (UI tests are macOS-only; iOS cannot be gated
   automatically beyond compile + unit tests.)
2. `just build-ios` then launch in Simulator via Xcode manually.
3. Manually exercise the create-transaction flow on iOS: press the `+`
   button, watch for sheet flashes / layout glitches as the placeholder
   commits.

**Exit criteria**

- No visible regression (ideal — sheet-flash removed).
- **If regression:** gate Change 2 behind `#if os(macOS)` in
  `createNewTransaction`. The focus bug is macOS-only; iOS keeps the
  current (flashing but working) behaviour.

## Phase 6 — Draft-resync safeguard (only if Phase 2 found mutations)

**Steps**

1. In `TransactionDetailView`, add:
   ```swift
   .onChange(of: transaction) { _, new in
     if draft.isUnmodifiedFromInitial {
       draft = TransactionDraft(from: new, viewingAccountId: viewingAccountId,
                                accounts: accounts)
     }
   }
   ```
2. Add `TransactionDraft.isUnmodifiedFromInitial` (or equivalent guard) —
   either a captured snapshot compared against current values, or a
   `var hasUserEdits = false` flag set on any user-driven mutation.
3. Write a store/logic test: creating a transaction, waiting for the
   persisted swap, then mutating the transaction prop refreshes the
   draft *only* when the user hasn't started editing.

**Exit criteria**

- Logic test passes on `TestBackend`.
- Manual check: typing in payee during the placeholder window survives
  the persisted swap.

## Phase 7 — Tests

Land with the changes (not after):

1. **Keep** `TransactionDetailFocusTests.testOpeningTradeFocusesPayee`.
2. **Keep** `TransactionDetailFocusTests.testCreatingTransactionFocusesPayee`.
   With the retry loop removed, this test is what proves Changes 1 / 2
   actually fix the race.
3. **Add** a store/logic test `TransactionStoreTests`:
   - `testCreatePreservesInputUUIDOnCloudKit` — builds a transaction
     with a fixed UUID, calls `store.create(_:)`, asserts `returned.id
     == input.id` and `rawTransactions` contains a single entry with
     that id.
4. **Add** (if Phase 4 ran): `TransactionListViewModelTests` or
   equivalent exercising `createNewTransaction` — verifies that after
   the async create completes, `selectedTransaction.id` matches the
   placeholder id.

## Phase 8 — Cleanup

1. If `store.createDefault` / `createDefaultEarmark` have no other
   callers after Phase 4, remove them. Otherwise leave alone (they're
   convenience wrappers; removing them is scope creep).
2. Expand `guides/STYLE_GUIDE.md §13` with the inspector / `.searchable`
   caveat: "`defaultFocus` does not pull focus in from outside its
   region. If your form is presented alongside a scene-level focus
   claimant (e.g. `.searchable` toolbar), blur that claimant explicitly
   on presentation."
3. Delete the `BUGS.md` entry if PR #241's deletion missed it (it did —
   PR #240 removed it; verify).

## Phase 9 — Final gate

1. `just format`
2. `just format-check`
3. `just test-mac` (non-UI)
4. `just test-ui TransactionDetailFocusTests` — full 20-run gate one
   more time on the final branch state.
5. Run `@ui-test-review` agent on any driver / test changes.
6. Open PR, add to merge queue.

## Findings (to fill in during execution)

### Phase 1 findings

*Pending.* List every write site of `selectedTransaction` with its
classification.

### Phase 2 findings

*Pending.* Field-diff between placeholder and `store.create` return
value on CloudKit.

### Phase 3 result

*Pending.* 20-run result of "Change 1 alone". Decides whether Phase 4
is needed.

### Phase 5 result

*Pending.* iOS sheet behaviour with the UUID-preserving flow.

## Out of scope

- `Remote` backend focus behaviour — retiring soon, accepted regression.
- Server-side acceptance of client-provided UUIDs — would simplify the
  store, not this fix.
- Generalising to other `.searchable` screens (earmarks, categories,
  accounts).
