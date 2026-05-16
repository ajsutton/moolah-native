import Foundation
import Testing

@testable import Moolah

@Suite("SortedDateSeries")
struct SortedDateSeriesTests {
  @Test("exact returns the value only for an exact key match")
  func exact() {
    var s = SortedDateSeries<Int>()
    s.upsert(20_240_101, 1)
    s.upsert(20_240_103, 3)
    #expect(s.exact(20_240_101) == 1)
    #expect(s.exact(20_240_103) == 3)
    #expect(s.exact(20_240_102) == nil)
  }

  @Test("floor returns the newest entry on or before the key")
  func floor() {
    var s = SortedDateSeries<Int>()
    s.upsert(20_240_101, 1)
    s.upsert(20_240_105, 5)
    s.upsert(20_240_110, 10)
    #expect(s.floor(20_240_100) == nil)  // before first
    #expect(s.floor(20_240_101) == 1)  // exact
    #expect(s.floor(20_240_107) == 5)  // gap → prior
    #expect(s.floor(20_240_999) == 10)  // after last → last
  }

  @Test("upsert keeps entries sorted and replaces duplicates")
  func upsertReplaces() {
    var s = SortedDateSeries<Int>()
    s.upsert(20_240_103, 3)
    s.upsert(20_240_101, 1)
    s.upsert(20_240_103, 33)  // replace
    #expect(s.sortedKeys == [20_240_101, 20_240_103])
    #expect(s.exact(20_240_103) == 33)
  }

  @Test("init(unsorted:) sorts and de-duplicates last-wins")
  func initUnsorted() {
    let s = SortedDateSeries<Int>(unsorted: [
      (20_240_103, 3), (20_240_101, 1), (20_240_103, 33),
    ])
    #expect(s.sortedKeys == [20_240_101, 20_240_103])
    #expect(s.exact(20_240_103) == 33)
  }

  @Test("first/last/isEmpty")
  func bounds() {
    var s = SortedDateSeries<Int>()
    #expect(s.isEmpty)
    s.upsert(20_240_105, 5)
    s.upsert(20_240_101, 1)
    #expect(s.first?.key == 20_240_101)
    #expect(s.last?.key == 20_240_105)
    #expect(!s.isEmpty)
  }

  @Test("plan-pin: floor does not scan linearly")
  func floorIsLogarithmic() {
    var s = SortedDateSeries<Int>()
    for d in 0..<4_000 { s.upsert(Int32(20_000_000 + d), d) }
    SortedDateSeries<Int>.probeCount = 0
    // 1,000 mixed queries (gaps + exacts) over a 4,000-entry series.
    for q in 0..<1_000 { _ = s.floor(Int32(20_000_000 + q * 4)) }
    // Linear-scan-after-sort would be >> 1_000 * 4_000 probes. A binary
    // search is ~1_000 * ceil(log2(4_000)) ≈ 12_000. Cap generously.
    #expect(SortedDateSeries<Int>.probeCount < 40_000)
  }

  @Test("Codable round-trips")
  func codable() throws {
    var s = SortedDateSeries<Int>()
    s.upsert(20_240_101, 1)
    s.upsert(20_240_103, 3)
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(SortedDateSeries<Int>.self, from: data)
    #expect(back == s)
  }
}
