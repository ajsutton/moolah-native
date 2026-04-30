import Foundation
import Testing

@testable import Moolah

@Suite("IRRSolver")
struct IRRSolverTests {
  /// Single $1,000 deposit one year ago, terminal value $1,100 →
  /// effective annual return ≈ 10%.
  @Test("single deposit grown 10 percent over a year converges on 10 percent")
  func singleDepositTenPercent() throws {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(365 * 86_400)
    let result = IRRSolver.annualisedReturn(
      flows: [CashFlow(date: start, amount: 1_000)],
      terminalValue: 1_100,
      terminalDate: end
    )
    let value = try #require(result)
    let asDouble = (value as NSDecimalNumber).doubleValue
    #expect(abs(asDouble - 0.10) < 0.001, "expected ~0.10 (10% p.a.), got \(asDouble)")
  }
}
