# Moolah UI Style Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)
**Based on:** Apple Human Interface Guidelines (2025)

---

## 1. Design Principles

### macOS-First Philosophy
Moolah is optimized for the desktop experience, where users manage their finances with precision, keyboard efficiency, and high information density. The iOS version inherits these patterns but adapts for touch and portability.

**Core Tenets:**
- **Clarity:** Financial data must be instantly scannable and unambiguous
- **Efficiency:** Minimize clicks/taps for common tasks (add transaction, categorize, filter)
- **Precision:** Support keyboard navigation, drag & drop, and pointer-based workflows
- **Trustworthiness:** Use conservative, professional design; avoid playful or frivolous UI

### Adaptive Data Density
- **macOS/iPadOS:** Compact lists, smaller text, maximize visible transactions (10–15 per screen)
- **iPhone:** Comfortable spacing, larger touch targets, prioritize readability (5–8 per screen)
- Use SwiftUI's `@Environment(\.horizontalSizeClass)` and `@Environment(\.verticalSizeClass)` to adapt

---

## 2. Brand Identity

Moolah has a brand guide at `guides/BRAND_GUIDE.md` that defines voice, tone, color palette, typography, logo usage, and approved marketing copy. When making UI decisions:

- **Apple HIG is primary.** This is a native Mac/iOS app. It must look and feel like a first-class citizen of the platform. SF Pro for all UI text, system colors for semantic meaning, standard controls and navigation patterns. Never sacrifice native feel for brand expression.
- **The brand guide is supplementary.** Reference it for: language and tone in user-facing strings (empty states, onboarding, error messages), the income-blue/expense-red/balance-gold color story when choosing accent treatments, and understanding the product's personality ("Solid money. Chill vibes.").
- **Where they conflict, HIG wins.** For example: the brand guide specifies Poppins as the brand typeface, but the app uses SF Pro because that's the system font. The brand palette defines specific hex colors, but the app uses semantic system colors (`.green`, `.red`, `.secondary`) for automatic dark mode adaptation.

See `guides/BRAND_GUIDE.md` for the full brand reference.

---

## 3. Layout & Navigation

### Navigation Structure
```
NavigationSplitView (macOS/iPad) or NavigationStack (iPhone)
├─ Sidebar (200–250pt)
│  ├─ Accounts section
│  ├─ Earmarks section
│  └─ Navigation items (All Transactions, Upcoming, Categories)
├─ Content (flexible width)
│  └─ Transaction lists, account views, analysis dashboard
└─ Inspector (trailing sidebar via .inspector(), shown on selection)
   └─ Forms, transaction details, category editing
```

**Sidebar (macOS/iPad):**
- Use `.navigationSplitViewStyle(.balanced)` to allow resizing
- Show section headers with SF Symbols (e.g., `"dollarsign.circle"` for Accounts)
- Use `List` with `.listStyle(.sidebar)` for native appearance
- Add toolbar buttons for user menu (top) and global actions

**Primary List:**
- Use `List` with `.listStyle(.inset)` on macOS for bordered appearance
- Use `.listStyle(.plain)` on iOS for full-width rows
- Always provide `.refreshable` for pull-to-refresh (iOS) or Cmd+R (macOS)
- Support `.searchable()` for filtering lists

**Detail Panel (Inspector):**
- macOS: Use `.inspector()` modifier — shown as a trailing sidebar at the window level
- iOS: Use `.sheet()` presentation wrapped in `NavigationStack`
- Must be attached at the outermost view level (see Detail Panels section below)
- Use `Form` for editing, `VStack` for read-only details

### Spacing & Sizing

| Element | macOS | iPad | iPhone |
|---------|-------|------|--------|
| List row height | 44–52pt | 52–60pt | 60–68pt |
| Inspector width | System default (~350pt) | System default | Full screen (sheet) |
| Sidebar width | 220pt | 220pt | N/A |
| Form section spacing | 16pt | 20pt | 24pt |
| Inline padding | 12pt | 16pt | 20pt |

---

## 4. Typography

### Font Hierarchy
Use **SF Pro** (system default) for all text. **Never** override with custom fonts for financial data.

| Style | Usage | macOS | iOS |
|-------|-------|-------|-----|
| **Large Title** | Screen titles (navigation bar) | `.font(.largeTitle)` 26pt | `.font(.largeTitle)` 34pt |
| **Title** | Section headers | `.font(.title)` 22pt | `.font(.title)` 28pt |
| **Headline** | List row primary text | `.font(.headline)` 14pt semibold | `.font(.headline)` 17pt semibold |
| **Body** | List row secondary text | `.font(.body)` 13pt | `.font(.body)` 17pt |
| **Subheadline** | Metadata (dates, notes) | `.font(.subheadline)` 11pt | `.font(.subheadline)` 15pt |
| **Caption** | Auxiliary info | `.font(.caption)` 10pt | `.font(.caption)` 12pt |

**Monospaced Digits:**
- Always use `.monospacedDigit()` for amounts, balances, and dates to prevent layout jitter
- Example: `Text("$1,234.56").monospacedDigit()`

**Dynamic Type:**
- Respect user's text size preferences via `.dynamicTypeSize(.medium...(.accessibility3))`
- Test layouts at largest accessibility sizes to ensure no clipping

---

## 5. Color & Theming

### Semantic Color System
Moolah uses semantic colors to communicate financial meaning at a glance.

#### Transaction Amount Colors
```swift
// Current implementation in MonetaryAmountView.swift
.foregroundStyle(amount.isPositive ? .green : amount.isNegative ? .red : .primary)
```

| Amount | Color | Usage |
|--------|-------|-------|
| Positive (income, inflows) | `.green` | System green (adaptive to light/dark mode) |
| Negative (expenses, outflows) | `.red` | System red |
| Zero | `.primary` | Standard text color |
| Balances (neutral) | `.secondary` | Use `colorOverride: .secondary` |

#### Expense Amount Display Convention
Expenses are stored internally as **negative cents** (they reduce the account balance). However, when displaying expense totals to the user (e.g., in category breakdowns, analysis summaries), **negate them to positive** values. Users expect "an expense of $20" — not "$-20". A negative expense (e.g., a refund) should display as a negative value.

```swift
// Server returns -5000 cents for a $50 expense
// Display as: $50.00 (positive)
let displayAmount = MonetaryAmount(cents: max(0, -serverAmount.cents), currency: serverAmount.currency)
```

This matches the web app's `Math.max(0, -totalExpenses)` pattern. This convention applies to both aggregated expense summaries **and** expense amount fields in forms/editors — users enter and see positive values (e.g., "$50"), and the sign is applied internally based on transaction type. Transaction lists that show the raw signed amount (with income positive and expenses negative) are the exception.

**Do:**
- Use system colors (`.green`, `.red`) for automatic dark mode adaptation
- Reserve `.green` and `.red` exclusively for amounts; don't use for buttons or accents
- Use `.secondary` for muted text (e.g., running balances, notes)

**Don't:**
- Mix custom RGB values with semantic colors
- Use color alone to convey information (always pair with text/icons for accessibility)

#### Accent Color
- **macOS:** Default blue (`.accentColor(.blue)`) for buttons, links, selection
- **iOS:** Use default tint color (`.tint(.blue)`)
- Apply globally in `MoolahApp.swift` via `.tint(.blue)`

#### Background Colors
| Element | Light Mode | Dark Mode |
|---------|-----------|-----------|
| Primary background | `.background` | `.background` |
| Secondary background (forms) | `.secondaryGroupedBackground` | `.secondaryGroupedBackground` |
| Elevated surfaces (popovers) | `.regularMaterial` | `.regularMaterial` |

### Dark Mode
- **Always test in dark mode** via Xcode preview or system settings
- Use system colors exclusively to ensure proper adaptation
- Avoid pure black (`#000000`) or pure white (`#FFFFFF`); use `.primary` / `.background`

---

## 6. Components & Patterns

### Lists

#### Transaction Row
**Layout:**
```
┌─────────────────────────────────────────────────┐
│ [Icon] Payee Name              $-1,234.56       │
│        Category • Date         Balance: $4,567  │ (optional)
└─────────────────────────────────────────────────┘
```

**Implementation guidelines:**
```swift
HStack(alignment: .firstTextBaseline, spacing: 12) {
  // Icon (24×24pt)
  Image(systemName: transactionIcon)
    .frame(width: 24, height: 24)
    .foregroundStyle(.secondary)

  VStack(alignment: .leading, spacing: 4) {
    Text(payee)
      .font(.headline)
    HStack(spacing: 4) {
      Text(category)
      Text("•")
      Text(date, format: .dateTime.month(.abbreviated).day())
    }
    .font(.subheadline)
    .foregroundStyle(.secondary)
  }

  Spacer()

  VStack(alignment: .trailing, spacing: 4) {
    MonetaryAmountView(amount: amount, font: .body)
    if let balance = balance {
      MonetaryAmountView(amount: balance, colorOverride: .secondary, font: .caption)
    }
  }
}
.padding(.vertical, 8) // macOS: 8pt, iOS: 12pt via @Environment
```

**Swipe Actions (iOS):**
```swift
.swipeActions(edge: .trailing) {
  Button(role: .destructive) {
    deleteTransaction()
  } label: {
    Label("Delete", systemImage: "trash")
  }
}
```

**Context Menu (macOS):**
```swift
.contextMenu {
  Button("Edit", systemImage: "pencil") { editTransaction() }
  Button("Duplicate", systemImage: "doc.on.doc") { duplicateTransaction() }
  Divider()
  Button("Delete", systemImage: "trash", role: .destructive) { deleteTransaction() }
}
```

#### Empty States
Use `ContentUnavailableView` for empty lists:
```swift
ContentUnavailableView(
  "No Transactions",
  systemImage: "tray",
  description: Text("Tap + to add your first transaction")
)
```

**Icons:** Use SF Symbols that match the domain:
- Transactions: `"tray"`, `"arrow.left.arrow.right"`
- Accounts: `"banknote"`, `"creditcard"`
- Categories: `"folder"`, `"tag"`

### Forms

#### Transaction Detail Form
```swift
Form {
  Section("Details") {
    Picker("Type", selection: $type) {
      Text("Income").tag(TransactionType.income)
      Text("Expense").tag(TransactionType.expense)
      Text("Transfer").tag(TransactionType.transfer)
    }

    TextField("Payee", text: $payee)
      .textFieldStyle(.roundedBorder) // macOS only

    DatePicker("Date", selection: $date, displayedComponents: .date)
  }

  Section("Amount") {
    // Custom amount entry view
    AmountTextField(cents: $cents)
  }
}
.formStyle(.grouped) // iOS: grouped inset, macOS: bordered sections
```

**Field Validation:**
- Show validation errors inline below fields using `.foregroundStyle(.red)` text
- Use `.disabled(true)` on save button until form is valid
- Provide immediate feedback (not just on submit)

**Form Section Order:**
Follow this standard order for transaction forms:
1. Type selection (if applicable)
2. Details (payee, amount, date)
3. Accounts
4. Categories/Earmarks
5. Recurrence (scheduled transactions)
6. Notes
7. Destructive actions (delete)

**Multi-line Text Input:**
- Use `TextField(axis: .vertical)` with `.lineLimit(3...6)` for short notes
- Use `TextEditor` with `.frame(height:)` for longer content (>6 lines)
- Always set bounds to prevent layout issues

### Scheduled Transactions

#### Recurrence UI Pattern
Use a Toggle + conditional fields for recurrence settings:
```swift
Section("Recurrence") {
  Toggle("Repeat", isOn: $isRepeating)

  if isRepeating {
    HStack {
      Text("Every")
      Spacer()
      TextField("", value: $recurEvery, format: .number)
        .keyboardType(.numberPad)
        .multilineTextAlignment(.trailing)
        .frame(minWidth: 40, idealWidth: 60, maxWidth: 80)
        .accessibilityLabel("Recurrence interval")
    }

    Picker("Period", selection: $recurPeriod) {
      Text("Days").tag(RecurPeriod.day)
      Text("Weeks").tag(RecurPeriod.week)
      Text("Months").tag(RecurPeriod.month)
      Text("Years").tag(RecurPeriod.year)
    }
    .accessibilityLabel("Recurrence period")
  }
}
```

**Validation:**
- Both period and frequency must be set when repeat is enabled
- Frequency must be ≥ 1
- Disable save button if incomplete

#### Upcoming Transactions Display
Structure upcoming lists with "Overdue" and "Upcoming" sections:
```swift
List {
  Section("Overdue") {
    ForEach(overdueTransactions) { transaction in
      UpcomingRow(transaction: transaction, isOverdue: true)
    }
  }

  Section("Upcoming") {
    ForEach(upcomingTransactions) { transaction in
      UpcomingRow(transaction: transaction, isOverdue: false)
    }
  }
}
```

**Overdue Visual Treatment:**
- ⚠️ Use **icon + color** to indicate overdue (not color alone)
- Red text + exclamation triangle icon
- Add `.accessibilityLabel("Overdue")` to icon

```swift
HStack(spacing: 4) {
  if isOverdue {
    Image(systemName: "exclamationmark.triangle.fill")
      .foregroundStyle(.red)
      .imageScale(.small)
      .accessibilityLabel("Overdue")
  }
  Text(transaction.payee)
    .foregroundStyle(isOverdue ? .red : .primary)
}
```

**Recurrence Description:**
Display in caption text with accessibility label:
```swift
Text("Every 2 weeks")
  .font(.caption)
  .foregroundStyle(.secondary)
  .accessibilityLabel("Repeats every 2 weeks")
```

**Pay Action:**
- iOS: Use `.buttonStyle(.borderedProminent)` for primary action
- macOS: Use `.buttonStyle(.bordered)` to match platform conventions
- Include accessibility label with payee name

### Buttons & Actions

#### Primary Actions
```swift
// iOS: Use .buttonStyle(.borderedProminent)
Button("Add Transaction") { ... }
  .buttonStyle(.borderedProminent)
  .controlSize(.large)

// macOS: Use default .bordered style, rely on accent color
Button("Save") { ... }
  .buttonStyle(.bordered)
  .keyboardShortcut(.return, modifiers: .command)
```

#### Destructive Actions
```swift
Button("Delete Account", role: .destructive) { ... }
  .buttonStyle(.bordered)
```

#### Toolbar Buttons
```swift
.toolbar {
  ToolbarItem(placement: .primaryAction) {
    Button { createTransaction() } label: {
      Label("Add Transaction", systemImage: "plus")
    }
  }
}
```

**macOS:**
- Use `Label` with `.labelStyle(.iconOnly)` for compact toolbar
- Add keyboard shortcuts via `.keyboardShortcut(.defaultAction)`

**iOS:**
- Use `Label` with `.labelStyle(.titleAndIcon)` in sheets/modals
- Prefer SF Symbols in toolbar for space efficiency

### Detail Panels (Inspector Pattern)

Detail panels (transaction detail, category detail) use SwiftUI's `.inspector()` modifier on macOS and `.sheet()` on iOS. The inspector appears as a trailing sidebar at the window level.

**Critical rule:** The `.inspector()` or `.sheet()` must be attached to the **outermost view that fills the NavigationSplitView detail column** — never to a view nested inside a card, tab, or scroll view. If the inspector is attached too deep in the hierarchy, it will be constrained to that subview's bounds instead of spanning the full window height.

**Use `TransactionInspectorModifier`** (via `.transactionInspector()`) for transaction detail panels. It handles both platforms and includes a toolbar close button on macOS.

**When a view embeds `TransactionListView`** (e.g., `EarmarkDetailView`, `InvestmentAccountView`), the parent must:
1. Own the `@State var selectedTransaction: Transaction?`
2. Pass a binding to `TransactionListView` via the `selectedTransaction:` parameter
3. Attach `.transactionInspector()` at its own level

```swift
// Parent view that embeds TransactionListView
struct EarmarkDetailView: View {
  @State private var selectedTransaction: Transaction?

  var body: some View {
    VStack {
      overviewPanel
      TransactionListView(
        title: ..., filter: ..., accounts: ...,
        categories: ..., earmarks: ...,
        transactionStore: ...,
        selectedTransaction: $selectedTransaction  // pass binding
      )
    }
    .transactionInspector(                         // attach at parent level
      selectedTransaction: $selectedTransaction,
      accounts: accounts, categories: categories,
      earmarks: earmarks, transactionStore: transactionStore
    )
  }
}
```

**When `TransactionListView` is the direct detail content** (e.g., in `ContentView`), omit the `selectedTransaction:` parameter — it manages its own state and inspector internally.

**Toolbar close button:** The `TransactionInspectorModifier` automatically adds a `sidebar.trailing` toolbar button on macOS to dismiss the inspector. For non-transaction inspectors (e.g., category detail), add the button manually:
```swift
.toolbar {
  ToolbarItem(placement: .automatic) {
    if selectedCategory != nil {
      Button { selectedCategory = nil } label: {
        Label("Hide Details", systemImage: "sidebar.trailing")
      }
      .help("Hide Details")
    }
  }
}
```

**iOS behavior:** On iOS, detail panels always use `.sheet(item:)` wrapped in a `NavigationStack` with a "Done" toolbar button.

---

## 7. Data Visualization (Charts)

### Swift Charts Integration
Use **Swift Charts** for spending trends, budget progress, and balance history.

#### Spending Over Time (Line Chart)
```swift
import Charts

Chart(transactions) { transaction in
  LineMark(
    x: .value("Date", transaction.date),
    y: .value("Amount", transaction.amount.decimalValue)
  )
  .foregroundStyle(.green)
}
.chartXAxis {
  AxisMarks(values: .stride(by: .day, count: 7))
}
.chartYAxis {
  AxisMarks(format: .currency(code: "AUD"))
}
.frame(height: 200)
```

#### Category Spending (Bar Chart)
```swift
Chart(categoryTotals) { category in
  BarMark(
    x: .value("Amount", category.total.decimalValue),
    y: .value("Category", category.name)
  )
  .foregroundStyle(by: .value("Category", category.name))
}
.chartLegend(.hidden) // Categories are on Y-axis
```

#### Budget Progress (Gauge)
```swift
Gauge(value: spent, in: 0...budgeted) {
  Text(category.name)
} currentValueLabel: {
  MonetaryAmountView(amount: spentAmount, font: .body)
} minimumValueLabel: {
  Text("$0")
} maximumValueLabel: {
  MonetaryAmountView(amount: budgetedAmount, font: .caption)
}
.gaugeStyle(.accessoryCircularCapacity)
.tint(spent > budgeted ? .red : .green)
```

**Chart Guidelines:**
- Keep charts **simple**; avoid 3D, gradients, or excessive decoration
- Use **monochrome** or semantic colors (green/red for gains/losses)
- Provide **context:** always label axes, show units, include legends if multi-series
- Test with **zero data** and **extreme values** (e.g., $0, negative balances)

---

## 8. Iconography

### SF Symbols Usage
Moolah uses SF Symbols 6 for all icons. **Never** use custom bitmap icons.

#### Standard Icons
| Concept | Symbol | Example Usage |
|---------|--------|---------------|
| Transaction | `"arrow.left.arrow.right"` | Generic transaction icon |
| Income | `"arrow.up"` | Positive flow (money in) |
| Expense | `"arrow.down"` | Negative flow (money out) |
| Transfer | `"arrow.left.arrow.right"` | Between accounts |
| Account | `"creditcard"`, `"banknote"` | Bank accounts, cash |
| Category | `"tag"`, `"folder"` | Transaction categories |
| Earmark/Budget | `"bookmark.fill"` | Earmark allocations and savings goals |
| Calendar | `"calendar"` | Scheduled transactions |
| Search | `"magnifyingglass"` | Search/filter |
| Add | `"plus"` | Create new item |
| Edit | `"pencil"` | Edit existing |
| Delete | `"trash"` | Remove item |
| Settings | `"gearshape"` | User preferences |

#### Rendering Modes
```swift
// Monochrome (default, use semantic colors)
Image(systemName: "arrow.up")
  .foregroundStyle(.green)

// Hierarchical (automatic depth via opacity)
Image(systemName: "creditcard")
  .symbolRenderingMode(.hierarchical)

// Palette (multi-color, use sparingly)
Image(systemName: "chart.pie.fill")
  .symbolRenderingMode(.palette)
  .foregroundStyle(.blue, .green, .red)
```

**Sizing:**
- List icons: 20×20pt (macOS), 24×24pt (iOS)
- Toolbar icons: 16×16pt (macOS), 22×22pt (iOS)
- Empty state icons: 64×64pt (all platforms)

---

## 9. Accessibility

### VoiceOver Support
- Always provide `.accessibilityLabel()` for images and custom controls
- Use `.accessibilityValue()` for amounts: `"One thousand two hundred thirty-four dollars and fifty-six cents"`
- Group related elements with `.accessibilityElement(children: .combine)`

**Example:**
```swift
HStack {
  Text(transaction.payee)
  Spacer()
  MonetaryAmountView(amount: transaction.amount)
}
.accessibilityElement(children: .combine)
.accessibilityLabel("\(transaction.payee), \(transaction.amount.decimalValue.formatted(.currency(code: transaction.amount.currency.code)))")
```

### Keyboard Navigation (macOS)
- **Tab order:** Ensure logical tab order through forms
- **Keyboard shortcuts:**
  - `Cmd+N`: New transaction
  - `Cmd+F`: Focus search field
  - `Cmd+R`: Refresh current view
  - `Delete`: Delete selected item (with confirmation)
  - `Cmd+,`: Open settings (if applicable)
- Use `.keyboardShortcut()` modifier

```swift
Button("New Transaction") { ... }
  .keyboardShortcut("n", modifiers: .command)
```

### Color Contrast
- Ensure **4.5:1** contrast ratio for body text (13pt+)
- Ensure **3:1** contrast ratio for large text (18pt+)
- Test with **Increase Contrast** enabled in Accessibility settings
- Use system colors to automatically meet WCAG AA standards

### Reduce Motion
- Disable decorative animations when `.accessibilityReduceMotion` is enabled
- Keep essential animations (e.g., loading spinners)

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

var animation: Animation? {
  reduceMotion ? nil : .easeInOut
}
```

---

## 10. Implementation Checklist

### Before Building a New Screen
- [ ] Choose the appropriate navigation pattern (split view vs. stack)
- [ ] Define the empty state (`ContentUnavailableView`)
- [ ] Plan keyboard shortcuts (macOS)
- [ ] Identify swipe actions (iOS) and context menus (macOS)
- [ ] Design for both size classes (compact/regular)

### During Development
- [ ] Use semantic colors (`.green`, `.red`, `.secondary`)
- [ ] Apply `.monospacedDigit()` to all amounts
- [ ] Add `.refreshable` for pull-to-refresh
- [ ] Implement `.searchable()` if list is filterable
- [ ] Test with Dynamic Type at largest size
- [ ] Test in dark mode

### Before Shipping
- [ ] Run with VoiceOver enabled (at least one screen)
- [ ] Verify keyboard navigation (macOS)
- [ ] Test with Increase Contrast enabled
- [ ] Check color contrast ratios (use Xcode Accessibility Inspector)
- [ ] Validate forms prevent submission of invalid data
- [ ] Test with slow network (loading states, errors)

---

## 11. Anti-Patterns (Avoid These)

### Layout
- ❌ Fixed pixel widths on text elements (breaks Dynamic Type)
- ❌ Hardcoded colors (e.g., `Color(red: 0.2, green: 0.8, blue: 0.3)`)
- ❌ Using `GeometryReader` for spacing (prefer `Spacer()`, `padding()`)
- ❌ Over-nesting `VStack`/`HStack` (flatten where possible)

### Typography
- ❌ Custom fonts for amounts (always use SF Pro with `.monospacedDigit()`)
- ❌ Setting explicit `.frame(height:)` on text (causes clipping)
- ❌ ALL CAPS TEXT (use `.textCase(.uppercase)` if required by HIG)

### Interaction
- ❌ Buttons without clear labels (icon-only without `.accessibilityLabel`)
- ❌ Destructive actions without confirmation dialogs
- ❌ Touch targets smaller than 44×44pt (iOS)
- ❌ Relying solely on color to communicate state (add icons/text)

### Data Display
- ❌ Showing raw cents values (e.g., "5023¢") — always format as currency
- ❌ Truncating amounts with `...` (use `.minimumScaleFactor()` if needed)
- ❌ Inconsistent date formats (use `.formatted(.dateTime.month().day())`)

---

## 12. Resources

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [SF Symbols App](https://developer.apple.com/sf-symbols/) (browse all symbols)
- [Swift Charts Documentation](https://developer.apple.com/documentation/charts)
- [Accessibility Developer Guide](https://developer.apple.com/accessibility/)
- [Color Contrast Analyzer](https://www.figma.com/community/plugin/733159460536249875) (Figma plugin)

---

## Version History
- **1.0** (2026-04-08): Initial style guide for Moolah native app (macOS-first, adaptive density, semantic colors, charts)
