import Foundation

/// Computes per-instrument profit/loss from transaction history.
///
/// Combines FIFO cost basis tracking with current market valuation.
enum ProfitLossCalculator {
  static func compute(
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    asOfDate: Date
  ) async throws -> [InstrumentProfitLoss] {
    let gainsResult = try await CapitalGainsCalculator.computeWithConversion(
      transactions: transactions,
      profileCurrency: profileCurrency,
      conversionService: conversionService
    )

    var instrumentData: [String: InstrumentData] = [:]
    try await accumulateInvested(
      into: &instrumentData,
      transactions: transactions,
      profileCurrency: profileCurrency,
      conversionService: conversionService)
    accumulateGainsAndLots(into: &instrumentData, result: gainsResult)

    return try await buildResults(
      from: instrumentData,
      profileCurrency: profileCurrency,
      conversionService: conversionService,
      asOfDate: asOfDate)
  }

  /// Process all transactions to compute total invested.
  ///
  /// `totalInvested` is the lifetime fiat input attributed to each
  /// non-fiat acquisition: every fiat `.trade` outflow plus every
  /// `.expense` fee leg attached to the same transaction, all converted
  /// to `profileCurrency` on the transaction's date. Mirrors the
  /// classifier's fee fold-in via `TradeEventClassifier.feeContribution`
  /// so `totalInvested` stays consistent with `remainingCostBasis` from
  /// the FIFO engine — otherwise `returnPercentage` (computed against
  /// `totalInvested`) would over-state returns by ignoring transaction
  /// costs. See guides/INSTRUMENT_CONVERSION_GUIDE.md Rules 1, 5, and 8.
  private static func accumulateInvested(
    into instrumentData: inout [String: InstrumentData],
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService
  ) async throws {
    let sorted = transactions.sorted { $0.date < $1.date }
    for transaction in sorted {
      let tradeLegs = transaction.legs.filter { $0.type == .trade }
      let fiatLegs = tradeLegs.filter { $0.instrument.kind == .fiatCurrency }
      let nonFiatLegs = tradeLegs.filter { $0.instrument.kind != .fiatCurrency }

      var fiatOutflow: Decimal = 0
      for leg in fiatLegs where leg.quantity < 0 {
        let converted = try await conversionService.convert(
          -leg.quantity, from: leg.instrument, to: profileCurrency, on: transaction.date
        )
        fiatOutflow += converted
      }
      fiatOutflow += try await TradeEventClassifier.feeContribution(
        from: transaction.legs,
        hostCurrency: profileCurrency,
        on: transaction.date,
        using: conversionService)

      for leg in nonFiatLegs where leg.quantity > 0 {
        instrumentData[leg.instrument.id, default: InstrumentData(instrument: leg.instrument)]
          .totalInvested += fiatOutflow
      }
    }
  }

  private static func accumulateGainsAndLots(
    into instrumentData: inout [String: InstrumentData],
    result: CapitalGainsResult
  ) {
    for event in result.events {
      instrumentData[event.instrument.id, default: InstrumentData(instrument: event.instrument)]
        .realizedGain += event.gain
    }
    for lot in result.openLots {
      let id = lot.instrument.id
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .currentQuantity += lot.remainingQuantity
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .remainingCostBasis += lot.remainingCost
    }
  }

  private static func buildResults(
    from instrumentData: [String: InstrumentData],
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    asOfDate: Date
  ) async throws -> [InstrumentProfitLoss] {
    var results: [InstrumentProfitLoss] = []
    for (_, data) in instrumentData {
      var currentValue: Decimal = 0
      if data.currentQuantity > 0 {
        currentValue = try await conversionService.convert(
          data.currentQuantity, from: data.instrument, to: profileCurrency, on: asOfDate
        )
      }
      let unrealized = currentValue - data.remainingCostBasis
      results.append(
        InstrumentProfitLoss(
          instrument: data.instrument,
          currentQuantity: data.currentQuantity,
          totalInvested: data.totalInvested,
          currentValue: currentValue,
          realizedGain: data.realizedGain,
          unrealizedGain: unrealized
        ))
    }
    return results.sorted { $0.totalGain > $1.totalGain }
  }

  private struct InstrumentData {
    let instrument: Instrument
    var totalInvested: Decimal = 0
    var realizedGain: Decimal = 0
    var currentQuantity: Decimal = 0
    var remainingCostBasis: Decimal = 0
  }
}
