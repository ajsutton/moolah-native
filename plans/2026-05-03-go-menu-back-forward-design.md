# Go Menu — Go Back / Go Forward

Date: 2026-05-03
Status: Design approved, in implementation
Owner: Adrian

## Summary

Implement the Go menu's `Go Back` (⌘[) and `Go Forward` (⌘]) items, which currently exist as disabled placeholders in `MoolahDomainCommands.swift`. These items navigate forward and backward through the focused window's history of `SidebarSelection` values (the detail-pane destination chosen from the sidebar or via existing menu commands).

## Goals

- ⌘[ navigates to the previously-selected sidebar destination, ⌘] re-applies a destination just navigated away from via Go Back.
- Menu items are disabled when their respective stack is empty, matching the existing focused-value-driven disable pattern used by every other Moolah-domain command.
- History is per-window / per-profile and lives only in memory.

## Non-goals

- Persisting history across app relaunches (browser-tab back/forward isn't expected to survive a quit either).
- Cmd-clicking the menu / showing a multi-step history pop-out.
- Recording navigation finer than sidebar selection (e.g. transaction inspector open/close, account scroll position).

## Behaviour

A "navigation step" is a change to `ContentView.selection: SidebarSelection?`. Concretely, the navigable destinations are: `account(UUID)`, `earmark(UUID)`, `recentlyAdded`, `allTransactions`, `upcomingTransactions`, `categories`, `reports`, `analysis`.

- Each change to `selection` driven by user action (sidebar click, ⌘1–⌘5, "View Transactions" account-menu item, App Intents / AppleScript navigation) pushes the **prior** value of `selection` onto the back stack and clears the forward stack. This matches a standard browser back/forward model.
- Back/forward navigation does **not** itself record history — it pops from one stack and pushes onto the other, mediated by a `historyDrivenSelection` token that the recorder compares against the new `selection` value. A value-based token is used (rather than a Bool flag) so the suppression doesn't depend on whether SwiftUI delivers `onChange` synchronously or on the next render cycle.
- A `nil` prior value is **not** pushed. (Realistically only happens on iOS, where the initial `selection` is `nil`; we don't want "go back to nothing".)
- Selecting an already-selected sidebar row does not fire `onChange(of: selection)` and so does not pollute the history.
- Both stacks are capped at 50 entries; pushing onto a full stack drops the oldest entry. (Bounds memory in the unlikely event of pathological navigation.)
- History is per-`ContentView`, which is recreated per `ProfileSession`. Switching profile naturally resets both stacks. Closing a window discards its history.
- Menu items are disabled when their stack is empty — same `.disabled(action == nil)` pattern as `New Transaction…`, `Edit Transaction…`, etc.

## Implementation

### 1. `Shared/FocusedValues.swift` — two new focused values

```swift
/// Trigger action for Go > Go Back (⌘[). nil = nothing to go back to.
struct GoBackActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for Go > Go Forward (⌘]). nil = nothing to go forward to.
struct GoForwardActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var goBackAction: GoBackActionKey.Value? {
    get { self[GoBackActionKey.self] }
    set { self[GoBackActionKey.self] = newValue }
  }
  var goForwardAction: GoForwardActionKey.Value? {
    get { self[GoForwardActionKey.self] }
    set { self[GoForwardActionKey.self] = newValue }
  }
}
```

### 2. `App/ContentView.swift` — stack-management state & helpers

Add three pieces of `@State` to the primary struct, and a `private extension ContentView` block at the end of the file holding the helpers (so SwiftLint's `type_body_length` keeps counting only the primary struct body):

```swift
@State private var backStack: [SidebarSelection] = []
@State private var forwardStack: [SidebarSelection] = []
@State private var historyDrivenSelection: SidebarSelection?
```

Add an `.onChange(of: selection)` and the focused-value exposures inside `body`:

```swift
.focusedSceneValue(\.goBackAction, backStack.isEmpty ? nil : { goBack() })
.focusedSceneValue(\.goForwardAction, forwardStack.isEmpty ? nil : { goForward() })
.onChange(of: selection) { oldValue, newValue in
  recordHistory(previous: oldValue, new: newValue)
}
```

In a `private extension ContentView` after the primary body:

```swift
static let historyLimit = 50

func recordHistory(previous: SidebarSelection?, new: SidebarSelection?) {
  if let token = historyDrivenSelection, token == new {
    historyDrivenSelection = nil
    return
  }
  guard let previous else { return }
  backStack.append(previous)
  Self.trimToHistoryLimit(&backStack)
  forwardStack.removeAll()
}

func goBack() {
  guard let previous = backStack.popLast() else { return }
  if let current = selection {
    forwardStack.append(current)
    Self.trimToHistoryLimit(&forwardStack)
  }
  historyDrivenSelection = previous
  selection = previous
}

func goForward() {
  guard let next = forwardStack.popLast() else { return }
  if let current = selection {
    backStack.append(current)
    Self.trimToHistoryLimit(&backStack)
  }
  historyDrivenSelection = next
  selection = next
}

static func trimToHistoryLimit(_ stack: inout [SidebarSelection]) {
  if stack.count > historyLimit { stack.removeFirst(stack.count - historyLimit) }
}
```

**Why a value token, not a Bool flag.** A flag-based suppression (`isNavigatingHistory = true; selection = …; isNavigatingHistory = false`) assumes `onChange` fires synchronously inside the `selection` setter. SwiftUI does not guarantee that — `onChange` is generally delivered as part of the next view-update cycle, by which time the flag has already been reset. The value-token approach instead checks whether the new selection equals the destination we just intentionally navigated to, which is true regardless of when the callback fires.

### 3. `App/MoolahDomainCommands.swift` — wire the menu items

In `MoolahDomainCommands` add two `@FocusedValue` properties:

```swift
@FocusedValue(\.goBackAction) private var goBackAction
@FocusedValue(\.goForwardAction) private var goForwardAction
```

Replace the placeholder Buttons in `goMenuItems`:

```swift
Button("Go Back") { goBackAction?() }
  .keyboardShortcut("[", modifiers: .command)
  .disabled(goBackAction == nil)
Button("Go Forward") { goForwardAction?() }
  .keyboardShortcut("]", modifiers: .command)
  .disabled(goForwardAction == nil)
```

## Edge cases

| Scenario                                            | Handled how                                                                            |
| --------------------------------------------------- | -------------------------------------------------------------------------------------- |
| User clicks the same sidebar row again              | `onChange(of:)` doesn't fire — no-op.                                                  |
| AppleScript / App Intents navigation                | Flows through `applyNavigation` → sets `selection` → trips `onChange` → recorded.      |
| Initial selection is `nil` (iOS first launch)       | First non-nil change has `oldValue == nil` → not pushed. `backStack` correctly empty.  |
| Profile switch                                      | New `ProfileSession` → new `ContentView` → fresh `@State` stacks.                      |
| Window close / reopen                               | New `ContentView` → fresh `@State` stacks. (In-memory only by design.)                 |
| Rapid back/forward presses                          | Stack pops are synchronous; `withHistorySuppressed` brackets the mutation.             |
| 51st entry pushed                                   | `cap(_:)` removes the oldest so the stack stays at 50.                                 |

## Testing

- **No store-level unit test.** All logic lives in `ContentView.@State`, which is bound to view lifetime. Adding a store solely to host two arrays and three methods would be over-engineering, and we agreed during brainstorming to skip it.
- **Manual / UI verification (macOS):**
  1. Launch app, observe Go > Go Back and Go > Go Forward both disabled.
  2. ⌘1 (Transactions) — Go Back becomes enabled, Go Forward stays disabled.
  3. ⌘2 (Scheduled) — both eligible to be navigated; Go Back enabled.
  4. ⌘3 (Categories).
  5. ⌘[ — selection goes to Scheduled. Go Forward now enabled.
  6. ⌘[ — selection goes to Transactions. Go Forward enabled.
  7. ⌘] — selection goes to Scheduled. Go Back enabled, Go Forward enabled.
  8. ⌘1 (Transactions, fresh user navigation) — forward stack clears; Go Forward becomes disabled.
  9. ⌘[ until exhausted — Go Back becomes disabled at the bottom of the stack.

## Out of scope

- Persisting history across launches.
- Showing a popover/menu of recent destinations on long-press.
- A separate iOS gesture-based back affordance (the iOS UI doesn't have a menu bar; this PR is fundamentally a macOS menu feature, but the focused-value plumbing is cross-platform and the iOS build will continue to compile).
