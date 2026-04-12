import Foundation
import Testing

@testable import Moolah

@Suite("Net Worth Benchmark")
struct NetWorthBenchmarkTests {

  @Test func measurePositionAccumulation_20Years_10Instruments() {
    let instruments: [String] = (0..<10).map { "INST\($0)" }
    let days = 7300

    let start = ContinuousClock.now
    var positions: [String: Decimal] = [:]
    for d in 0..<days {
      if d % 7 == 0 {
        for inst in instruments {
          positions[inst, default: 0] += Decimal(Int.random(in: 1...100))
        }
      }
    }
    let elapsed = ContinuousClock.now - start

    // Position accumulation should be < 500ms for 10K+ legs
    #expect(elapsed < .milliseconds(500), "Position accumulation took \(elapsed)")
    #expect(!positions.isEmpty)
  }

  @Test func measureDailyConversion_5Years_5Instruments() {
    let days = 1825
    let instrumentCount = 5
    let calendar = Calendar(identifier: .gregorian)
    let startDate = calendar.date(byAdding: .day, value: -days, to: Date())!

    // Pre-build price maps (simulating what batch fetch would produce)
    var priceMaps: [String: [String: Decimal]] = [:]
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]

    for i in 0..<instrumentCount {
      let id = "INST\(i)"
      var prices: [String: Decimal] = [:]
      for d in 0..<days {
        let date = calendar.date(byAdding: .day, value: d, to: startDate)!
        let dateStr = formatter.string(from: date)
        prices[dateStr] = Decimal(Double.random(in: 10...1000))
      }
      priceMaps[id] = prices
    }

    // Simulate daily conversion
    let start = ContinuousClock.now
    var dailyNetWorth: [(date: Date, value: Decimal)] = []
    var positions: [String: Decimal] = [:]

    for d in 0..<days {
      let date = calendar.date(byAdding: .day, value: d, to: startDate)!
      let dateStr = formatter.string(from: date)

      if d % 7 == 0 {
        for i in 0..<instrumentCount {
          positions["INST\(i)", default: 0] += Decimal(10)
        }
      }

      var total: Decimal = 0
      for (instrumentId, qty) in positions {
        if let price = priceMaps[instrumentId]?[dateStr] {
          total += qty * price
        }
      }
      dailyNetWorth.append((date, total))
    }
    let elapsed = ContinuousClock.now - start

    // Full daily conversion over 5 years should be well under 2 seconds in-memory
    #expect(elapsed < .seconds(2), "Daily conversion took \(elapsed)")
    #expect(dailyNetWorth.count == days)
  }
}
