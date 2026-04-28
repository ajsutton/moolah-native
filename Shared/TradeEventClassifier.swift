import Foundation

/// One step in the FIFO cost-basis machine. Shape unchanged from the previous
/// implementation; consumers (CapitalGainsCalculator, InvestmentStore cost
/// basis snapshot, PositionsHistoryBuilder) read these structurally.
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
/// Per design §2, the classifier filters by `type == .trade` and ignores
/// every other leg. For each `.trade` leg, the per-unit value is derived
/// from the *other* `.trade` leg's value converted to `hostCurrency` on
/// the transaction date. Fee legs (`.expense`) are not part of cost basis
/// in this iteration; that decision moves with the SelfWealthParser
/// brokerage-attach work tracked in
/// https://github.com/ajsutton/moolah-native/issues/558.
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

    var buys: [TradeBuyEvent] = []
    var sells: [TradeSellEvent] = []
    for index in capitalIndices {
      let leg = tradeLegs[index]
      let pairIndex = index == 0 ? 1 : 0
      let pair = tradeLegs[pairIndex]
      let pairValue = try await conversionService.convert(
        pair.quantity, from: pair.instrument, to: hostCurrency, on: date)
      // pair.quantity has the *opposite* sign by convention (paid vs received),
      // so |pairValue / leg.quantity| is the per-unit cost or proceed.
      let perUnit = abs(pairValue / leg.quantity)
      if leg.quantity > 0 {
        buys.append(
          TradeBuyEvent(
            instrument: leg.instrument,
            quantity: leg.quantity,
            costPerUnit: perUnit))
      } else {
        sells.append(
          TradeSellEvent(
            instrument: leg.instrument,
            quantity: -leg.quantity,
            proceedsPerUnit: perUnit))
      }
    }
    return TradeEventClassification(buys: buys, sells: sells)
  }
}
