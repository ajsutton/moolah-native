import Foundation

// Private helpers driving the load/rebuild lifecycle of
// `InvestmentAccountView`. Hoisted out of the main view file so it
// stays under SwiftLint's `file_length` budget; the methods stay
// `private` and remain part of the view's API surface only — they
// continue to be testable indirectly through the view's behaviour.
extension InvestmentAccountView {
  /// The profile's reporting currency — used for valuing positions and the
  /// chart series. NOT the account's own instrument: an investment account
  /// can be denominated in a non-fiat instrument (e.g., a crypto wallet),
  /// but valuations should always roll up into the user's fiat currency.
  var profileCurrencyInstrument: Instrument {
    session.profile.instrument
  }

  /// Drives the full `loadAllData → positionsViewInput` rebuild used by
  /// both `.task(id:)` and `.refreshable`. Sets `isLoadingPositions`
  /// across the work so progress UI binds correctly.
  func reloadPositions() async {
    isLoadingPositions = true
    defer { isLoadingPositions = false }
    do {
      positionsInput = try await investmentStore.loadAndBuildPositionsInput(
        account: account,
        profileCurrency: profileCurrencyInstrument,
        range: positionsRange)
    } catch is CancellationError {
      return
    } catch {
      Self.logger.error(
        "Unexpected error from positionsViewInput: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// If the account just loaded into a chart-only state but the active
  /// range carries no points (the last trade pre-dates it), default the
  /// range to `.all` so the historic chart populates on first paint
  /// instead of stranding the user on "No chart data yet" with no
  /// indication that widening the range would help. The chart-only
  /// branch's range picker stays bound to `positionsRange`, so the user
  /// can still narrow back to `.threeMonths` if they want.
  ///
  /// Rebuilds `positionsInput` inline rather than waiting for
  /// `.task(id: positionsRange)` to land — flipping `positionsRange`
  /// without first widening `positionsInput` would briefly render the
  /// chart-only branch with stale (empty) data before the task settles.
  /// The cost is one redundant `positionsViewInput` call when the
  /// `.task(id: positionsRange)` fire eventually arrives; for the
  /// expected use case (idle, conversion cache warm) it is sub-second.
  func maybeAutoWidenRange() async {
    guard positionsInput.shouldHide,
      positionsInput.hasAnyHistoricalActivity,
      !positionsInput.hasHistoricalSeries,
      positionsRange != .all
    else { return }
    do {
      positionsInput = try await investmentStore.positionsViewInput(
        title: account.name, range: .all)
      positionsRange = .all
    } catch is CancellationError {
      return
    } catch {
      Self.logger.error(
        "Auto-widen rebuild failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
