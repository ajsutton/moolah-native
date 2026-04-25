import Foundation
import OSLog

@MainActor
@Observable
final class InstrumentPickerStore {
  private(set) var query: String = ""
  private(set) var results: [InstrumentSearchResult] = []
  private(set) var isLoading: Bool = false
  private(set) var error: String?

  let kinds: Set<Instrument.Kind>

  private let searchService: InstrumentSearchService
  private let registry: any InstrumentRegistryRepository
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "InstrumentPickerStore")
  private var searchTask: Task<Void, Never>?

  init(
    searchService: InstrumentSearchService,
    registry: any InstrumentRegistryRepository,
    kinds: Set<Instrument.Kind>
  ) {
    self.searchService = searchService
    self.registry = registry
    self.kinds = kinds
  }

  func start() async {
    await runSearch()
  }

  func updateQuery(_ newQuery: String) {
    query = newQuery
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      if Task.isCancelled { return }
      await self?.runSearch()
    }
  }

  func select(_ result: InstrumentSearchResult) async -> Instrument? {
    if result.isRegistered { return result.instrument }
    do {
      try await registry.registerStock(result.instrument)
      return result.instrument
    } catch {
      logger.error(
        "Stock registration failed: \(error, privacy: .public)")
      self.error = "Couldn't add \(result.instrument.displayLabel)."
      return nil
    }
  }

  private func runSearch() async {
    isLoading = true
    defer { isLoading = false }
    let snapshot = await searchService.search(
      query: query,
      kinds: kinds,
      providerSources: .stocksOnly
    )
    results = snapshot
  }
}
