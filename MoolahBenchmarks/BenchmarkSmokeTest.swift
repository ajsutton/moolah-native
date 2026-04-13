import SwiftData
import XCTest

@testable import Moolah

final class BenchmarkSmokeTest: XCTestCase {
  func testBenchmarkTargetBuildsAndRuns() {
    // Verify the benchmark target links correctly against Moolah
    let container = try! TestModelContainer.create()
    XCTAssertNotNil(container)
  }

  @MainActor
  func testFixtureSeedingProducesExpectedCounts_1x() throws {
    let result = try TestBackend.create()
    let context = result.container.mainContext
    BenchmarkFixtures.seed(scale: .x1, in: result.container)

    let txnCount = try context.fetchCount(FetchDescriptor<TransactionRecord>())
    let accountCount = try context.fetchCount(FetchDescriptor<AccountRecord>())
    let categoryCount = try context.fetchCount(FetchDescriptor<CategoryRecord>())
    let earmarkCount = try context.fetchCount(FetchDescriptor<EarmarkRecord>())
    let investmentCount = try context.fetchCount(FetchDescriptor<InvestmentValueRecord>())

    XCTAssertEqual(txnCount, 18_662)
    XCTAssertEqual(accountCount, 31)
    XCTAssertEqual(categoryCount, 158)
    XCTAssertEqual(earmarkCount, 21)
    XCTAssertEqual(investmentCount, 2_711)
  }

  @MainActor
  func testFixtureSeedingProducesExpectedCounts_2x() throws {
    let result = try TestBackend.create()
    let context = result.container.mainContext
    BenchmarkFixtures.seed(scale: .x2, in: result.container)

    let txnCount = try context.fetchCount(FetchDescriptor<TransactionRecord>())
    let accountCount = try context.fetchCount(FetchDescriptor<AccountRecord>())
    let categoryCount = try context.fetchCount(FetchDescriptor<CategoryRecord>())
    let earmarkCount = try context.fetchCount(FetchDescriptor<EarmarkRecord>())
    let investmentCount = try context.fetchCount(FetchDescriptor<InvestmentValueRecord>())

    XCTAssertEqual(txnCount, 37_324)
    XCTAssertEqual(accountCount, 62)
    XCTAssertEqual(categoryCount, 316)
    XCTAssertEqual(earmarkCount, 42)
    XCTAssertEqual(investmentCount, 5_422)
  }
}
