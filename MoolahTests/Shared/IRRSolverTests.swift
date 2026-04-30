import Foundation
import Testing

@testable import Moolah

@Suite("IRRSolver")
struct IRRSolverTests {
  /// Single $1,000 deposit one year ago, terminal value $1,100 →
  /// effective annual return ≈ 10%.
  @Test("single deposit grown 10 percent over a year converges on 10 percent")
  func singleDepositTenPercent() throws {
    // Fixed reference date — any stable Date works; the IRR result is independent of the absolute date.
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(365 * 86_400)
    let result = IRRSolver.annualisedReturn(
      flows: [CashFlow(date: start, amount: 1_000)],
      terminalValue: 1_100,
      terminalDate: end
    )
    let value = try #require(result)
    let asDouble = Double(truncating: value as NSDecimalNumber)
    #expect(asDouble > 0, "rate must be positive for a gain")
    #expect(abs(asDouble - 0.10) < 0.001, "expected ~0.10 (10% p.a.), got \(asDouble)")
  }

  /// Deposit $1,000, value unchanged a year later → 0% p.a.
  @Test("zero growth returns approximately zero")
  func zeroGrowth() throws {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(365 * 86_400)
    let result = IRRSolver.annualisedReturn(
      flows: [CashFlow(date: start, amount: 1_000)],
      terminalValue: 1_000,
      terminalDate: end
    )
    let value = try #require(result)
    let asDouble = Double(truncating: value as NSDecimalNumber)
    #expect(abs(asDouble) < 0.001, "expected ~0, got \(asDouble)")
  }

  /// $100 deposit, $90 a year later → ≈ −10% p.a.
  @Test("negative return converges below zero")
  func negativeReturn() throws {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(365 * 86_400)
    let result = IRRSolver.annualisedReturn(
      flows: [CashFlow(date: start, amount: 100)],
      terminalValue: 90,
      terminalDate: end
    )
    let value = try #require(result)
    let asDouble = Double(truncating: value as NSDecimalNumber)
    #expect(abs(asDouble - (-0.10)) < 0.001, "expected ~-0.10, got \(asDouble)")
  }

  /// Two equal deposits 6 months apart, terminal value 10% above contributions
  /// → IRR > 10% (deposits weren't all in for the full year).
  @Test("multiple deposits converges higher than naive ROI")
  func multiDeposit() throws {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let mid = start.addingTimeInterval(182 * 86_400)
    let end = start.addingTimeInterval(365 * 86_400)
    let result = IRRSolver.annualisedReturn(
      flows: [
        CashFlow(date: start, amount: 500),
        CashFlow(date: mid, amount: 500),
      ],
      terminalValue: 1_100,
      terminalDate: end
    )
    let value = try #require(result)
    let asDouble = Double(truncating: value as NSDecimalNumber)
    #expect(asDouble > 0.12, "expected IRR ~13.5%, got \(asDouble)")
    #expect(asDouble < 0.16, "expected IRR ~13.5%, got \(asDouble)")
  }

  @Test("empty flows returns nil")
  func emptyFlows() {
    let anyDate = Date(timeIntervalSinceReferenceDate: 0)
    #expect(IRRSolver.annualisedReturn(flows: [], terminalValue: 100, terminalDate: anyDate) == nil)
  }

  @Test("span under one day returns nil")
  func subDaySpan() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = start.addingTimeInterval(60 * 60)  // one hour
    let result = IRRSolver.annualisedReturn(
      flows: [CashFlow(date: start, amount: 1_000)],
      terminalValue: 1_010,
      terminalDate: end
    )
    #expect(result == nil)
  }
}
