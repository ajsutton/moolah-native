// Features/Accounts/CryptoPositionsSectionView.swift
import SwiftUI

/// Displays crypto token positions for an account with current fiat values.
struct CryptoPositionsSectionView: View {
  let positions: [Position]
  let profileCurrency: Instrument
  let conversionService: any InstrumentConversionService

  @State private var valuations: [String: Decimal] = [:]
  @State private var isLoading = true

  var body: some View {
    Section("Crypto Holdings") {
      if isLoading {
        ProgressView()
      } else if cryptoPositions.isEmpty {
        Text("No crypto holdings")
          .foregroundStyle(.secondary)
      } else {
        ForEach(cryptoPositions, id: \.instrument.id) { position in
          HStack {
            VStack(alignment: .leading) {
              Text(position.instrument.displayLabel)
                .font(.headline)
              Text(position.instrument.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing) {
              Text(formatQuantity(position.quantity, instrument: position.instrument))
                .monospacedDigit()
              if let fiatValue = valuations[position.instrument.id] {
                let amount = InstrumentAmount(quantity: fiatValue, instrument: profileCurrency)
                Text(amount.formatted)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .monospacedDigit()
              }
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(accessibilityLabel(for: position))
        }
      }
    }
    .task {
      await loadValuations()
    }
  }

  private var cryptoPositions: [Position] {
    positions.filter { $0.instrument.kind == .cryptoToken && !$0.quantity.isZero }
  }

  private func loadValuations() async {
    isLoading = true
    defer { isLoading = false }

    for position in cryptoPositions {
      do {
        let fiatValue = try await conversionService.convert(
          position.quantity,
          from: position.instrument,
          to: profileCurrency,
          on: Date()
        )
        valuations[position.instrument.id] = fiatValue
      } catch {
        // Price unavailable -- show quantity without value
      }
    }
  }

  private func formatQuantity(_ quantity: Decimal, instrument: Instrument) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = min(instrument.decimals, 8)
    formatter.minimumFractionDigits = 0
    let number = formatter.string(from: quantity as NSDecimalNumber) ?? "\(quantity)"
    return "\(number) \(instrument.displayLabel)"
  }

  private func accessibilityLabel(for position: Position) -> String {
    let qty = formatQuantity(position.quantity, instrument: position.instrument)
    if let fiatValue = valuations[position.instrument.id] {
      let amount = InstrumentAmount(quantity: fiatValue, instrument: profileCurrency)
      return "\(qty), valued at \(amount.formatted)"
    }
    return qty
  }
}
