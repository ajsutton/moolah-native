// MoolahTests/Backends/GRDB/PricingStatusMergeRuleTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("GRDBInstrumentRegistryRepository pricingStatus merge rule")
struct PricingStatusMergeRuleTests {
  private let priced = TokenPricingStatus.priced.rawValue
  private let unpriced = TokenPricingStatus.unpriced.rawValue
  private let spam = TokenPricingStatus.spam.rawValue

  @Test
  func localSpamSurvivesAnyIncoming() {
    #expect(
      GRDBInstrumentRegistryRepository.mergedPricingStatus(
        local: spam, incoming: priced) == spam)
    #expect(
      GRDBInstrumentRegistryRepository.mergedPricingStatus(
        local: spam, incoming: unpriced) == spam)
    #expect(
      GRDBInstrumentRegistryRepository.mergedPricingStatus(
        local: spam, incoming: spam) == spam)
  }

  @Test
  func incomingSpamWinsOverNonSpamLocal() {
    #expect(
      GRDBInstrumentRegistryRepository.mergedPricingStatus(
        local: priced, incoming: spam) == spam)
    #expect(
      GRDBInstrumentRegistryRepository.mergedPricingStatus(
        local: unpriced, incoming: spam) == spam)
  }

  @Test
  func pricedWinsOverUnpricedEitherDirection() {
    #expect(
      GRDBInstrumentRegistryRepository.mergedPricingStatus(
        local: priced, incoming: unpriced) == priced)
    #expect(
      GRDBInstrumentRegistryRepository.mergedPricingStatus(
        local: unpriced, incoming: priced) == priced)
  }

  @Test
  func identicalStatusesAreUnchanged() {
    #expect(
      GRDBInstrumentRegistryRepository.mergedPricingStatus(
        local: priced, incoming: priced) == priced)
    #expect(
      GRDBInstrumentRegistryRepository.mergedPricingStatus(
        local: unpriced, incoming: unpriced) == unpriced)
  }
}
