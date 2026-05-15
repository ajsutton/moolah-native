import Foundation
import GRDB

@testable import Moolah

// A BackendProvider that wires up GRDB-backed repositories on a single
// in-memory queue. Used by the `AnalysisRepository` contract tests.
//
// Visibility is internal (was fileprivate) so sibling test files across the
// split AnalysisRepository* test suites can use this helper — `strict_fileprivate`
// disallows fileprivate in this codebase.
struct CloudKitAnalysisTestBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let investments: any InvestmentRepository
  let conversionService: any InstrumentConversionService
  let csvImportProfiles: any CSVImportProfileRepository
  let importRules: any ImportRuleRepository
  let walletSyncState: any WalletSyncStateRepository

  /// The GRDB queue backing every repository — exposed so tests can seed
  /// rows alongside the standard repository APIs.
  let database: DatabaseQueue

  /// The shared profile-index instrument registry every repository
  /// resolves and registers through. Pointed at its own in-memory
  /// profile-index DB, never the per-profile `instrument` table the
  /// `v10_drop_shared_instrument_legacy` migration removes. Exposed so
  /// `fetchAggregationForTesting` resolves the exact instrument map the
  /// repositories built during seeding.
  let instrumentRegistry: GRDBInstrumentRegistryRepository

  /// Creates a backend wired to an in-memory GRDB queue.
  ///
  /// - Parameter customConversion: An optional conversion service override. When
  ///   `nil`, a default `FiatConversionService` backed by a throwaway in-memory
  ///   rate cache is created.
  ///
  /// Throws when the in-memory `DatabaseQueue` fails to construct.
  init(conversionService customConversion: (any InstrumentConversionService)? = nil) throws {
    let database = try ProfileDatabase.openInMemory()
    self.database = database
    let currency = Instrument.defaultTestInstrument
    let conversion: any InstrumentConversionService
    if let customConversion {
      conversion = customConversion
    } else {
      let rateClient = FixedRateClient()
      let exchangeRates = ExchangeRateService(
        client: rateClient, database: database)
      conversion = FiatConversionService(exchangeRates: exchangeRates)
    }
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    self.instrumentRegistry = registry
    let backend = CloudKitBackend(
      database: database,
      instrument: currency,
      profileLabel: "Test",
      conversionService: conversion,
      instrumentRegistry: registry
    )
    self.auth = backend.auth
    self.accounts = backend.accounts
    self.transactions = backend.transactions
    self.categories = backend.categories
    self.earmarks = backend.earmarks
    self.analysis = backend.analysis
    self.investments = backend.investments
    self.conversionService = backend.conversionService
    self.csvImportProfiles = backend.csvImportProfiles
    self.importRules = backend.importRules
    self.walletSyncState = backend.walletSyncState
  }
}

extension CloudKitAnalysisTestBackend {
  /// Test-only entry point that exposes `fetchDailyBalancesAggregation`
  /// for aggregation-layer integration tests. Production callers go
  /// through `analysis.fetchDailyBalances(...)`; this shim lets tests
  /// pin the aggregation contract without re-running the full
  /// per-day walk. Reads from the backend's already-public
  /// `DatabaseQueue` — no peek into `GRDBAnalysisRepository`'s
  /// private storage.
  func fetchAggregationForTesting(
    after: Date?, forecastUntil: Date?
  ) async throws -> GRDBAnalysisRepository.DailyBalancesAggregation {
    // Resolve the instrument map from the shared profile-index registry
    // the repositories registered into during seeding — the same
    // resolver the production aggregation path consults, never the
    // per-profile `instrument` table.
    let instruments = try await instrumentRegistry.instrumentMap()
    return try await GRDBAnalysisRepository.fetchDailyBalancesAggregation(
      database: self.database,
      instruments: instruments,
      after: after,
      forecastUntil: forecastUntil)
  }
}
