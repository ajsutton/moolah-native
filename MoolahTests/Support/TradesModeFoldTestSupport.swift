import Foundation

@testable import Moolah

/// Shared helpers for the trades-mode position-valuation fold tests.
/// Hoisted out of `GRDBDailyBalancesTradesModeTests` so the suite can be
/// split across multiple files (SwiftLint `file_length` /
/// `type_body_length`) while keeping the helper definitions in a
/// single place.
enum TradesModeFoldTestSupport {

  /// Build the standard `DailyBalancesHandlers` for fold-contract
  /// tests. The trades-mode fold only ever invokes
  /// `handleInvestmentValueFailure` — the other two callbacks are
  /// no-ops. Pass `InvestmentValueFailureLog.append` (or a
  /// `{ _, _ in }` no-op for cases that don't assert on failures).
  static func makeHandlers(
    failures: @escaping @Sendable (Error, Date) -> Void
  ) -> GRDBAnalysisRepository.DailyBalancesHandlers {
    GRDBAnalysisRepository.DailyBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in },
      handleInvestmentValueFailure: failures)
  }

  /// Zero-everything `DailyBalance` placeholder so the fold has an
  /// entry to look up / drop on the given day.
  static func placeholderBalance(at dayKey: Date) -> DailyBalance {
    DailyBalance(
      date: dayKey,
      balance: .zero(instrument: .defaultTestInstrument),
      earmarked: .zero(instrument: .defaultTestInstrument),
      availableFunds: .zero(instrument: .defaultTestInstrument),
      investments: .zero(instrument: .defaultTestInstrument),
      investmentValue: nil,
      netWorth: .zero(instrument: .defaultTestInstrument),
      bestFit: nil,
      isForecast: false)
  }

  /// Pre-seeded `DailyBalance` mirroring a recorded-value snapshot
  /// contribution on the day. Used by tests that exercise the
  /// add-not-overwrite contract for `investmentValue` /
  /// `netWorth`.
  static func preSeededDailyBalance(on dayKey: Date) -> DailyBalance {
    DailyBalance(
      date: dayKey,
      balance: InstrumentAmount(
        quantity: 10, instrument: .defaultTestInstrument),
      earmarked: .zero(instrument: .defaultTestInstrument),
      availableFunds: InstrumentAmount(
        quantity: 10, instrument: .defaultTestInstrument),
      investments: .zero(instrument: .defaultTestInstrument),
      investmentValue: InstrumentAmount(
        quantity: 100, instrument: .defaultTestInstrument),
      netWorth: InstrumentAmount(
        quantity: 110, instrument: .defaultTestInstrument),
      bestFit: nil,
      isForecast: false)
  }

  /// Build a `DailyBalancesAssemblyContext` parameterised for the
  /// trades-mode fold: empty `investmentAccountIds` (the
  /// snapshot/recorded-value fold isn't under test), explicit
  /// trades-mode ids, instrument map, and conversion service. Profile
  /// instrument is the default test instrument (AUD).
  static func makeContext(
    tradesIds: Set<UUID>,
    instrumentMap: [String: Instrument],
    conversionService: any InstrumentConversionService
  ) -> GRDBAnalysisRepository.DailyBalancesAssemblyContext {
    GRDBAnalysisRepository.DailyBalancesAssemblyContext(
      investmentAccountIds: [],
      tradesModeInvestmentAccountIds: tradesIds,
      instrumentMap: instrumentMap,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService)
  }
}
