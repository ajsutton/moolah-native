# Transaction Detail Focus — Proper Fix Design

Status: draft — supersedes the timing-based workaround in PR #241.

## 1. Problem

Two focus failures in `TransactionDetailView`, each gated by a different race:

1. **Opening an existing transaction.** Initial first-responder on app launch
   is the transaction list's `.searchable` toolbar field. `defaultFocus(.payee)`
   inside the inspector's detail view does not steal that focus because
   `defaultFocus` only picks the default *within* its focus region.
   **Fixed (partially) by PR #240** — imperative `focusedField = target` in
   `.task(id:)`.
2. **Creating via ⌘N.** After the menu event, the inspector opens with a
   placeholder transaction whose UUID does not match the persisted transaction
   that the store returns. The inspector modifier's `.id(selected.id)` forces
   a view recreation during the swap; `@FocusState` resets, and AppKit
   simultaneously restores first-responder to the `.searchable` field.
   **Patched in PR #241** with a 50 ms / 150 ms retry loop in `.task(id:)` —
   acknowledged as hacky and marked for replacement here.

## 2. Scope: CloudKit only

`moolah-server` will not be changed, and the `Remote` backend is being retired
soon. **This design targets the CloudKit path only.** On the way out we will
let `Remote` keep whatever focus behaviour falls out of the CloudKit-shaped
fix — any residual race there is acceptable given its lifespan.

## 3. Why the current fix is hacky

`TransactionDetailView.swift`:

```swift
.task(id: transaction.id) {
  let target: Field = isSimpleEarmarkOnly ? .amount : .payee
  focusedField = target
  for delayMs: UInt64 in [50, 150] {
    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
    if Task.isCancelled { return }
    if focusedField == nil { focusedField = target }
  }
}
```

- Timer-driven: `Task.sleep` values were picked empirically and will race
  with SwiftUI animation timing on slower machines.
- Re-asserts reactively rather than preventing the focus loss.
- Obscures two independent root causes behind a single workaround.

## 4. Root-cause analysis

### Race A — `.searchable` claims the window's initial first-responder

The list view wires:

```swift
@FocusState private var searchFieldFocused: Bool
…
.focusedSceneValue(\.findInListAction) { searchFieldFocused = true }
.searchFocused($searchFieldFocused)
```

AppKit designates the `.searchable` toolbar field as the window's
`initialFirstResponder`. On launch, and after menu events that reset the
responder chain (⌘N is one), focus lands there. `defaultFocus` inside the
inspector does not pull focus *into* its region, so the detail view stays
unfocused.

### Race B — placeholder → persisted-transaction view recreation

`TransactionListView.createNewTransaction()`:

```swift
selectedTransaction = placeholder                    // id = A
Task {
  if let created = await store.createDefault(...) {  // id = B (fresh UUID)
    if selectedTransaction?.id == placeholder?.id {
      selectedTransaction = created                  // triggers .id() swap
    }
  }
}
```

`TransactionInspectorModifier.swift`:

```swift
.inspector(isPresented: isPresented) {
  if let selected = selectedTransaction {
    TransactionDetailView(...)
      .id(selected.id)                               // forces recreation
  }
}
```

When `.id(selected.id)` changes (A → B), SwiftUI destroys the current
`TransactionDetailView` instance and instantiates a new one; `@FocusState`
resets, and the old instance's `.task(id:)` is cancelled. The new instance's
`.task(id:B)` fires *during* the window AppKit is using to pick a replacement
first-responder — often landing on `.searchable` before the new `.task` runs.

**The fundamental thing to change**: the caller manufactures a *new* UUID
each create flow. `TransactionListView` builds `placeholder` with a random id,
then `store.createDefault(...)` builds *another* transaction with *another*
random id, and the returned value is what lands in `selectedTransaction`.
Two UUIDs are generated for one user action — so the swap is guaranteed even
on CloudKit, where the repository would have happily echoed a single input
UUID straight back.

| Backend    | `repository.create(_:)` UUID behaviour |
| ---------- | -------------------------------------- |
| CloudKit   | returns the input transaction unchanged — UUID preserved |
| Remote     | server-assigned — UUID changes (out of scope, being retired) |

## 5. Design goals

1. Restore the invariant in `guides/STYLE_GUIDE.md §13`: opening the inspector
   places first-responder on payee (or amount, for simple earmark-only).
2. No `Task.sleep`, no retry loops.
3. Works on CloudKit (Remote is out of scope; it will be retired).
4. Stable across the 20-run UI-test gate.
5. No change to backend DTOs, no change to `moolah-server`.

## 6. Proposed approach — two independent changes

The two races are separable; fix each at its root.

### Change 1 — Blur `.searchable` when the inspector opens (fixes Race A)

Owner: `TransactionListView.swift`.

Add to the list view body (near the existing `searchFocused`/`focusedSceneValue`
modifiers):

```swift
.onChange(of: selectedTransaction) { _, new in
  if new != nil { searchFieldFocused = false }
}
```

When the inspector presents, the list view explicitly releases its claim on
first-responder. AppKit's responder chain then falls through to the inspector's
content instead of re-grabbing the search field after a menu event. Combined
with the existing `.task(id:)` assignment in the detail view, focus lands on
payee on the first try for the ⌘N case too.

No timer, no retry.

### Change 2 — Pass the placeholder through `store.create` so the UUID is preserved (fixes Race B on CloudKit)

Owner: `TransactionListView.swift`. Optionally prune
`TransactionStore.createDefault` if no other call sites remain.

Today `createNewTransaction` does:

```swift
let placeholder = Transaction(..., id: UUID())         // id = A
selectedTransaction = placeholder
Task {
  if let created = await store.createDefault(...) {    // id = B (new)
    if selectedTransaction?.id == placeholder?.id {
      selectedTransaction = created                    // swap — forces recreation
    }
  }
}
```

Rework to build the placeholder once and pass it to the existing
`store.create(_:)` entry point:

```swift
let placeholder = Transaction(                         // id = A, retained
  id: UUID(),
  date: Date(),
  payee: "",
  legs: [TransactionLeg(accountId: acctId, instrument: instrument,
                        quantity: 0, type: .expense)]
)
selectedTransaction = placeholder
Task {
  _ = await store.create(placeholder)                  // returns same id on CloudKit
}
```

No reassignment of `selectedTransaction` is needed on CloudKit — the persisted
transaction returned by `store.create` carries the same UUID, so the view keeps
its identity through the create flow. `.id(selected.id)` stays constant,
`@FocusState` survives, and the initial `.task(id:)` focus assignment is
enough.

Behaviour differences vs. today:

- The placeholder is inserted into the store's optimistic list as soon as
  the Task enters `store.create`. That's fine — it's an empty zero-amount
  transaction while the user types, exactly what the UX already shows.
  `store.create` already does optimistic insert + replace-on-confirm.
- On `Remote`, `repository.create` still returns a server-assigned UUID.
  The store currently replaces `rawTransactions[index] = created` which
  leaves a stale `selectedTransaction` (pointing at UUID A) referencing an
  entry that no longer exists under that id. Two ways to handle:
  - **Accept the regression on Remote.** It's on its way out; the worst
    case is the inspector holding a dangling reference until the view is
    closed, matching the pre-existing behaviour in that backend's quirks.
  - **Gate the new flow on `isCloudKit`.** Keep `createDefault` + swap for
    Remote; use the UUID-preserving path on CloudKit. Not worth the
    conditional given Remote's timeline.
  Pick the first option unless testing surfaces a concrete breakage.

### Change 3 — Simplify `.task(id:)` (prereq of Changes 1 + 2)

Owner: `TransactionDetailView.swift`.

With Races A and B eliminated on CloudKit:

```swift
.task(id: transaction.id) {
  focusedField = isSimpleEarmarkOnly ? .amount : .payee
}
```

Drop the sleep + re-assertion loop introduced by PR #241.

## 7. Alternative approaches considered & rejected

| Approach | Why rejected |
| --- | --- |
| Session-id abstraction (`InspectorSession` struct with a user-intent UUID decoupled from `transaction.id`) | Cleaner on paper but requires auditing every `selectedTransaction` write site (URL scheme, NotificationCenter, sheet binding on iOS) and changes the sheet's `Identifiable` key. Change 2 achieves the same outcome without a new type. |
| Remove `.id(selected.id)` entirely | Loses the draft-reset correctness — editing transaction A's unsaved fields would bleed into transaction B when the user selects B. Keeping the modifier and just fixing what flows through it is safer. |
| Window-level `defaultFocus`/`prefersDefaultFocus` to override AppKit's initial-first-responder pick | `prefersDefaultFocus(_:in:)` still applies *within* the focus region; no public hook cleanly prevents `.searchable` from being picked as initial responder. Change 1 achieves the same effect without spelunking. |
| Wrap the payee field in an `NSViewRepresentable` that calls `window?.makeFirstResponder(…)` on appear | Solves the problem but adds an AppKit escape hatch the style guide discourages. Hold in reserve if Changes 1 + 2 prove insufficient. |
| Delay `selectedTransaction = placeholder` so AppKit's menu chain settles before the inspector renders | Still timer-based. Moves the hack; doesn't remove it. |

## 8. Implementation plan

Single PR. Changes 1–3 land together; each alone is insufficient, and the
timer-based `.task` retry (PR #241) gets removed in the same change so the
20-run gate proves the new mechanism.

1. **Blur search on inspector open** (Change 1). One `.onChange` line in
   `TransactionListView`.
2. **Use `store.create(placeholder)` in `createNewTransaction`** (Change 2),
   both the account-attached and earmark-only branches. Drop the
   `selectedTransaction = created` reassignment on CloudKit.
3. **Audit `store.createDefault` / `createDefaultEarmark` call sites.**
   If this view is the only caller, mark them deprecated or remove them in
   the same PR. If there are other callers (keyboard shortcut / scripting
   bridge / URL scheme), update them to the new pattern or leave the
   convenience wrappers in place but unused by `TransactionListView`.
4. **Simplify `.task(id:)`** in `TransactionDetailView` — delete the
   retry loop.
5. **Tests**
   - Keep both existing UI tests (`testOpeningTradeFocusesPayee`,
     `testCreatingTransactionFocusesPayee`). Both must pass 20/20 with the
     timer removed.
   - Add a store/logic test asserting `store.create(placeholder)` returns
     a transaction whose `id == placeholder.id` on `TestBackend`.
   - Add a store/logic test asserting the `rawTransactions` entry after
     `create(placeholder)` carries the caller's UUID (no implicit reassignment).

## 9. Risks / open questions

- **Other entry points that set `selectedTransaction`** — the
  `.requestTransactionEdit` NotificationCenter observer, the URL-scheme
  handler, and the earmark-only create branch. Audit each for UUID
  stability. Edit/URL flows set `selectedTransaction` to a transaction
  that already lives in the store, so no fresh-UUID issue — but worth
  confirming.
- **iOS `sheet(item:)`**. `selectedTransaction.id` is already the key via
  `Identifiable`. The UUID-preserving flow keeps that key stable through
  the create, which avoids a sheet re-presentation animation on create.
  Should be an improvement; verify.
- **Draft reset correctness.** After Change 2 the detail view is *not*
  recreated during the create flow, so `@State private var draft`
  (initialised in `init`) persists. The placeholder and the persisted
  transaction carry the same user-facing fields at this point (both are
  empty), so the `init`-time draft is still correct. If anything changes
  that assumption later (e.g. server-side defaulting), add
  `.onChange(of: transaction.id) { draft = TransactionDraft(from: …) }`.
- **If Change 1 alone suffices for the ⌘N case** — run the UI test with
  Change 1 only and see. Change 2 is still worth landing for the
  architectural cleanup (single UUID per user action), but Change 1 may
  turn out to carry the focus win on its own.

## 10. Follow-up work out of scope

- `Remote` backend retirement — once removed, the swap/reassign branches
  in `TransactionStore.create` can simplify further (caller UUID is always
  preserved, no optimistic-replace needed).
- Audit other `.searchable` screens (earmarks, categories, accounts) for
  the same inspector/focus interaction.
- Expand `guides/STYLE_GUIDE.md §13` with the inspector-vs-searchable
  caveat so the next contributor doesn't re-discover it.
