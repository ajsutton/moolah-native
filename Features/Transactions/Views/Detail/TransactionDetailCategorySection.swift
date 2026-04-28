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
        onAcceptHighlighted: acceptHighlighted,
        onCancel: { state.cancel() }
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

  /// Resets picker UI state on blur and either commits the highlighted
  /// suggestion or normalises the typed text against the category tree —
  /// whichever applies. Delegated to `TransactionDraft` so the rules are
  /// exercised directly by `TransactionDraft` tests. Without committing
  /// the highlighted suggestion before normalising, Tab from a highlighted
  /// suggestion would clear the field (#509).
  private func handleBlur() {
    let highlighted = state.highlightedSuggestion(
      for: draft.categoryText, in: categories)
    state.dismiss()
    draft.commitHighlightedCategoryOrNormalise(
      highlighted: highlighted, using: categories)
  }

  private func acceptHighlighted() {
    guard let index = state.highlightedIndex, index < visibleSuggestions.count else {
      return
    }
    let selected = visibleSuggestions[index]
    state.dismiss()
    draft.commitCategorySelection(id: selected.id, path: selected.path)
  }
}
