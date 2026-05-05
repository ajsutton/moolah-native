// MoolahTests/Backends/GRDB/PricingStatusMergeRuleTests.swift
import Foundation
import Testing

@testable import Moolah

/// Pure-function tests for `PricingStatusMerge.merge(local:incoming:)`.
/// Covers every cell of the 3x3 truth table from the design's "Cross-device
/// conflict resolution" section.
@Suite("PricingStatusMerge.merge — full truth table")
struct PricingStatusMergeRuleTests {
  // MARK: - Local .spam wins over any incoming

  @Test
  func localSpamBeatsIncomingPriced() {
    #expect(
      PricingStatusMerge.merge(local: .spam, incoming: .priced) == .spam)
  }

  @Test
  func localSpamBeatsIncomingUnpriced() {
    #expect(
      PricingStatusMerge.merge(local: .spam, incoming: .unpriced) == .spam)
  }

  @Test
  func localSpamMatchesIncomingSpam() {
    #expect(
      PricingStatusMerge.merge(local: .spam, incoming: .spam) == .spam)
  }

  // MARK: - Incoming .spam wins over any non-spam local

  @Test
  func incomingSpamBeatsLocalPriced() {
    #expect(
      PricingStatusMerge.merge(local: .priced, incoming: .spam) == .spam)
  }

  @Test
  func incomingSpamBeatsLocalUnpriced() {
    #expect(
      PricingStatusMerge.merge(local: .unpriced, incoming: .spam) == .spam)
  }

  // MARK: - .priced beats .unpriced either direction (resolution sticks)

  @Test
  func localPricedBeatsIncomingUnpriced() {
    #expect(
      PricingStatusMerge.merge(local: .priced, incoming: .unpriced) == .priced)
  }

  @Test
  func incomingPricedBeatsLocalUnpriced() {
    #expect(
      PricingStatusMerge.merge(local: .unpriced, incoming: .priced) == .priced)
  }

  // MARK: - Same-on-both-sides → unchanged

  @Test
  func bothPricedReturnsPriced() {
    #expect(
      PricingStatusMerge.merge(local: .priced, incoming: .priced) == .priced)
  }

  @Test
  func bothUnpricedReturnsUnpriced() {
    #expect(
      PricingStatusMerge.merge(local: .unpriced, incoming: .unpriced) == .unpriced)
  }
}
