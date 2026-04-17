import Foundation

/// Input type: a transaction's legs with its date.
struct LegTransaction: Sendable {
  let date: Date
  let legs: [TransactionLeg]
}

/// Result of capital gains computation over a set of transactions.
struct CapitalGainsResult: Sendable {
  let events: [CapitalGainEvent]
  let openLots: [CostBasisLot]

  var totalRealizedGain: Decimal {
    events.reduce(Decimal(0)) { $0 + $1.gain }
  }

  var shortTermGain: Decimal {
    events.filter { !$0.isLongTerm }.reduce(Decimal(0)) { $0 + $1.gain }
  }

  var longTermGain: Decimal {
    events.filter { $0.isLongTerm }.reduce(Decimal(0)) { $0 + $1.gain }
  }
}

/// Processes transaction legs to extract buy/sell events and compute capital gains.
///
/// **Buy detection:** A non-fiat instrument leg with positive quantity, paired with a
/// fiat outflow leg in the same transaction. Cost per unit = fiat amount / quantity.
///
/// **Sell detection:** A non-fiat instrument leg with negative quantity, paired with a
/// fiat inflow leg. Proceeds per unit = fiat amount / quantity.
///
/// **Crypto-to-crypto swaps:** Both legs are non-fiat. Requires conversion service to
/// determine AUD-equivalent proceeds. Use `computeWithConversion` for these cases.
enum CapitalGainsCalculator {

  /// Compute capital gains from fiat-paired trades (no conversion needed).
  static func compute(
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    sellDateRange: ClosedRange<Date>? = nil
  ) -> CapitalGainsResult {
    var engine = CostBasisEngine()
    var allEvents: [CapitalGainEvent] = []

    let sorted = transactions.sorted { $0.date < $1.date }

    for tx in sorted {
      let (buys, sells) = classifyLegs(
        legs: tx.legs, date: tx.date, profileCurrency: profileCurrency
      )

      for buy in buys {
        engine.processBuy(
          instrument: buy.instrument,
          quantity: buy.quantity,
          costPerUnit: buy.costPerUnit,
          date: tx.date
        )
      }

      for sell in sells {
        let inRange = sellDateRange.map { $0.contains(tx.date) } ?? true
        let events = engine.processSell(
          instrument: sell.instrument,
          quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit,
          date: tx.date
        )
        if inRange {
          allEvents.append(contentsOf: events)
        }
      }
    }

    return CapitalGainsResult(events: allEvents, openLots: engine.allOpenLots())
  }

  /// Compute capital gains including non-fiat swaps, using conversion service for AUD-equivalent.
  static func computeWithConversion(
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    sellDateRange: ClosedRange<Date>? = nil
  ) async throws -> CapitalGainsResult {
    var engine = CostBasisEngine()
    var allEvents: [CapitalGainEvent] = []

    let sorted = transactions.sorted { $0.date < $1.date }

    for tx in sorted {
      let (buys, sells) = try await classifyLegsWithConversion(
        legs: tx.legs, date: tx.date,
        profileCurrency: profileCurrency,
        conversionService: conversionService
      )

      for buy in buys {
        engine.processBuy(
          instrument: buy.instrument,
          quantity: buy.quantity,
          costPerUnit: buy.costPerUnit,
          date: tx.date
        )
      }

      for sell in sells {
        let inRange = sellDateRange.map { $0.contains(tx.date) } ?? true
        let events = engine.processSell(
          instrument: sell.instrument,
          quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit,
          date: tx.date
        )
        if inRange {
          allEvents.append(contentsOf: events)
        }
      }
    }

    return CapitalGainsResult(events: allEvents, openLots: engine.allOpenLots())
  }

  // MARK: - Leg classification

  private struct BuyEvent {
    let instrument: Instrument
    let quantity: Decimal
    let costPerUnit: Decimal
  }

  private struct SellEvent {
    let instrument: Instrument
    let quantity: Decimal
    let proceedsPerUnit: Decimal
  }

  /// Classify legs into buy/sell events using fiat legs for cost/proceeds.
  private static func classifyLegs(
    legs: [TransactionLeg],
    date: Date,
    profileCurrency: Instrument
  ) -> (buys: [BuyEvent], sells: [SellEvent]) {
    let fiatLegs = legs.filter { $0.instrument.kind == .fiatCurrency }
    let nonFiatLegs = legs.filter { $0.instrument.kind != .fiatCurrency }

    let fiatOutflow = fiatLegs.filter { $0.quantity < 0 }
      .reduce(Decimal(0)) { $0 + abs($1.quantity) }
    let fiatInflow = fiatLegs.filter { $0.quantity > 0 }
      .reduce(Decimal(0)) { $0 + $1.quantity }

    var buys: [BuyEvent] = []
    var sells: [SellEvent] = []

    for leg in nonFiatLegs {
      if leg.quantity > 0 && fiatOutflow > 0 {
        let costPerUnit = fiatOutflow / leg.quantity
        buys.append(
          BuyEvent(
            instrument: leg.instrument, quantity: leg.quantity, costPerUnit: costPerUnit))
      } else if leg.quantity < 0 && fiatInflow > 0 {
        let proceedsPerUnit = fiatInflow / abs(leg.quantity)
        sells.append(
          SellEvent(
            instrument: leg.instrument, quantity: abs(leg.quantity),
            proceedsPerUnit: proceedsPerUnit))
      }
    }

    return (buys, sells)
  }

  /// Classify legs including non-fiat swaps, using conversion for AUD-equivalent value.
  ///
  /// Fiat legs are converted individually to `profileCurrency` on `date`
  /// before being summed — a transaction may contain fiat legs in
  /// different currencies (e.g. USD payment + AUD fee), and summing their
  /// raw quantities would silently blend currencies into a meaningless
  /// cost basis. See `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1.
  private static func classifyLegsWithConversion(
    legs: [TransactionLeg],
    date: Date,
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService
  ) async throws -> (buys: [BuyEvent], sells: [SellEvent]) {
    let fiatLegs = legs.filter { $0.instrument.kind == .fiatCurrency }
    let nonFiatLegs = legs.filter { $0.instrument.kind != .fiatCurrency }

    // Sum fiat outflow / inflow in the profile currency, converting each
    // leg individually so mixed-currency transactions aggregate correctly.
    var fiatOutflow: Decimal = 0
    var fiatInflow: Decimal = 0
    for leg in fiatLegs where leg.quantity != 0 {
      let convertedAbs = try await conversionService.convert(
        abs(leg.quantity), from: leg.instrument, to: profileCurrency, on: date
      )
      if leg.quantity < 0 {
        fiatOutflow += convertedAbs
      } else {
        fiatInflow += convertedAbs
      }
    }

    // Fiat-paired trades
    var buys: [BuyEvent] = []
    var sells: [SellEvent] = []
    for leg in nonFiatLegs {
      if leg.quantity > 0 && fiatOutflow > 0 {
        let costPerUnit = fiatOutflow / leg.quantity
        buys.append(
          BuyEvent(
            instrument: leg.instrument, quantity: leg.quantity, costPerUnit: costPerUnit))
      } else if leg.quantity < 0 && fiatInflow > 0 {
        let proceedsPerUnit = fiatInflow / abs(leg.quantity)
        sells.append(
          SellEvent(
            instrument: leg.instrument, quantity: abs(leg.quantity),
            proceedsPerUnit: proceedsPerUnit))
      }
    }
    if !buys.isEmpty || !sells.isEmpty {
      return (buys, sells)
    }

    // Non-fiat swap: both sides are non-fiat.
    guard nonFiatLegs.count >= 2 else { return ([], []) }

    for leg in nonFiatLegs {
      let profileValue = try await conversionService.convert(
        abs(leg.quantity), from: leg.instrument, to: profileCurrency, on: date
      )
      let valuePerUnit = profileValue / abs(leg.quantity)

      if leg.quantity > 0 {
        buys.append(
          BuyEvent(
            instrument: leg.instrument, quantity: leg.quantity, costPerUnit: valuePerUnit))
      } else {
        sells.append(
          SellEvent(
            instrument: leg.instrument, quantity: abs(leg.quantity), proceedsPerUnit: valuePerUnit))
      }
    }

    return (buys, sells)
  }
}
