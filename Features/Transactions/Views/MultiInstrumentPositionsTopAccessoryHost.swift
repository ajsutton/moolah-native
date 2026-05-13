import SwiftUI

/// macOS top-accessory host. Owns the same positions-valuator lifecycle
/// as `MultiInstrumentPositionsSplitModifier` (`@State positionsInput`,
/// `@State positionsRange`, `.task(id:)` keyed on positions + the
/// crypto-registry version), but yields a typed `PositionsPanel` enum
/// to its `content` builder so call sites switch on three concrete
/// cases (`.panel` / `.loading` / `.absent`) instead of branching on
/// `AnyView?`.
///
/// The visibility predicate is `MultiInstrumentPositionsSplitModifier.shouldShow(…)`
/// (shared with the iOS modifier) so host and modifier agree on when
/// to render a panel.
/// What `MultiInstrumentPositionsTopAccessoryHost` has resolved for the
/// current positions + valuator state. Call sites switch on this so the
/// topAccessory builder is type-driven, not `AnyView`-driven.
///
/// Hoisted to module scope (rather than nested in the generic host)
/// because Swift treats nested types inside generic types as distinct
/// across outer instantiations (`Host<A>.Panel` ≠ `Host<B>.Panel`).
/// When a leaf's host call has a trailing-closure body that contains
/// `TransactionListView<TopAccessory>(topAccessory: { switch panel { … } })`,
/// the compiler must bottom-up infer the host's `Content` from the
/// closure return type while simultaneously top-down resolving the
/// switch's enum cases against `panel`'s type — and the latter depends
/// on `Content` if the enum is nested. The cycle prevents inference at
/// every leaf call site. Module-scope `PositionsPanel` breaks the
/// cycle.
enum PositionsPanel {
  /// The valuator has produced an input — render `PositionsView`.
  case panel(input: PositionsViewInput, range: Binding<PositionsTimeRange>)
  /// The valuator hasn't produced an input yet but should — render a
  /// `ProgressView`. Distinct from `.absent` so call sites can
  /// render a placeholder during the first valuation.
  case loading
  /// No panel is appropriate for this account (single-host-currency
  /// account; or post-valuation `shouldHide` is true). Call sites
  /// return `EmptyView` to collapse the slot.
  case absent
}

struct MultiInstrumentPositionsTopAccessoryHost<Content: View>: View {
  let positions: [Position]
  let hostCurrency: Instrument
  let title: String
  let conversionService: (any InstrumentConversionService)?
  let registrationsVersion: Int
  @ViewBuilder let content: (PositionsPanel) -> Content

  @State private var positionsInput: PositionsViewInput?
  @State private var positionsRange: PositionsTimeRange = .threeMonths

  private var panel: PositionsPanel {
    let shouldShow = MultiInstrumentPositionsSplitModifier.shouldShow(
      rawPositions: positions,
      hostCurrency: hostCurrency,
      positionsInput: positionsInput)
    guard shouldShow else { return .absent }
    if let positionsInput {
      return .panel(input: positionsInput, range: $positionsRange)
    }
    return .loading
  }

  var body: some View {
    content(panel)
      .task(
        id: PositionsTopAccessoryTaskKey(
          positions: positions,
          registrationsVersion: registrationsVersion)
      ) {
        await valuatePositions()
      }
  }

  private func valuatePositions() async {
    positionsInput = await MultiInstrumentPositionsSplitModifier.makePositionsInput(
      positions: positions,
      hostCurrency: hostCurrency,
      title: title,
      conversionService: conversionService)
  }
}

/// Distinct from `MultiInstrumentPositionsSplitModifier`'s
/// `PositionsTaskKey` so `.task(id:)` invalidations on the host and the
/// modifier never cross-fire when both are instantiated under the same
/// parent view — each uses its own `Hashable` identity space. Re-fires
/// on positions-list changes or a crypto-registry version bump
/// (issue #790).
private struct PositionsTopAccessoryTaskKey: Hashable {
  let positions: [Position]
  let registrationsVersion: Int
}
