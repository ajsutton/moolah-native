import Foundation
import Testing

@testable import Moolah

@Suite("CostBasisEngine")
struct CostBasisEngineTests {

  // MARK: - Buy lots

  @Test func singleBuy_createsOneLot() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: Decimal(42), date: date(0))

    let lots = engine.openLots(for: bhp)
    #expect(lots.count == 1)
    #expect(lots[0].remainingQuantity == 100)
    #expect(lots[0].costPerUnit == 42)
  }

  @Test func multipleBuys_createsMultipleLots() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 40, date: date(0))
    engine.processBuy(instrument: bhp, quantity: 50, costPerUnit: 45, date: date(30))

    let lots = engine.openLots(for: bhp)
    #expect(lots.count == 2)
    #expect(lots[0].costPerUnit == 40)
    #expect(lots[1].costPerUnit == 45)
  }

  // MARK: - FIFO sells

  @Test func sellAll_fromSingleLot_producesOneGainEvent() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 40, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 100, proceedsPerUnit: 50, date: date(365)
    )

    #expect(events.count == 1)
    #expect(events[0].quantity == 100)
    #expect(events[0].costBasis == 4000)
    #expect(events[0].proceeds == 5000)
    #expect(events[0].gain == 1000)
    #expect(events[0].holdingDays >= 365)
    #expect(engine.openLots(for: bhp).isEmpty)
  }

  @Test func partialSell_FIFO_consumesFirstLotFirst() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 40, date: date(0))
    engine.processBuy(instrument: bhp, quantity: 50, costPerUnit: 45, date: date(30))

    let events = engine.processSell(
      instrument: bhp, quantity: 120, proceedsPerUnit: 50, date: date(365)
    )

    // FIFO: first 100 from lot 1 (cost 40), next 20 from lot 2 (cost 45)
    #expect(events.count == 2)
    #expect(events[0].quantity == 100)
    #expect(events[0].costBasis == 4000)
    #expect(events[1].quantity == 20)
    #expect(events[1].costBasis == 900)

    // Remaining: 30 units in lot 2
    let remaining = engine.openLots(for: bhp)
    #expect(remaining.count == 1)
    #expect(remaining[0].remainingQuantity == 30)
    #expect(remaining[0].costPerUnit == 45)
  }

  @Test func sellAtLoss_negativeGain() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 50, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 100, proceedsPerUnit: 30, date: date(180)
    )

    #expect(events.count == 1)
    #expect(events[0].gain == -2000)
    #expect(events[0].holdingDays >= 180)
  }

  @Test func holdingPeriod_underOneYear_shortTerm() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 10, costPerUnit: 100, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 10, proceedsPerUnit: 120, date: date(364)
    )

    #expect(events[0].isLongTerm == false)
  }

  @Test func holdingPeriod_overOneYear_longTerm() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 10, costPerUnit: 100, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 10, proceedsPerUnit: 120, date: date(366)
    )

    #expect(events[0].isLongTerm == true)
  }

  @Test func multipleInstruments_trackedSeparately() {
    let bhp = stockInstrument("BHP")
    let cba = stockInstrument("CBA")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 100, costPerUnit: 40, date: date(0))
    engine.processBuy(instrument: cba, quantity: 50, costPerUnit: 100, date: date(0))

    let bhpEvents = engine.processSell(
      instrument: bhp, quantity: 50, proceedsPerUnit: 50, date: date(365)
    )
    #expect(bhpEvents.count == 1)
    #expect(bhpEvents[0].quantity == 50)

    // CBA lots unaffected
    let cbaLots = engine.openLots(for: cba)
    #expect(cbaLots.count == 1)
    #expect(cbaLots[0].remainingQuantity == 50)
  }

  @Test func sellMoreThanOwned_processesAvailableOnly() {
    let bhp = stockInstrument("BHP")
    var engine = CostBasisEngine()
    engine.processBuy(instrument: bhp, quantity: 50, costPerUnit: 40, date: date(0))

    let events = engine.processSell(
      instrument: bhp, quantity: 100, proceedsPerUnit: 50, date: date(365)
    )

    #expect(events.count == 1)
    #expect(events[0].quantity == 50)
    #expect(engine.openLots(for: bhp).isEmpty)
  }

  // MARK: - Helpers

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument(
      id: "ASX:\(name)", kind: .stock, name: name, decimals: 0,
      ticker: "\(name).AX", exchange: "ASX", chainId: nil, contractAddress: nil)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let base = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2024, month: 1, day: 1))!
    return Calendar(identifier: .gregorian).date(byAdding: .day, value: daysFromBase, to: base)!
  }
}
