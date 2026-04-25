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
