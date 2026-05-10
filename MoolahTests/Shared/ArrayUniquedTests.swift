import Foundation
import Testing

@testable import Moolah

@Suite("Array.uniqued()")
struct ArrayUniquedTests {
  @Test("removes duplicates while preserving order")
  func preservesOrder() {
    #expect([1, 2, 2, 3, 1, 4].uniqued() == [1, 2, 3, 4])
  }

  @Test("empty array stays empty")
  func emptyStaysEmpty() {
    #expect([Int]().uniqued().isEmpty)
  }

  @Test("no duplicates is a no-op (modulo equality)")
  func noDuplicatesIsNoOp() {
    let input = ["a", "b", "c"]
    #expect(input.uniqued() == input)
  }
}
