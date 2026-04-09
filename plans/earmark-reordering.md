# Earmark Reordering Implementation Plan

## Overview

Add drag-and-drop reordering for earmarks in the sidebar, mirroring how accounts already support `.onMove` reordering. The reorder logic will live in `EarmarkStore` (not in the view), following the architecture rule that views must be thin and all business logic belongs in stores.

> Note: The existing account reordering methods (`reorderCurrentAccounts` / `reorderInvestmentAccounts`) are private view methods in `SidebarView.swift` lines 202-225, which technically violates the CLAUDE.md architecture rule. This plan follows the correct pattern by placing logic in the store.

---

## 1. Add `reorder` Method to EarmarkStore

**File:** `Features/Earmarks/EarmarkStore.swift`

```swift
func reorderEarmarks(from source: IndexSet, to destination: Int) async {
    var visible = visibleEarmarks
    visible.move(fromOffsets: source, toOffset: destination)

    // Update positions (0-indexed) and persist each change
    for (index, earmark) in visible.enumerated() {
        var updated = earmark
        updated.position = index
        _ = try? await repository.update(updated)
    }

    // Rebuild local state: merge visible (reordered) with hidden (unchanged)
    let hiddenEarmarks = earmarks.ordered.filter { $0.isHidden }
    earmarks = Earmarks(from: visible + hiddenEarmarks)
}
```

Key design decisions:
- Only reorders **visible** earmarks (hidden earmarks keep their positions)
- Uses `try?` to silently handle individual update failures, matching the existing account reordering pattern
- Rebuilds local state immediately so the UI reflects the change without a full reload

---

## 2. Add `.onMove` to Earmarks ForEach in SidebarView

**File:** `Features/Navigation/SidebarView.swift`

At the earmarks `ForEach` closing brace, add `.onMove`:

```swift
ForEach(earmarkStore.visibleEarmarks) { earmark in
    NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
        EarmarkRowView(earmark: earmark)
    }
}
.onMove { source, destination in
    Task { await earmarkStore.reorderEarmarks(from: source, to: destination) }
}
```

One-liner view change that dispatches to the store.

---

## 3. Tests

**File:** `MoolahTests/Features/EarmarkStoreTests.swift`

### Test 1: `testReorderEarmarksUpdatesPositions`
- Create 3 earmarks with positions 0, 1, 2
- Call `reorderEarmarks(from: IndexSet(integer: 2), to: 0)` (move last to first)
- Verify positions are 0, 1, 2 in the new order
- Verify repository state matches

### Test 2: `testReorderEarmarksSkipsHiddenEarmarks`
- Create 3 earmarks: positions 0, 1, 2, with position-1 earmark hidden
- Call `reorderEarmarks` on the 2 visible earmarks
- Verify hidden earmark's position is unchanged

### Test 3: `testReorderSingleEarmarkIsNoOp`
- Create 1 earmark, reorder from 0 to 0
- Verify position unchanged

### Test 4: `testReorderEmptyListIsNoOp`
- Empty store, call reorder
- Verify no crash

### Test 5: `testReorderPersistsToRepository`
- Create 3 earmarks, reorder, fetch from repository directly
- Verify repository has updated positions

---

## 4. Implementation Order (TDD)

1. **Write tests** in `EarmarkStoreTests.swift` — all 5 tests (will fail)
2. **Add `reorderEarmarks`** to `EarmarkStore` — run tests to confirm pass
3. **Add `.onMove`** to earmarks `ForEach` in `SidebarView`
4. **Build and verify** — `just test`, check for warnings
5. **Manual test** — drag-and-drop on macOS (native drag) and iOS (edit mode handles)

---

## 5. Edge Cases

| Edge Case | Handling |
|---|---|
| Empty earmark list | `.onMove` never fires; `reorderEarmarks` is no-op on empty array |
| Single earmark | `.move` on single-element array is no-op |
| Hidden earmarks | Only `visibleEarmarks` reordered; hidden retain original positions |
| Network failure on update | `try?` swallows error; local state reflects new order. On next `load()`, server state overwrites — partial revert possible (matches account behavior) |
| Rapid successive reorders | Each reorder awaits completion; SwiftUI coalesces moves during same gesture |

---

## 6. Files Changed

| File | Change |
|---|---|
| `Features/Earmarks/EarmarkStore.swift` | Add `reorderEarmarks(from:to:)` method |
| `Features/Navigation/SidebarView.swift` | Add `.onMove` modifier (1 line + closure) |
| `MoolahTests/Features/EarmarkStoreTests.swift` | Add 5 new test methods |

No changes needed to `Earmark.swift`, `EarmarkRepository.swift`, or `InMemoryEarmarkRepository.swift` — all already have the required `position` field and `update` method.

---

**Estimate:** 2-3 hours
