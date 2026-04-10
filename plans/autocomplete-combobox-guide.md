# Autocomplete Combo Box Guide — TextField + Anchor Overlay

## Why This Approach

SwiftUI has no native inline combo box or autocomplete control (even in iOS 26/macOS 26). The `.searchable` API is toolbar-only. `NSComboBox` via `NSViewRepresentable` gives native macOS feel but can't do custom row layouts, match highlighting, hierarchical paths, or cross-platform support.

The **TextField + anchor preference overlay** pattern is what quality SwiftUI implementations converge on. It gives full control over rendering, keyboard handling, and accessibility while working cross-platform.

---

## Architecture

```
TextField (inside Form row)
    ↓ anchorPreference — publishes its bounds
Form (common ancestor)
    ↓ overlayPreferenceValue — reads anchor, positions dropdown
DropdownView (rendered at Form level, not clipped by row)
```

The dropdown renders as an overlay on the Form itself, so it floats above other form rows and isn't clipped by scroll containers.

---

## Core Pattern

### Step 1: Define the PreferenceKey

```swift
struct DropdownAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
```

`Anchor<CGRect>` is a deferred geometry token — it records bounds in the source view's coordinate space but only resolves to actual points when read through a `GeometryProxy`.

**Multiple pickers in one form:** Use separate PreferenceKey types, or a dictionary-based key:

```swift
struct MultiAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
```

### Step 2: Attach to the source view

```swift
TextField("Search...", text: $searchText)
    .anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { $0 }
```

### Step 3: Read on the Form with overlayPreferenceValue

```swift
Form {
    Section { /* fields including the TextField */ }
}
.overlayPreferenceValue(DropdownAnchorKey.self) { anchor in
    if let anchor {
        GeometryReader { proxy in
            let rect = proxy[anchor]
            DropdownView()
                .frame(width: rect.width)
                .offset(x: rect.minX, y: rect.maxY + 4)
        }
    }
}
```

The `GeometryProxy` resolves the anchor from the nested TextField up to the Form's coordinate space, giving correct positioning even when the Form scrolls.

---

## Keyboard Navigation (macOS)

### Arrow keys, Return, Escape

```swift
TextField("Search", text: $state.searchText)
    .focused($isFieldFocused)
    #if os(macOS)
    .onKeyPress(.downArrow) {
        guard totalRowCount > 0 else { return .ignored }
        highlightedIndex = min((highlightedIndex ?? -1) + 1, totalRowCount - 1)
        return .handled
    }
    .onKeyPress(.upArrow) {
        guard let current = highlightedIndex else { return .ignored }
        highlightedIndex = current > 0 ? current - 1 : nil
        return .handled
    }
    .onKeyPress(.return) {
        guard let index = highlightedIndex else { return .ignored }
        acceptSuggestion(at: index)
        return .handled
    }
    .onKeyPress(.escape) {
        dismissDropdown()
        return .handled
    }
    #endif
```

**`.handled` vs `.ignored`:** Returning `.handled` consumes the event — it won't propagate. Returning `.ignored` lets it pass through. If you handle Return, the TextField's normal submit behavior is suppressed.

### Tab-to-accept

SwiftUI's Tab key is consumed by the focus system *before* `onKeyPress` fires in most contexts. Two reliable alternatives:

**Option A: onChange(of: isFocused)** — catches both Tab and click-away:

```swift
.onChange(of: isFieldFocused) { wasFocused, isFocused in
    if wasFocused && !isFocused {
        if let index = highlightedIndex {
            acceptSuggestion(at: index)
        }
        dismissDropdown()
    }
}
```

**Option B: FocusState enum** with explicit advancement on submit:

```swift
enum FormField: Hashable {
    case payee, amount, date, category
}
@FocusState private var focusedField: FormField?

TextField("Category", text: $searchText)
    .focused($focusedField, equals: .category)
    .onSubmit {
        commitSelection()
        focusedField = .amount  // explicit advance
    }
```

### onExitCommand (macOS supplementary Escape)

Handles Escape when focus is on the dropdown itself rather than the text field:

```swift
DropdownContent()
    .onExitCommand {
        dismissDropdown()
    }
```

---

## Click-Outside Dismissal

The overlay approach needs explicit outside-click handling (unlike popovers which get this for free).

### Transparent tap catcher

```swift
.overlayPreferenceValue(DropdownAnchorKey.self) { anchor in
    if isDropdownVisible, let anchor {
        // Layer 1: invisible full-screen tap catcher
        Color.clear
            .contentShape(Rectangle())  // REQUIRED — Color.clear has no hit area by default
            .onTapGesture { dismissDropdown() }
            .accessibilityHidden(true)

        // Layer 2: positioned dropdown
        GeometryReader { proxy in
            let rect = proxy[anchor]
            DropdownContent()
                .frame(width: rect.width)
                .offset(x: rect.minX, y: rect.maxY + 4)
                .onExitCommand { dismissDropdown() }
        }
    }
}
```

**Critical detail:** `.contentShape(Rectangle())` is required — without it, `Color.clear` has no hit-testable area and taps pass through.

### Supplementary: focus-loss detection

Catches when the user clicks a different interactive element (not the tap catcher):

```swift
.onChange(of: isFieldFocused) { wasFocused, isFocused in
    if wasFocused && !isFocused {
        dismissDropdown()
    }
}
```

---

## Accessibility

### accessibilityRepresentation

Replaces the entire accessibility subtree with a standard Picker, giving VoiceOver full native combo box behavior:

```swift
.accessibilityRepresentation {
    Picker(label, selection: $selection) {
        Text("None").tag(UUID?.none)
        ForEach(flatCategories) { cat in
            Text(cat.path).tag(Optional(cat.id))
        }
    }
}
```

VoiceOver announces: "Category, Food > Groceries, picker, double-tap to select." Users get swipe-up/down to cycle.

### Granular alternative

When `accessibilityRepresentation` is overkill:

```swift
.accessibilityLabel("\(label): \(selectedLabel)")
.accessibilityAddTraits(.isButton)
.accessibilityHint("Tap to change category")
```

### Accessibility identifiers (for UI tests)

```swift
TextField("", text: $state.searchText)
    .accessibilityIdentifier("categoryPicker.searchField")

Text("None")
    .accessibilityIdentifier("categoryPicker.option.none")

// Each row:
HStack { /* ... */ }
    .accessibilityIdentifier("categoryPicker.option.\(entry.category.id)")
```

---

## Libraries & References

### Open-source libraries

| Library | Approach | Notes |
|---------|----------|-------|
| [bryceac/ComboBox](https://github.com/bryceac/ComboBox) | NSComboBox wrapper | macOS-only, plain text rows, ~80 lines |
| [MrAsterisco/ComboPicker](https://github.com/MrAsterisco/ComboPicker) | Multi-platform NSComboBox/UIPickerView | More polished, protocol-based data model |
| [dmytro-anokhin/Autocomplete](https://github.com/dmytro-anokhin/Autocomplete) | Pure SwiftUI, async/await | Debounced search with Task cancellation |

### Key blog posts & documentation

- [Anchor preferences in SwiftUI — Swift with Majid](https://swiftwithmajid.com/2020/03/18/anchor-preferences-in-swiftui/)
- [Inspecting the View Tree — The SwiftUI Lab](https://swiftui-lab.com/communicating-with-the-view-tree-part-2/)
- [Key press events detection — SwiftLee](https://www.avanderlee.com/swiftui/key-press-events-detection/)
- [Keyboard-driven actions — Create with Swift](https://www.createwithswift.com/keyboard-driven-actions-in-swiftui-with-onkeypress/)
- [accessibilityRepresentation — Swift with Majid](https://swiftwithmajid.com/2021/09/01/the-power-of-accessibility-representation-view-modifier-in-swiftui/)
- [The SwiftUI cookbook for focus — WWDC23](https://developer.apple.com/videos/play/wwdc2023/10162/)
- [Apple: anchorPreference(key:value:transform:)](https://developer.apple.com/documentation/swiftui/view/anchorpreference(key:value:transform:))
- [Apple: overlayPreferenceValue](https://developer.apple.com/documentation/swiftui/view/overlaypreferencevalue(_:_:))
- [Apple: onExitCommand(perform:)](https://developer.apple.com/documentation/swiftui/view/onexitcommand(perform:))

---

## UI Testing Plan

### Unit tests (store/state logic)

These run against `InMemoryBackend` with no simulator. Test the picker's state management:

| Test | What it verifies |
|------|-----------------|
| `testFilteredEntriesMatchesPartialSearch` | Typing "groc" shows only Groceries |
| `testFilteredEntriesMultiWordSearch` | Typing "food groc" matches "Food > Groceries" |
| `testFilteredEntriesEmptySearchShowsAll` | Empty search shows all categories |
| `testAcceptHighlightedAtZeroReturnsNil` | Row 0 is "None", returns nil selection |
| `testAcceptHighlightedReturnsCorrectCategory` | Highlight row N → returns correct category ID |
| `testCloseResetsState` | close() clears searchText, highlightedIndex, isEditing |
| `testArrowDownIncrementsHighlight` | Moves highlight down, clamps to max |
| `testArrowUpDecrementsHighlight` | Moves highlight up, nil at top |
| `testArrowUpFromNilDoesNothing` | No crash when no highlight |

### XCUITest (integration)

These require the simulator. Use accessibility identifiers to drive interactions:

```swift
final class CategoryPickerUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testDropdownAppearsOnTap() throws {
        app.staticTexts["categoryPicker.label"].tap()
        XCTAssertTrue(app.textFields["categoryPicker.searchField"].waitForExistence(timeout: 2))
    }

    func testTypingFiltersSuggestions() throws {
        app.staticTexts["categoryPicker.label"].tap()
        let searchField = app.textFields["categoryPicker.searchField"]
        searchField.typeText("Groc")
        XCTAssertTrue(app.buttons["categoryPicker.option.groceries"].waitForExistence(timeout: 2))
    }

    func testTappingSuggestionSelectsAndCloses() throws {
        app.staticTexts["categoryPicker.label"].tap()
        app.textFields["categoryPicker.searchField"].typeText("Groc")
        app.buttons["categoryPicker.option.groceries"].tap()
        XCTAssertFalse(app.textFields["categoryPicker.searchField"].exists)
    }

    func testTapOutsideDismisses() throws {
        app.staticTexts["categoryPicker.label"].tap()
        XCTAssertTrue(app.textFields["categoryPicker.searchField"].waitForExistence(timeout: 2))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertFalse(app.textFields["categoryPicker.searchField"].exists)
    }
}
```

### Manual testing checklist

**Keyboard (macOS):**
- [ ] Tab into field — activates, dropdown appears
- [ ] Type text — dropdown filters in real time
- [ ] Down arrow — highlight moves down through suggestions
- [ ] Up arrow — highlight moves up; past first item clears highlight
- [ ] Return with highlight — selects highlighted item, closes dropdown
- [ ] Return without highlight — does nothing (or commits as-is)
- [ ] Escape — closes dropdown, reverts to previous selection
- [ ] Tab with highlight — accepts suggestion, focus moves to next field
- [ ] Tab without highlight — closes dropdown, focus moves to next field

**Mouse/Trackpad (macOS):**
- [ ] Click closed picker — opens dropdown
- [ ] Hover over suggestions — highlight follows cursor
- [ ] Click suggestion — selects it, closes dropdown
- [ ] Click outside dropdown — closes without changing selection

**Touch (iOS):**
- [ ] Tap closed picker — opens dropdown with keyboard
- [ ] Tap suggestion — selects it, closes dropdown
- [ ] Tap outside — closes dropdown

**VoiceOver:**
- [ ] Closed state announces: "Category: [current value], button, tap to change"
- [ ] Open state announces: "N category suggestions" on dropdown
- [ ] Each suggestion is reachable and announces: "Category: [path], button"
- [ ] None row announces: "None — remove category, button"
- [ ] After selection, focus returns and announces new value

**Visual:**
- [ ] Dropdown appears directly below text field
- [ ] Shadow and border match system appearance
- [ ] Max 8 visible entries with scroll for longer lists
- [ ] Match text is visually highlighted (bold or color)
- [ ] Works in both light and dark mode
- [ ] Dropdown does not get clipped by form row bounds
