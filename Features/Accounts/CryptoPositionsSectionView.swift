// Features/Accounts/CryptoPositionsSectionView.swift
import Foundation
import OSLog
import SwiftUI

/// Valuates crypto positions against the profile currency.
///
/// Pulled out of the view so the per-position conversion loop is unit-testable
/// and so failures are handled uniformly: on a throwing conversion we log via
/// `os.Logger` and surface a `.failure` result for the affected position. Per
/// Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`, the view must render
/// the failing row as "unavailable" with a retry affordance — never silently
/// drop it, substitute zero, or fall back to the native instrument.
struct CryptoPositionValuator {
  let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoPositionValuator")

  /// Returns a per-position result keyed by instrument id.
  /// Single-instrument fast path: positions whose instrument matches the profile
  /// currency skip the conversion service entirely (Rule 8).
  func valuate(
    positions: [Position],
    profileCurrency: Instrument,
    on date: Date
  ) async -> [String: Result<Decimal, any Error>] {
    var results: [String: Result<Decimal, any Error>] = [:]
    for position in positions {
      if position.instrument.id == profileCurrency.id {
        results[position.instrument.id] = .success(position.quantity)
        continue
      }
      do {
        let value = try await conversionService.convert(
          position.quantity,
          from: position.instrument,
          to: profileCurrency,
          on: date
        )
        results[position.instrument.id] = .success(value)
      } catch {
        logger.warning(
          "Failed to valuate crypto position \(position.instrument.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        results[position.instrument.id] = .failure(error)
      }
    }
    return results
  }
}

/// Displays crypto token positions for an account with current fiat values.
///
/// When a position's conversion fails the row renders an explicit
/// "Value unavailable" label with a retry button, per Rule 11 in
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md`. Sibling rows keep rendering with
/// their successful values — a single failure does not blank the section.
struct CryptoPositionsSectionView: View {
  let positions: [Position]
  let profileCurrency: Instrument
  let conversionService: any InstrumentConversionService

  @State private var valuations: [String: Result<Decimal, any Error>] = [:]
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
          row(for: position)
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

  @ViewBuilder
  private func row(for position: Position) -> some View {
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
        valuationLabel(for: position)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel(for: position))
  }

  @ViewBuilder
  private func valuationLabel(for position: Position) -> some View {
    switch valuations[position.instrument.id] {
    case .success(let quantity):
      let amount = InstrumentAmount(quantity: quantity, instrument: profileCurrency)
      Text(amount.formatted)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    case .failure:
      HStack(spacing: 4) {
        Text("Value unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button {
          Task { await retry(position: position) }
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .accessibilityLabel("Retry valuation for \(position.instrument.name)")
      }
    case .none:
      EmptyView()
    }
  }

  private func loadValuations() async {
    isLoading = true
    defer { isLoading = false }
    let valuator = CryptoPositionValuator(conversionService: conversionService)
    valuations = await valuator.valuate(
      positions: cryptoPositions,
      profileCurrency: profileCurrency,
      on: Date()
    )
  }

  private func retry(position: Position) async {
    let valuator = CryptoPositionValuator(conversionService: conversionService)
    let results = await valuator.valuate(
      positions: [position],
      profileCurrency: profileCurrency,
      on: Date()
    )
    if let result = results[position.instrument.id] {
      valuations[position.instrument.id] = result
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
    switch valuations[position.instrument.id] {
    case .success(let quantity):
      let amount = InstrumentAmount(quantity: quantity, instrument: profileCurrency)
      return "\(qty), valued at \(amount.formatted)"
    case .failure:
      return "\(qty), value unavailable"
    case .none:
      return qty
    }
  }
}
