import Foundation
import Testing

@testable import Moolah

@Suite("HTTPRetryPolicy")
struct HTTPRetryPolicyTests {
  @Test
  func defaultsMatchApprovedDesign() {
    let policy = HTTPRetryPolicy()
    #expect(policy.requestTimeout == 120)
    #expect(policy.maxAttempts == 3)
    #expect(policy.backoffBase == 0.5)
    #expect(policy.backoffCap == 5)
    #expect(policy.totalBudget == 300)
    #expect(policy.honorsRetryAfterInPlace == false)
    #expect(policy.maxRateLimitWait == 60)
  }

  @Test
  func perClientOverridesAreIndependent() {
    let blockscout = HTTPRetryPolicy(honorsRetryAfterInPlace: true)
    #expect(blockscout.honorsRetryAfterInPlace == true)
    #expect(blockscout.requestTimeout == 120)
    #expect(HTTPRetryPolicy().honorsRetryAfterInPlace == false)
  }

  @Test
  func backoffIsExponentialJitteredAndCapped() {
    let policy = HTTPRetryPolicy()
    #expect(policy.backoffCeiling(forAttempt: 1) == 0.5)
    #expect(policy.backoffCeiling(forAttempt: 2) == 1.0)
    #expect(policy.backoffCeiling(forAttempt: 3) == 2.0)
    #expect(policy.backoffCeiling(forAttempt: 10) == 5.0)
  }
}
