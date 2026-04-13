import XCTest

@testable import Moolah

final class BenchmarkSmokeTest: XCTestCase {
  func testBenchmarkTargetBuildsAndRuns() {
    // Verify the benchmark target links correctly against Moolah
    let container = try! TestModelContainer.create()
    XCTAssertNotNil(container)
  }
}
