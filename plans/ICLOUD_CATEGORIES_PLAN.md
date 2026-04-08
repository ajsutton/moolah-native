# iCloud Migration — Categories

**Date:** 2026-04-08
**Component:** Categories (hierarchical CRUD)
**Parent plan:** [ICLOUD_MIGRATION_PLAN.md](./ICLOUD_MIGRATION_PLAN.md)

## Overview

Categories are the simplest data component — flat records with an optional `parentId` for hierarchy, and straightforward CRUD. The main complexity is deletion with replacement (re-parenting children).

---

## Current Implementation

### CategoryRepository Protocol (`Domain/Repositories/CategoryRepository.swift`)
```swift
protocol CategoryRepository: Sendable {
  func fetchAll() async throws -> [Category]
  func create(_ category: Category) async throws -> Category
  func update(_ category: Category) async throws -> Category
  func delete(id: UUID, withReplacement replacementId: UUID?) async throws
}
```

### Category Domain Model (`Domain/Models/Category.swift`)
```swift
struct Category: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var name: String
  var parentId: UUID?
}
```

### Categories Lookup Structure
```swift
struct Categories: Sendable {
  var roots: [Category]                     // top-level (parentId == nil), sorted by name
  func children(of parentId: UUID) -> [Category]  // children of a parent, sorted by name
  func by(id: UUID) -> Category?
}
```

### Server Behavior (from InMemoryCategoryRepository)
- `fetchAll()` — returns all categories sorted by name
- `create(_:)` — inserts category (client generates UUID)
- `update(_:)` — updates name and/or parentId
- `delete(id:withReplacement:)`:
  - If `replacementId` is provided: re-parent all children to `replacementId`
  - If `nil`: orphan all children (set their `parentId` to `nil`)
  - Then delete the category itself

---

## SwiftData Model

### File: `Backends/CloudKit/Models/CategoryRecord.swift`

```swift
import Foundation
import SwiftData

@Model
final class CategoryRecord {
  #Unique<CategoryRecord>([\.id])

  @Attribute(.preserveValueOnDeletion)
  var id: UUID

  var name: String
  var parentId: UUID?

  init(id: UUID, name: String, parentId: UUID? = nil) {
    self.id = id
    self.name = name
    self.parentId = parentId
  }
}
```

### Design Decision: UUID FK vs SwiftData Relationship

| Option | Pros | Cons |
|--------|------|------|
| **UUID `parentId`** | Simple, CloudKit-friendly, matches domain model | No cascade delete, manual orphan logic |
| **SwiftData `@Relationship`** | Automatic cascade, type-safe navigation | CloudKit sync complications, self-referencing relationships are tricky |

**Recommendation: UUID `parentId`** — matches the domain model exactly, avoids CloudKit relationship sync issues, and the orphan/re-parent logic is simple (4 lines of code in `InMemoryCategoryRepository`).

---

## CloudKitCategoryRepository

### File: `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift`

```swift
import Foundation
import SwiftData
import OSLog

@ModelActor
actor CloudKitCategoryRepository: CategoryRepository {
  private let logger = Logger(subsystem: "com.moolah.app", category: "CloudKitCategoryRepo")

  func fetchAll() async throws -> [Category] {
    let descriptor = FetchDescriptor<CategoryRecord>(
      sortBy: [SortDescriptor(\.name, order: .forward)]
    )
    let records = try modelContext.fetch(descriptor)
    return records.map { $0.toDomain() }
  }

  func create(_ category: Category) async throws -> Category {
    let record = CategoryRecord(
      id: category.id,
      name: category.name,
      parentId: category.parentId
    )
    modelContext.insert(record)
    try modelContext.save()
    return category
  }

  func update(_ category: Category) async throws -> Category {
    let id = category.id
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == id }
    )
    guard let record = try modelContext.fetch(descriptor).first else {
      throw BackendError.serverError(404)
    }
    record.name = category.name
    record.parentId = category.parentId
    try modelContext.save()
    return category
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    // Find the category to delete
    let descriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate { $0.id == id }
    )
    guard let record = try modelContext.fetch(descriptor).first else {
      throw BackendError.serverError(404)
    }

    // Re-parent children
    let childDescriptor = FetchDescriptor<CategoryRecord>(
      predicate: #Predicate<CategoryRecord> { $0.parentId == id }
    )
    let children = try modelContext.fetch(childDescriptor)
    for child in children {
      child.parentId = replacementId
    }

    // Delete the category
    modelContext.delete(record)
    try modelContext.save()
  }
}
```

---

## Domain Model Mapping

```swift
extension CategoryRecord {
  func toDomain() -> Category {
    Category(id: id, name: name, parentId: parentId)
  }
}
```

---

## Hierarchy Handling

The `Categories` struct (in `Domain/Models/Category.swift`) builds the tree from a flat list. This is already implemented in the domain layer and works with any flat `[Category]` array. No changes needed.

### Edge Case: Partial Sync

If CloudKit syncs a child category before its parent:
- The child's `parentId` references a UUID that doesn't exist locally yet
- `Categories.children(of:)` will not find the child (it's looking under the parent)
- `Categories.roots` will not include it (its `parentId` is not nil)
- **Result:** The category is temporarily invisible

**Mitigation options:**
1. **Treat orphaned children as roots** — if `parentId` is set but the parent doesn't exist in the local set, treat as a root. This requires a small change to `Categories.init(from:)`.
2. **Accept temporary invisibility** — CloudKit sync is typically fast; the category will appear once the parent syncs.

**Recommendation:** Option 2 for now (keep it simple). Option 1 can be added if users report issues.

---

## CloudKit Sync Considerations

### Conflicts
- Name change from two devices: last-writer-wins, acceptable
- Parent change from two devices: last-writer-wins, acceptable
- Simultaneous create: both categories will sync (different UUIDs), no conflict

### Deletion
- If device A deletes a category while device B creates a child under it:
  - Device A's delete syncs, removing the parent
  - Device B's child has a dangling `parentId`
  - This is the same "orphaned child" case as partial sync — handled identically

### Transactions Referencing Deleted Categories
- Transactions have a `categoryId` field. If a category is deleted, transactions still reference the old UUID.
- The server handles this by simply leaving the reference dangling (the web app shows "Uncategorized" if the categoryId doesn't resolve).
- The native app should do the same — `Categories.by(id:)` returns `nil` for deleted categories, and the UI already handles this.

---

## Testing Strategy

### Contract Tests
Run existing `CategoryRepositoryContractTests` against `CloudKitCategoryRepository`:

```swift
@Suite("CloudKitCategoryRepository contract")
struct CloudKitCategoryRepositoryContractTests {
  private func makeRepository() throws -> CloudKitCategoryRepository {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: CategoryRecord.self,
      configurations: config
    )
    return CloudKitCategoryRepository(modelContainer: container)
  }
}
```

### Test Cases
1. `fetchAll()` returns categories sorted by name
2. `create()` inserts and returns the category
3. `update()` changes name and/or parentId
4. `delete()` with no replacement orphans children (parentId → nil)
5. `delete()` with replacement re-parents children
6. `delete()` throws 404 for non-existent category
7. `update()` throws 404 for non-existent category
8. Hierarchy: parent-child relationships preserved through CRUD cycle

---

## Files to Create

| File | Purpose |
|------|---------|
| `Backends/CloudKit/Models/CategoryRecord.swift` | SwiftData `@Model` |
| `Backends/CloudKit/Repositories/CloudKitCategoryRepository.swift` | Repository implementation |
| `MoolahTests/Backends/CloudKitCategoryRepositoryTests.swift` | Contract tests |

---

## Estimated Effort

| Task | Estimate |
|------|----------|
| `CategoryRecord` model | 30 minutes |
| `CloudKitCategoryRepository` full CRUD | 2 hours |
| Deletion with replacement logic | 30 minutes |
| Tests | 1.5 hours |
| **Total** | **~4.5 hours** |
