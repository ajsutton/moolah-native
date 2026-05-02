import SwiftUI

/// One sub-transaction (leg) section in the multi-leg editor: type,
/// account, instrument override, amount, category autocomplete, earmark,
/// and a destructive delete button (omitted for the last remaining leg).
///
/// Owns the leg's category-field `@FocusState` so the blur handler that
/// normalises stray text against the category tree is reachable without
/// lifting focus into the parent. The shared `CategoryAutocompleteState`
/// is mutated alongside `TransactionDetailLegCategoryOverlay`.
struct TransactionDetailLegRow: View {
  let index: Int
  let totalLegCount: Int
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  @Binding var categoryState: CategoryAutocompleteState
  @FocusState.Binding var focusedField: TransactionDetailFocus?
  let onRequestDelete: () -> Void

  @FocusState private var categoryFieldFocused: Bool

  private var isEarmarkOnly: Bool { draft.legDrafts[index].isEarmarkOnly }

  private var visibleSuggestions: [CategorySuggestion] {
    categoryState.visibleSuggestions(
      for: draft.legDrafts[index].categoryText, in: categories)
  }

  var body: some View {
    Section("Sub-transaction \(index + 1) of \(totalLegCount)") {
      if !isEarmarkOnly {
        typePicker
      }
      accountPicker
      amountRow
      if !isEarmarkOnly {
        categoryField
      }
      earmarkPicker
      if totalLegCount > 1 {
        Button(role: .destructive) {
          onRequestDelete()
        } label: {
          Text("Delete Sub-transaction")
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  private var typePicker: some View {
    Picker("Type", selection: $draft.legDrafts[index].type) {
      Text(TransactionType.income.displayName).tag(TransactionType.income)
      Text(TransactionType.expense.displayName).tag(TransactionType.expense)
      Text(TransactionType.transfer.displayName).tag(TransactionType.transfer)
      Text(TransactionType.trade.displayName).tag(TransactionType.trade)
    }
  }

  private var accountPicker: some View {
    Picker("Account", selection: $draft.legDrafts[index].accountId) {
      Text("None").tag(UUID?.none)
      AccountPickerOptions(
        accounts: accounts,
        exclude: nil,
        currentSelection: draft.legDrafts[index].accountId
      )
    }
    #if os(macOS)
      .pickerStyle(.menu)
    #endif
    .onChange(of: draft.legDrafts[index].accountId) { _, newAccountId in
      draft.enforceEarmarkOnlyInvariants(at: index)
      if let newAccountId, let account = accounts.by(id: newAccountId) {
        draft.legDrafts[index].instrument = account.instrument
      } else if let emId = draft.legDrafts[index].earmarkId,
        let earmark = earmarks.by(id: emId)
      {
        draft.legDrafts[index].instrument = earmark.instrument
      }
    }
  }

  private var amountRow: some View {
    let instrumentBinding = Binding<Instrument>(
      get: { draft.legDrafts[index].instrument ?? defaultInstrument },
      set: { draft.legDrafts[index].instrument = $0 }
    )
    return LabeledContent {
      HStack(spacing: 8) {
        TextField("Amount", text: $draft.legDrafts[index].amountText)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .focused($focusedField, equals: .legAmount(index))
        CompactInstrumentPickerButton(selection: instrumentBinding)
          .accessibilityLabel("Currency for sub-transaction \(index + 1)")
          .accessibilityHint("Overrides the currency derived from the account")
      }
    } label: {
      Text("Amount")
    }
  }

  private var categoryField: some View {
    LegCategoryAutocompleteField(
      legIndex: index,
      text: $draft.legDrafts[index].categoryText,
      highlightedIndex: $categoryState.highlightedIndex,
      suggestionCount: visibleSuggestions.count,
      onTextChange: { _ in openDropdownIfFocused() },
      onAcceptHighlighted: acceptHighlighted,
      onCancel: { categoryState.cancel() }
    )
    .focused($categoryFieldFocused)
    .accessibilityIdentifier(UITestIdentifiers.Detail.legCategory(index))
    .onChange(of: categoryFieldFocused) { _, focused in
      if !focused { handleBlur() }
    }
  }

  private var earmarkPicker: some View {
    Picker("Earmark", selection: $draft.legDrafts[index].earmarkId) {
      if !isEarmarkOnly {
        Text("None").tag(UUID?.none)
      }
      ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
        Text(earmark.name).tag(UUID?.some(earmark.id))
      }
    }
    #if os(macOS)
      .pickerStyle(.menu)
    #endif
    .onChange(of: draft.legDrafts[index].earmarkId) { _, _ in
      draft.enforceEarmarkOnlyInvariants(at: index)
    }
  }

  /// Falls back to the leg's account instrument and then earmark
  /// instrument when the leg has no explicit instrument stored.
  private var defaultInstrument: Instrument {
    let leg = draft.legDrafts[index]
    if let acctId = leg.accountId, let account = accounts.by(id: acctId) {
      return account.instrument
    }
    if let emId = leg.earmarkId, let earmark = earmarks.by(id: emId) {
      return earmark.instrument
    }
    return Instrument.AUD
  }

  /// Opens the dropdown in response to a *user-driven* edit. Programmatic
  /// writes also flow through `onChange(of: text)`; without the focus
  /// guard they'd open the picker the user never asked to browse.
  private func openDropdownIfFocused() {
    guard categoryFieldFocused else { return }
    if categoryState.justSelected {
      categoryState.justSelected = false
    } else {
      categoryState.showSuggestions = true
    }
  }

  private func handleBlur() {
    let highlighted = categoryState.highlightedSuggestion(
      for: draft.legDrafts[index].categoryText, in: categories)
    categoryState.dismiss()
    draft.commitHighlightedLegCategoryOrNormalise(
      at: index, highlighted: highlighted, using: categories)
  }

  private func acceptHighlighted() {
    guard let highlighted = categoryState.highlightedIndex,
      highlighted < visibleSuggestions.count
    else { return }
    let selected = visibleSuggestions[highlighted]
    categoryState.dismiss()
    draft.commitLegCategorySelection(at: index, id: selected.id, path: selected.path)
  }
}
