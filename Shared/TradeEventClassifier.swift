import Foundation

/// One step in the FIFO cost-basis machine. Consumers
/// (`CapitalGainsCalculator`, `InvestmentStore` cost-basis snapshot,
/// `PositionsHistoryBuilder`) read these structurally.
struct TradeBuyEvent: Sendable, Equatable {
  let instrument: Instrument
  let quantity: Decimal
  let costPerUnit: Decimal
}

struct TradeSellEvent: Sendable, Equatable {
  let instrument: Instrument
  let quantity: Decimal
  let proceedsPerUnit: Decimal
}

struct TradeEventClassification: Sendable, Equatable {
  let buys: [TradeBuyEvent]
  let sells: [TradeSellEvent]
}

/// Classifies a transaction's `.trade` legs into FIFO buy / sell events.
///
/// Per design §2, the classifier filters by `type == .trade` to identify
/// capital legs. For each one, the per-unit value is derived from the
/// *other* `.trade` leg's value converted to `hostCurrency` on the
/// transaction date.
///
/// Attached `.expense` legs are folded into per-unit cost: each fee leg
/// is converted to `hostCurrency` on the trade date (or summed directly
/// when already in `hostCurrency`), summed, and split *evenly* across
/// the capital events. Even split is deterministic and avoids the extra
/// conversion call value-weighting would require; for the typical
/// two-leg fair-value swap the result is the same to within rounding.
/// Buy events have the per-unit fee added to `costPerUnit`; Sell events
/// have it subtracted from `proceedsPerUnit`. Transfers (`In` / `Out`)
/// do not enter the classifier and are unaffected.
///
/// Only non-fiat legs emit capital events. In a fiat+non-fiat pair the
/// fiat leg is the price carrier; in a non-fiat swap both legs emit events.
/// Zero-quantity `.trade` legs cause the whole classification to return empty
/// (no divide-by-zero, no half-emitted event).
enum TradeEventClassifier {
  static func classify(
    legs: [TransactionLeg],
    on date: Date,
    hostCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> TradeEventClassification {
    let tradeLegs = legs.filter { $0.type == .trade }
    guard tradeLegs.count == 2 else {
      return TradeEventClassification(buys: [], sells: [])
    }

    // If either trade leg has a zero quantity, we cannot compute a per-unit
    // price and there is no meaningful event to emit.
    guard tradeLegs[0].quantity != 0, tradeLegs[1].quantity != 0 else {
      return TradeEventClassification(buys: [], sells: [])
    }

    // Fiat legs act as the price carrier; non-fiat legs are the capital assets.
    // In a non-fiat swap both legs generate capital events; in a fiat-paired
    // trade only the non-fiat leg does.
    let nonFiatIndices = tradeLegs.indices.filter {
      tradeLegs[$0].instrument.kind != .fiatCurrency
    }
    let capitalIndices = nonFiatIndices.isEmpty ? Array(tradeLegs.indices) : nonFiatIndices

    let feePerEvent =
      try await feeContribution(
        from: legs,
        hostCurrency: hostCurrency,
        on: date,
        using: conversionService)
      / Decimal(capitalIndices.count)

    var buys: [TradeBuyEvent] = []
    var sells: [TradeSellEvent] = []
    for index in capitalIndices {
      let leg = tradeLegs[index]
      let pairIndex = index == 0 ? 1 : 0
      let pair = tradeLegs[pairIndex]
      let pairValue = try await conversionService.convert(
        pair.quantity, from: pair.instrument, to: hostCurrency, on: date)
      // pair.quantity has the *opposite* sign by convention (paid vs received),
      // so |pairValue / leg.quantity| is the per-unit cost or proceed. abs()
      // here gives the magnitude of the exchange rate, NOT a monetary amount;
      // the buy-vs-sell sign is carried by `leg.quantity > 0` below.
      let perUnit = abs(pairValue / leg.quantity)
      // The Sell formula uses subtraction so a positive feePerUnit (the
      // normal-fee case) reduces proceeds, and a negative feePerUnit
      // (the refund case) increases them. Buy is the mirror — addition
      // gives cost-up for fees, cost-down for refunds.
      let feePerUnit = feePerEvent / leg.quantity.magnitude
      if leg.quantity > 0 {
        buys.append(
          TradeBuyEvent(
            instrument: leg.instrument,
            quantity: leg.quantity,
            costPerUnit: perUnit + feePerUnit))
      } else {
        sells.append(
          TradeSellEvent(
            instrument: leg.instrument,
            quantity: -leg.quantity,
            proceedsPerUnit: perUnit - feePerUnit))
      }
    }
    return TradeEventClassification(buys: buys, sells: sells)
  }

  /// Sum attached `.expense` legs converted to `hostCurrency` on `date`,
  /// then negate so a normal-sign (negative-quantity) fee yields a
  /// positive cost contribution. A positive `.expense` quantity (refund
  /// attached to a trade) yields a negative contribution and reduces
  /// cost. Sign-preserving on purpose; never `abs()`.
  ///
  /// Same-instrument fast path is enforced here at the call site, not
  /// delegated to the conversion service — that keeps the host-currency
  /// case off the async hop and is directly testable (see
  /// `hostCurrencyFeeNeedsNoConversionLookup`).
  ///
  /// Also called by `ProfitLossCalculator.accumulateInvested` so
  /// `totalInvested` stays consistent with the FIFO `remainingCostBasis`.
  static func feeContribution(
    from legs: [TransactionLeg],
    hostCurrency: Instrument,
    on date: Date,
    using conversionService: any InstrumentConversionService
  ) async throws -> Decimal {
    var totalFeeHost: Decimal = 0
    for feeLeg in legs where feeLeg.type == .expense {
      if feeLeg.instrument == hostCurrency {
        totalFeeHost += feeLeg.quantity
      } else {
        totalFeeHost += try await conversionService.convert(
          feeLeg.quantity, from: feeLeg.instrument, to: hostCurrency, on: date)
      }
    }
    return -totalFeeHost
  }
}
