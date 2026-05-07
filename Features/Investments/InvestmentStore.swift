import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class InvestmentStore {
  private(set) var values: [InvestmentValue] = []
  private(set) var dailyBalances: [AccountDailyBalance] = []
  private(set) var isLoading = false
  private(set) var error: Error?
  private(set) var positions: [Position] = []
  private(set) var valuedPositions: [ValuedPosition] = []
  /// Total portfolio value in the profile currency. `nil` when any
  /// individual position's conversion failed — per Rule 11 in
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` we must not display a
  /// partial sum as the portfolio total.
  private(set) var totalPortfolioValue: Decimal?
  /// Lifetime account-level performance numbers in profile currency.
  /// `nil` until `loadAllData(...)` runs, or when conversion failure
  /// during cash-flow extraction marks it unavailable. A failure here
  /// does not invalidate other store state — `valuedPositions` and
  /// `totalPortfolioValue` continue to render normally; only the
  /// header tile reverts to "Unavailable".
  private(set) var accountPerformance: AccountPerformance?

  var selectedPeriod: TimePeriod = .all
  private(set) var loadedAccountId: UUID?
  private(set) var loadedHostCurrency: Instrument?

  /// Callback fired after an investment value is set or removed, so other stores
  /// can update the account's displayed investment value.
  /// Parameters: (accountId, latest value or nil if all values removed).
  var onInvestmentValueChanged:
    (@MainActor (_ accountId: UUID, _ latestValue: InstrumentAmount?) -> Void)?

  private let repository: InvestmentRepository
  // internal (was private) so the `+PositionsInput` extension file can fetch
  // transactions and classify trades using the same injected dependencies.
  let transactionRepository: TransactionRepository?
  let conversionService: any InstrumentConversionService
  let logger = Logger(subsystem: "com.moolah.app", category: "InvestmentStore")

  init(
    repository: InvestmentRepository,
    transactionRepository: TransactionRepository? = nil,
    conversionService: any InstrumentConversionService
  ) {
    self.repository = repository
    self.transactionRepository = transactionRepository
    self.conversionService = conversionService
  }

  // MARK: - Loading & Mutations

  /// Load all values for the account.
  ///
  /// Per `guides/CONCURRENCY_GUIDE.md`, pagination loops must check
  /// `Task.isCancelled` after each network round-trip so that when the
  /// caller is cancelled (e.g. the `.task` on `InvestmentAccountView`
  /// tears down) we stop paginating immediately rather than fetching
  /// every remaining page and then discarding the result.
  func loadValues(accountId: UUID) async {
    do {
      var all: [InvestmentValue] = []
      var page = 0
      let batchSize = 200
      while true {
        let result = try await repository.fetchValues(
          accountId: accountId, page: page, pageSize: batchSize)
        guard !Task.isCancelled else { return }
        all.append(contentsOf: result.values)
        if !result.hasMore { break }
        page += 1
      }
      values = all
    } catch is CancellationError {
      return  // Cancelling a `.task` mid-pagination is not a failure.
    } catch {
      logger.error("Failed to load investment values: \(error.localizedDescription)")
      self.error = error
    }
  }

  /// Loads the legacy account-level cumulative-balance series.
  ///
  /// The repository now returns one entry per (date, instrument) tuple
  /// so multi-instrument legacy accounts no longer conflate quantities
  /// of different instruments under one label (issue #579). This store
  /// converts each per-instrument balance to `hostCurrency` on its own
  /// date and aggregates by date so the consuming chart sees a single
  /// series in the host currency.
  ///
  /// Per Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`: if any
  /// per-instrument conversion fails, the whole series is marked
  /// unavailable (`dailyBalances = []` and `error` set) rather than
  /// rendering a partial sum or a native-instrument fallback.
  func loadDailyBalances(accountId: UUID, hostCurrency: Instrument) async {
    do {
      let raw = try await repository.fetchDailyBalances(accountId: accountId)
      dailyBalances = try await aggregateDailyBalances(
        raw: raw, hostCurrency: hostCurrency)
    } catch is CancellationError {
      return  // Cancelling a `.task` mid-load is not a failure.
    } catch {
      logger.error("Failed to load daily balances: \(error.localizedDescription)")
      self.error = error
      dailyBalances = []
    }
  }

  // The legacy chart's per-instrument forward-fill aggregation lives in
  // `InvestmentStore+DailyBalanceAggregation.swift`.

  /// Loads the full dataset required by `InvestmentAccountView`, branching on
  /// the account's `valuationMode`. Keeps the branching logic out of the view
  /// so `.task`/`.refreshable` blocks stay one-liners.
  func loadAllData(account: Account, profileCurrency: Instrument) async {
    loadedHostCurrency = profileCurrency
    accountPerformance = nil  // clear stale data immediately
    switch account.valuationMode {
    case .recordedValue:
      // `loadValues` and `loadDailyBalances` each paginate against the
      // backend (potentially many round-trips on accounts with long
      // history) and write disjoint state (`self.values` vs
      // `self.dailyBalances`). Running them in parallel turns the
      // wall-clock latency from `t(values) + t(balances)` to `max(...)`
      // — measurable on accounts with multi-page history. Both methods
      // are `@MainActor`-isolated, so the actual writes still serialise
      // on the main actor.
      async let loadedValues: Void = loadValues(accountId: account.id)
      async let loadedBalances: Void = loadDailyBalances(
        accountId: account.id, hostCurrency: profileCurrency)
      _ = await (loadedValues, loadedBalances)
      guard !Task.isCancelled else { return }
      accountPerformance = AccountPerformanceCalculator.computeLegacy(
        dailyBalances: dailyBalances,
        values: values,
        instrument: profileCurrency)
    case .calculatedFromTrades:
      await loadPositions(accountId: account.id)
      guard !Task.isCancelled else { return }
      await valuatePositions(profileCurrency: profileCurrency, on: Date())
      guard !Task.isCancelled else { return }
      await refreshPositionTrackedPerformance(
        accountId: account.id, profileCurrency: profileCurrency)
    }
  }

  /// Recompute the position-tracked `accountPerformance` from the loaded
  /// transactions and `valuedPositions`. Called from `loadAllData` and
  /// `reloadPositionsIfNeeded` after a trade is recorded. Sets
  /// `accountPerformance` to `nil` and surfaces the error on conversion
  /// failure; partial sums are not shown.
  private func refreshPositionTrackedPerformance(
    accountId: UUID, profileCurrency: Instrument
  ) async {
    guard let transactionRepository else {
      accountPerformance = nil
      return
    }
    do {
      let txns = try await fetchAllTransactions(
        repository: transactionRepository,
        accountId: accountId)
      accountPerformance = try await AccountPerformanceCalculator.compute(
        accountId: accountId,
        transactions: txns,
        valuedPositions: valuedPositions,
        profileCurrency: profileCurrency,
        conversionService: conversionService)
    } catch is CancellationError {
      return
    } catch {
      logger.warning(
        "AccountPerformance unavailable: \(error.localizedDescription, privacy: .public)"
      )
      accountPerformance = nil
      // self.error intentionally not set — performance tile degrades to
      // "Unavailable" while the rest of the account view stays functional.
    }
  }

  /// Recompute the legacy `accountPerformance` from the in-memory `values`
  /// and `dailyBalances` arrays after a `setValue` / `removeValue`
  /// mutation. Synchronous: the legacy path doesn't need conversion.
  ///
  /// Uses `loadedHostCurrency` to match `loadAllData`'s legacy branch —
  /// `dailyBalances` are always in `loadedHostCurrency` (converted by
  /// `loadDailyBalances`), so callers must not pass a different
  /// instrument. The `.AUD` final fallback only fires if a mutation
  /// happens before `loadAllData` ran, which should not occur in
  /// practice.
  private func refreshLegacyPerformance() {
    accountPerformance = AccountPerformanceCalculator.computeLegacy(
      dailyBalances: dailyBalances,
      values: values,
      instrument: loadedHostCurrency ?? .AUD)
  }

  /// Refreshes position data after a trade is recorded. Used from
  /// `.onChange` where we only care about position-tracked accounts.
  func reloadPositionsIfNeeded(account: Account, profileCurrency: Instrument) async {
    guard account.valuationMode == .calculatedFromTrades else { return }
    await loadPositions(accountId: account.id)
    guard !Task.isCancelled else { return }
    await valuatePositions(profileCurrency: profileCurrency, on: Date())
    guard !Task.isCancelled else { return }
    await refreshPositionTrackedPerformance(
      accountId: account.id, profileCurrency: profileCurrency)
  }

  /// Re-runs `valuatePositions` against the most recently loaded
  /// account. `ProfileSession` calls this from
  /// `CryptoTokenStore.onRegistrationsChanged` so a freshly-marked
  /// `.spam` token drops out of `valuedPositions` without the user
  /// having to navigate away and back. Issue #790.
  func revaluateLoadedPositions() async {
    guard let profileCurrency = loadedHostCurrency else { return }
    await valuatePositions(profileCurrency: profileCurrency, on: Date())
  }

  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async {
    error = nil
    do {
      try await repository.setValue(accountId: accountId, date: date, value: value)
      let newValue = InvestmentValue(date: date, value: value)
      values.removeAll { $0.date.isSameDay(as: date) }
      values.append(newValue)
      values.sort()
      // The latest value is the first one (values sorted descending by date)
      onInvestmentValueChanged?(accountId, values.first?.value)
      refreshLegacyPerformance()
    } catch {
      logger.error("Failed to set investment value: \(error.localizedDescription)")
      self.error = error
    }
  }

  func removeValue(accountId: UUID, date: Date) async {
    error = nil
    do {
      try await repository.removeValue(accountId: accountId, date: date)
      values.removeAll { $0.date.isSameDay(as: date) }
      onInvestmentValueChanged?(accountId, values.first?.value)
      refreshLegacyPerformance()
    } catch {
      logger.error("Failed to remove investment value: \(error.localizedDescription)")
      self.error = error
    }
  }

  // MARK: - Position Tracking

  /// Load positions for a position-tracked account by computing them from transaction legs.
  func loadPositions(accountId: UUID) async {
    guard let transactionRepository else {
      logger.warning("loadPositions called without transactionRepository")
      return
    }
    do {
      var allTransactions: [Transaction] = []
      var page = 0
      while true {
        let result = try await transactionRepository.fetch(
          filter: TransactionFilter(accountId: accountId),
          page: page,
          pageSize: 200
        )
        // Per guides/CONCURRENCY_GUIDE.md: stop paginating as soon as
        // the enclosing task is cancelled so we don't keep hitting the
        // network after the view that requested this data has gone.
        guard !Task.isCancelled else { return }
        allTransactions.append(contentsOf: result.transactions)
        if result.transactions.count < 200 { break }
        page += 1
      }

      var quantityByInstrument: [Instrument: Decimal] = [:]
      for txn in allTransactions {
        for leg in txn.legs where leg.accountId == accountId {
          quantityByInstrument[leg.instrument, default: 0] += leg.quantity
        }
      }

      loadedAccountId = accountId
      positions = quantityByInstrument.compactMap { instrument, quantity in
        guard quantity != 0 else { return nil }
        return Position(instrument: instrument, quantity: quantity)
      }.sorted { $0.instrument.name < $1.instrument.name }
    } catch is CancellationError {
      return  // Cancelling a `.task` mid-pagination is not a failure.
    } catch {
      logger.error("Failed to load positions: \(error.localizedDescription)")
      self.error = error
    }
  }

  /// Valuate all loaded positions using current market prices. Per
  /// Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`: a failed
  /// conversion marks the aggregate `totalPortfolioValue` unavailable
  /// and sets `error`; sibling rows still render with their successful
  /// values. `.knownZero` positions drop out of `valuedPositions`
  /// entirely (issue #790).
  func valuatePositions(profileCurrency: Instrument, on date: Date) async {
    var valued: [ValuedPosition] = []
    var total: Decimal = 0
    var firstFailure: Error?

    for position in positions {
      let (entry, outcome) = await valuate(
        position: position, profileCurrency: profileCurrency, on: date)
      if let entry { valued.append(entry) }
      switch outcome {
      case .success(let value):
        total += value
      case .knownZero:
        continue
      case .failure(let error):
        if firstFailure == nil { firstFailure = error }
      }
    }

    valuedPositions = valued
    if let firstFailure {
      totalPortfolioValue = nil
      self.error = firstFailure
    } else {
      totalPortfolioValue = total
    }
  }

}

// MARK: - Position Valuation Helper

// Hoisted into an extension so the class body stays under
// `type_body_length`. Same-file private access still works.
extension InvestmentStore {
  private enum ValuationOutcome {
    case success(Decimal)
    /// `.unpriced` / `.spam` crypto source — drop the position from
    /// `valuedPositions`. Issue #790.
    case knownZero
    case failure(Error)
  }

  private func valuate(
    position: Position, profileCurrency: Instrument, on date: Date
  ) async -> (ValuedPosition?, ValuationOutcome) {
    if position.instrument.id == profileCurrency.id {
      let entry = ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: nil,
        costBasis: nil,
        value: InstrumentAmount(quantity: position.quantity, instrument: profileCurrency))
      return (entry, .success(position.quantity))
    }
    do {
      let amount = InstrumentAmount(
        quantity: position.quantity, instrument: position.instrument)
      let result = try await conversionService.convertResult(
        amount, to: profileCurrency, on: date)
      switch result {
      case .knownZero:
        return (nil, .knownZero)
      case .value(let converted):
        let value = converted.quantity
        let unit =
          position.quantity == 0
          ? nil
          : InstrumentAmount(quantity: value / position.quantity, instrument: profileCurrency)
        let entry = ValuedPosition(
          instrument: position.instrument,
          quantity: position.quantity,
          unitPrice: unit,
          costBasis: nil,
          value: converted)
        return (entry, .success(value))
      }
    } catch {
      logger.warning(
        "Failed to valuate position \(position.instrument.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      let entry = ValuedPosition(
        instrument: position.instrument,
        quantity: position.quantity,
        unitPrice: nil,
        costBasis: nil,
        value: nil)
      return (entry, .failure(error))
    }
  }
}

// `chartDataPoints` and the other pure-read computed properties live in
// `InvestmentStore+ComputedProperties.swift`. `InvestmentChartData` (merge +
// forward-fill helpers) lives in `InvestmentChartData.swift`. Both are
// extracted so this file stays under the file_length budget.
