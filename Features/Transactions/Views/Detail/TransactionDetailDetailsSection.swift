import SwiftUI

/// Simple-mode details section: payee autocomplete, amount + instrument,
/// date. The payee field shares `PayeeAutocompleteState` with the form-
/// level `PayeeAutocompleteOverlay`. The amount field hops focus to the
/// counterpart amount on submit when the draft is a cross-currency
/// transfer, keeping keyboard navigation linear.
struct TransactionDetailDetailsSection: View {
  @Binding var draft: TransactionDraft
  let amountBinding: Binding<String>
  let relevantInstrument: Instrument?
  let isCrossCurrency: Bool
  let suggestionSource: PayeeSuggestionSource
  @Binding var payeeState: PayeeAutocompleteState
  let onAutofill: (String) -> Void
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  var body: some View {
    Section {
      PayeeAutocompleteRow(
        payee: $draft.payee,
        state: $payeeState,
        suggestionSource: suggestionSource,
        onAutofill: onAutofill
      )
      .focused($focusedField, equals: .payee)

      HStack {
        TextField("Amount", text: amountBinding)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .focused($focusedField, equals: .amount)
          .onSubmit {
            if isCrossCurrency {
              focusedField = .counterpartAmount
            }
          }
        Text(relevantInstrument?.id ?? "").foregroundStyle(.secondary)
          .monospacedDigit()
      }

      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
    }
  }
}
