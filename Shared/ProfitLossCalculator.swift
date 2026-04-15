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
    // Run capital gains computation to get events and open lots
    let gainsResult = try await CapitalGainsCalculator.computeWithConversion(
      transactions: transactions,
      profileCurrency: profileCurrency,
      conversionService: conversionService
    )

    // Track total invested and realized gains per instrument
    var instrumentData: [String: InstrumentData] = [:]

    // Process all transactions to compute total invested
    let sorted = transactions.sorted { $0.date < $1.date }
    for tx in sorted {
      let fiatLegs = tx.legs.filter { $0.instrument.kind == .fiatCurrency }
      let nonFiatLegs = tx.legs.filter { $0.instrument.kind != .fiatCurrency }

      let fiatOutflow = fiatLegs.filter { $0.quantity < 0 }
        .reduce(Decimal(0)) { $0 + abs($1.quantity) }

      for leg in nonFiatLegs where leg.quantity > 0 {
        instrumentData[leg.instrument.id, default: InstrumentData(instrument: leg.instrument)]
          .totalInvested += fiatOutflow
      }
    }

    // Add realized gains from events
    for event in gainsResult.events {
      instrumentData[event.instrument.id, default: InstrumentData(instrument: event.instrument)]
        .realizedGain += event.gain
    }

    // Compute current value and unrealized gain from open lots
    for lot in gainsResult.openLots {
      let id = lot.instrument.id
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .currentQuantity += lot.remainingQuantity
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .remainingCostBasis += lot.remainingCost
    }

    // Get current market values
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
