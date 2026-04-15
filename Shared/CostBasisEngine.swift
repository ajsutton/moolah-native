import Foundation

/// Pure synchronous engine for FIFO cost basis tracking.
///
/// Feed buy and sell events in chronological order. The engine maintains open lots
/// per instrument and produces CapitalGainEvent values on sells.
///
/// Not async, no repository dependencies — all data passed in. Highly testable.
struct CostBasisEngine: Sendable {
  /// Open lots grouped by instrument ID, in acquisition order (FIFO).
  private var lots: [String: [CostBasisLot]] = [:]

  /// Record a buy: adds a new lot for the instrument.
  mutating func processBuy(
    instrument: Instrument,
    quantity: Decimal,
    costPerUnit: Decimal,
    date: Date
  ) {
    let lot = CostBasisLot(
      id: UUID(),
      instrument: instrument,
      acquiredDate: date,
      costPerUnit: costPerUnit,
      originalQuantity: quantity,
      remainingQuantity: quantity
    )
    lots[instrument.id, default: []].append(lot)
  }

  /// Record a sell: consume lots in FIFO order, return gain/loss events.
  ///
  /// If sell quantity exceeds available lots, only the available quantity is processed.
  mutating func processSell(
    instrument: Instrument,
    quantity: Decimal,
    proceedsPerUnit: Decimal,
    date: Date
  ) -> [CapitalGainEvent] {
    var remaining = quantity
    var events: [CapitalGainEvent] = []
    let calendar = Calendar(identifier: .gregorian)

    while remaining > 0 {
      guard var openLots = lots[instrument.id], !openLots.isEmpty else { break }

      var lot = openLots[0]
      let consumed = min(remaining, lot.remainingQuantity)

      let holdingDays =
        calendar.dateComponents(
          [.day], from: lot.acquiredDate, to: date
        ).day ?? 0

      events.append(
        CapitalGainEvent(
          instrument: instrument,
          sellDate: date,
          acquiredDate: lot.acquiredDate,
          quantity: consumed,
          costBasis: consumed * lot.costPerUnit,
          proceeds: consumed * proceedsPerUnit,
          holdingDays: holdingDays
        ))

      lot.remainingQuantity -= consumed
      remaining -= consumed

      if lot.remainingQuantity <= 0 {
        openLots.removeFirst()
      } else {
        openLots[0] = lot
      }
      lots[instrument.id] = openLots
    }

    return events
  }

  /// Return open (unsold) lots for an instrument, in FIFO order.
  func openLots(for instrument: Instrument) -> [CostBasisLot] {
    lots[instrument.id] ?? []
  }

  /// All open lots across all instruments.
  func allOpenLots() -> [CostBasisLot] {
    lots.values.flatMap { $0 }
  }
}
