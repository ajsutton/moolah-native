// swiftlint:disable multiline_arguments

import Foundation

/// One step in the FIFO cost-basis machine. The shape mirrors what
/// `CostBasisEngine.processBuy` / `processSell` consume, so callers can feed
/// these straight in.
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

/// Classifies a single transaction's legs into FIFO buy / sell events.
///
/// Two cases:
///
/// **Fiat-paired:** non-fiat legs paired with one or more fiat legs in the
/// same transaction. Cost / proceeds-per-unit derive from `fiatOutflow /
/// qty` or `fiatInflow / qty`. Mixed-currency fiat is allowed: each fiat
/// leg is converted to `hostCurrency` on the txn date before being summed
/// (per `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1).
///
/// **Non-fiat swap:** every leg is non-fiat (e.g. ETH → BTC). Each leg's
/// signed quantity is converted to `hostCurrency`; positive legs are buys
/// (cost = converted value / qty), negative legs are sells (proceeds =
/// converted value / qty).
///
/// Per CLAUDE.md sign convention, signs are preserved end-to-end; we never
/// `abs()` a raw leg quantity. Per-unit values are always positive because
/// numerator and denominator share the leg's sign.
///
/// A transaction with a single non-fiat leg and no fiat legs (e.g. a
/// dividend reinvestment recorded as one income leg) is not classifiable
/// and produces an empty `TradeEventClassification`. Callers that want to
/// treat such legs as opening positions must handle them separately.
///
/// This is the single source of truth used by both
/// `CapitalGainsCalculator` (tax reporting) and the
/// `PositionsHistoryBuilder` / `InvestmentStore` cost-basis snapshots
/// (chart + per-row).
enum TradeEventClassifier {
  static func classify(
    legs: [TransactionLeg],
    on date: Date,
    hostCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> TradeEventClassification {
    let fiatLegs = legs.filter { $0.instrument.kind == .fiatCurrency }
    let nonFiatLegs = legs.filter { $0.instrument.kind != .fiatCurrency }

    var fiatOutflow: Decimal = 0
    var fiatInflow: Decimal = 0
    for leg in fiatLegs where leg.quantity != 0 {
      let converted = try await conversionService.convert(
        leg.quantity, from: leg.instrument, to: hostCurrency, on: date
      )
      if leg.quantity < 0 {
        fiatOutflow -= converted
      } else {
        fiatInflow += converted
      }
    }

    var buys: [TradeBuyEvent] = []
    var sells: [TradeSellEvent] = []
    for leg in nonFiatLegs {
      if leg.quantity > 0 && fiatOutflow > 0 {
        buys.append(
          TradeBuyEvent(
            instrument: leg.instrument, quantity: leg.quantity,
            costPerUnit: fiatOutflow / leg.quantity))
      } else if leg.quantity < 0 && fiatInflow > 0 {
        let sellQty = -leg.quantity
        sells.append(
          TradeSellEvent(
            instrument: leg.instrument, quantity: sellQty,
            proceedsPerUnit: fiatInflow / sellQty))
      }
    }
    if !buys.isEmpty || !sells.isEmpty {
      return TradeEventClassification(buys: buys, sells: sells)
    }

    // Non-fiat swap: every leg is non-fiat.
    guard nonFiatLegs.count >= 2 else {
      return TradeEventClassification(buys: [], sells: [])
    }
    for leg in nonFiatLegs {
      let profileValue = try await conversionService.convert(
        leg.quantity, from: leg.instrument, to: hostCurrency, on: date
      )
      let valuePerUnit = profileValue / leg.quantity
      if leg.quantity > 0 {
        buys.append(
          TradeBuyEvent(
            instrument: leg.instrument, quantity: leg.quantity, costPerUnit: valuePerUnit))
      } else {
        let sellQty = -leg.quantity
        sells.append(
          TradeSellEvent(
            instrument: leg.instrument, quantity: sellQty, proceedsPerUnit: valuePerUnit))
      }
    }
    return TradeEventClassification(buys: buys, sells: sells)
  }
}
