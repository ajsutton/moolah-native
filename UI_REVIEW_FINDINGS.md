# Moolah UI Review Findings

**Reviewed:** 2026-04-08
**Reviewer:** UI Review Agent
**Scope:** All 20 SwiftUI view files against STYLE_GUIDE.md v1.0 and Apple HIG

---

## Executive Summary

The Moolah codebase demonstrates **strong adherence** to modern SwiftUI patterns and the style guide in most areas. Key strengths include:

- ✅ Consistent use of `MonetaryAmountView` with `.monospacedDigit()` for all amounts
- ✅ Proper semantic color usage (green/red/primary for amounts)
- ✅ Good navigation structure with `NavigationSplitView` for macOS/iPad
- ✅ Appropriate use of `ContentUnavailableView` for empty states
- ✅ `.refreshable` implemented on list views
- ✅ Detail panels at correct 350pt width

However, several **critical accessibility gaps** and **minor inconsistencies** were found:

- ❌ **Missing VoiceOver labels** throughout (accessibility critical)
- ⚠️ **Missing keyboard shortcuts** on macOS (productivity impact)
- ⚠️ Inconsistent row spacing and font usage
- ⚠️ Some missing context menus on macOS
- ⚠️ Icon inconsistencies with style guide recommendations
- ℹ️ Missing `.monospacedDigit()` on some dates
- ℹ️ Opportunity to use `.searchable()` on filterable lists

**Overall Grade: B+ (85%)**
*Would be A- with accessibility improvements*

---

## Critical Issues (Must Fix)

### ❌ A1: Missing VoiceOver Accessibility Labels

**Impact:** App is unusable for VoiceOver users
**Priority:** P0 - Blocking accessibility compliance

#### Issues:

1. **TransactionRowView.swift** (lines 11-47)
   - Row has no `.accessibilityLabel()` combining payee, amount, and date
   - Icon has no label explaining transaction type
   ```swift
   // Current: No accessibility support
   HStack {
     Image(systemName: iconName)
       .foregroundStyle(iconColor)
     // ...
   }
   ```

   **Fix:**
   ```swift
   HStack {
     Image(systemName: iconName)
       .foregroundStyle(iconColor)
       .accessibilityLabel(transaction.type.rawValue.capitalized)
     // ...
   }
   .accessibilityElement(children: .combine)
   .accessibilityLabel(accessibilityDescription)

   private var accessibilityDescription: String {
     let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
     let amountStr = transaction.amount.decimalValue.formatted(.currency(code: transaction.amount.currency.code))
     return "\(displayPayee), \(amountStr), \(dateStr)"
   }
   ```

2. **AccountRowView.swift** (lines 6-18)
   - Icon has no accessibility label
   ```swift
   Image(systemName: iconName)
     .foregroundStyle(.secondary)
     .accessibilityLabel(account.type.rawValue) // ADD THIS
   ```

3. **EarmarkRowView.swift** (lines 6-18)
   - Similar issue with bookmark icon
   ```swift
   Image(systemName: "bookmark.fill")
     .accessibilityLabel("Earmark") // ADD THIS
   ```

4. **UpcomingView.swift** (lines 184-186)
   - "Pay" button needs clearer context
   ```swift
   Button("Pay") { onPay() }
     .accessibilityLabel("Pay \(transaction.payee ?? "transaction")") // ADD THIS
   ```

5. **UserMenuView.swift** (lines 28-30)
   - Good example! Already has `.accessibilityLabel()` but could improve placeholder
   ```swift
   // Line 44-54: Placeholder should describe what it represents
   .accessibilityLabel("User avatar placeholder") // ENHANCE
   ```

6. **MonetaryAmountView.swift** (lines 6-24)
   - Missing `.accessibilityValue()` for spoken currency
   ```swift
   Text(amount.decimalValue, format: .currency(code: amount.currency.code))
     .foregroundStyle(effectiveColor)
     .monospacedDigit()
     .font(font)
     .accessibilityLabel(amount.decimalValue.formatted(.currency(code: amount.currency.code).presentation(.spelled))) // ADD THIS
   ```

7. **SidebarView.swift** (lines 52-61)
   - Summary rows lack labels describing what the amounts represent
   ```swift
   LabeledContent("Available Funds") {
     MonetaryAmountView(amount: availableFunds)
   }
   .accessibilityLabel("Available Funds: \(availableFunds.decimalValue.formatted(.currency(code: availableFunds.currency.code)))") // ADD THIS
   ```

### ❌ A2: Missing Keyboard Shortcuts (macOS)

**Impact:** Reduces productivity for power users on macOS
**Priority:** P1 - Required by style guide section 8

#### Missing shortcuts:

1. **TransactionListView.swift** (lines 134-138)
   ```swift
   Button {
     createNewTransaction()
   } label: {
     Label("Add Transaction", systemImage: "plus")
   }
   .keyboardShortcut("n", modifiers: .command) // ADD THIS
   ```

2. **AllTransactionsView.swift** (lines 23-30)
   ```swift
   Button {
     showFilterSheet = true
   } label: {
     Label("Filter", systemImage: ...)
   }
   .keyboardShortcut("f", modifiers: .command) // ADD THIS
   ```

3. **TransactionListView.swift** (line 147)
   - Refresh action exists but no Cmd+R shortcut binding
   ```swift
   .refreshable { ... }
   .keyboardShortcut("r", modifiers: .command) // ADD THIS to a toolbar button
   ```

4. **CategoriesView.swift** (lines 64-68)
   ```swift
   Button { showCreateSheet = true } label: {
     Label("Add Category", systemImage: "plus")
   }
   .keyboardShortcut("n", modifiers: [.command, .shift]) // ADD THIS (Cmd+Shift+N)
   ```

5. **TransactionDetailView.swift** (line 127-128)
   - Delete action lacks Delete key shortcut
   ```swift
   Button("Delete", role: .destructive) {
     onDelete(transaction.id)
   }
   .keyboardShortcut(.delete, modifiers: []) // ADD THIS
   ```

---

## Important Issues (Should Fix)

### ⚠️ B1: Inconsistent Row Spacing

**Impact:** Visual inconsistency across platforms
**Priority:** P2

#### Issues:

1. **TransactionRowView.swift** (line 46)
   ```swift
   .padding(.vertical, 2) // Too tight! Style guide recommends 8pt (macOS)
   ```
   **Fix:**
   ```swift
   #if os(macOS)
     .padding(.vertical, 8)
   #else
     .padding(.vertical, 12)
   #endif
   ```

2. **UpcomingView.swift** (lines 140-178)
   - `UpcomingTransactionRow` uses `spacing: 4` (line 140) which is inconsistent with `TransactionRowView` spacing of 2
   **Fix:** Standardize to 4pt spacing for VStacks in rows

### ⚠️ B2: Missing Context Menus (macOS)

**Impact:** Reduces discoverability of actions on macOS
**Priority:** P2

#### Issues:

1. **TransactionRowView.swift** - No context menu
   - Style guide section 5 shows example at lines 196-204
   ```swift
   // ADD after line 47:
   .contextMenu {
     Button("Edit", systemImage: "pencil") { /* navigate to detail */ }
     Button("Duplicate", systemImage: "doc.on.doc") { /* duplicate */ }
     Divider()
     Button("Delete", systemImage: "trash", role: .destructive) { /* delete */ }
   }
   ```

2. **AccountRowView.swift** - No context menu
   ```swift
   // ADD:
   .contextMenu {
     Button("View Transactions", systemImage: "list.bullet") { /* ... */ }
   }
   ```

3. **CategoryTreeView.swift** (lines 30-48) - `CategoryNodeView` has no context menu
   - `CategoriesView.swift` has it on line 83-88, but `CategoryTreeView` reuses the component without it
   **Fix:** Add context menu to `CategoryNodeView` in both files

### ⚠️ B3: Icon Inconsistencies with Style Guide

**Impact:** Minor visual inconsistency
**Priority:** P2

#### Issues:

1. **TransactionRowView.swift** (lines 50-54)
   ```swift
   case .income: return "arrow.up.circle"    // ❌ Style guide says "arrow.down.circle" (money in)
   case .expense: return "arrow.down.circle" // ❌ Style guide says "arrow.up.circle" (money out)
   ```
   - **Style guide section 7, lines 398-400:** Income uses down arrow (money flowing in), expense uses up arrow (money flowing out)
   - Current implementation is backwards from style guide

   **Fix:**
   ```swift
   case .income: return "arrow.down.circle"
   case .expense: return "arrow.up.circle"
   case .transfer: return "arrow.left.arrow.right.circle" // Also add .circle for consistency
   ```

2. **EarmarkRowView.swift** (line 8)
   ```swift
   Image(systemName: "bookmark.fill")
   ```
   - Style guide section 7 (line 404) recommends `"chart.pie"` or `"target"` for earmarks/budgets
   - `bookmark.fill` is acceptable but not aligned with style guide

   **Recommendation:** Consider changing to `"chart.pie"` for better semantic alignment

3. **SidebarView.swift** (line 78)
   ```swift
   Label("Manage Earmarks", systemImage: "folder")
   ```
   - Should use earmark-specific icon like `"chart.pie"` instead of generic `"folder"`

### ⚠️ B4: Missing .monospacedDigit() on Dates

**Impact:** Potential layout jitter when dates change
**Priority:** P2

#### Issues:

1. **TransactionRowView.swift** (line 22)
   ```swift
   Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
     // Missing .monospacedDigit()
   ```
   **Fix:**
   ```swift
   Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
     .monospacedDigit() // ADD THIS
   ```

2. **UpcomingView.swift** (line 146)
   ```swift
   Text(transaction.date, style: .date)
     .font(.caption)
     .foregroundStyle(.secondary)
     .monospacedDigit() // ADD THIS
   ```

### ⚠️ B5: Hardcoded Color in UserMenuView

**Impact:** Dark mode compatibility issue
**Priority:** P2

**File:** UserMenuView.swift (line 46)
```swift
Color.gray.opacity(0.3) // ❌ Should use semantic color
```

**Fix:**
```swift
#if os(macOS)
  Color(nsColor: .quaternaryLabelColor)
#else
  Color(uiColor: .quaternaryLabel)
#endif
```

### ⚠️ B6: Missing List Style Modifiers

**Impact:** Inconsistent appearance across platforms
**Priority:** P2

#### Issues:

1. **TransactionListView.swift** (line 96)
   - List has no `.listStyle()` modifier
   - Style guide section 2 (lines 49-50) requires `.listStyle(.inset)` on macOS, `.listStyle(.plain)` on iOS
   ```swift
   List(selection: $selectedTransaction) {
     // ...
   }
   #if os(macOS)
     .listStyle(.inset) // ADD THIS
   #else
     .listStyle(.plain) // ADD THIS
   #endif
   ```

2. **AllTransactionsView.swift** - Wraps `TransactionListView` but doesn't control list style
   - Not an issue since `TransactionListView` should handle it

3. **CategoriesView.swift** (line 52), **CategoryTreeView.swift** (line 7)
   - Both have lists without explicit style
   ```swift
   List(selection: $selectedCategory) { ... }
     #if os(macOS)
       .listStyle(.inset) // ADD
     #else
       .listStyle(.plain) // ADD
     #endif
   ```

4. **EarmarksView.swift** (line 54)
   - Same issue
   ```swift
   List(selection: $selectedEarmark) { ... }
     #if os(macOS)
       .listStyle(.inset) // ADD
     #else
       .listStyle(.plain) // ADD
     #endif
   ```

---

## Minor Issues (Nice to Have)

### ℹ️ C1: Missing .searchable() Support

**Impact:** Reduces usability for large lists
**Priority:** P3

**Style guide reference:** Section 2, lines 51-52

#### Opportunities:

1. **TransactionListView.swift**
   - Could add `.searchable()` to filter by payee
   ```swift
   @State private var searchText = ""

   var filteredTransactions: [TransactionWithBalance] {
     if searchText.isEmpty {
       return transactionStore.transactions
     }
     return transactionStore.transactions.filter {
       $0.transaction.payee?.localizedCaseInsensitiveContains(searchText) ?? false
     }
   }

   // Add after line 148:
   .searchable(text: $searchText, prompt: "Search payee")
   ```

2. **CategoriesView.swift**
   - Could search category names

3. **EarmarksView.swift**
   - Could search earmark names

### ℹ️ C2: Font Hierarchy Inconsistencies

**Impact:** Minor visual inconsistency
**Priority:** P3

#### Issues:

1. **TransactionRowView.swift** (line 18)
   ```swift
   Text(displayPayee)
     .lineLimit(1)
     // Missing .font(.headline) - currently using default
   ```
   **Fix:**
   ```swift
   Text(displayPayee)
     .font(.headline) // ADD THIS per style guide section 5, line 164
     .lineLimit(1)
   ```

2. **TransactionRowView.swift** (lines 40-44)
   - Balance row missing explicit font
   ```swift
   VStack(alignment: .trailing, spacing: 2) {
     MonetaryAmountView(amount: transaction.amount)
       // Should specify .font(.headline) for primary amount

     MonetaryAmountView(amount: balance)
       // Should specify .font(.caption) for balance
   }
   ```
   **Fix:**
   ```swift
   VStack(alignment: .trailing, spacing: 2) {
     MonetaryAmountView(amount: transaction.amount, font: .headline)
     MonetaryAmountView(amount: balance, font: .caption, colorOverride: .secondary)
   }
   ```

3. **UpcomingView.swift** (line 182)
   ```swift
   MonetaryAmountView(amount: transaction.amount, font: .body)
   ```
   - Should be `.headline` for consistency with `TransactionRowView`

### ℹ️ C3: Icon Size Inconsistencies

**Impact:** Minor visual issue
**Priority:** P3

#### Issues:

1. **TransactionRowView.swift** (line 15)
   ```swift
   .frame(width: 24)
   ```
   - Missing height specification (should be `frame(width: 24, height: 24)`)
   - Style guide section 7, line 429: "List icons: 20×20pt (macOS), 24×24pt (iOS)"

   **Fix:**
   ```swift
   .frame(width: 24, height: 24)
   #if os(macOS)
     .imageScale(.medium) // Optionally scale down on macOS
   #endif
   ```

2. **AccountRowView.swift** (line 10), **EarmarkRowView.swift** (line 10)
   - Same issue

### ℹ️ C4: Missing Loading States

**Impact:** User feedback during async operations
**Priority:** P3

#### Issues:

1. **TransactionListView.swift** (lines 123-129)
   - Loading spinner shown inline, but no visual indication on initial load before transactions arrive
   - Good implementation! ✅

2. **CategoriesView.swift** (line 79)
   - Shows `ProgressView()` during loading - good! ✅

3. **EarmarksView.swift** (line 110)
   - Shows `ProgressView()` during loading - good! ✅

4. **TransactionDetailView.swift**
   - No loading state shown when debounced save is in progress
   - Could add a subtle indicator
   ```swift
   // After line 102:
   .overlay(alignment: .topTrailing) {
     if saveTask != nil {
       ProgressView()
         .controlSize(.small)
         .padding(8)
     }
   }
   ```

### ℹ️ C5: Empty State Icon Alignment

**Impact:** Visual consistency
**Priority:** P3

#### Observations:

All empty states use appropriate SF Symbols (good!):
- TransactionListView: `"tray"` ✅
- UpcomingView: `"calendar"` ✅
- CategoriesView: `"tag"` ✅
- EarmarksView: `"folder"` ✅

**Recommendation:** Consider using more specific icons per style guide section 7:
- Transactions: `"arrow.left.arrow.right"` instead of `"tray"`
- Earmarks: `"chart.pie"` instead of `"folder"`

### ℹ️ C6: Progress Bar Color Customization

**Impact:** Visual consistency with amount colors
**Priority:** P3

**File:** EarmarkDetailView.swift (line 43)
```swift
ProgressView(value: min(progress, 1.0)) { ... }
```

**Enhancement:**
```swift
ProgressView(value: min(progress, 1.0)) { ... }
  .tint(progress >= 1.0 ? .green : .blue) // Green when goal met
```

### ℹ️ C7: Form Button Styling

**Impact:** Consistency with platform conventions
**Priority:** P3

#### Issues:

1. **CategoryDetailView.swift** (line 42)
   ```swift
   Button("Save Changes", action: saveChanges)
     .disabled(editedName == category.name || editedName.isEmpty)
   ```
   - Missing `.buttonStyle(.bordered)` for macOS
   - Should use toolbar button instead per Apple HIG

   **Fix:**
   ```swift
   // Move to toolbar:
   .toolbar {
     ToolbarItem(placement: .confirmationAction) {
       Button("Save", action: saveChanges)
         .disabled(editedName == category.name || editedName.isEmpty)
     }
   }
   ```

2. **TransactionFormView.swift** - Already uses toolbar buttons correctly! ✅
3. **TransactionFilterView.swift** - Already uses toolbar buttons correctly! ✅

---

## Positive Highlights

### ✅ Excellent Implementations

1. **MonetaryAmountView.swift**
   - Perfect implementation of `.monospacedDigit()` ✅
   - Semantic color system correctly applied ✅
   - Supports `colorOverride` for flexibility ✅
   - Single source of truth for amount display ✅

2. **Detail Panel Pattern**
   - All detail views use correct 350pt width (TransactionListView line 37, UpcomingView line 32, etc.) ✅
   - Proper `HStack(spacing: 0)` with `Divider()` ✅

3. **Navigation Structure**
   - ContentView uses `NavigationSplitView` correctly ✅
   - SidebarView uses `.listStyle(.sidebar)` ✅
   - Adaptive layout with proper selection binding ✅

4. **Empty States**
   - Consistent use of `ContentUnavailableView` ✅
   - Helpful descriptions guiding next actions ✅
   - Proper SF Symbol usage ✅

5. **Form Validation**
   - TransactionDetailView uses `.disabled()` on buttons correctly ✅
   - Debounced auto-save pattern is excellent ✅
   - Field focus management for new transactions ✅

6. **Error Handling**
   - TransactionListView has comprehensive error formatting (lines 53-66) ✅
   - Uses `.alert()` for user-friendly error messages ✅

7. **Platform Adaptation**
   - Widespread use of `#if os(macOS)` for platform-specific UI ✅
   - Keyboard type `.decimalPad` on iOS for amount fields ✅
   - `.navigationBarTitleDisplayMode(.inline)` on iOS ✅

8. **Refresh Support**
   - `.refreshable` implemented on all list views ✅
   - Proper async/await patterns ✅

---

## Actionable Checklist

Copy this checklist to track remediation progress:

### Critical (Must Fix)

- [ ] **A1.1** Add VoiceOver labels to TransactionRowView (combine payee, amount, date)
- [ ] **A1.2** Add VoiceOver labels to AccountRowView icon
- [ ] **A1.3** Add VoiceOver labels to EarmarkRowView icon
- [ ] **A1.4** Add VoiceOver context to "Pay" button in UpcomingView
- [ ] **A1.5** Add `.accessibilityValue()` to MonetaryAmountView for spoken amounts
- [ ] **A1.6** Add VoiceOver labels to SidebarView summary rows
- [ ] **A2.1** Add Cmd+N shortcut to "Add Transaction" button
- [ ] **A2.2** Add Cmd+F shortcut to filter button
- [ ] **A2.3** Add Cmd+R shortcut for refresh
- [ ] **A2.4** Add Cmd+Shift+N shortcut to "Add Category" button
- [ ] **A2.5** Add Delete key shortcut to transaction delete action

### Important (Should Fix)

- [ ] **B1.1** Fix TransactionRowView vertical padding (8pt macOS, 12pt iOS)
- [ ] **B1.2** Standardize UpcomingTransactionRow spacing to 4pt
- [ ] **B2.1** Add context menu to TransactionRowView
- [ ] **B2.2** Add context menu to AccountRowView
- [ ] **B2.3** Add context menu to CategoryTreeView's CategoryNodeView
- [ ] **B3.1** Fix income/expense icon directions (swap up/down arrows)
- [ ] **B3.2** Consider changing earmark icon to "chart.pie"
- [ ] **B3.3** Update "Manage Earmarks" icon to "chart.pie"
- [ ] **B4.1** Add `.monospacedDigit()` to date in TransactionRowView
- [ ] **B4.2** Add `.monospacedDigit()` to date in UpcomingView
- [ ] **B5** Fix hardcoded gray color in UserMenuView placeholder
- [ ] **B6.1** Add `.listStyle()` to TransactionListView
- [ ] **B6.2** Add `.listStyle()` to CategoriesView
- [ ] **B6.3** Add `.listStyle()` to CategoryTreeView
- [ ] **B6.4** Add `.listStyle()` to EarmarksView

### Minor (Nice to Have)

- [ ] **C1.1** Add `.searchable()` to TransactionListView
- [ ] **C1.2** Add `.searchable()` to CategoriesView
- [ ] **C1.3** Add `.searchable()` to EarmarksView
- [ ] **C2.1** Add `.font(.headline)` to payee in TransactionRowView
- [ ] **C2.2** Specify fonts on amount VStack in TransactionRowView
- [ ] **C2.3** Change UpcomingView amount font to `.headline`
- [ ] **C3.1** Add height to icon frame in TransactionRowView
- [ ] **C3.2** Add height to icon frame in AccountRowView
- [ ] **C3.3** Add height to icon frame in EarmarkRowView
- [ ] **C4** Add loading indicator to TransactionDetailView during save
- [ ] **C5.1** Consider more specific empty state icons per style guide
- [ ] **C6** Add color to EarmarkDetailView progress bar
- [ ] **C7** Move "Save Changes" button to toolbar in CategoryDetailView

---

## Testing Recommendations

After implementing fixes, test the following:

### Accessibility Testing
1. **VoiceOver (macOS):** System Preferences → Accessibility → VoiceOver → Enable
   - Navigate through transaction list and verify all elements are speakable
   - Test that amounts are spoken correctly ("twelve hundred thirty-four dollars and fifty-six cents")
   - Verify context menus are announced

2. **VoiceOver (iOS):** Settings → Accessibility → VoiceOver → Enable
   - Test all interactive elements
   - Verify touch gestures work correctly

3. **Dynamic Type:** Settings → Accessibility → Display & Text Size → Larger Text
   - Test at largest size (Accessibility 3)
   - Verify no text clipping or overlap

4. **Increase Contrast:** Accessibility settings
   - Verify all text meets contrast ratios
   - Check that semantic colors still work

### Keyboard Testing (macOS)
1. Verify all keyboard shortcuts work
2. Test tab order through forms
3. Verify Return/Enter submits forms
4. Test Escape dismisses sheets

### Dark Mode Testing
1. Toggle dark mode on both macOS and iOS
2. Verify all colors adapt correctly
3. Check UserMenuView avatar placeholder

### Platform Testing
1. Build and run on macOS
2. Build and run on iOS Simulator (iPhone and iPad)
3. Verify list styles appear correctly on each platform
4. Test detail panel on iPhone (should use sheet) vs iPad (should show inline)

---

## Compliance Summary

| Style Guide Section | Compliance | Notes |
|---------------------|------------|-------|
| 1. Design Principles | ✅ 95% | Conservative, professional design maintained |
| 2. Layout & Navigation | ✅ 90% | Missing some `.listStyle()` modifiers |
| 3. Typography | ⚠️ 85% | Missing `.monospacedDigit()` on some dates, font hierarchy inconsistencies |
| 4. Color & Theming | ⚠️ 90% | One hardcoded color in UserMenuView |
| 5. Components & Patterns | ⚠️ 75% | Missing context menus, some spacing issues |
| 6. Data Visualization | N/A | No charts implemented yet |
| 7. Iconography | ⚠️ 80% | Icon direction issues, some inconsistencies |
| 8. Accessibility | ❌ 40% | Critical VoiceOver gaps, missing keyboard shortcuts |
| 9. Implementation Checklist | ⚠️ 70% | Most items covered, accessibility missing |
| 10. Anti-Patterns | ✅ 100% | No anti-patterns found! |

**Overall Style Guide Compliance: 78%**

---

## Recommended Prioritization

### Sprint 1 (Critical Accessibility)
- Fix all A1.x (VoiceOver) issues
- Fix all A2.x (keyboard shortcuts) issues
- **Goal:** Achieve WCAG AA compliance

### Sprint 2 (Visual Consistency)
- Fix B3.x (icon inconsistencies)
- Fix B6.x (list styles)
- Fix B1.x (spacing)
- **Goal:** Achieve 90%+ style guide compliance

### Sprint 3 (Polish)
- Add B2.x (context menus)
- Implement C1.x (searchable)
- Fix C2.x (font hierarchy)
- **Goal:** Achieve A- overall grade

---

## Additional Resources

- [Apple Accessibility Programming Guide](https://developer.apple.com/accessibility/)
- [VoiceOver Testing Guide](https://developer.apple.com/documentation/accessibility/supporting_voiceover_in_your_app)
- [Keyboard Navigation (macOS)](https://developer.apple.com/design/human-interface-guidelines/keyboard)
- [SF Symbols Browser](https://developer.apple.com/sf-symbols/)

---

**End of Review**
