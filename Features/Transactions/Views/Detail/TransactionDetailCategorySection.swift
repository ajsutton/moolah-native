import SwiftUI

/// Simple-mode category section: the category autocomplete field plus the
/// earmark picker. Owns the field's `@FocusState` locally so the blur
/// handler that normalises stray text against the category tree is
/// reachable without lifting focus into the parent. The shared
/// `CategoryAutocompleteState` is mutated alongside
/// `TransactionDetailCategoryOverlay`, which renders the floating
/// dropdown.
struct TransactionDetailCategorySection: View {
  @Binding var draft: TransactionDraft
  let categories: Categories
  let earmarks: Earmarks
  @Binding var state: CategoryAutocompleteState

  @FocusState private var fieldFocused: Bool

  private var visibleSuggestions: [CategorySuggestion] {
    state.visibleSuggestions(for: draft.categoryText, in: categories)
  }

  var body: some View {
    Section {
      CategoryAutocompleteField(
        text: $draft.categoryText,
        highlightedIndex: $state.highlightedIndex,
        suggestionCount: visibleSuggestions.count,
        onTextChange: { _ in openDropdownIfFocused() },
        onAcceptHighlighted: acceptHighlighted
      )
      .focused($fieldFocused)
      .accessibilityIdentifier(UITestIdentifiers.Detail.category)
      .onChange(of: fieldFocused) { _, focused in
        if !focused { handleBlur() }
      }

      Picker("Earmark", selection: $draft.earmarkId) {
        Text("None").tag(UUID?.none)
        ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
          Text(earmark.name).tag(UUID?.some(earmark.id))
        }
      }
      #if os(macOS)
        .pickerStyle(.menu)
      #endif
    }
  }

  /// Opens the dropdown in response to a *user-driven* edit. Programmatic
  /// writes (payee-autofill, focus-out normalisation) also flow through
  /// `onChange(of: text)`; without the focus guard they'd open the picker
  /// the user never asked to browse.
  private func openDropdownIfFocused() {
    guard fieldFocused else { return }
    if state.justSelected {
      state.justSelected = false
    } else {
      state.showSuggestions = true
    }
  }

  /// Resets picker UI state on blur and delegates the
  /// `categoryText`/`categoryId` reconciliation to `TransactionDraft` so
  /// the rule — "text that doesn't resolve to a known category is
  /// cleared" — is exercised directly by `TransactionDraft` tests.
  private func handleBlur() {
    state.dismiss()
    draft.normaliseCategoryText(using: categories)
  }

  private func acceptHighlighted() {
    guard let index = state.highlightedIndex, index < visibleSuggestions.count else {
      return
    }
    let selected = visibleSuggestions[index]
    state.dismiss()
    draft.categoryId = selected.id
    draft.categoryText = selected.path
  }
}
