import Foundation
import Testing

@testable import Moolah

@Suite("PositionsSortState")
struct PositionsSortStateTests {

  // MARK: - State machine

  @Test("Tapping an inactive column activates it in descending order")
  func inactiveColumnActivatesDescending() {
    var state = PositionsSortState(column: .value, direction: .descending)
    state.toggleSort(.instrument)
    #expect(state.column == .instrument)
    #expect(state.direction == .descending)
  }

  @Test("Tapping the active column flips the direction")
  func activeColumnFlipsDirection() {
    var state = PositionsSortState(column: .value, direction: .descending)
    state.toggleSort(.value)
    #expect(state.column == .value)
    #expect(state.direction == .ascending)
    state.toggleSort(.value)
    #expect(state.direction == .descending)
  }

  @Test("Sort never reaches a no-sort state — there is always an active column")
  func sortNeverResetsToNoSort() {
    var state = PositionsSortState(column: .value, direction: .descending)
    for _ in 0..<10 {
      state.toggleSort(.value)
      #expect(state.column == .value)
    }
  }

  // MARK: - Sorting (same column set as production Table today)

  @Test("Sorting by value descending puts the largest value first")
  func sortByValueDescending() {
    let rows = Self.mixedRows()
    let state = PositionsSortState(column: .value, direction: .descending)
    let sorted = state.sorted(rows)
    // Values: BHP 11_325 > ETH 9_800 > CBA 9_600 > AUD 2_480 (raw quantity, native instrument).
    // Instrument.id shapes: stocks = "exchange:ticker"; native crypto = "chainId:native".
    #expect(sorted.map(\.instrument.id) == ["ASX:BHP.AX", "1:native", "ASX:CBA.AX", "AUD"])
  }

  @Test("Sorting by instrument ascending orders by name lexicographically")
  func sortByInstrumentAscending() {
    let rows = Self.mixedRows()
    let state = PositionsSortState(column: .instrument, direction: .ascending)
    let sorted = state.sorted(rows)
    #expect(sorted.first?.instrument.name == "AUD")
    #expect(sorted.last?.instrument.name == "Ethereum")
  }

  @Test("Sorting by quantity descending orders by raw quantity")
  func sortByQuantityDescending() {
    let rows = Self.mixedRows()
    let state = PositionsSortState(column: .quantity, direction: .descending)
    let sorted = state.sorted(rows)
    #expect(sorted.first?.quantity == 2_480)  // AUD cash
  }

  @Test("Sorting by gain descending orders non-nil gains by value")
  func sortByGainDescendingOrdersNonNilGainsDescendingByValue() {
    let rows = Self.mixedRows()
    let state = PositionsSortState(column: .gain, direction: .descending)
    let sorted = state.sorted(rows)
    // BHP gain +1_200, CBA +600, ETH +2_300, AUD has no gain.
    let withGains = sorted.prefix(while: { $0.gainLoss != nil }).map(\.instrument.id)
    #expect(withGains == ["1:native", "ASX:BHP.AX", "ASX:CBA.AX"])
  }

  @Test("Sorting by gain sinks rows with no gain to the end regardless of direction")
  func sortByGainSinksNilGainsToEndRegardlessOfDirection() {
    let rows = Self.mixedRows()
    for direction in [PositionsSortDirection.descending, .ascending] {
      let state = PositionsSortState(column: .gain, direction: direction)
      let sorted = state.sorted(rows)
      // AUD has no gainLoss (no cost basis) and must always be last.
      #expect(sorted.last?.instrument.id == "AUD")
    }
  }

  @Test("Equal sort keys tiebreak on instrument.id regardless of direction")
  func equalSortKeysTiebreakOnInstrumentIdRegardlessOfDirection() {
    let aud = Instrument.AUD
    let alpha = Instrument.stock(ticker: "AAA.AX", exchange: "ASX", name: "Alpha")
    let bravo = Instrument.stock(ticker: "BBB.AX", exchange: "ASX", name: "Bravo")
    // Two rows with identical `value` quantity but different instrument ids.
    let rows = [
      ValuedPosition(
        instrument: bravo, quantity: 10,
        unitPrice: InstrumentAmount(quantity: 100, instrument: aud),
        costBasis: InstrumentAmount(quantity: 800, instrument: aud),
        value: InstrumentAmount(quantity: 1_000, instrument: aud)),
      ValuedPosition(
        instrument: alpha, quantity: 5,
        unitPrice: InstrumentAmount(quantity: 200, instrument: aud),
        costBasis: InstrumentAmount(quantity: 900, instrument: aud),
        value: InstrumentAmount(quantity: 1_000, instrument: aud)),
    ]
    // Instrument ids: "ASX:AAA.AX" < "ASX:BBB.AX".
    for direction in [PositionsSortDirection.descending, .ascending] {
      let state = PositionsSortState(column: .value, direction: direction)
      let sorted = state.sorted(rows)
      #expect(sorted.map(\.instrument.id) == ["ASX:AAA.AX", "ASX:BBB.AX"])
    }
  }

  // MARK: - Fixtures

  /// Mixed-instrument fixture matching `PositionsTable.swift`'s
  /// `mixedPositionsInput()` preview so sort assertions reflect the
  /// production preview shape.
  private static func mixedRows() -> [ValuedPosition] {
    let aud = Instrument.AUD
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    return [
      ValuedPosition(
        instrument: bhp, quantity: 250,
        unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
        costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
        value: InstrumentAmount(quantity: 11_325, instrument: aud)),
      ValuedPosition(
        instrument: cba, quantity: 80,
        unitPrice: InstrumentAmount(quantity: 120, instrument: aud),
        costBasis: InstrumentAmount(quantity: 9_000, instrument: aud),
        value: InstrumentAmount(quantity: 9_600, instrument: aud)),
      ValuedPosition(
        instrument: eth, quantity: 2.45,
        unitPrice: InstrumentAmount(quantity: 4_000, instrument: aud),
        costBasis: InstrumentAmount(quantity: 7_500, instrument: aud),
        value: InstrumentAmount(quantity: 9_800, instrument: aud)),
      ValuedPosition(
        instrument: aud, quantity: 2_480,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 2_480, instrument: aud)),
    ]
  }
}
