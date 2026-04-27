import SwiftUI

struct AddBudgetLineItemSheet: View {
  let earmark: Earmark
  let categories: Categories
  let existingCategoryIds: Set<UUID>
  @State private var selectedCategoryId: UUID?
  @State private var amountText = ""
  @State private var categoryText = ""
  @State private var categoryState = CategoryAutocompleteState()
  @FocusState private var categoryFieldFocused: Bool
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      form
    }
    .presentationDetents([.medium])
    #if os(macOS)
      .frame(minWidth: 400, minHeight: 300)
    #endif
  }

  private var form: some View {
    Form {
      categorySection
      budgetAmountSection
    }
    .formStyle(.grouped)
    .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
      if categoryState.showSuggestions, !categoryVisibleSuggestions.isEmpty, let anchor {
        suggestionDropdown(anchor: anchor)
      }
    }
    .navigationTitle("Add Budget Item")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(selectedCategoryId == nil || amountText.isEmpty)
      }
    }
  }

  private var categorySection: some View {
    Section("Category") {
      CategoryAutocompleteField(
        text: $categoryText,
        highlightedIndex: $categoryState.highlightedIndex,
        suggestionCount: categoryVisibleSuggestionCount,
        onTextChange: { _ in handleTextChange() },
        onAcceptHighlighted: acceptHighlightedCategory,
        onCancel: { categoryState.cancel() }
      )
      .focused($categoryFieldFocused)
      .onChange(of: categoryFieldFocused) { _, focused in
        if !focused { handleCategoryFieldUnfocused() }
      }
    }
  }

  private var budgetAmountSection: some View {
    Section("Budget Amount") {
      HStack {
        Text(earmark.instrument.currencySymbol ?? earmark.instrument.id)
          .foregroundStyle(.secondary)
        TextField("Amount", text: $amountText)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
      }
    }
  }

  @ViewBuilder
  private func suggestionDropdown(anchor: Anchor<CGRect>) -> some View {
    GeometryReader { proxy in
      let rect = proxy[anchor]
      CategorySuggestionDropdown(
        suggestions: categoryVisibleSuggestions,
        searchText: categoryText,
        highlightedIndex: $categoryState.highlightedIndex,
        onSelect: { selected in commit(suggestion: selected) }
      )
      .frame(width: rect.width)
      .offset(x: rect.minX, y: rect.maxY + 4)
    }
  }

  private func handleTextChange() {
    if categoryState.justSelected {
      categoryState.justSelected = false
    } else {
      categoryState.showSuggestions = true
    }
  }

  /// On focus loss, commit a highlighted suggestion if there is one
  /// (#509 — same blur-loses-highlight bug as the transaction-detail
  /// category field), otherwise reconcile typed text against
  /// `selectedCategoryId` so partially-typed input that never resolved
  /// to a known category doesn't linger in the field.
  private func handleCategoryFieldUnfocused() {
    let highlighted = categoryState.highlightedSuggestion(
      for: categoryText, in: categories)
    categoryState.dismiss()
    if let highlighted {
      selectedCategoryId = highlighted.id
      categoryText = highlighted.path
    } else if let id = selectedCategoryId, let cat = categories.by(id: id) {
      categoryText = categories.path(for: cat)
    } else {
      categoryText = ""
      selectedCategoryId = nil
    }
  }

  private var categoryVisibleSuggestions: [CategorySuggestion] {
    categoryState.visibleSuggestions(for: categoryText, in: categories)
  }

  private var categoryVisibleSuggestionCount: Int {
    categoryVisibleSuggestions.count
  }

  private func acceptHighlightedCategory() {
    guard
      let selected = categoryState.highlightedSuggestion(
        for: categoryText, in: categories)
    else { return }
    commit(suggestion: selected)
  }

  private func commit(suggestion: CategorySuggestion) {
    categoryState.dismiss()
    selectedCategoryId = suggestion.id
    categoryText = suggestion.path
  }

  private func save() {
    guard let categoryId = selectedCategoryId else { return }
    guard
      let qty = InstrumentAmount.parseQuantity(
        from: amountText, decimals: earmark.instrument.decimals)
    else { return }
    let amount = InstrumentAmount(quantity: qty, instrument: earmark.instrument)
    Task {
      await earmarkStore.addBudgetItem(
        earmarkId: earmark.id,
        categoryId: categoryId,
        amount: amount
      )
      dismiss()
    }
  }
}
