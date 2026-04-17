import SwiftUI

struct AddBudgetLineItemSheet: View {
  let earmark: Earmark
  let categories: Categories
  let existingCategoryIds: Set<UUID>
  @State private var selectedCategoryId: UUID?
  @State private var amountText = ""
  @State private var categoryText = ""
  @State private var showCategorySuggestions = false
  @State private var categoryHighlightedIndex: Int?
  @State private var categoryJustSelected = false
  @FocusState private var categoryFieldFocused: Bool
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Category") {
          CategoryAutocompleteField(
            text: $categoryText,
            highlightedIndex: $categoryHighlightedIndex,
            suggestionCount: categoryVisibleSuggestionCount,
            onTextChange: { _ in
              if categoryJustSelected {
                categoryJustSelected = false
              } else {
                showCategorySuggestions = true
              }
            },
            onAcceptHighlighted: acceptHighlightedCategory
          )
          .focused($categoryFieldFocused)
          .onChange(of: categoryFieldFocused) { _, focused in
            if !focused {
              categoryJustSelected = true
              showCategorySuggestions = false
              categoryHighlightedIndex = nil
              if let id = selectedCategoryId, let cat = categories.by(id: id) {
                categoryText = categories.path(for: cat)
              } else {
                categoryText = ""
                selectedCategoryId = nil
              }
            }
          }
        }

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
      .formStyle(.grouped)
      .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
        if showCategorySuggestions, !categoryVisibleSuggestions.isEmpty, let anchor {
          GeometryReader { proxy in
            let rect = proxy[anchor]
            CategorySuggestionDropdown(
              suggestions: categoryVisibleSuggestions,
              searchText: categoryText,
              highlightedIndex: $categoryHighlightedIndex,
              onSelect: { selected in
                categoryJustSelected = true
                selectedCategoryId = selected.id
                categoryText = selected.path
                showCategorySuggestions = false
                categoryHighlightedIndex = nil
              }
            )
            .frame(width: rect.width)
            .offset(x: rect.minX, y: rect.maxY + 4)
          }
        }
      }
      .navigationTitle("Add Budget Item")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            save()
          }
          .disabled(selectedCategoryId == nil || amountText.isEmpty)
        }
      }
    }
    .presentationDetents([.medium])
  }

  private var categoryVisibleSuggestions: [CategorySuggestion] {
    guard showCategorySuggestions else { return [] }
    let allEntries = categories.flattenedByPath()
    let filtered: [Categories.FlatEntry]
    if categoryText.trimmingCharacters(in: .whitespaces).isEmpty {
      filtered = allEntries
    } else {
      filtered = allEntries.filter { matchesCategorySearch($0.path, query: categoryText) }
    }
    return filtered.prefix(8).map { CategorySuggestion(id: $0.category.id, path: $0.path) }
  }

  private var categoryVisibleSuggestionCount: Int {
    categoryVisibleSuggestions.count
  }

  private func acceptHighlightedCategory() {
    guard let index = categoryHighlightedIndex, index < categoryVisibleSuggestions.count else {
      return
    }
    let selected = categoryVisibleSuggestions[index]
    categoryJustSelected = true
    selectedCategoryId = selected.id
    categoryText = selected.path
    showCategorySuggestions = false
    categoryHighlightedIndex = nil
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
