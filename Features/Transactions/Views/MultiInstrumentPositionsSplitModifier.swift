import SwiftUI

/// Conditionally wraps a `TransactionListView` (or any other content)
/// in a `PositionsTransactionsSplit` when the account has positions in
/// instruments other than its host currency. Owns the positions
/// valuator `.task(id:)` so the wrapping leaf doesn't need to manage
/// the valuation lifecycle.
///
/// **Decision predicate** — `shouldShow` returns true iff there are
/// positions AND the set of non-zero instruments contains anything
/// other than the host currency. This matches the predicate that used
/// to live inside `TransactionListView.shouldShowPositionsSplit`.
///
/// **Re-fire trigger** — the `.task(id:)` re-fires whenever the
/// positions list changes OR the crypto-registry version bumps (e.g.
/// the user marks a token as `.spam`). Without the version dimension
/// a spam flip in preferences would leave a stale `valuedPositions`
/// on screen — see issue #790 for the original rationale.
struct MultiInstrumentPositionsSplitModifier: ViewModifier {
  let positions: [Position]
  let hostCurrency: Instrument
  let title: String
  let conversionService: (any InstrumentConversionService)?
  let registrationsVersion: Int

  @State private var positionsInput: PositionsViewInput?
  @State private var positionsRange: PositionsTimeRange = .threeMonths

  private var shouldShow: Bool {
    guard !positions.isEmpty else { return false }
    let nonZeroInstruments = Set(
      positions.lazy.filter { $0.quantity != 0 }.map(\.instrument)
    )
    return nonZeroInstruments != [hostCurrency]
  }

  func body(content: Content) -> some View {
    if shouldShow {
      PositionsTransactionsSplit(defaultTab: .transactions) {
        if let positionsInput {
          PositionsView(input: positionsInput, range: $positionsRange)
        } else {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
        }
      } transactions: {
        content
      }
      .task(id: PositionsTaskKey(positions: positions, registrationsVersion: registrationsVersion))
      {
        await valuatePositions()
      }
    } else {
      content
    }
  }

  private func valuatePositions() async {
    guard let conversionService, !positions.isEmpty else {
      positionsInput = nil
      return
    }
    let valuator = PositionsValuator(conversionService: conversionService)
    let rows = await valuator.valuate(
      positions: positions,
      hostCurrency: hostCurrency,
      costBasis: [:],
      on: Date()
    )
    // The valuator cooperates with cancellation by breaking out of its
    // per-row loop, but it cannot signal cancellation through the
    // non-throwing return — re-check here so a stale (or partial) `rows`
    // from a superseded task never overwrites the freshly-emitting one.
    guard !Task.isCancelled else { return }
    positionsInput = PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: rows,
      historicalValue: nil
    )
  }
}

/// Composite id for the positions-valuation `.task(id:)`. Re-fires when
/// the positions list changes OR when the crypto-registry version bumps
/// (spam flip in preferences). Issue #790.
private struct PositionsTaskKey: Hashable {
  let positions: [Position]
  let registrationsVersion: Int
}

extension View {
  /// Wraps the view in a `PositionsTransactionsSplit` when the account
  /// has positions in non-host-currency instruments. No-op otherwise.
  /// Owns the positions valuator lifecycle.
  func multiInstrumentPositionsSplit(
    positions: [Position],
    hostCurrency: Instrument,
    title: String,
    conversionService: (any InstrumentConversionService)?,
    registrationsVersion: Int = 0
  ) -> some View {
    modifier(
      MultiInstrumentPositionsSplitModifier(
        positions: positions,
        hostCurrency: hostCurrency,
        title: title,
        conversionService: conversionService,
        registrationsVersion: registrationsVersion))
  }
}

// MARK: - Preview

@MainActor
private func multiInstrumentSplitPreviewContent(
  positions: [Position],
  title: String
) -> some View {
  let (backend, _) = PreviewBackend.create()
  return Text("Transactions list goes here")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .multiInstrumentPositionsSplit(
      positions: positions,
      hostCurrency: .AUD,
      title: title,
      conversionService: backend.conversionService)
}

/// Multi-instrument positions exercise the split-shown branch. The
/// host currency is AUD; the positions include a USD holding so
/// `shouldShow` returns true and the wrapper renders the split.
#Preview("Split shown — multi-instrument") {
  multiInstrumentSplitPreviewContent(
    positions: [
      Position(instrument: .AUD, quantity: 1_000),
      Position(instrument: .USD, quantity: 250),
    ],
    title: "Multi-currency Account")
}

/// Single-instrument positions in the host currency exercise the
/// no-op branch — `shouldShow` returns false and the wrapper passes
/// the content through unchanged.
#Preview("Split hidden — host-currency only") {
  multiInstrumentSplitPreviewContent(
    positions: [Position(instrument: .AUD, quantity: 1_000)],
    title: "Plain Account")
}
