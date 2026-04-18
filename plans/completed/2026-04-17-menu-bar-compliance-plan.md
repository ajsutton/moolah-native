# Menu Bar Compliance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Moolah's menu bar, toolbar, and context menus into compliance with `guides/STYLE_GUIDE.md` §14 (Menu Bar & Commands), addressing all 29 findings from the 2026-04-17 UI review without breaking iOS (which has no menu bar).

**Architecture:** Implement in 10 phases. Each phase is independently commit-able, leaves the app working on both macOS and iOS, and can be reviewed as its own unit. Focused values + selection plumbing come first so later phases can consume them. All new `CommandMenu`s and `CommandGroup`s live in macOS-only files or `#if os(macOS)` guards — the `.commands { }` block is already macOS-only in `MoolahApp.swift`. Changes that touch shared views (context-menu renames, focused-value publication) are safe on iOS: `focusedSceneValue` is a no-op without a consumer, and relabeled context menus improve clarity on both platforms.

**iOS considerations:**
- `.commands { … }` is only applied to the `WindowGroup` in the `#if os(macOS)` branch of `MoolahApp.swift`. New `CommandMenu`/`CommandGroup` structs added to it do not compile into the iOS binary (keep them in macOS-only files, or wrap them in `#if os(macOS)`).
- Context menu items (`.contextMenu { Button(…, systemImage:) }`) **keep their `systemImage:`** — iOS renders contextual menus with leading icons by convention, and macOS 26 does too. The style guide's "no icons in menu items" rule is scoped to the menu bar; Phase 0 clarifies this in the guide.
- `.focusedSceneValue(...)` compiles and runs on iOS without issues (there are simply no command groups consuming it) — keep publications unconditional unless the published type is macOS-only.
- Keyboard shortcuts on view controls: harmless on iOS (no hardware keyboard focused on menu), but they still register if an external keyboard is attached. The plan removes duplicates and view-level shortcuts that belong to menu commands — this is pure cleanup and behaves identically on iOS.
- Accessibility: removing icons from views would hurt iOS accessibility (VoiceOver users rely on shared labels). The plan does not remove any `systemImage:` from toolbar buttons or context menus — only from labels where we also adjust the text, and in those cases we keep the `systemImage:`.

**Tech Stack:** SwiftUI, Swift 6, macOS 26+, iOS 26+. Existing patterns: `@FocusedValue` / `FocusedValueKey` in `Shared/FocusedValues.swift`, `CommandGroup`/`CommandMenu` in feature-specific `*Commands.swift` files under `Features/`.

---

## Finding Coverage

Each phase closes specific findings from the 2026-04-17 review:

| Phase | Findings addressed |
|-------|--------------------|
| Phase 0 | Style guide clarifications (context menu icons; additional domain menus; single-key shortcuts) |
| Phase 1 | 5.1, 5.2, 5.3, 5.4 — focused value keys & selection publication |
| Phase 2 | 1.10, 4.6 — compose standard builders, restore View menu |
| Phase 3 | 1.3, 1.9, 4.2, 5.1, 6.2, 8.2 — Transaction menu + delete confirmation |
| Phase 4 | 1.4, 1.8, 4.1 — Go menu (with disabled Back/Forward) + Account menu |
| Phase 5 | 1.1, 1.2 (stub), 1.6, 2.4, 2.5, 4.7, 8.1 — Edit menu (Find + Find Next/Prev + Copy Link stub) + remove duplicate toolbar shortcuts |
| Phase 6 | 4.5 — Help menu (appended, not replacing) + Keyboard Shortcuts window |
| Phase 7 | 3.1, 8.3 — ShowHiddenCommands verb-pair |
| Phase 8 | 2.2, 4.3, 6.1, 6.3, 8.4 — Sign Out → File, New Account/Category commands |
| Phase 9 | 1.5, 2.1, 2.6, 2.7, 3.2, 3.3, 3.5, 3.6, 6.4 — naming, ellipsis, remove dangerous shortcuts, Refresh grouping |
| Phase 10 | Verification — ui-review agent re-run until zero findings |

---

## Phase 0: Style Guide Refinement ✅ Complete

Before touching code, clarify two points in `guides/STYLE_GUIDE.md` §14 that the current text leaves ambiguous. These are guide-only changes and committed separately.

### Task 0.1: Clarify icon policy for context menus

**Files:**
- Modify: `guides/STYLE_GUIDE.md` — Section 14 "Icons in Menu Items"

- [x] **Step 1: Add a "Context menus vs menu bar" clarification**

In the "Icons in Menu Items" subsection, after the "Acceptable uses" list and before "Unacceptable", insert:

```markdown
**Context menus (right-click / long-press) are a separate case.** iOS renders contextual menus with leading icons by convention, and macOS 26 does the same. Keep `systemImage:` on context-menu `Button`s — they read as system-native on iOS and provide visual affordance on macOS. The "no icons by default" rule applies to **the menu bar only** (`CommandMenu`, `CommandGroup`).
```

- [x] **Step 2: Commit**

```bash
git add guides/STYLE_GUIDE.md
git commit -m "docs: clarify style guide — context menu icons are permitted"
```

### Task 0.2: Sanction additional domain menus (Account, Earmark)

**Files:**
- Modify: `guides/STYLE_GUIDE.md` — Section 14 "Top-Level Menu Structure"

- [x] **Step 1: Allow additional domain menus alongside Transaction**

After the "Transaction" subsection and before "Window", insert a new subsection:

```markdown
#### Additional Domain Menus (Account, Earmark)

When the app has more than one primary noun the user acts on, each gets its own domain menu positioned between `Transaction` and `Window`:

```
… View · Go · Transaction · Account · Earmark · Window · Help
```

Each domain menu follows the same rules as `Transaction` — verb-phrase items, operate on the focused window's selection via `@FocusedValue`, disabled (not hidden) when no selection is present. Keep each menu short (3–6 items). If a domain has only one or two menu-worthy actions, inline them into `Transaction` under a noun prefix (`Edit Account…`, `View Account Transactions`) instead of creating a dedicated menu.

Do not create a domain menu just to host a single command. And do not invent a generic `Domain` or `Items` menu that covers multiple nouns — each menu owns exactly one noun.
```

- [x] **Step 2: Commit**

```bash
git add guides/STYLE_GUIDE.md
git commit -m "docs: permit Account and Earmark domain menus alongside Transaction"
```

### Task 0.3: Remove ambiguous single-key shortcuts from §14 Transaction outline

**Files:**
- Modify: `guides/STYLE_GUIDE.md`

The §14 Transaction menu outline currently shows `Edit Transaction…  ↩` and `Delete Transaction ⌫`, which creates a tension with §14's Philosophy: "Menus are for ⌘-modified commands. Single-key shortcuts … do not belong in the menu bar." The Return and Delete keys fire via List row focus (list primaryAction / onDeleteCommand), not via menu-registered shortcuts.

- [x] **Step 1: Update the Transaction menu code block**

In §14's Transaction menu code block, change:
```
Edit Transaction…            ↩       (primary action on selection)
```
to:
```
Edit Transaction…                    (opens inspector; fires on list double-click / Return)
```

And change:
```
Delete Transaction           ⌫        (on menu; fires via Delete key on selection)
```
to:
```
Delete Transaction…                  (ellipsis — confirmation alert; Delete key fires on list focus)
```

- [x] **Step 2: Update the Moolah-Specific Shortcut Map**

Change:
```
| Pay Scheduled Transaction | — | Transaction (⌘P reserved for Print) |
| Delete Transaction | ⌫ | Transaction (fires on selection) |
```
to:
```
| Pay Scheduled Transaction | — | Transaction (⌘P reserved for Print) |
| Edit Transaction… | — | Transaction (list primaryAction on Return/double-click) |
| Delete Transaction… | — | Transaction (Delete key on list focus via onDeleteCommand) |
```

- [x] **Step 3: Update the "Context Menu ↔ Menu Bar Parity" code example**

Find the code block under "Context Menu ↔ Menu Bar Parity" that shows:
```swift
CommandMenu("Transaction") {
    Button("Edit Transaction…") { … }.keyboardShortcut(.return, modifiers: [])
    Button("Duplicate Transaction") { … }.keyboardShortcut("d")
    Button("Mark as Cleared") { … }.keyboardShortcut("k")
    Divider()
    Button("Delete Transaction", role: .destructive) { … }
}
```
Replace with:
```swift
CommandMenu("Transaction") {
    Button("Edit Transaction…") { … }                  // no menu shortcut — fires on list focus
    Button("Duplicate Transaction") { … }.keyboardShortcut("d")
    Button("Mark as Cleared") { … }.keyboardShortcut("k")
    Divider()
    Button("Delete Transaction…", role: .destructive) { … }   // ellipsis for confirmation
}
```

- [x] **Step 4: Commit**

```bash
git add guides/STYLE_GUIDE.md
git commit -m "docs: remove single-key shortcut annotations from Transaction menu outline"
```

---

## Phase 1: Focused Value Foundation ✅ Complete

All subsequent menu-bar commands operate on selection. Centralize the selection state via `@FocusedValue` first so later phases can consume it without circular changes.

Status verified 2026-04-18:
- `Shared/FocusedValues.swift` contains all eleven focused value keys listed in Task 1.1.
- `TransactionListView.swift:105` and `UpcomingView.swift:24` publish `selectedTransaction`.
- `SidebarView.swift:187–188` publish `sidebarSelection` and `selectedAccount`; `EarmarksView.swift:97` publishes `selectedEarmark`; `CategoriesView.swift:99` publishes `selectedCategory`.

### Task 1.1: Add focused value keys for selection state

**Files:**
- Modify: `Shared/FocusedValues.swift`

- [x] **Step 1: Add new focused value keys**

Replace the contents of `Shared/FocusedValues.swift` with:

```swift
import SwiftUI

/// Trigger action for creating a new transaction (File > New Transaction, ⌘N).
struct NewTransactionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for creating a new earmark (File > New Earmark, ⇧⌘N).
struct NewEarmarkActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for creating a new account (File > New Account, ⌃⌘N).
struct NewAccountActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for creating a new category (File > New Category, ⌥⌘N).
struct NewCategoryActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for refreshing the focused window's data (⌘R).
struct RefreshActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for focusing the search field in the active list (⌘F).
struct FindInListActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Binding to the View > Show Hidden Accounts toggle.
struct ShowHiddenAccountsKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

/// The transaction currently selected in the focused window (for Transaction menu).
struct SelectedTransactionKey: FocusedValueKey {
  typealias Value = Binding<Transaction?>
}

/// The account currently selected in the focused window (for Account menu items).
struct SelectedAccountKey: FocusedValueKey {
  typealias Value = Binding<Account?>
}

/// The earmark currently selected in the focused window (for Earmark menu items).
struct SelectedEarmarkKey: FocusedValueKey {
  typealias Value = Binding<Earmark?>
}

/// The category currently selected in the focused window (for Category menu items).
struct SelectedCategoryKey: FocusedValueKey {
  typealias Value = Binding<Category?>
}

/// Binding to the sidebar destination (for Go menu ⌘1…⌘9).
struct SidebarSelectionKey: FocusedValueKey {
  typealias Value = Binding<SidebarSelection?>
}

extension FocusedValues {
  var newTransactionAction: NewTransactionActionKey.Value? {
    get { self[NewTransactionActionKey.self] }
    set { self[NewTransactionActionKey.self] = newValue }
  }
  var newEarmarkAction: NewEarmarkActionKey.Value? {
    get { self[NewEarmarkActionKey.self] }
    set { self[NewEarmarkActionKey.self] = newValue }
  }
  var newAccountAction: NewAccountActionKey.Value? {
    get { self[NewAccountActionKey.self] }
    set { self[NewAccountActionKey.self] = newValue }
  }
  var newCategoryAction: NewCategoryActionKey.Value? {
    get { self[NewCategoryActionKey.self] }
    set { self[NewCategoryActionKey.self] = newValue }
  }
  var refreshAction: RefreshActionKey.Value? {
    get { self[RefreshActionKey.self] }
    set { self[RefreshActionKey.self] = newValue }
  }
  var findInListAction: FindInListActionKey.Value? {
    get { self[FindInListActionKey.self] }
    set { self[FindInListActionKey.self] = newValue }
  }
  var showHiddenAccounts: ShowHiddenAccountsKey.Value? {
    get { self[ShowHiddenAccountsKey.self] }
    set { self[ShowHiddenAccountsKey.self] = newValue }
  }
  var selectedTransaction: SelectedTransactionKey.Value? {
    get { self[SelectedTransactionKey.self] }
    set { self[SelectedTransactionKey.self] = newValue }
  }
  var selectedAccount: SelectedAccountKey.Value? {
    get { self[SelectedAccountKey.self] }
    set { self[SelectedAccountKey.self] = newValue }
  }
  var selectedEarmark: SelectedEarmarkKey.Value? {
    get { self[SelectedEarmarkKey.self] }
    set { self[SelectedEarmarkKey.self] = newValue }
  }
  var selectedCategory: SelectedCategoryKey.Value? {
    get { self[SelectedCategoryKey.self] }
    set { self[SelectedCategoryKey.self] = newValue }
  }
  var sidebarSelection: SidebarSelectionKey.Value? {
    get { self[SidebarSelectionKey.self] }
    set { self[SidebarSelectionKey.self] = newValue }
  }
}
```

- [x] **Step 2: Build — verify warning-free compile**

```bash
just build-mac 2>&1 | tee .agent-tmp/phase1-build.txt
grep -i 'warning\|error' .agent-tmp/phase1-build.txt
```
Expected: No warnings, no errors.

- [x] **Step 3: Commit**

```bash
git add Shared/FocusedValues.swift
git commit -m "feat: add focused value keys for menu selection state"
```

### Task 1.2: Publish `selectedTransaction` from TransactionListView and UpcomingView

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift:104`
- Modify: `Features/Transactions/Views/UpcomingView.swift` (wherever list selection is owned)

- [x] **Step 1: Find the selection binding in TransactionListView**

Read `Features/Transactions/Views/TransactionListView.swift` and locate `selectedTransactionBinding` (used on line 182 `List(selection: selectedTransactionBinding)`).

- [x] **Step 2: Publish the binding alongside the existing `newTransactionAction` publication**

At line 104, change:

```swift
.focusedSceneValue(\.newTransactionAction, createNewTransaction)
```

to:

```swift
.focusedSceneValue(\.newTransactionAction, createNewTransaction)
.focusedSceneValue(\.selectedTransaction, selectedTransactionBinding)
```

- [x] **Step 3: Same publication for UpcomingView**

Read `Features/Transactions/Views/UpcomingView.swift`. Locate its selection state (`@State private var selectedTransaction: Transaction?` and a `List(selection:)`). Append to its root view modifier:

```swift
.focusedSceneValue(\.selectedTransaction, $selectedTransaction)
```

- [x] **Step 4: Build**

```bash
just build-mac 2>&1 | tee .agent-tmp/phase1-build.txt
grep -i 'warning\|error' .agent-tmp/phase1-build.txt
```
Expected: clean.

- [x] **Step 5: Commit**

```bash
git add Features/Transactions/Views/TransactionListView.swift Features/Transactions/Views/UpcomingView.swift
git commit -m "feat: publish selectedTransaction focused value from list views"
```

### Task 1.3: Publish `selectedAccount`, `selectedEarmark`, `selectedCategory`, `sidebarSelection`

**Files:**
- Modify: `Features/Navigation/SidebarView.swift`
- Modify: `Features/Earmarks/Views/EarmarksView.swift`
- Modify: `Features/Categories/Views/CategoriesView.swift`

- [x] **Step 1: Publish `sidebarSelection` and `selectedAccount` from SidebarView**

Read `Features/Navigation/SidebarView.swift`. Near the existing `.focusedSceneValue(\.showHiddenAccounts, $showHidden)` at line 181, add:

```swift
.focusedSceneValue(\.sidebarSelection, $selection)      // `$selection` is the existing List selection binding
.focusedSceneValue(\.selectedAccount, selectedAccountBinding)  // derive from `selection` when it is an account
```

If `selectedAccountBinding` does not yet exist, create a computed `Binding<Account?>` at the top of the view body:

```swift
private var selectedAccountBinding: Binding<Account?> {
  Binding(
    get: {
      guard case let .account(id) = selection else { return nil }
      return accounts.first { $0.id == id }
    },
    set: { newAccount in
      selection = newAccount.map { .account($0.id) }
    }
  )
}
```

Adjust the case matching to match the actual `SidebarSelection` enum shape in the codebase.

- [x] **Step 2: Publish `selectedEarmark` from EarmarksView**

Read `Features/Earmarks/Views/EarmarksView.swift`. Locate its list selection. Add to its root view modifier:

```swift
.focusedSceneValue(\.selectedEarmark, $selectedEarmark)
```

- [x] **Step 3: Publish `selectedCategory` from CategoriesView**

Read `Features/Categories/Views/CategoriesView.swift`. Locate its list selection. Add:

```swift
.focusedSceneValue(\.selectedCategory, $selectedCategory)
```

- [x] **Step 4: Build**

```bash
just build-mac 2>&1 | tee .agent-tmp/phase1-build.txt
grep -i 'warning\|error' .agent-tmp/phase1-build.txt
```
Expected: clean.

- [x] **Step 5: Run tests**

```bash
just test 2>&1 | tee .agent-tmp/phase1-test.txt
grep -i 'failed\|error:' .agent-tmp/phase1-test.txt
```
Expected: no new failures.

- [x] **Step 6: Commit**

```bash
git add Features/Navigation/SidebarView.swift Features/Earmarks/Views/EarmarksView.swift Features/Categories/Views/CategoriesView.swift
git commit -m "feat: publish selection focused values from sidebar, earmarks, categories"
```

---

## Phase 2: Compose Standard SwiftUI Command Builders

Restore the standard View menu (Show Sidebar, Show Toolbar, Customize Toolbar, Show Inspector) by composing SwiftUI's built-in `Commands` structs. This is a three-line change with high impact.

### Task 2.1: Add SidebarCommands, ToolbarCommands, InspectorCommands

**Files:**
- Modify: `App/MoolahApp.swift:208-217`

- [ ] **Step 1: Extend the `.commands { }` block**

In the `#if os(macOS)` branch, change the existing:

```swift
.commands {
  AboutCommands()
  ProfileCommands(
    profileStore: profileStore, sessionManager: sessionManager,
    containerManager: containerManager)
  NewTransactionCommands()
  NewEarmarkCommands()
  RefreshCommands()
  ShowHiddenCommands()
}
```

to:

```swift
.commands {
  AboutCommands()
  ProfileCommands(
    profileStore: profileStore, sessionManager: sessionManager,
    containerManager: containerManager)
  NewTransactionCommands()
  NewEarmarkCommands()
  RefreshCommands()
  SidebarCommands()
  ToolbarCommands()
  InspectorCommands()
  ShowHiddenCommands()
}
```

- [ ] **Step 2: Launch the app and verify menu contents**

```bash
just run-mac 2>&1 | tee .agent-tmp/phase2-run.txt
```
Manually verify the View menu now contains:
- Show Sidebar (⌃⌘S) with label flip
- Show Toolbar (⌥⌘T) / Hide Toolbar
- Customize Toolbar…
- Show Inspector (⌥⌘I) / Hide Inspector
- Enter Full Screen (⌃⌘F)

- [ ] **Step 3: Commit**

```bash
git add App/MoolahApp.swift
git commit -m "feat: compose standard Sidebar/Toolbar/Inspector commands in View menu"
```

---

## Phase 3: Transaction Menu (BLOCKER Finding)

Create the domain menu for transactions — the single biggest structural gap in the current app. All transaction actions are currently only reachable via context menu or swipe. This phase adds a top-level `Transaction` menu consuming the `selectedTransaction` focused value from Phase 1.

### Task 3.0: Create shared NotificationNames file

**Files:**
- Create: `Shared/NotificationNames.swift`

`Notification.Name` constants must live in a shared (non-macOS-guarded) file because the views that listen to them (in `Features/*/Views/*.swift`) compile on both platforms. Putting the extension inside `#if os(macOS)` in a commands file would cause iOS compile errors at the `.onReceive` call site.

- [ ] **Step 1: Create the shared names file**

```swift
import Foundation

/// Cross-platform `Notification.Name` constants used by menu-bar commands to request
/// actions from the focused window's views. The commands (macOS-only) post these
/// notifications; the views (shared) listen via `.onReceive`. Keeping the names
/// outside `#if os(macOS)` lets both compile.
extension Notification.Name {
  // Transaction commands (posted by Features/Transactions/Commands/TransactionCommands.swift)
  static let requestTransactionEdit = Notification.Name("requestTransactionEdit")
  static let requestTransactionDuplicate = Notification.Name("requestTransactionDuplicate")
  static let requestTransactionDelete = Notification.Name("requestTransactionDelete")

  // Account commands
  static let requestAccountEdit = Notification.Name("requestAccountEdit")

  // Earmark commands
  static let requestEarmarkEdit = Notification.Name("requestEarmarkEdit")
  static let requestEarmarkToggleHidden = Notification.Name("requestEarmarkToggleHidden")
}
```

- [ ] **Step 2: Regenerate, build for both platforms, commit**

```bash
just generate
just build-mac && just build-ios
git add Shared/NotificationNames.swift project.yml Moolah.xcodeproj
git commit -m "feat: add shared Notification.Name constants for menu commands"
```

### Task 3.1: Create TransactionCommands struct

**Files:**
- Create: `Features/Transactions/Commands/TransactionCommands.swift`
- Modify: `App/MoolahApp.swift` — add to `.commands { }` block

- [ ] **Step 1: Create the commands file**

Create `Features/Transactions/Commands/TransactionCommands.swift`:

```swift
#if os(macOS)
  import SwiftUI

  /// Top-level `Transaction` menu. Operates on the focused window's selected transaction.
  ///
  /// See `guides/STYLE_GUIDE.md` §14 "Transaction" for naming, ordering, and shortcut rationale.
  /// Return and Delete keys fire via the list's native focus handling — they are *not* registered
  /// as menu shortcuts here (doing so would make them fire globally, e.g. while typing in a search
  /// field, which §14 explicitly forbids for destructive actions).
  struct TransactionCommands: Commands {
    @FocusedValue(\.selectedTransaction) private var selectedTransaction

    var body: some Commands {
      CommandMenu("Transaction") {
        Button("Edit Transaction\u{2026}") {
          NotificationCenter.default.post(
            name: .requestTransactionEdit,
            object: selectedTransaction?.wrappedValue?.id
          )
        }
        .disabled(selectedTransaction?.wrappedValue == nil)

        Button("Duplicate Transaction") {
          NotificationCenter.default.post(
            name: .requestTransactionDuplicate,
            object: selectedTransaction?.wrappedValue?.id
          )
        }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(selectedTransaction?.wrappedValue == nil)

        Divider()

        Button("Delete Transaction\u{2026}") {
          NotificationCenter.default.post(
            name: .requestTransactionDelete,
            object: selectedTransaction?.wrappedValue?.id
          )
        }
        .disabled(selectedTransaction?.wrappedValue == nil)
      }
    }
  }
#endif
```

Notification names live in a shared file (`Shared/NotificationNames.swift`) created in Task 3.0 below — they cannot be declared inside `#if os(macOS)` because views that listen to them compile on iOS.

Rationale: menu commands cannot call async store methods directly without access to the store. The `NotificationCenter` hop keeps `TransactionCommands` free of dependencies and lets the views that own the store listen and react. Return and Delete keys are handled by List's native row focus — the menu items appear with no shortcut indicator, which is correct per §14 (Philosophy: "Menus are for ⌘-modified commands").

- [ ] **Step 2: Add TransactionCommands to the app's commands block**

Edit `App/MoolahApp.swift` inside the `#if os(macOS)` `.commands { }` block, after `InspectorCommands()`:

```swift
.commands {
  AboutCommands()
  ProfileCommands(
    profileStore: profileStore, sessionManager: sessionManager,
    containerManager: containerManager)
  NewTransactionCommands()
  NewEarmarkCommands()
  RefreshCommands()
  SidebarCommands()
  ToolbarCommands()
  InspectorCommands()
  ShowHiddenCommands()
  TransactionCommands()
}
```

- [ ] **Step 3: Handle the Edit and Delete notifications in TransactionListView**

In `Features/Transactions/Views/TransactionListView.swift`, add state for the confirmation:

```swift
@State private var transactionPendingDelete: Transaction.ID?
```

At the end of the root view modifier chain (after the existing `.alert`), add:

```swift
.confirmationDialog(
  "Delete this transaction?",
  isPresented: Binding(
    get: { transactionPendingDelete != nil },
    set: { if !$0 { transactionPendingDelete = nil } }
  ),
  titleVisibility: .visible
) {
  Button("Delete Transaction", role: .destructive) {
    if let id = transactionPendingDelete {
      Task { await transactionStore.delete(id: id) }
    }
    transactionPendingDelete = nil
  }
  Button("Cancel", role: .cancel) { transactionPendingDelete = nil }
} message: {
  Text("This action cannot be undone.")
}
.onReceive(NotificationCenter.default.publisher(for: .requestTransactionEdit)) { note in
  // Open the inspector by setting the binding.
  guard let id = note.object as? Transaction.ID,
        let entry = filteredTransactions.first(where: { $0.transaction.id == id })
  else { return }
  selectedTransaction = entry.transaction
}
.onReceive(NotificationCenter.default.publisher(for: .requestTransactionDelete)) { note in
  // Only respond when this view owns the referenced transaction.
  guard let id = note.object as? Transaction.ID,
        filteredTransactions.contains(where: { $0.transaction.id == id })
  else { return }
  transactionPendingDelete = id
}
```

- [ ] **Step 4: Same confirmation handler in UpcomingView**

Apply the analogous change to `Features/Upcoming/Views/UpcomingView.swift` — its list of upcoming/overdue transactions. Scope the `guard` to its own data set.

- [ ] **Step 5: Update context-menu Delete to use the same confirmation path**

In `Features/Transactions/Views/TransactionListView.swift:198-202`, change:

```swift
Button("Delete", systemImage: "trash", role: .destructive) {
  Task {
    await transactionStore.delete(id: entry.transaction.id)
  }
}
```

to:

```swift
Button("Delete Transaction", systemImage: "trash", role: .destructive) {
  transactionPendingDelete = entry.transaction.id
}
```

Apply the same rename and flow to the swipe action at lines 204-212 (swipe actions on iOS can keep their existing direct-delete-or-confirm choice — see Task 3.6).

- [ ] **Step 6: Verify iOS swipe actions still show a confirmation**

On iOS the swipe `Button(role: .destructive)` label "Delete" should become "Delete Transaction" and drive the same `transactionPendingDelete` state, so iOS gets the confirmation alert via the same `.confirmationDialog`.

- [ ] **Step 7: Build and test**

```bash
just build-mac 2>&1 | tee .agent-tmp/phase3-build.txt
grep -i 'warning\|error' .agent-tmp/phase3-build.txt
just test TransactionStoreTests 2>&1 | tee .agent-tmp/phase3-test.txt
grep -i 'failed\|error:' .agent-tmp/phase3-test.txt
```
Expected: clean build, tests pass.

- [ ] **Step 8: Manual verification**

```bash
just run-mac
```

Verify:
- Transaction menu appears between View and Window
- With no selection: Edit Transaction… and Delete Transaction… are disabled (greyed out, not hidden)
- Select a transaction row: items enable; pressing Return opens the inspector; pressing Delete shows a confirmation dialog
- On iOS, swipe-to-delete a transaction: confirmation dialog appears, "Delete Transaction" is the destructive button

- [ ] **Step 9: Regenerate xcodeproj (new file added)**

```bash
just generate
```

- [ ] **Step 10: Commit**

```bash
git add Features/Transactions/Commands/TransactionCommands.swift Features/Transactions/Views/TransactionListView.swift Features/Upcoming/Views/UpcomingView.swift App/MoolahApp.swift project.yml Moolah.xcodeproj
git commit -m "feat: add Transaction menu with Edit/Delete and confirmation

Closes findings 1.3, 1.9, 4.2, 5.1, 6.2, 8.2"
```

### Task 3.2: Duplicate Transaction handler

Task 3.1 already registers the `Duplicate Transaction ⌘D` menu item. Wire up the view-side handler here; if the backing store method doesn't exist, disable the menu item rather than omitting it (§14 "Disable, don't hide").

**Files:**
- Modify: `Features/Transactions/TransactionStore.swift` (only if adding a `duplicate(id:)` method)
- Modify: `Features/Transactions/Views/TransactionListView.swift`

- [ ] **Step 1: Check whether `TransactionStore` has a duplicate method**

```bash
grep -n 'func duplicate' Features/Transactions/TransactionStore.swift
```

- [ ] **Step 2a: If the method exists — add the notification handler**

In `TransactionListView.swift`, alongside the existing delete `.onReceive`, add:

```swift
.onReceive(NotificationCenter.default.publisher(for: .requestTransactionDuplicate)) { note in
  guard let id = note.object as? Transaction.ID,
        filteredTransactions.contains(where: { $0.transaction.id == id })
  else { return }
  Task { await transactionStore.duplicate(id: id) }
}
```

- [ ] **Step 2b: If the method does NOT exist — disable the menu item**

In `TransactionCommands.swift`, change:

```swift
Button("Duplicate Transaction") { … }
  .keyboardShortcut("d", modifiers: .command)
  .disabled(selectedTransaction?.wrappedValue == nil)
```

to:

```swift
Button("Duplicate Transaction") { }
  .keyboardShortcut("d", modifiers: .command)
  .disabled(true)  // TODO: implement TransactionStore.duplicate(id:) and wire via notification
```

Add to `plans/FEATURE_IDEAS.md`:

```markdown
## Transaction menu items pending store support

- Duplicate Transaction (⌘D) — menu item exists disabled; needs `TransactionStore.duplicate(id:)`
- Mark as Cleared / Mark All as Cleared — needs `TransactionStore.markCleared(id:)`
- Pay Scheduled Transaction — exists as UpcomingView inline button; promote to store method
- Skip Next Occurrence — needs scheduled-transaction store action
- Reveal in Account — needs navigation via `sidebarSelection` focused value
- Copy Transaction Link — needs URL scheme for deep-linking to a transaction (see Task 5.3)
```

- [ ] **Step 3: Build, commit**

```bash
just build-mac && just build-ios
git add Features/Transactions/Commands/TransactionCommands.swift Features/Transactions/Views/TransactionListView.swift plans/FEATURE_IDEAS.md
git commit -m "feat: wire (or disable) Duplicate Transaction menu item"
```

---

## Phase 4: Go Menu + Account Menu Items

Add ⌘1–⌘6 navigation to the sidebar destinations. This is the Mac convention (NetNewsWire, Mail) and is a major discoverability gap today.

### Task 4.1: Create GoCommands

**Files:**
- Create: `Features/Navigation/Commands/GoCommands.swift`
- Modify: `App/MoolahApp.swift` — add to `.commands { }`

- [ ] **Step 1: Inspect the SidebarSelection enum**

Read `Features/Navigation/SidebarView.swift` and find the `SidebarSelection` enum (or whatever enum drives the `List` selection). Note the exact case names.

- [ ] **Step 2: Create the Go commands**

Create `Features/Navigation/Commands/GoCommands.swift`:

```swift
#if os(macOS)
  import SwiftUI

  /// Top-level `Go` menu. Navigates the focused window's sidebar to one of the primary destinations.
  ///
  /// See `guides/STYLE_GUIDE.md` §14 "Go" — ⌘1…⌘9 map to primary sidebar destinations only.
  struct GoCommands: Commands {
    @FocusedValue(\.sidebarSelection) private var sidebarSelection

    var body: some Commands {
      CommandMenu("Go") {
        Button("Accounts") { sidebarSelection?.wrappedValue = .accounts }
          .keyboardShortcut("1", modifiers: .command)
          .disabled(sidebarSelection == nil)

        Button("Transactions") { sidebarSelection?.wrappedValue = .allTransactions }
          .keyboardShortcut("2", modifiers: .command)
          .disabled(sidebarSelection == nil)

        Button("Scheduled") { sidebarSelection?.wrappedValue = .upcoming }
          .keyboardShortcut("3", modifiers: .command)
          .disabled(sidebarSelection == nil)

        Button("Earmarks") { sidebarSelection?.wrappedValue = .earmarksRoot }
          .keyboardShortcut("4", modifiers: .command)
          .disabled(sidebarSelection == nil)

        Button("Categories") { sidebarSelection?.wrappedValue = .categories }
          .keyboardShortcut("5", modifiers: .command)
          .disabled(sidebarSelection == nil)

        Button("Reports") { sidebarSelection?.wrappedValue = .analysis }
          .keyboardShortcut("6", modifiers: .command)
          .disabled(sidebarSelection == nil)

        Divider()

        // Back / Forward sidebar history. Disabled until the sidebar tracks history
        // (`SidebarHistoryStore` or similar) — §14 "Disable, don't hide" keeps them
        // in the menu so the shortcut namespace is reserved.
        Button("Go Back") { /* TODO: sidebar history pop */ }
          .keyboardShortcut("[", modifiers: .command)
          .disabled(true)

        Button("Go Forward") { /* TODO: sidebar history push */ }
          .keyboardShortcut("]", modifiers: .command)
          .disabled(true)
      }
    }
  }
#endif
```

Add to `plans/FEATURE_IDEAS.md`:

```markdown
- Go Back / Go Forward — requires a sidebar history stack (stored per-window). Disabled stubs are in `GoCommands` so ⌘[ / ⌘] are reserved.
```

Adjust the enum case names to match the actual codebase — this is the pattern, not the literal cases.

- [ ] **Step 3: Add to the commands block**

In `App/MoolahApp.swift` `.commands { }`, insert `GoCommands()` after `InspectorCommands()`:

```swift
InspectorCommands()
GoCommands()
ShowHiddenCommands()
TransactionCommands()
```

- [ ] **Step 4: Regenerate and build**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/phase4-build.txt
grep -i 'warning\|error' .agent-tmp/phase4-build.txt
```

- [ ] **Step 5: Manual verification**

```bash
just run-mac
```

Verify Go menu appears between View and Window; pressing ⌘1…⌘6 navigates the sidebar. Each item disabled when no window is focused.

- [ ] **Step 6: Commit**

```bash
git add Features/Navigation/Commands/GoCommands.swift App/MoolahApp.swift project.yml Moolah.xcodeproj
git commit -m "feat: add Go menu with Cmd+1..6 sidebar navigation

Closes findings 1.8, 4.1"
```

### Task 4.2: Add Edit Account / View Transactions menu items (Finding 1.4)

The current app only exposes these via context menu on sidebar account rows. Add them to the Transaction menu (as "Reveal in Account") or a new Account sub-group. Simplest: add them as an Account `CommandMenu` positioned after Transaction.

**Files:**
- Create: `Features/Accounts/Commands/AccountCommands.swift`
- Modify: `App/MoolahApp.swift`

- [ ] **Step 1: Create AccountCommands**

```swift
#if os(macOS)
  import SwiftUI

  /// Top-level `Account` menu. Operates on the focused window's selected account (sidebar).
  /// Permitted by §14 "Additional Domain Menus" — positioned between Transaction and Earmark.
  /// Notification names are declared in `Shared/NotificationNames.swift` (cross-platform).
  struct AccountCommands: Commands {
    @FocusedValue(\.selectedAccount) private var selectedAccount
    @FocusedValue(\.sidebarSelection) private var sidebarSelection

    var body: some Commands {
      CommandMenu("Account") {
        Button("Edit Account\u{2026}") {
          NotificationCenter.default.post(
            name: .requestAccountEdit,
            object: selectedAccount?.wrappedValue?.id
          )
        }
        .disabled(selectedAccount?.wrappedValue == nil)

        Button("View Transactions") {
          if let id = selectedAccount?.wrappedValue?.id {
            sidebarSelection?.wrappedValue = .account(id)
          }
        }
        .disabled(selectedAccount?.wrappedValue == nil)
      }
    }
  }
#endif
```

- [ ] **Step 2: Handle the notification in SidebarView (or wherever EditAccountView is presented)**

Wire the existing "Edit Account" context-menu handler in `SidebarView.swift:37` to also respond to `requestAccountEdit` notifications with the ID payload.

- [ ] **Step 3: Add to commands block**

Insert `AccountCommands()` after `TransactionCommands()`:

```swift
TransactionCommands()
AccountCommands()
```

- [ ] **Step 4: Regenerate, build, commit**

```bash
just generate
just build-mac
git add Features/Accounts/Commands/AccountCommands.swift Features/Navigation/SidebarView.swift App/MoolahApp.swift project.yml Moolah.xcodeproj
git commit -m "feat: add Account menu with Edit and View Transactions

Closes finding 1.4"
```

---

## Phase 5: Edit Menu Additions + Remove Duplicate Toolbar Shortcuts

Add Find Transactions… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G), and Copy Transaction Link (⌃⌘C) to the Edit menu. Remove the ⌘F and ⌘R shortcuts from the TransactionListView toolbar buttons so the menu items are authoritative.

### Task 5.1: Create FindCommands

**Files:**
- Create: `Features/Transactions/Commands/FindCommands.swift`
- Modify: `Features/Transactions/Views/TransactionListView.swift` — publish `findInListAction`
- Modify: `App/MoolahApp.swift` — add to `.commands { }`

- [ ] **Step 1: Create the command**

```swift
#if os(macOS)
  import SwiftUI

  /// Adds Find Transactions… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G) to the Edit menu.
  /// Find Next and Find Previous are registered disabled — the list's search field does not
  /// support cycling through matches yet. §14 "Disable, don't hide" keeps them visible so
  /// the shortcut namespace is reserved and Help > Search can find them.
  struct FindCommands: Commands {
    @FocusedValue(\.findInListAction) private var findAction

    var body: some Commands {
      CommandGroup(after: .textEditing) {
        Button("Find Transactions\u{2026}") { findAction?() }
          .keyboardShortcut("f", modifiers: .command)
          .disabled(findAction == nil)

        Button("Find Next") { /* TODO: advance search cursor */ }
          .keyboardShortcut("g", modifiers: .command)
          .disabled(true)

        Button("Find Previous") { /* TODO: retreat search cursor */ }
          .keyboardShortcut("g", modifiers: [.command, .shift])
          .disabled(true)
      }
    }
  }
#endif
```

- [ ] **Step 2: Publish `findInListAction` from TransactionListView**

In `Features/Transactions/Views/TransactionListView.swift`, add state for focusing search:

```swift
@FocusState private var searchFieldFocused: Bool
```

and apply `.focused($searchFieldFocused)` to the search field (the `.searchable(...)` modifier doesn't directly support `@FocusState` — if so, wrap the list in a container and use `.searchFocused($searchFieldFocused)` available in iOS 17+/macOS 14+).

Publish the focus action:

```swift
.focusedSceneValue(\.findInListAction, { searchFieldFocused = true })
```

If `.searchFocused` is not available on the target OS, fall back to: publish a closure that triggers a `@State private var focusSearchToggle: Bool` toggle, and observe it in a `.onChange` that sets `searchFieldFocused = true`.

- [ ] **Step 3: Remove the toolbar `.keyboardShortcut("f", modifiers: .command)` on the Filter button**

In `Features/Transactions/Views/TransactionListView.swift:258`, change:

```swift
.keyboardShortcut("f", modifiers: .command)
```

**This needs care** — the toolbar button is labeled "Filter" and opens a sheet, while the menu item is labeled "Find Transactions…" and focuses the search field. These are *different actions*. Per the style guide: ⌘F means "find" on Mac, which aligns with the search field, not the filter sheet. Options:

- **Option A (recommended):** Keep the Filter toolbar button, remove its `.keyboardShortcut`, and make ⌘F exclusively focus the search field via the new menu item. The filter sheet is reached via the toolbar button only.
- **Option B:** Rename Filter to Find, drop the sheet, build filtering into the search field. Larger change — out of scope for this plan.

Go with Option A: delete `.keyboardShortcut("f", modifiers: .command)` from line 258.

- [ ] **Step 4: Add FindCommands to the commands block**

```swift
AccountCommands()
FindCommands()
```

- [ ] **Step 5: Build, verify**

```bash
just generate
just build-mac
just run-mac
```

Verify ⌘F focuses the search field in the transaction list. The toolbar Filter button still opens the sheet (no longer bound to ⌘F).

- [ ] **Step 6: Commit**

```bash
git add Features/Transactions/Commands/FindCommands.swift Features/Transactions/Views/TransactionListView.swift App/MoolahApp.swift project.yml Moolah.xcodeproj
git commit -m "feat: add Edit > Find Transactions... (Cmd+F); remove duplicate toolbar shortcut

Closes findings 1.1, 2.4, 4.7"
```

### Task 5.3: Stub Copy Transaction Link in Edit menu

**Files:**
- Create: `Features/Transactions/Commands/CopyLinkCommands.swift`
- Modify: `App/MoolahApp.swift`

§14's Edit menu outline lists `Copy Transaction Link ⌃⌘C`. A real implementation depends on a deep-link URL scheme that doesn't yet exist. Per §14 "Disable, don't hide," add the item now as a disabled stub so the shortcut is reserved and Help > Search can find it.

- [ ] **Step 1: Create CopyLinkCommands**

```swift
#if os(macOS)
  import SwiftUI

  /// Edit > Copy Transaction Link (⌃⌘C). Currently a disabled stub — the URL scheme
  /// handler (`URLSchemeHandler`) doesn't yet support per-transaction deep links.
  /// Tracked in `plans/FEATURE_IDEAS.md`.
  struct CopyLinkCommands: Commands {
    @FocusedValue(\.selectedTransaction) private var selectedTransaction

    var body: some Commands {
      CommandGroup(after: .pasteboard) {
        Button("Copy Transaction Link") { /* TODO: generate and copy moolah:// URL */ }
          .keyboardShortcut("c", modifiers: [.command, .control])
          .disabled(true)  // Always disabled until deep-link URL scheme is implemented
      }
    }
  }
#endif
```

- [ ] **Step 2: Register in the commands block**

```swift
AccountCommands()
FindCommands()
CopyLinkCommands()
HelpCommands()
```

- [ ] **Step 3: Build, commit**

```bash
just generate
just build-mac && just build-ios
git add Features/Transactions/Commands/CopyLinkCommands.swift App/MoolahApp.swift project.yml Moolah.xcodeproj
git commit -m "feat: stub Edit > Copy Transaction Link (disabled, reserves Ctrl+Cmd+C)"
```

### Task 5.2: Remove duplicate ⌘N and ⌘R from TransactionListView toolbar

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift`

- [ ] **Step 1: Remove duplicate shortcuts**

On line 269 (Refresh button):
```swift
.keyboardShortcut("r", modifiers: .command)   // ← DELETE this line
```

On line 278 (Add Transaction button):
```swift
.keyboardShortcut("n", modifiers: .command)   // ← DELETE this line
```

Rationale: `NewTransactionCommands` owns ⌘N and `RefreshCommands` owns ⌘R app-wide. Duplicating them on toolbar buttons is the anti-pattern flagged by §14.

- [ ] **Step 2: Verify the shortcuts still work**

```bash
just run-mac
```

Verify ⌘N and ⌘R still fire the correct actions (from the menu bar). The toolbar buttons themselves remain clickable.

- [ ] **Step 3: Commit**

```bash
git add Features/Transactions/Views/TransactionListView.swift
git commit -m "refactor: remove duplicate Cmd+N and Cmd+R shortcuts from toolbar buttons

Closes findings 2.5, 8.1"
```

---

## Phase 6: Help Menu + Keyboard Shortcuts Window

Populate the Help menu with Moolah Help, Keyboard Shortcuts…, Release Notes, Report a Bug. Add an in-app Keyboard Shortcuts cheatsheet window.

### Task 6.1: Create the Keyboard Shortcuts cheatsheet view

**Files:**
- Create: `Features/Help/KeyboardShortcutsView.swift`

- [ ] **Step 1: Build the cheatsheet**

```swift
import SwiftUI

/// In-app reference listing every app keyboard shortcut, including unmodified list-navigation keys
/// that don't live in menus. See `guides/STYLE_GUIDE.md` §14 Keyboard Shortcuts.
struct KeyboardShortcutsView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("Keyboard Shortcuts")
          .font(.largeTitle.bold())

        section("File") {
          row("⌘N", "New Transaction")
          row("⇧⌘N", "New Earmark")
          row("⌃⌘N", "New Account")
          row("⌥⌘N", "New Category")
          row("⇧⌘I", "Import Profile")
          row("⇧⌘E", "Export Profile")
          row("⇧⌘Q", "Sign Out")
          row("⌘W", "Close Window")
        }
        section("Edit") {
          row("⌘F", "Find Transactions")
          row("⌘G", "Find Next")
          row("⇧⌘G", "Find Previous")
          row("⌃⌘C", "Copy Transaction Link")
        }
        section("View") {
          row("⌃⌘S", "Show / Hide Sidebar")
          row("⌥⌘I", "Show / Hide Inspector")
          row("⇧⌘H", "Show / Hide Hidden Accounts")
          row("⌃⌘F", "Enter / Exit Full Screen")
        }
        section("Go") {
          row("⌘1", "Accounts")
          row("⌘2", "Transactions")
          row("⌘3", "Scheduled")
          row("⌘4", "Earmarks")
          row("⌘5", "Categories")
          row("⌘6", "Reports")
          row("⌘[", "Go Back")
          row("⌘]", "Go Forward")
        }
        section("Transaction") {
          row("Return", "Edit Transaction (on selected row)")
          row("Delete", "Delete Transaction (on selected row)")
          row("⌘D", "Duplicate Transaction")
        }
        section("List Navigation") {
          row("↑ / ↓", "Move selection")
          row("Space", "Open inspector for selected item")
          row("Escape", "Deselect / dismiss inspector")
        }
        section("Help") {
          row("⇧⌘/", "Open Keyboard Shortcuts")
        }
        section("System") {
          row("⌘,", "Settings")
          row("⌘Q", "Quit Moolah")
          row("⌘H", "Hide Moolah")
          row("⌘M", "Minimize Window")
        }
      }
      .padding(32)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 520, minHeight: 640)
  }

  @ViewBuilder
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      content()
    }
  }

  private func row(_ keys: String, _ action: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(keys)
        .font(.body.monospaced())
        .frame(minWidth: 80, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)  // key column sizes to content; won't clip at large Dynamic Type
      Text(action)
      Spacer()
    }
  }
}

#Preview { KeyboardShortcutsView() }
```

- [ ] **Step 2: Commit**

```bash
just generate
git add Features/Help/KeyboardShortcutsView.swift project.yml Moolah.xcodeproj
git commit -m "feat: add in-app Keyboard Shortcuts cheatsheet view"
```

### Task 6.2: Add HelpCommands and a shortcuts Window scene

**Files:**
- Create: `Features/Help/HelpCommands.swift`
- Modify: `App/MoolahApp.swift` — add Window scene + register HelpCommands

- [ ] **Step 1: Create HelpCommands**

```swift
#if os(macOS)
  import SwiftUI

  /// Appends Moolah Help, Keyboard Shortcuts cheatsheet, and support links to the system Help menu.
  /// Uses `after: .help` — never `replacing: .help` — to preserve the SwiftUI-provided search field
  /// that indexes every menu item by name. §14 explicitly forbids removing the Help menu.
  /// ⌘? is reserved by the system for Help menu activation and is NOT registered here.
  struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
      CommandGroup(after: .help) {
        Button("Moolah Help") {
          openURL(URL(string: "https://moolah.app/help")!)
        }

        Button("Keyboard Shortcuts\u{2026}") {
          openWindow(id: "keyboard-shortcuts")
        }
        .keyboardShortcut("/", modifiers: [.command, .shift])

        Divider()

        Button("Release Notes\u{2026}") {
          openURL(URL(string: "https://moolah.app/release-notes")!)
        }

        Button("Report a Bug\u{2026}") {
          openURL(URL(string: "https://github.com/ajsutton/moolah-native/issues/new")!)
        }

        Divider()

        Button("Privacy Policy") {
          openURL(URL(string: "https://moolah.app/privacy")!)
        }

        Button("Terms of Service") {
          openURL(URL(string: "https://moolah.app/terms")!)
        }
      }
    }
  }
#endif
```

Rationale: `CommandGroup(after: .help)` appends items *below* SwiftUI's built-in search field, preserving it. The Keyboard Shortcuts cheatsheet gets ⇧⌘/ (matching the §14 shortcut map); ⌘? remains owned by the system for opening the Help menu. Privacy Policy and Terms of Service take no user input so they have no ellipsis. Release Notes… and Report a Bug… open external pages/forms so they do.

- [ ] **Step 2: Add the Window scene and register HelpCommands**

In `App/MoolahApp.swift` `#if os(macOS)` branch, near the existing `Window("About Moolah", id: "about")` scene:

```swift
Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
  KeyboardShortcutsView()
}
.windowResizability(.contentSize)
```

Register the command in `.commands { }`:

```swift
AccountCommands()
FindCommands()
HelpCommands()
```

- [ ] **Step 3: Build, run, verify**

```bash
just generate
just build-mac
just run-mac
```

Verify Help menu now contains: [system search field], Moolah Help (⌘?), Keyboard Shortcuts… (⇧⌘/), Release Notes…, Report a Bug…. Clicking Keyboard Shortcuts… opens the cheatsheet window. URLs open in browser.

- [ ] **Step 4: Commit**

```bash
git add Features/Help/HelpCommands.swift App/MoolahApp.swift project.yml Moolah.xcodeproj
git commit -m "feat: populate Help menu and add Keyboard Shortcuts window

Closes finding 4.5"
```

---

## Phase 7: Fix ShowHiddenCommands (Toggle → Button Verb-Pair)

### Task 7.1: Replace Toggle with Button that flips label and stays visible

**Files:**
- Modify: `App/MoolahApp.swift:53-63`

- [ ] **Step 1: Replace the struct body**

Change:

```swift
struct ShowHiddenCommands: Commands {
  @FocusedValue(\.showHiddenAccounts) private var showHidden

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      if let showHidden {
        Toggle("Show Hidden Accounts", isOn: showHidden)
          .keyboardShortcut("h", modifiers: [.command, .shift])
      }
    }
  }
}
```

to:

```swift
struct ShowHiddenCommands: Commands {
  @FocusedValue(\.showHiddenAccounts) private var showHidden

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button(showHidden?.wrappedValue == true ? "Hide Hidden Accounts" : "Show Hidden Accounts") {
        showHidden?.wrappedValue.toggle()
      }
      .keyboardShortcut("h", modifiers: [.command, .shift])
      .disabled(showHidden == nil)
    }
  }
}
```

Rationale: §14 "Toggle State" requires verb-pair labels and §14 Anti-Patterns forbids hiding items when a focused value is nil (must be disabled instead).

- [ ] **Step 2: Build and verify**

```bash
just build-mac
just run-mac
```

Verify: View menu always contains "Show Hidden Accounts" / "Hide Hidden Accounts" (label flips with state). Disabled (greyed) when no window is focused. ⇧⌘H toggles it.

- [ ] **Step 3: Commit**

```bash
git add App/MoolahApp.swift
git commit -m "fix: ShowHiddenCommands uses verb-pair label and stays visible when disabled

Closes findings 3.1, 8.3"
```

---

## Phase 8: Sign Out Placement + New Account/Category Commands

### Task 8.1: Move Sign Out to File menu, change shortcut to ⇧⌘Q

**Files:**
- Modify: `Features/Profiles/ProfileCommands.swift`

- [ ] **Step 1: Restructure the ProfileCommands body**

Replace the current two-`CommandGroup` body with a single group that positions Sign Out at the end of File, separated by a divider:

```swift
var body: some Commands {
  CommandGroup(before: .saveItem) {
    OpenProfileMenu(profileStore: profileStore)

    Divider()

    ExportImportButtons(
      profileStore: profileStore,
      containerManager: containerManager,
      session: session
    )
  }

  CommandGroup(after: .importExport) {
    Divider()
    Button("Sign Out") {
      if let authStore {
        Task { await authStore.signOut() }
      }
    }
    .disabled(authStore == nil || authStore?.requiresSignIn != true)
    .keyboardShortcut("q", modifiers: [.command, .shift])
  }
}
```

Note: `after: .importExport` puts Sign Out in File, below the Import/Export group and above the system-provided Close Window / Quit.

- [ ] **Step 2: Build and verify**

```bash
just build-mac
just run-mac
```

Verify: Sign Out now appears in the File menu (below Import/Export, in its own divider-separated group). Shortcut is ⇧⌘Q. Disabled when no window or no sign-in-capable auth store is present.

- [ ] **Step 3: Commit**

```bash
git add Features/Profiles/ProfileCommands.swift
git commit -m "fix: move Sign Out to File menu with Cmd+Shift+Q shortcut

Closes findings 2.2, 4.3, 6.1, 6.3"
```

### Task 8.2: Create NewAccountCommands and NewCategoryCommands

**Files:**
- Create: `App/NewAccountCommands.swift` (next to the existing new-* commands in MoolahApp.swift — or extract all New* commands into a new file)

- [ ] **Step 1: Create the new command structs**

In a new file `Features/Accounts/Commands/NewAccountCommands.swift`:

```swift
#if os(macOS)
  import SwiftUI

  struct NewAccountCommands: Commands {
    @FocusedValue(\.newAccountAction) private var newAccountAction

    var body: some Commands {
      CommandGroup(after: .newItem) {
        Button("New Account\u{2026}") { newAccountAction?() }
          .keyboardShortcut("n", modifiers: [.command, .control])
          .disabled(newAccountAction == nil)
      }
    }
  }
#endif
```

In `Features/Categories/Commands/NewCategoryCommands.swift`:

```swift
#if os(macOS)
  import SwiftUI

  struct NewCategoryCommands: Commands {
    @FocusedValue(\.newCategoryAction) private var newCategoryAction

    var body: some Commands {
      CommandGroup(after: .newItem) {
        Button("New Category\u{2026}") { newCategoryAction?() }
          .keyboardShortcut("n", modifiers: [.command, .option])
          .disabled(newCategoryAction == nil)
      }
    }
  }
#endif
```

- [ ] **Step 2: Publish the new actions**

In `SidebarView.swift`, alongside the existing `.focusedSceneValue(\.newEarmarkAction, …)`, add:

```swift
.focusedSceneValue(\.newAccountAction) { /* existing "new account" closure from the toolbar button */ }
```

The closure should match the action currently wired to the SidebarView's macOS-only "+ New Account" toolbar button (line 200 per the audit).

In `Features/Categories/Views/CategoriesView.swift`, alongside its existing list handlers, publish:

```swift
.focusedSceneValue(\.newCategoryAction) { showAddCategorySheet = true }   // or whatever the existing toolbar handler does
```

- [ ] **Step 3: Add both commands to the app commands block**

Insert after `NewEarmarkCommands()`:

```swift
NewTransactionCommands()
NewEarmarkCommands()
NewAccountCommands()
NewCategoryCommands()
```

- [ ] **Step 4: Regenerate, build, run, verify**

```bash
just generate
just build-mac
just run-mac
```

File menu now has: New Transaction (⌘N), New Earmark (⇧⌘N), New Account… (⌃⌘N), New Category… (⌥⌘N). Each disabled when no corresponding window is focused.

- [ ] **Step 5: Commit**

```bash
git add Features/Accounts/Commands/NewAccountCommands.swift Features/Categories/Commands/NewCategoryCommands.swift Features/Navigation/SidebarView.swift Features/Categories/Views/CategoriesView.swift App/MoolahApp.swift project.yml Moolah.xcodeproj
git commit -m "feat: add New Account and New Category menu commands

Closes finding 8.4"
```

---

## Phase 9: Naming, Ellipsis, Remove Dangerous View-Level Shortcuts

Pure cleanup — no new surface area. A handful of small fixes that each close one finding.

### Task 9.1: Remove ⇧⌘N from CategoriesView and SettingsView toolbar buttons

**Files:**
- Modify: `Features/Categories/Views/CategoriesView.swift:164`
- Modify: `Features/Settings/SettingsView.swift:284`

- [ ] **Step 1: Remove conflicting shortcuts**

Delete these lines entirely:

```swift
.keyboardShortcut("n", modifiers: [.command, .shift])   // from CategoriesView:164
.keyboardShortcut("n", modifiers: [.command, .shift])   // from SettingsView:284
```

Rationale: Both collide with `NewEarmarkCommands` (⇧⌘N). The New Category shortcut is ⌥⌘N via the new `NewCategoryCommands` from Phase 8; the SettingsView profile-add button should not have any global shortcut (it lives in a settings sheet).

- [ ] **Step 2: Build and commit**

```bash
just build-mac
git add Features/Categories/Views/CategoriesView.swift Features/Settings/SettingsView.swift
git commit -m "fix: remove Cmd+Shift+N shortcut collisions with NewEarmarkCommands

Closes finding 2.1"
```

### Task 9.2: Remove ⌘⌫ from Clear All and bare ⌫ from SettingsView profile remove

**Files:**
- Modify: `Features/Transactions/Views/TransactionFilterView.swift:173`
- Modify: `Features/Settings/SettingsView.swift:301`

- [ ] **Step 1: Delete dangerous shortcuts**

From `TransactionFilterView.swift:173`:
```swift
.keyboardShortcut(.delete, modifiers: .command)   // ← DELETE
```

From `SettingsView.swift:301`:
```swift
.keyboardShortcut(.delete, modifiers: [])   // ← DELETE
```

Rationale: §14 Destructive Actions — "No bare shortcut on destructive items" (Clear All filter with ⌘⌫ is a misfire hazard); bare ⌫ on a sheet button inside SettingsView fires whenever a user presses Delete with unrelated intent.

- [ ] **Step 2: Build and commit**

```bash
just build-mac
git add Features/Transactions/Views/TransactionFilterView.swift Features/Settings/SettingsView.swift
git commit -m "fix: remove dangerous destructive keyboard shortcuts

Closes findings 2.6, 2.7"
```

### Task 9.3: Add ellipsis to New Transaction and New Earmark menu items

**Files:**
- Modify: `App/MoolahApp.swift:12,27`

- [ ] **Step 1: Add ellipses**

```swift
// Line 12
Button("New Transaction\u{2026}") { newTransactionAction?() }
// Line 27
Button("New Earmark\u{2026}") { newEarmarkAction?() }
```

Rationale: Both open form sheets requiring user input (payee, amount, etc.). §14 Naming: ellipsis iff the action requires additional input before taking effect.

- [ ] **Step 2: Build and commit**

```bash
just build-mac
git add App/MoolahApp.swift
git commit -m "fix: add ellipsis to New Transaction… and New Earmark… menu items

Closes finding 3.2"
```

### Task 9.4: Rename context menu labels (add object noun, add ellipsis where appropriate)

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift:194,198`
- Modify: `Features/Upcoming/Views/UpcomingView.swift:46,49,53,95,98,102`
- Modify: `Features/Categories/Views/CategoriesView.swift:131`
- Modify: `Features/Earmarks/Views/EarmarksView.swift:146,150`
- Modify: `Features/Navigation/SidebarView.swift:37-43,109-115`

- [ ] **Step 1: TransactionListView context menu**

Already partially handled in Phase 3. Confirm the rename landed there. If not, now:

- `Button("Edit", systemImage: "pencil")` → `Button("Edit Transaction\u{2026}", systemImage: "pencil")`
- `Button("Delete", systemImage: "trash", role: .destructive)` → `Button("Delete Transaction", systemImage: "trash", role: .destructive)`

Keep `systemImage:` — context menu icons are correct per Phase 0 clarification.

- [ ] **Step 2: UpcomingView context menus**

Both the Overdue (line 46) and Upcoming (line 95) context menus. Change (per §14 "Keep the object noun"):

- `"Pay Now"` → `"Pay Scheduled Transaction"`
- `"Edit"` → `"Edit Transaction\u{2026}"`
- `"Delete"` → `"Delete Transaction"`

No ellipsis on Pay — it acts immediately without an additional form.

- [ ] **Step 3: CategoriesView context menu**

`Button("Edit", systemImage: "pencil")` → `Button("Edit Category\u{2026}", systemImage: "pencil")` at line 131.

- [ ] **Step 4: EarmarksView context menu**

- `"Edit"` → `"Edit Earmark\u{2026}"`
- `"Hide"` → ternary `earmark.isHidden ? "Show Earmark" : "Hide Earmark"` — must flip to match `EarmarkCommands` (§14 Context Menu ↔ Menu Bar Parity). Also swap the `systemImage` and `role`:

```swift
Button(
  earmark.isHidden ? "Show Earmark" : "Hide Earmark",
  systemImage: earmark.isHidden ? "eye" : "eye.slash",
  role: earmark.isHidden ? nil : .destructive
) {
  toggleHidden(earmark)
}
```

- [ ] **Step 5: SidebarView context menus**

Both the Current Accounts context menu (line 37) and Investment account context menu (line 109):
- `"Edit Account"` → `"Edit Account\u{2026}"` (opens a form)
- `"View Transactions"` stays as-is (no object ambiguity)

- [ ] **Step 6: Verify iOS**

Build for iOS and verify the renamed context menus render correctly (long-press on a transaction row in the simulator):

```bash
just build-ios
```

Expected: clean build, no layout issues. Context menus keep their icons on iOS.

- [ ] **Step 7: Commit**

```bash
git add Features/Transactions/Views/TransactionListView.swift Features/Upcoming/Views/UpcomingView.swift Features/Categories/Views/CategoriesView.swift Features/Earmarks/Views/EarmarksView.swift Features/Navigation/SidebarView.swift
git commit -m "fix: rename context menu labels to include object noun and ellipsis

Closes findings 1.6, 3.5, 3.6"
```

### Task 9.5: Hide Earmark — verify not just context-menu but also menu-bar reachable

**Files:**
- Modify: `Features/Earmarks/Commands/EarmarkCommands.swift` (create)
- Modify: `App/MoolahApp.swift`

- [ ] **Step 1: Create EarmarkCommands with Hide/Show**

```swift
#if os(macOS)
  import SwiftUI

  /// Top-level `Earmark` menu. Permitted by §14 "Additional Domain Menus."
  /// Notification names live in `Shared/NotificationNames.swift`.
  struct EarmarkCommands: Commands {
    @FocusedValue(\.selectedEarmark) private var selectedEarmark

    var body: some Commands {
      CommandMenu("Earmark") {
        Button("Edit Earmark\u{2026}") {
          NotificationCenter.default.post(
            name: .requestEarmarkEdit,
            object: selectedEarmark?.wrappedValue?.id
          )
        }
        .disabled(selectedEarmark?.wrappedValue == nil)

        Button(selectedEarmark?.wrappedValue?.isHidden == true ? "Show Earmark" : "Hide Earmark") {
          NotificationCenter.default.post(
            name: .requestEarmarkToggleHidden,
            object: selectedEarmark?.wrappedValue?.id
          )
        }
        .disabled(selectedEarmark?.wrappedValue == nil)
      }
    }
  }
#endif
```

- [ ] **Step 2: Handle the notifications in EarmarksView**

Listen with `.onReceive` and call the existing edit / hide actions.

- [ ] **Step 3: Add to commands block, build, commit**

Insert `EarmarkCommands()` after `AccountCommands()` in `.commands { }`:

```swift
TransactionCommands()
AccountCommands()
EarmarkCommands()
FindCommands()
HelpCommands()
```

```bash
just generate
just build-mac
git add Features/Earmarks/Commands/EarmarkCommands.swift Features/Earmarks/Views/EarmarksView.swift App/MoolahApp.swift project.yml Moolah.xcodeproj
git commit -m "feat: add Earmark menu with Edit and Hide/Show

Closes finding 1.5"
```

### Task 9.6: Move RefreshCommands to its own File group

**Files:**
- Modify: `App/MoolahApp.swift:37-50`

§14's note on Refresh says: "If you want the shortcut available outside a scrollable list, add a File > Refresh item." The current placement `after: .newItem` puts Refresh immediately adjacent to the New* items, which is a grouping error — Refresh is not a creation action. The fix is to keep it in File but place it in its own divider-separated group, not inline with creations.

- [ ] **Step 1: Change the placement anchor**

```swift
struct RefreshCommands: Commands {
  @FocusedValue(\.refreshAction) private var refreshAction

  var body: some Commands {
    CommandGroup(before: .saveItem) {  // ← was after: .newItem
      Divider()
      Button("Refresh") { refreshAction?() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(refreshAction == nil)
    }
  }
}
```

Rationale: `before: .saveItem` places this group after the New* creation group but before the Open Profile / Import / Export group added by `ProfileCommands`. The explicit `Divider()` guarantees separation regardless of registration order.

- [ ] **Step 2: Build, verify, commit**

```bash
just build-mac
just run-mac
# Verify: Refresh appears in File below the New* items, separated by a divider.
git add App/MoolahApp.swift
git commit -m "fix: separate Refresh from New* group in File menu

Closes finding 3.3"
```

---

## Phase 10: UI Reviewer Verification

Final verification that the implementation matches the style guide. Run the `ui-review` agent over all modified files, fix any findings, repeat until clean.

### Task 10.1: Run UI reviewer on the full menu surface

**Files:**
- All files modified in Phases 1–9

- [ ] **Step 1: Invoke the `ui-review` agent**

Dispatch via the Agent tool (from a Claude Code session):

```
Agent tool → subagent_type: ui-review
Prompt:
Review all macOS menu bar and command code in Moolah against guides/STYLE_GUIDE.md §14 Menu Bar & Commands. Files to review:
- App/MoolahApp.swift (commands block, NewTransactionCommands, NewEarmarkCommands, RefreshCommands, ShowHiddenCommands)
- Features/About/AboutCommands.swift
- Features/Profiles/ProfileCommands.swift
- Features/Export/ExportImportCommands.swift
- Features/Transactions/Commands/TransactionCommands.swift
- Features/Transactions/Commands/FindCommands.swift
- Features/Navigation/Commands/GoCommands.swift
- Features/Accounts/Commands/AccountCommands.swift
- Features/Accounts/Commands/NewAccountCommands.swift
- Features/Categories/Commands/NewCategoryCommands.swift
- Features/Earmarks/Commands/EarmarkCommands.swift
- Features/Help/HelpCommands.swift
- Features/Help/KeyboardShortcutsView.swift
- Shared/FocusedValues.swift

Cross-check:
- Features/Transactions/Views/TransactionListView.swift (toolbar, context menu, focused values)
- Features/Upcoming/Views/UpcomingView.swift (context menus, focused values, delete confirmation)
- Features/Categories/Views/CategoriesView.swift (toolbar, context menu, focused value)
- Features/Earmarks/Views/EarmarksView.swift (toolbar, context menu, focused value)
- Features/Navigation/SidebarView.swift (toolbar, context menus, focused values)
- Features/Transactions/Views/TransactionFilterView.swift
- Features/Settings/SettingsView.swift

Produce findings only for issues that remain *after* this plan's changes — prior findings that were addressed should not reappear. Flag:
1. Any remaining naming violations (title case, ellipsis, verb-pair)
2. Any remaining shortcut issues (collisions, view-only shortcuts, reserved assignments)
3. Any remaining toolbar ↔ menu ↔ context-menu parity gaps
4. Any new issues introduced by the fix (e.g. a new command without a focused value, a new context menu that doesn't mirror a menu-bar entry)
5. Any regressions in iOS compatibility (e.g. macOS-only code leaking out of #if, iOS context menus losing icons)

Output a prioritized list. If there are zero findings, say so explicitly.
```

- [ ] **Step 2: Fix any reported issues**

For each finding:
- Open the referenced file, make the fix
- Run `just build-mac` and `just build-ios` to verify no regressions
- Commit as a separate fix

- [ ] **Step 3: Re-run the ui-review agent**

Repeat Step 1 with the same prompt, plus:
```
This is iteration N+1. Previous iteration found [list]. Verify those are now resolved.
```

- [ ] **Step 4: Repeat Steps 2–3 until the agent reports zero findings**

- [ ] **Step 5: Final manual verification on both platforms**

```bash
just build-mac && just run-mac
just build-ios
```

Manual checklist (macOS):
- Every top-level menu (Moolah / File / Edit / View / Go / Transaction / Account / Earmark / Window / Help) exists and matches the §14 outline
- No two visible menu items share a keyboard shortcut
- Pressing ⌘H hides the app (not some other action); ⌘M minimizes
- ⌘N creates a transaction, ⇧⌘N creates an earmark, ⌃⌘N creates an account, ⌥⌘N creates a category
- ⌘1…⌘6 navigate the sidebar
- Transaction menu items are disabled (not hidden) when no transaction is selected
- View > Show Hidden Accounts label flips between Show/Hide when toggled
- Delete on a transaction row shows a confirmation dialog
- Help menu has the system search field and Keyboard Shortcuts… opens the cheatsheet window

Manual checklist (iOS):
- App launches, transaction list renders, context menus appear on long-press with icons
- Swipe-to-delete on a transaction shows the confirmation dialog
- No runtime crashes or missing-symbol errors

- [ ] **Step 6: Final commit if any changes were made during iteration**

```bash
git status
# if clean: no final commit needed
# otherwise: commit the cumulative fixes
```

### Task 10.2: Update ROADMAP.md and move this plan

**Files:**
- Modify: `plans/ROADMAP.md` (if it has a menu-bar entry)
- Move: `plans/2026-04-17-menu-bar-compliance-plan.md` → `plans/completed/2026-04-17-menu-bar-compliance-plan.md`

- [ ] **Step 1: Move the plan file**

```bash
git mv plans/2026-04-17-menu-bar-compliance-plan.md plans/completed/2026-04-17-menu-bar-compliance-plan.md
git commit -m "docs: mark menu bar compliance plan complete"
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "Menu bar & commands compliance (Style Guide §14)" \
  --body "Implements plans/completed/2026-04-17-menu-bar-compliance-plan.md. Closes all 29 findings from the 2026-04-17 UI review. iOS behavior unchanged aside from context-menu label improvements and delete confirmations."
```

---

## Execution Notes

- **Commit frequency:** Each task commits independently. Do not batch multiple tasks into one commit — keeps review diffs small and rollback surgical.
- **Build gate:** After every task with code changes, `just build-mac` must be warning-free (project has `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`).
- **iOS gate:** After every task that touches shared views (context menus, focused values, `TransactionListView`, `UpcomingView`, `SidebarView`, `EarmarksView`, `CategoriesView`, `SettingsView`, `TransactionFilterView`), also run `just build-ios` to confirm no iOS regressions.
- **Test gate:** After any task that touches store logic (currently only Phase 3's delete-confirmation flow — the store isn't modified, only the call site is), run the relevant store test suite.
- **UI gate:** After Phase 10, the `ui-review` agent must report zero findings. Iterate until clean.
- **Xcodegen:** After adding any `*.swift` file, run `just generate` before the next build. The `project.yml` is the source of truth; the generated `Moolah.xcodeproj` is gitignored, so the commit containing a new file also commits the corresponding `project.yml` update if any manual change was required (usually not — xcodegen picks up new files automatically).

## Deferred / Out of Scope

These findings from the review are intentionally **not** addressed in this plan:

- **Mark as Cleared / Mark All as Cleared menu items** — require new `TransactionStore.markCleared(id:)` method. Tracked in `plans/FEATURE_IDEAS.md`.
- **Pay Scheduled Transaction menu item** — requires promoting the inline `UpcomingView` "Pay Now" action to a store method reachable from menu context. Tracked in `FEATURE_IDEAS.md`.
- **Copy Transaction Link** — requires a URL scheme for deep-linking. The URL scheme handler exists (`URLSchemeHandler.parse`) but doesn't yet support per-transaction links. Tracked in `FEATURE_IDEAS.md`.
- **Undo/Redo with action names** — SwiftUI wires ⌘Z/⇧⌘Z automatically via `UndoManager`, but the app's stores don't currently register undo groups. Separate plan.
- **Keyboard Shortcuts cheatsheet window on iOS** — the style guide's cheatsheet is a Mac-only UX. iOS users discover shortcuts via the native shortcut overlay (hold ⌘ with external keyboard), which SwiftUI supplies automatically for any `.keyboardShortcut` applied to a view.

## Risk Notes

- **NotificationCenter coupling:** The Transaction/Account/Earmark menus use `NotificationCenter.default.post` because command structs don't have access to the store. This is a pragmatic simplification — the alternative is passing the store through focused values, which complicates the type signatures. If the pattern grows unwieldy, replace with a lightweight `CommandRouter` environment object.
- **Context menu rename diff size:** Phase 9.4 touches six views. Split into per-view commits if the diff feels too large to review as one.
- **`#if os(macOS)` file boundaries:** Every new `*Commands.swift` file is wrapped in `#if os(macOS)`. Verify iOS builds after each Phase — if a helper type ends up inside the `#if` but is needed by iOS, extract it to a non-macOS-only file.
