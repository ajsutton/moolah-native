import SwiftUI

/// One fee section in the trade-mode editor. Renders amount + instrument,
/// category, earmark, and a destructive Remove button.
struct TransactionDetailFeeSection: View {
  let legIndex: Int
  let displayNumber: Int
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let knownInstruments: [Instrument]
  @Binding var categoryState: CategoryAutocompleteState
  @FocusState.Binding var focusedField: TransactionDetailFocus?
  let onRequestRemove: () -> Void

  var body: some View {
    Section("Fee \(displayNumber)") {
      amountRow
      categoryField
      earmarkPicker
      Button(role: .destructive, action: onRequestRemove) {
        Text("Remove Fee").frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier(UITestIdentifiers.Detail.tradeFeeRemove(displayNumber - 1))
    }
  }

  private var amountRow: some View {
    let amountBinding = Binding(
      get: { draft.legDrafts[legIndex].amountText },
      set: { draft.legDrafts[legIndex].amountText = $0 })
    let instrumentBinding = Binding<Instrument>(
      get: {
        let id = draft.legDrafts[legIndex].instrumentId ?? Instrument.AUD.id
        return knownInstruments.first { $0.id == id } ?? Instrument.fiat(code: id)
      },
      set: { draft.legDrafts[legIndex].instrumentId = $0.id })

    return LabeledContent {
      HStack(spacing: 8) {
        TextField("Amount", text: amountBinding)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .focused($focusedField, equals: .tradeFeeAmount(legIndex))
          .accessibilityIdentifier(UITestIdentifiers.Detail.tradeFeeAmount(displayNumber - 1))
        CompactInstrumentPickerButton(
          selection: instrumentBinding,
          knownInstruments: knownInstruments
        )
      }
    } label: {
      Text("Amount")
    }
  }

  // Reuse the same legCategory autocomplete machinery used by Custom mode
  // (TransactionDetailLegRow). The category field component is small
  // enough to inline here; mirror that file's pattern.
  @ViewBuilder private var categoryField: some View {
    LegCategoryAutocompleteField(
      legIndex: legIndex,
      text: Binding(
        get: { draft.legDrafts[legIndex].categoryText },
        set: { draft.legDrafts[legIndex].categoryText = $0 }),
      highlightedIndex: $categoryState.highlightedIndex,
      suggestionCount: categoryState.visibleSuggestions(
        for: draft.legDrafts[legIndex].categoryText, in: categories
      ).count,
      onTextChange: { _ in categoryState.showSuggestions = true },
      onAcceptHighlighted: {},
      onCancel: { categoryState.cancel() }
    )
    .accessibilityIdentifier(UITestIdentifiers.Detail.legCategory(legIndex))
  }

  private var earmarkPicker: some View {
    Picker(
      "Earmark",
      selection: Binding(
        get: { draft.legDrafts[legIndex].earmarkId },
        set: { draft.legDrafts[legIndex].earmarkId = $0 })
    ) {
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
