# Step 14 — Platform Polish & Feature Parity

**Date:** 2026-04-08
**Status:** Planning

---

## Executive Summary

Step 14 is the final polish phase that transforms moolah-native from a functional cross-platform app into a **truly native experience** on both macOS and iOS. This step focuses on platform-specific UI patterns, offline resilience, accessibility compliance, and visual refinement—ensuring the app feels indistinguishable from first-party Apple software.

By the end of this step:
- **macOS** users will have keyboard-driven workflows, three-column navigation, right-click context menus, and toolbar customization
- **iOS** users will have familiar swipe gestures, pull-to-refresh, haptic feedback, and adaptive tab bar navigation
- **Both platforms** will support offline reads (SwiftData cache), queued offline writes, comprehensive accessibility (VoiceOver, Dynamic Type, keyboard navigation), semantic dark mode, and localization infrastructure

This step does **not** introduce new features or data models. It refines existing functionality to match or exceed the web version's UX while adhering to Apple Human Interface Guidelines.

---

## 1. macOS-Specific Features

### 1.1 Three-Column NavigationSplitView

#### Current State
- ✅ Two-column layout: `SidebarView` (accounts/earmarks) + detail view
- ❌ No third column for transaction detail panels on macOS

#### Web Version Pattern
- Three-pane layout: Sidebar → List → Detail
- Example: Accounts sidebar → Transaction list → Transaction detail form

#### Implementation

**Goal:** Use `NavigationSplitView` with three columns on macOS (sidebar, content, detail) while maintaining two-column behavior on iPad and single-column on iPhone.

**Files to modify:**
- `/Users/aj/Documents/code/moolah-project/moolah-native/App/ContentView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions/Views/AllTransactionsView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions/Views/TransactionListView.swift`

**Pattern:**
```swift
#if os(macOS)
NavigationSplitView {
  SidebarView(selection: $selection)
} content: {
  // Middle column: transaction list, category list, etc.
  contentView
} detail: {
  // Right column: transaction form, category detail, etc.
  detailView
}
.navigationSplitViewStyle(.balanced)
#else
// iOS/iPadOS: current two-column behavior
NavigationSplitView {
  SidebarView(selection: $selection)
} detail: {
  contentView  // Detail shown in sheet on compact width
}
#endif
```

**Acceptance Criteria:**
- macOS shows three resizable columns when viewing transactions or categories
- Sidebar min width: 220pt, middle column min width: 300pt, detail column fixed: 350pt
- iPad shows two columns (sidebar + content) with detail in sheet
- iPhone shows single column with stacked navigation

**Estimated Effort:** 4 hours

---

### 1.2 Keyboard Shortcuts

#### Current State
- ✅ `Cmd+N` for new transaction (via `NewTransactionCommands`)
- ❌ `Cmd+F` for search/filter not implemented
- ❌ `Cmd+,` for preferences not implemented
- ❌ `Cmd+R` for refresh only in `TransactionListView`
- ❌ No shortcuts for editing, deleting, or navigation

#### Web Version Pattern
- `Ctrl+F` for search
- Standard edit/delete shortcuts
- Keyboard-driven form navigation

#### Implementation

**Global Shortcuts (all views):**
- `Cmd+F`: Focus search field (if `.searchable` is present)
- `Cmd+R`: Refresh current view
- `Cmd+,`: Open settings/preferences (future; placeholder for now)
- `Delete`: Delete selected item (with confirmation)
- `Esc`: Dismiss sheets/popovers

**View-Specific Shortcuts:**
- `Cmd+N`: New transaction (already implemented)
- `Cmd+Shift+N`: New earmark
- `Cmd+E`: Edit selected transaction/category/earmark
- `Cmd+D`: Duplicate selected transaction

**Files to modify:**
- `/Users/aj/Documents/code/moolah-project/moolah-native/App/MoolahApp.swift` (add command groups)
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions/Views/AllTransactionsView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions/Views/TransactionListView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Categories/Views/CategoriesView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Earmarks/Views/EarmarksView.swift`

**Pattern (search shortcut):**
```swift
@FocusState private var isSearchFocused: Bool

var body: some View {
  List { ... }
    .searchable(text: $searchText, prompt: "Search")
    .focused($isSearchFocused)
    .onAppear {
      // Register Cmd+F handler
      NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.modifierFlags.contains(.command) && event.characters == "f" {
          isSearchFocused = true
          return nil  // Consume event
        }
        return event
      }
    }
}
```

**Improved Pattern (SwiftUI-native):**
```swift
struct RefreshCommands: Commands {
  @FocusedValue(\.refreshAction) private var refreshAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Refresh") {
        refreshAction?()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(refreshAction == nil)
    }
  }
}
```

**Acceptance Criteria:**
- All shortcuts listed above work consistently across views
- Shortcuts appear in menu bar with correct symbols
- Keyboard navigation follows standard macOS tab order
- Shortcuts do not conflict with system shortcuts

**Estimated Effort:** 6 hours

---

### 1.3 Right-Click Context Menus

#### Current State
- ✅ Context menu on transaction rows (Edit, Delete)
- ✅ Context menu on account rows (View Transactions)
- ❌ No context menu on category rows
- ❌ No context menu on earmark rows
- ❌ Missing "Pay" action on scheduled transactions
- ❌ No "Duplicate" action on transactions

#### Web Version Pattern
- Right-click on any list item shows relevant actions
- Edit, Delete, Duplicate, Pay (scheduled), View Details

#### Implementation

**Locations for Context Menus:**
1. Transaction rows (`TransactionRowView`)
2. Category rows (`CategoryTreeView`)
3. Earmark rows (`EarmarkRowView`)
4. Account rows (`AccountRowView`)
5. Scheduled transaction rows (`UpcomingView`)

**Standard Menu Structure:**
```swift
.contextMenu {
  Button("Edit", systemImage: "pencil") { editAction() }
  Button("Duplicate", systemImage: "doc.on.doc") { duplicateAction() }
  Divider()
  Button("Delete", systemImage: "trash", role: .destructive) { deleteAction() }
}
```

**Scheduled Transaction Menu:**
```swift
.contextMenu {
  Button("Pay Now", systemImage: "checkmark.circle") { payAction() }
  Button("Edit", systemImage: "pencil") { editAction() }
  Divider()
  Button("Skip This Instance", systemImage: "forward") { skipAction() }
  Button("Delete Series", systemImage: "trash", role: .destructive) { deleteAction() }
}
```

**Files to modify:**
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions/Views/TransactionRowView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions/Views/UpcomingView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Categories/Views/CategoryTreeView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Earmarks/Views/EarmarkRowView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Accounts/Views/AccountRowView.swift`

**Acceptance Criteria:**
- Right-click (or Control-click) on any list item shows context menu
- Menu items are disabled when action is not available (e.g., "Duplicate" disabled for transfers)
- Destructive actions show confirmation dialogs
- All context menu actions match keyboard shortcuts where applicable

**Estimated Effort:** 3 hours

---

### 1.4 Toolbar Customization

#### Current State
- ✅ Basic toolbar with refresh and add buttons
- ❌ Toolbar not customizable
- ❌ No toolbar on macOS main window (only in detail views)

#### Web Version Pattern
- Fixed toolbar with common actions (filter, add, refresh)

#### Implementation

**Goal:** Allow users to customize the macOS toolbar (add/remove/reorder items) using standard macOS patterns.

**Toolbar Items to Offer:**
- Add Transaction (default visible)
- Add Earmark (default visible)
- Refresh (default visible)
- Filter (default hidden)
- Search (default visible)
- Settings (default hidden)

**Files to modify:**
- `/Users/aj/Documents/code/moolah-project/moolah-native/App/ContentView.swift`
- Create new file: `/Users/aj/Documents/code/moolah-project/moolah-native/Shared/ToolbarCustomization.swift`

**Pattern:**
```swift
.toolbar(id: "main-toolbar") {
  ToolbarItem(id: "add-transaction", placement: .primaryAction) {
    Button { createTransaction() } label: {
      Label("Add Transaction", systemImage: "plus")
    }
  }

  ToolbarItem(id: "refresh", placement: .automatic) {
    Button { refresh() } label: {
      Label("Refresh", systemImage: "arrow.clockwise")
    }
  }

  ToolbarItem(id: "filter", placement: .automatic, showsByDefault: false) {
    Button { showFilter() } label: {
      Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
    }
  }
}
.toolbarRole(.editor)
```

**Acceptance Criteria:**
- Right-click on toolbar → "Customize Toolbar" (macOS only)
- User can add/remove/reorder toolbar items
- Toolbar state persists across app launches
- iOS/iPadOS ignore toolbar customization (standard toolbar shown)

**Estimated Effort:** 2 hours

---

## 2. iOS-Specific Features

### 2.1 Swipe-to-Delete Patterns

#### Current State
- ✅ Swipe-to-delete on transaction rows (`TransactionListView`)
- ❌ Not implemented on category rows
- ❌ Not implemented on earmark rows
- ❌ No swipe-to-edit (leading edge)

#### Web Version Pattern
- Click delete button → confirmation modal

#### Implementation

**Goal:** Add swipe actions to all list views on iOS, following iOS conventions.

**Standard Pattern (Destructive):**
```swift
.swipeActions(edge: .trailing) {
  Button(role: .destructive) {
    deleteItem()
  } label: {
    Label("Delete", systemImage: "trash")
  }
}
```

**Extended Pattern (Edit + Delete):**
```swift
.swipeActions(edge: .leading) {
  Button {
    editItem()
  } label: {
    Label("Edit", systemImage: "pencil")
  }
  .tint(.blue)
}
.swipeActions(edge: .trailing) {
  Button(role: .destructive) {
    deleteItem()
  } label: {
    Label("Delete", systemImage: "trash")
  }
}
```

**Files to modify:**
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Categories/Views/CategoryTreeView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Earmarks/Views/EarmarksView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions/Views/UpcomingView.swift`

**Acceptance Criteria:**
- Swipe left (trailing edge) shows Delete on all iOS list items
- Swipe right (leading edge) shows Edit on transaction rows
- Destructive actions require confirmation (`.confirmationDialog`)
- Swipe actions do not appear on macOS (context menus used instead)

**Estimated Effort:** 2 hours

---

### 2.2 Pull-to-Refresh Implementation

#### Current State
- ✅ Pull-to-refresh on `TransactionListView` (`.refreshable`)
- ✅ Pull-to-refresh on `SidebarView`
- ✅ Pull-to-refresh on `CategoriesView`
- ✅ Pull-to-refresh on `UpcomingView`
- ❌ Not implemented on `EarmarksView`

#### Web Version Pattern
- Manual refresh button only

#### Implementation

**Goal:** Ensure all list views support pull-to-refresh on iOS.

**Files to modify:**
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Earmarks/Views/EarmarksView.swift`

**Pattern:**
```swift
List {
  // content
}
.refreshable {
  await store.load()
}
```

**Acceptance Criteria:**
- All list views support pull-to-refresh on iOS
- Refresh spinner appears while loading
- macOS shows "Refresh" menu item (Cmd+R) instead of pull gesture

**Estimated Effort:** 0.5 hours (already mostly implemented)

---

### 2.3 Tab Bar Navigation at Compact Width

#### Current State
- ✅ `NavigationSplitView` adapts to compact width (iPhone)
- ❌ No tab bar navigation; sidebar collapsed into back button

#### Web Version Pattern
- Single-page app with sidebar navigation

#### iOS HIG Recommendation
- iPhone apps should use `TabView` for top-level navigation instead of `NavigationSplitView`

#### Implementation

**Goal:** Replace `NavigationSplitView` with `TabView` at compact width on iOS.

**Files to modify:**
- `/Users/aj/Documents/code/moolah-project/moolah-native/App/ContentView.swift`

**Pattern:**
```swift
@Environment(\.horizontalSizeClass) private var sizeClass

var body: some View {
  #if os(iOS)
  if sizeClass == .compact {
    TabView {
      AllTransactionsView(...)
        .tabItem {
          Label("Transactions", systemImage: "list.bullet")
        }

      UpcomingView(...)
        .tabItem {
          Label("Upcoming", systemImage: "calendar")
        }

      CategoriesView(...)
        .tabItem {
          Label("Categories", systemImage: "tag")
        }

      // Accounts/Earmarks in a Settings-style grouped list
      AccountsAndEarmarksView(...)
        .tabItem {
          Label("Accounts", systemImage: "banknote")
        }
    }
  } else {
    // iPad: NavigationSplitView (current behavior)
    NavigationSplitView { ... }
  }
  #else
  // macOS: NavigationSplitView (three columns)
  NavigationSplitView { ... }
  #endif
}
```

**Acceptance Criteria:**
- iPhone shows tab bar with 4 tabs (Transactions, Upcoming, Categories, Accounts)
- Tab bar icons match SF Symbols conventions
- iPad and macOS continue using `NavigationSplitView`
- Tab selection persists across app launches

**Estimated Effort:** 5 hours

---

### 2.4 Haptic Feedback Patterns

#### Current State
- ❌ No haptic feedback implemented

#### Web Version Pattern
- No haptic feedback (web app)

#### iOS HIG Recommendation
- Haptic feedback on destructive actions, confirmations, and errors

#### Implementation

**Goal:** Add haptic feedback to enhance iOS interactions.

**Feedback Types:**
- **Success** (`.success`): Transaction created, updated, or deleted successfully
- **Warning** (`.warning`): Validation error, missing required field
- **Error** (`.error`): Network error, server error
- **Selection** (`.selection`): Selecting a transaction, account, or category
- **Impact** (`.medium`): Swipe action triggered (delete, edit)

**Files to modify:**
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions/TransactionStore.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Categories/CategoryStore.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Earmarks/EarmarkStore.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Accounts/AccountStore.swift`

**Pattern:**
```swift
#if os(iOS)
import UIKit

extension View {
  func hapticFeedback(_ style: UINotificationFeedbackGenerator.FeedbackType) {
    let generator = UINotificationFeedbackGenerator()
    generator.notificationOccurred(style)
  }

  func hapticImpact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
    let generator = UIImpactFeedbackGenerator(style: style)
    generator.impactOccurred()
  }

  func hapticSelection() {
    let generator = UISelectionFeedbackGenerator()
    generator.selectionChanged()
  }
}
#endif
```

**Usage:**
```swift
// In TransactionStore.swift
func delete(id: UUID) async {
  do {
    try await repository.delete(id: id)
    transactions.removeAll { $0.id == id }

    #if os(iOS)
    hapticFeedback(.success)
    #endif
  } catch {
    #if os(iOS)
    hapticFeedback(.error)
    #endif
    self.error = error
  }
}
```

**Acceptance Criteria:**
- Haptic feedback fires on iOS only (not macOS or iPad)
- Feedback type matches action severity (success, warning, error)
- Haptic feedback respects system settings (disabled if user turns off haptics)
- No noticeable performance impact

**Estimated Effort:** 3 hours

---

## 3. Shared Features

### 3.1 Offline Reads: SwiftData Cache Strategy

#### Current State
- ✅ `ModelContainer` initialized (empty schema)
- ❌ No SwiftData models defined
- ❌ No cache population on successful fetch
- ❌ Network errors do not fall back to cache

#### Web Version Pattern
- No offline support; requires network connection

#### Implementation

**Goal:** Populate a SwiftData cache on every successful network fetch. When the network is unavailable, serve stale cache data with a visual indicator.

**Architecture:**
```
┌─────────────────────────────────────┐
│  TransactionStore                   │
│  (calls repository)                 │
└────────────┬────────────────────────┘
             │
┌────────────▼────────────────────────┐
│  RemoteTransactionRepository        │
│  1. Try network fetch               │
│  2. On success: write to cache      │
│  3. On network error: read cache    │
└────────────┬────────────────────────┘
             │
   ┌─────────┴─────────┐
   │                   │
┌──▼────────┐   ┌──────▼──────────────┐
│ URLSession│   │ SwiftData Cache     │
│ (network) │   │ (local storage)     │
└───────────┘   └─────────────────────┘
```

**SwiftData Models:**

Create new files in `/Users/aj/Documents/code/moolah-project/moolah-native/Domain/Cache/`:

```swift
// CachedTransaction.swift
import SwiftData

@Model
final class CachedTransaction {
  @Attribute(.unique) var id: UUID
  var type: String
  var date: Date
  var payee: String?
  var amountCents: Int
  var currencyCode: String
  var accountId: UUID?
  var toAccountId: UUID?
  var categoryId: UUID?
  var earmarkId: UUID?
  var notes: String?
  var recurPeriod: String?
  var recurEvery: Int?
  var createdAt: Date  // Cache timestamp

  init(from transaction: Transaction) {
    self.id = transaction.id
    self.type = transaction.type.rawValue
    self.date = transaction.date
    self.payee = transaction.payee
    self.amountCents = transaction.amount.cents
    self.currencyCode = transaction.amount.currency.code
    self.accountId = transaction.accountId
    self.toAccountId = transaction.toAccountId
    self.categoryId = transaction.categoryId
    self.earmarkId = transaction.earmarkId
    self.notes = transaction.notes
    self.recurPeriod = transaction.recurPeriod?.rawValue
    self.recurEvery = transaction.recurEvery
    self.createdAt = Date()
  }

  func toDomain() -> Transaction {
    Transaction(
      id: id,
      type: TransactionType(rawValue: type)!,
      date: date,
      accountId: accountId,
      toAccountId: toAccountId,
      amount: MonetaryAmount(cents: amountCents, currency: Currency(code: currencyCode)),
      payee: payee,
      categoryId: categoryId,
      earmarkId: earmarkId,
      notes: notes,
      recurPeriod: recurPeriod.flatMap { RecurPeriod(rawValue: $0) },
      recurEvery: recurEvery
    )
  }
}
```

**Repository Changes:**

Modify `/Users/aj/Documents/code/moolah-project/moolah-native/Backends/Remote/Repositories/RemoteTransactionRepository.swift`:

```swift
import SwiftData

final class RemoteTransactionRepository: TransactionRepository {
  private let apiClient: APIClient
  private let modelContext: ModelContext

  init(apiClient: APIClient, modelContext: ModelContext) {
    self.apiClient = apiClient
    self.modelContext = modelContext
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> [Transaction] {
    do {
      // Try network fetch
      let transactions = try await fetchFromNetwork(filter: filter, page: page, pageSize: pageSize)

      // Success: update cache
      await updateCache(transactions)

      return transactions
    } catch let error as BackendError where error == .networkUnavailable {
      // Network unavailable: serve from cache
      return try await fetchFromCache(filter: filter, page: page, pageSize: pageSize)
    } catch {
      // Other error: rethrow
      throw error
    }
  }

  private func updateCache(_ transactions: [Transaction]) async {
    for transaction in transactions {
      let cached = CachedTransaction(from: transaction)
      modelContext.insert(cached)
    }
    try? modelContext.save()
  }

  private func fetchFromCache(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> [Transaction] {
    var descriptor = FetchDescriptor<CachedTransaction>(
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )

    // Apply filter predicates
    if let accountId = filter.accountId {
      descriptor.predicate = #Predicate { $0.accountId == accountId }
    }

    descriptor.fetchLimit = pageSize
    descriptor.fetchOffset = page * pageSize

    let cached = try modelContext.fetch(descriptor)
    return cached.map { $0.toDomain() }
  }
}
```

**Staleness Indicator:**

Add a "Last updated" timestamp in UI:

```swift
// In TransactionStore
@Published var lastFetchedAt: Date?
@Published var isShowingCachedData = false

// In TransactionListView
.toolbar {
  if transactionStore.isShowingCachedData {
    ToolbarItem(placement: .status) {
      Label("Showing cached data (offline)", systemImage: "wifi.slash")
        .foregroundStyle(.secondary)
        .font(.caption)
    }
  }
}
```

**Acceptance Criteria:**
- Network fetch success → cache updated with new data
- Network error → fallback to cache with visual indicator
- Cache is never shown if fresher than 5 minutes (configurable)
- Cache data older than 24 hours shows warning
- All domain models have corresponding SwiftData cache models (Account, Category, Earmark, Transaction)

**Estimated Effort:** 10 hours

---

### 3.2 Write Queue: Offline Mutation Queue

#### Current State
- ❌ Mutations (create/update/delete) fail immediately when offline
- ❌ No offline mutation queue

#### Web Version Pattern
- No offline support; mutations require network

#### Implementation

**Goal:** Queue mutations made while offline and flush them when connectivity returns.

**Architecture:**
```
User action (create/update/delete)
      ↓
TransactionStore
      ↓
Queue mutation if offline
      ↓
Apply optimistic UI update
      ↓
(on reconnect)
      ↓
Flush queue to server
      ↓
Rollback on conflict
```

**SwiftData Model:**

Create `/Users/aj/Documents/code/moolah-project/moolah-native/Domain/Cache/PendingMutation.swift`:

```swift
import SwiftData

@Model
final class PendingMutation {
  @Attribute(.unique) var id: UUID
  var entityType: String  // "transaction", "category", "earmark"
  var operation: String   // "create", "update", "delete"
  var payload: Data       // JSON-encoded domain model
  var createdAt: Date
  var retryCount: Int

  init(entityType: String, operation: String, payload: Data) {
    self.id = UUID()
    self.entityType = entityType
    self.operation = operation
    self.payload = payload
    self.createdAt = Date()
    self.retryCount = 0
  }
}
```

**Mutation Queue Service:**

Create `/Users/aj/Documents/code/moolah-project/moolah-native/Shared/MutationQueue.swift`:

```swift
import SwiftData
import Network

@MainActor
final class MutationQueue: ObservableObject {
  private let modelContext: ModelContext
  private let monitor = NWPathMonitor()
  @Published var isOnline = true

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
    startMonitoring()
  }

  func enqueue(entityType: String, operation: String, payload: Data) {
    let mutation = PendingMutation(entityType: entityType, operation: operation, payload: payload)
    modelContext.insert(mutation)
    try? modelContext.save()
  }

  func flush(using backend: BackendProvider) async {
    let descriptor = FetchDescriptor<PendingMutation>(sortBy: [SortDescriptor(\.createdAt)])
    guard let pending = try? modelContext.fetch(descriptor) else { return }

    for mutation in pending {
      do {
        try await apply(mutation, using: backend)
        modelContext.delete(mutation)
      } catch {
        mutation.retryCount += 1
        if mutation.retryCount > 3 {
          // Give up after 3 retries
          modelContext.delete(mutation)
        }
      }
    }

    try? modelContext.save()
  }

  private func apply(_ mutation: PendingMutation, using backend: BackendProvider) async throws {
    switch (mutation.entityType, mutation.operation) {
    case ("transaction", "create"):
      let tx = try JSONDecoder().decode(Transaction.self, from: mutation.payload)
      _ = try await backend.transactions.create(tx)
    case ("transaction", "update"):
      let tx = try JSONDecoder().decode(Transaction.self, from: mutation.payload)
      _ = try await backend.transactions.update(tx)
    case ("transaction", "delete"):
      let id = try JSONDecoder().decode(UUID.self, from: mutation.payload)
      try await backend.transactions.delete(id: id)
    // ... handle other entity types
    default:
      throw BackendError.serverError(400)
    }
  }

  private func startMonitoring() {
    monitor.pathUpdateHandler = { [weak self] path in
      DispatchQueue.main.async {
        self?.isOnline = path.status == .satisfied
      }
    }
    monitor.start(queue: DispatchQueue.global())
  }
}
```

**Store Integration:**

Modify `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Transactions/TransactionStore.swift`:

```swift
@Observable
@MainActor
final class TransactionStore {
  private let repository: any TransactionRepository
  private let mutationQueue: MutationQueue

  func create(_ transaction: Transaction) async -> Transaction? {
    // Optimistic update
    let optimistic = TransactionWithBalance(transaction: transaction, balance: nil)
    transactions.insert(optimistic, at: 0)

    if !mutationQueue.isOnline {
      // Queue for later
      let payload = try! JSONEncoder().encode(transaction)
      mutationQueue.enqueue(entityType: "transaction", operation: "create", payload: payload)
      return transaction
    }

    // Normal network path
    do {
      let created = try await repository.create(transaction)
      // Replace optimistic with server version
      transactions.removeAll { $0.id == transaction.id }
      transactions.insert(TransactionWithBalance(transaction: created, balance: nil), at: 0)
      return created
    } catch {
      // Rollback optimistic
      transactions.removeAll { $0.id == transaction.id }
      self.error = error
      return nil
    }
  }
}
```

**Flush on Reconnect:**

In `MoolahApp.swift`:

```swift
.onChange(of: mutationQueue.isOnline) { _, isOnline in
  if isOnline {
    Task {
      await mutationQueue.flush(using: backend)
      // Refresh all stores
      await accountStore.load()
      await transactionStore.load()
    }
  }
}
```

**Acceptance Criteria:**
- Create/update/delete operations succeed when offline (queued)
- Queued mutations flush when network returns
- Optimistic UI updates rollback on conflict
- Network status indicator in UI (online/offline)
- Queue persists across app restarts

**Estimated Effort:** 12 hours

---

### 3.3 Empty States for All List Views

#### Current State
- ✅ `ContentUnavailableView` in `TransactionListView`
- ✅ `ContentUnavailableView` in `UpcomingView`
- ✅ `ContentUnavailableView` in `CategoriesView`
- ❌ Missing in `EarmarksView`
- ❌ Missing in `CategoryTreeView` (when no categories exist)

#### Web Version Pattern
- Generic "No data" messages

#### Implementation

**Goal:** All list views show helpful, contextual empty states.

**Files to modify:**
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Earmarks/Views/EarmarksView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Features/Categories/Views/CategoryTreeView.swift`

**Pattern:**
```swift
List { ... }
  .overlay {
    if !store.isLoading && items.isEmpty {
      ContentUnavailableView(
        "No Earmarks",
        systemImage: "bookmark",
        description: Text("Create an earmark to track savings goals.")
      )
    }
  }
```

**Acceptance Criteria:**
- All list views show `ContentUnavailableView` when empty
- Icon and description match domain context
- Empty state appears after loading completes (not during initial load)

**Estimated Effort:** 1 hour

---

### 3.4 Accessibility: VoiceOver, Dynamic Type, Keyboard Navigation

#### Current State
- ✅ Some `.accessibilityLabel` usage (9 files, 22 occurrences)
- ❌ No Dynamic Type testing or `@ScaledMetric` usage
- ❌ No keyboard navigation testing (macOS)
- ❌ No VoiceOver audit

#### Web Version Pattern
- Basic ARIA labels; no advanced accessibility

#### Implementation

**VoiceOver Labels:**

Audit and add `.accessibilityLabel` to:
- All monetary amounts (spell out value in words)
- All icons (describe purpose, not appearance)
- All interactive elements (buttons, links, rows)
- All grouped elements (combine payee + amount + date)

**Example:**
```swift
// Before
Text(transaction.payee)

// After
Text(transaction.payee)
  .accessibilityLabel("\(transaction.payee ?? "Unknown"), \(transaction.amount.decimalValue.formatted(.currency(code: transaction.amount.currency.code)))")
```

**Dynamic Type Support:**

- Use semantic text styles (`.headline`, `.body`, `.caption`)
- Test at largest accessibility size (`Accessibility 5`)
- Use `@ScaledMetric` for custom spacing/sizing
- Ensure no text clipping at large sizes

**Example:**
```swift
@ScaledMetric private var iconSize: CGFloat = 24

Image(systemName: "arrow.up")
  .frame(width: iconSize, height: iconSize)
```

**Keyboard Navigation (macOS):**

- Ensure logical tab order through forms
- All buttons/links are keyboard-accessible
- Focus indicators visible
- Support standard shortcuts (Tab, Shift+Tab, Space, Return)

**Files to modify:**
- All view files in `/Users/aj/Documents/code/moolah-project/moolah-native/Features/`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Shared/MonetaryAmountView.swift`

**Accessibility Testing Checklist:**
- [ ] Run app with VoiceOver enabled (macOS: Cmd+F5, iOS: Settings → Accessibility)
- [ ] Navigate through all screens using VoiceOver
- [ ] Verify all amounts are spoken correctly
- [ ] Test with largest Dynamic Type size
- [ ] Verify no text clipping or layout breaks
- [ ] Test keyboard navigation (Tab, arrow keys, shortcuts)
- [ ] Run Xcode Accessibility Inspector (no warnings)

**Acceptance Criteria:**
- All interactive elements have meaningful VoiceOver labels
- All views support Dynamic Type up to Accessibility 5
- macOS keyboard navigation works in all forms and lists
- Xcode Accessibility Inspector reports zero warnings

**Estimated Effort:** 8 hours

---

### 3.5 Dark Mode: Semantic Colors and Testing

#### Current State
- ✅ Semantic colors used (`.green`, `.red`, `.secondary`)
- ❌ No dark mode testing or validation
- ❌ No custom colors defined (all using system colors)

#### Web Version Pattern
- Light mode only

#### Implementation

**Goal:** Ensure the app looks correct in dark mode with no custom fixes required (semantic colors already used).

**Validation:**
- Test all screens in dark mode (macOS: System Preferences → Appearance → Dark)
- Ensure contrast ratios meet WCAG AA (4.5:1 for body text, 3:1 for large text)
- Check for hardcoded colors (grep for `Color(red:`, `Color.init(`)
- Verify all images/icons adapt to dark mode (use `.symbolRenderingMode(.hierarchical)`)

**Files to audit:**
- All view files
- `/Users/aj/Documents/code/moolah-project/moolah-native/Shared/MonetaryAmountView.swift`
- `/Users/aj/Documents/code/moolah-project/moolah-native/Shared/UIConstants.swift`

**Dark Mode Testing Checklist:**
- [ ] All text is legible in dark mode
- [ ] No pure white (`#FFFFFF`) or pure black (`#000000`) backgrounds
- [ ] Green/red amounts have sufficient contrast
- [ ] Icons adapt correctly (no inverted symbols)
- [ ] Charts/graphs readable in dark mode

**Acceptance Criteria:**
- App passes visual dark mode audit (all screens tested)
- No contrast ratio violations (Xcode Accessibility Inspector)
- All colors are semantic (no hardcoded RGB values)

**Estimated Effort:** 2 hours

---

### 3.6 Localization: String(localized:) Adoption

#### Current State
- ❌ No localization infrastructure
- ❌ All strings hardcoded in English

#### Web Version Pattern
- English only

#### Implementation

**Goal:** Prepare for future localization by wrapping all user-facing strings in `String(localized:)`.

**Pattern:**
```swift
// Before
Text("All Transactions")

// After
Text(String(localized: "All Transactions", comment: "Title for the all transactions view"))
```

**Strings to Localize:**
- Navigation titles
- Button labels
- Error messages
- Empty state descriptions
- Accessibility labels (already localized if using `String(localized:)`)

**Files to modify:**
- All view files
- All store files (error messages)
- `/Users/aj/Documents/code/moolah-project/moolah-native/Domain/Models/BackendError.swift`

**Automation:**

Use `xcstrings` tool to extract strings:

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native
xcodebuild -exportLocalizations -localizationPath ./Localizations -project Moolah.xcodeproj
```

**Acceptance Criteria:**
- All user-facing strings use `String(localized:)`
- Strings extracted to `Localizable.xcstrings`
- English strings compile and display correctly
- No hardcoded strings in views or stores

**Estimated Effort:** 6 hours

---

## 4. Testing Strategy

### 4.1 Offline Queue Tests

**File:** `/Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/Domain/MutationQueueTests.swift`

**Test Cases:**
- ✅ `test_enqueueMutation_storesInDatabase`
- ✅ `test_flushQueue_appliesMutationsInOrder`
- ✅ `test_flushQueue_retriesOnFailure`
- ✅ `test_flushQueue_discardsAfterMaxRetries`
- ✅ `test_queue_persistsAcrossAppRestarts`
- ✅ `test_optimisticUpdate_rollsBackOnConflict`

**Estimated Effort:** 4 hours

---

### 4.2 Cache Tests

**File:** `/Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/Backends/CacheRepositoryTests.swift`

**Test Cases:**
- ✅ `test_fetchFromNetwork_updatesCache`
- ✅ `test_fetchWhenOffline_servesCachedData`
- ✅ `test_staleCacheWarning_showsAfter24Hours`
- ✅ `test_cache_respectsFilterPredicate`
- ✅ `test_cache_paginatesCorrectly`

**Estimated Effort:** 3 hours

---

### 4.3 Accessibility Tests

**File:** `/Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/UI/AccessibilityTests.swift`

**Test Cases:**
- ✅ `test_allInteractiveElements_haveAccessibilityLabels`
- ✅ `test_monetaryAmounts_spokenCorrectly`
- ✅ `test_dynamicType_noClippingAtLargestSize`
- ✅ `test_keyboardNavigation_logicalTabOrder`
- ✅ `test_contrastRatios_meetWCAGAA`

**Estimated Effort:** 5 hours

---

### 4.4 Platform-Specific Tests

**File:** `/Users/aj/Documents/code/moolah-project/moolah-native/MoolahTests/UI/PlatformAdaptationTests.swift`

**Test Cases:**
- ✅ `test_macOS_threeColumnLayout`
- ✅ `test_iOS_tabBarNavigationAtCompactWidth`
- ✅ `test_iOS_swipeActionsPresent`
- ✅ `test_macOS_contextMenusPresent`
- ✅ `test_iOS_hapticFeedbackTriggered` (using `UIImpactFeedbackGenerator`)
- ✅ `test_macOS_keyboardShortcutsRegistered`

**Estimated Effort:** 4 hours

---

## 5. Feature Parity Checklist

This checklist compares moolah-native against the web version to ensure no regression in functionality.

| Feature | Web Version | macOS Native | iOS Native | Status |
|---------|-------------|--------------|------------|--------|
| **Authentication** |
| Google Sign-In | ✅ | ✅ | ✅ | Done (Step 2) |
| Sign Out | ✅ | ✅ | ✅ | Done (Step 2) |
| Session persistence | ✅ | ✅ | ✅ | Done (Step 2) |
| **Accounts** |
| View accounts by type | ✅ | ✅ | ✅ | Done (Step 3) |
| Create account | ✅ | ❌ | ❌ | Step 13 (deferred) |
| Edit account | ✅ | ❌ | ❌ | Step 13 (deferred) |
| Reorder accounts | ✅ | ❌ | ❌ | Step 13 (deferred) |
| Hide/show accounts | ✅ | ❌ | ❌ | Step 13 (deferred) |
| **Transactions** |
| View transaction list | ✅ | ✅ | ✅ | Done (Step 4) |
| Create transaction | ✅ | ✅ | ✅ | Done (Step 5) |
| Edit transaction | ✅ | ✅ | ✅ | Done (Step 5) |
| Delete transaction | ✅ | ✅ | ✅ | Done (Step 5) |
| Infinite scroll | ✅ | ✅ | ✅ | Done (Step 4) |
| Payee autocomplete | ✅ | ✅ | ✅ | Done (Step 5) |
| **Filtering** |
| Filter by account | ✅ | ✅ | ✅ | Done (Step 6) |
| Filter by date range | ✅ | ✅ | ✅ | Done (Step 6) |
| Filter by category | ✅ | ✅ | ✅ | Done (Step 6) |
| Filter by earmark | ✅ | ✅ | ✅ | Done (Step 6) |
| Search by payee | ✅ | ✅ | ✅ | Done (Step 6) |
| **Categories** |
| View category tree | ✅ | ✅ | ✅ | Done (Step 7) |
| Create category | ✅ | ✅ | ✅ | Done (Step 7) |
| Edit category | ✅ | ✅ | ✅ | Done (Step 7) |
| Delete category | ✅ | ✅ | ✅ | Done (Step 7) |
| Merge categories | ✅ | ✅ | ✅ | Done (Step 7) |
| **Earmarks** |
| View earmarks | ✅ | ✅ | ✅ | Done (Step 8) |
| Create earmark | ✅ | ✅ | ✅ | Done (Step 8) |
| Edit earmark | ✅ | ✅ | ✅ | Done (Step 8) |
| Delete earmark | ✅ | ✅ | ✅ | Done (Step 8) |
| Savings goal tracking | ✅ | ✅ | ✅ | Done (Step 8) |
| Earmark budget | ✅ | ✅ | ✅ | Done (Step 8) |
| **Scheduled Transactions** |
| View upcoming | ✅ | ✅ | ✅ | Done (Step 9) |
| Pay scheduled | ✅ | ✅ | ✅ | Done (Step 9) |
| Create scheduled | ✅ | ✅ | ✅ | Done (Step 9) |
| Edit scheduled | ✅ | ✅ | ✅ | Done (Step 9) |
| Recurrence patterns | ✅ | ✅ | ✅ | Done (Step 9) |
| **Analysis** |
| Net worth graph | ✅ | ❌ | ❌ | Step 10 (deferred) |
| Spending by category | ✅ | ❌ | ❌ | Step 10 (deferred) |
| Forecasted balances | ✅ | ❌ | ❌ | Step 10 (deferred) |
| **Reports** |
| Income vs. expenses | ✅ | ❌ | ❌ | Step 11 (deferred) |
| Category breakdown | ✅ | ❌ | ❌ | Step 11 (deferred) |
| Custom date ranges | ✅ | ❌ | ❌ | Step 11 (deferred) |
| **Investments** |
| View holdings | ✅ | ❌ | ❌ | Step 12 (deferred) |
| Track performance | ✅ | ❌ | ❌ | Step 12 (deferred) |
| **Platform Features** |
| Keyboard shortcuts | ❌ | ✅ | N/A | **Step 14** |
| Context menus | ❌ | ✅ | N/A | **Step 14** |
| Three-column layout | ❌ | ✅ | N/A | **Step 14** |
| Swipe actions | N/A | N/A | ✅ | **Step 14** |
| Pull-to-refresh | N/A | N/A | ✅ | **Step 14** |
| Haptic feedback | N/A | N/A | ✅ | **Step 14** |
| Tab bar navigation | N/A | N/A | ✅ | **Step 14** |
| Offline reads | ❌ | ✅ | ✅ | **Step 14** |
| Offline writes | ❌ | ✅ | ✅ | **Step 14** |
| VoiceOver support | ❌ | ✅ | ✅ | **Step 14** |
| Dynamic Type | N/A | ✅ | ✅ | **Step 14** |
| Dark mode | ❌ | ✅ | ✅ | **Step 14** |
| Localization | ❌ | ✅ | ✅ | **Step 14** |

---

## 6. Acceptance Criteria

Step 14 is complete when **all** of the following criteria are met:

### 6.1 macOS Criteria
- [ ] Three-column `NavigationSplitView` renders correctly on macOS
- [ ] All keyboard shortcuts listed in §1.2 work correctly
- [ ] Right-click context menus appear on all list items
- [ ] Toolbar is customizable via "Customize Toolbar" menu
- [ ] Menu bar shows all keyboard shortcuts with correct symbols

### 6.2 iOS Criteria
- [ ] Tab bar navigation appears at compact width (iPhone)
- [ ] Swipe-to-delete works on all list views
- [ ] Pull-to-refresh works on all list views
- [ ] Haptic feedback fires on destructive actions
- [ ] Haptic feedback respects system settings

### 6.3 Offline Support
- [ ] Network fetch → cache updated
- [ ] Network unavailable → cache served with indicator
- [ ] Create/update/delete while offline → queued
- [ ] Queue flushes when network returns
- [ ] Optimistic updates rollback on conflict

### 6.4 Accessibility
- [ ] All interactive elements have VoiceOver labels
- [ ] VoiceOver navigation works in all views
- [ ] Dynamic Type supported up to Accessibility 5
- [ ] Keyboard navigation works in all forms (macOS)
- [ ] Xcode Accessibility Inspector reports zero warnings

### 6.5 Visual Polish
- [ ] Dark mode tested on all screens (no visual issues)
- [ ] Contrast ratios meet WCAG AA
- [ ] All empty states implemented
- [ ] All strings wrapped in `String(localized:)`

### 6.6 Testing
- [ ] All new tests pass on iOS Simulator and macOS
- [ ] `just test` passes without errors
- [ ] Manual testing checklist complete (see §7)

---

## 7. Implementation Steps

### Phase 1: macOS Platform Features (14 hours)
1. Implement three-column `NavigationSplitView` (4h)
2. Add keyboard shortcuts (6h)
3. Extend context menus to all list views (3h)
4. Implement toolbar customization (2h)

### Phase 2: iOS Platform Features (10.5 hours)
5. Add swipe actions to all lists (2h)
6. Complete pull-to-refresh coverage (0.5h)
7. Implement tab bar navigation at compact width (5h)
8. Add haptic feedback patterns (3h)

### Phase 3: Offline Support (22 hours)
9. Define SwiftData cache models (3h)
10. Implement cache-first repository pattern (7h)
11. Add staleness indicators (2h)
12. Implement mutation queue (8h)
13. Add network status monitoring (2h)

### Phase 4: Accessibility & Polish (17 hours)
14. Audit and add VoiceOver labels (4h)
15. Test Dynamic Type at all sizes (2h)
16. Validate keyboard navigation (2h)
17. Test dark mode on all screens (2h)
18. Wrap strings in `String(localized:)` (6h)
19. Implement all empty states (1h)

### Phase 5: Testing (16 hours)
20. Write offline queue tests (4h)
21. Write cache tests (3h)
22. Write accessibility tests (5h)
23. Write platform-specific tests (4h)

### Phase 6: Manual QA & Bug Fixes (8 hours)
24. Manual testing checklist (4h)
25. Bug fixes and polish (4h)

**Total Estimated Effort:** 87.5 hours (~11 days at 8h/day)

---

## 8. Manual Testing Checklist

### macOS Testing
- [ ] Open app on macOS
- [ ] Verify three-column layout (sidebar → list → detail)
- [ ] Test all keyboard shortcuts (Cmd+N, Cmd+F, Cmd+R, Delete, Cmd+E)
- [ ] Right-click on transaction → verify context menu
- [ ] Right-click on category → verify context menu
- [ ] Right-click on earmark → verify context menu
- [ ] Right-click on toolbar → "Customize Toolbar" appears
- [ ] Customize toolbar → add/remove items → verify persistence

### iOS Testing (iPhone)
- [ ] Open app on iPhone Simulator
- [ ] Verify tab bar navigation (4 tabs)
- [ ] Swipe left on transaction → delete appears
- [ ] Swipe right on transaction → edit appears
- [ ] Pull-to-refresh on transaction list
- [ ] Pull-to-refresh on categories list
- [ ] Delete transaction → verify haptic feedback

### iOS Testing (iPad)
- [ ] Open app on iPad Simulator
- [ ] Verify two-column layout (sidebar → content)
- [ ] Detail shown in sheet (not third column)

### Offline Testing
- [ ] Enable Airplane Mode (macOS: Option-click Wi-Fi icon)
- [ ] Navigate to transactions → verify cached data shown
- [ ] Verify "Offline" indicator appears
- [ ] Create transaction while offline → verify optimistic update
- [ ] Disable Airplane Mode → verify queue flushes
- [ ] Verify created transaction appears with server ID

### VoiceOver Testing (macOS)
- [ ] Enable VoiceOver (Cmd+F5)
- [ ] Navigate to transaction list
- [ ] Tab through rows → verify amounts spoken correctly
- [ ] Tab through form fields → verify labels correct
- [ ] Disable VoiceOver

### VoiceOver Testing (iOS)
- [ ] Enable VoiceOver (Settings → Accessibility → VoiceOver)
- [ ] Navigate to transaction list
- [ ] Swipe through rows → verify amounts spoken correctly
- [ ] Tap form fields → verify labels correct
- [ ] Disable VoiceOver

### Dynamic Type Testing
- [ ] Set text size to Accessibility 5 (Settings → Display → Text Size)
- [ ] Open all screens → verify no text clipping
- [ ] Verify layouts adapt correctly
- [ ] Reset text size to default

### Dark Mode Testing
- [ ] Enable dark mode (macOS: System Preferences → Appearance → Dark)
- [ ] Navigate to all screens
- [ ] Verify text legible, no contrast issues
- [ ] Verify green/red amounts readable
- [ ] Disable dark mode

---

## 9. Risks & Mitigations

### Risk 1: SwiftData Cache Complexity
**Risk:** SwiftData cache synchronization logic may introduce bugs or data inconsistencies.

**Mitigation:**
- Write comprehensive cache tests before implementation
- Use contract tests to ensure cache and network repositories behave identically
- Add logging/debugging UI to inspect cache state
- Implement cache invalidation strategy (clear cache on sign-out)

### Risk 2: Offline Queue Conflicts
**Risk:** Queued mutations may conflict with server state when flushed.

**Mitigation:**
- Use server timestamps to detect conflicts
- Rollback optimistic updates on conflict
- Show user-facing conflict resolution UI (future enhancement)
- Limit queue depth (max 100 pending mutations)

### Risk 3: Accessibility Regressions
**Risk:** New features may break VoiceOver or Dynamic Type support.

**Mitigation:**
- Add accessibility tests to CI pipeline
- Require accessibility review before merging UI changes
- Document accessibility patterns in UI_GUIDE.md

### Risk 4: Platform-Specific Code Drift
**Risk:** macOS and iOS implementations diverge, causing duplicate code.

**Mitigation:**
- Use `#if os(macOS)` / `#if os(iOS)` sparingly
- Extract shared logic to platform-agnostic stores
- Keep platform-specific code in separate files (e.g., `TabBarView_iOS.swift`, `ThreeColumnView_macOS.swift`)

---

## 10. Future Enhancements (Out of Scope)

These features are **not** required for Step 14 but may be added in future iterations:

- **CloudKit Backend:** Replace REST API with CloudKit for true offline-first architecture
- **Conflict Resolution UI:** User-facing UI to resolve merge conflicts
- **Localization:** Translate to languages other than English
- **Widgets (iOS):** Home screen widgets for upcoming transactions, net worth
- **macOS Menu Bar App:** Menu bar extra for quick transaction entry
- **Shortcuts Integration:** Siri Shortcuts for "Add transaction", "Check balance"
- **Face ID/Touch ID:** Biometric authentication for app launch
- **iCloud Sync:** Sync settings and preferences across devices
- **Export/Import:** CSV export, OFX import

---

## 11. Summary

Step 14 transforms moolah-native from a functional cross-platform app into a **polished, platform-native experience** that exceeds the web version's capabilities. By implementing offline support, comprehensive accessibility, and platform-specific UI patterns, the app will feel indistinguishable from first-party Apple software.

**Key Deliverables:**
- macOS: Three-column layout, keyboard shortcuts, context menus, toolbar customization
- iOS: Tab bar navigation, swipe actions, haptic feedback
- Shared: Offline cache, mutation queue, VoiceOver support, Dynamic Type, dark mode, localization infrastructure

**Success Metrics:**
- All acceptance criteria met (§6)
- All tests passing (§4)
- Manual QA checklist complete (§8)
- Feature parity with web version achieved (§5)

**Total Effort:** ~87.5 hours (~11 days)

---

**End of Step 14 Implementation Plan**
