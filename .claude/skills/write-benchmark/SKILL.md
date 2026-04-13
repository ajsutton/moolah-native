---
name: write-benchmark
description: Use when adding a new performance benchmark test to MoolahBenchmarks. Guides data seeding, measurement patterns, signpost instrumentation, and naming.
---

# Writing a Benchmark

Follow this checklist when adding a new benchmark. Read `guides/BENCHMARKING_GUIDE.md` for the full rationale behind each rule.

## Before Writing

1. **Identify the operation to benchmark.** What specific code path are you measuring? Name the method and the file.
2. **Check if a benchmark already exists.** Search `MoolahBenchmarks/` for the operation name. If one exists, add a new test method to the existing class rather than creating a new file.
3. **Decide on scale tiers.** Most benchmarks should run at both 1x and 2x data scale. If the operation doesn't scale with dataset size (e.g., single-record insert), one tier is enough.

## Writing the Benchmark

### File & Class

- One benchmark class per operation group (fetch, sync batch, balance, etc.)
- File goes in `MoolahBenchmarks/`
- Class name: `<OperationGroup>Benchmarks` (e.g., `TransactionFetchBenchmarks`)
- Import `XCTest` and `@testable import Moolah`

### Data Seeding

- Use `BenchmarkFixtures` methods to seed data in `setUpWithError()`
- Seed once per class, not per test
- Use the predefined fixture data — it has realistic distributions matching the live iCloud profile
- Set `backend = nil` and `container = nil` in `tearDownWithError()` to release memory

### Test Method

- **Name:** `test<Operation>_<Variant>_<Scale>` (e.g., `testFetchByAccount_1x`)
- **Metrics:** Always use `[XCTClockMetric(), XCTMemoryMetric()]`
- **Iterations:** Always set `options.iterationCount = 10`
- **Context reset:** Call `container.mainContext.reset()` at the start of the measure block for fetch benchmarks
- **Async bridging:** Use `awaitSync` helper for async repository methods
- **Dead-code prevention:** Assign results to `_` or access `.count`
- **Autoreleasepool:** Wrap tight conversion loops in `autoreleasepool {}`

### Template

```swift
func testOperationName_1x() {
  let options = XCTMeasureOptions()
  options.iterationCount = 10

  measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
    container.mainContext.reset()
    _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
  }
}
```

## Adding Signposts to Production Code

If the operation you're benchmarking doesn't already have signpost instrumentation:

1. **Add a coarse signpost** (begin/end pair) around the public method entry point
2. **Use `Signposts.repository`** for repository methods, **`Signposts.sync`** for sync operations, **`Signposts.balance`** for balance computation
3. **Include metadata** (record counts, batch sizes) for variable-size operations
4. **Add fine-grained signposts** inside the method only if benchmarks show it's a hot path — don't speculate

```swift
let signpostID = OSSignpostID(log: Signposts.repository)
os_signpost(.begin, log: Signposts.repository, name: "MethodName", signpostID: signpostID)
defer { os_signpost(.end, log: Signposts.repository, name: "MethodName", signpostID: signpostID) }
```

## After Writing

1. **Run the benchmark** with `just benchmark <ClassName>` and verify it completes without errors
2. **Check stddev** — if relative standard deviation exceeds 20%, the benchmark is too noisy. Investigate: are you measuring non-deterministic work? Is setup leaking into the measure block?
3. **Run at both scales** and compare. Document any unexpected scaling behavior in a code comment.
4. **Set a baseline** in Xcode after the first clean run
