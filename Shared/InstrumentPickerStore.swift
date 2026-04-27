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

  private let searchService: InstrumentSearchService?
  private let registry: (any InstrumentRegistryRepository)?
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "InstrumentPickerStore")
  private var searchTask: Task<Void, Never>?

  init(
    searchService: InstrumentSearchService? = nil,
    registry: (any InstrumentRegistryRepository)? = nil,
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
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        return
      }
      await self?.runSearch()
    }
  }

  /// Awaits the in-flight debounced search, if one is scheduled. Returns
  /// immediately when no search is pending. Tests use this instead of a
  /// time-based sleep so they don't race the debounce on slow CI runners.
  func waitForPendingSearch() async {
    guard let task = searchTask else { return }
    await task.value
  }

  func select(_ result: InstrumentSearchResult) async -> Instrument? {
    if result.isRegistered { return result.instrument }
    guard let registry else {
      // No registry: only fiat is reachable in this mode, and fiat is
      // always pre-registered, so this branch shouldn't fire — but if it
      // does, return the instrument as-is rather than silently failing.
      return result.instrument
    }
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
    if let searchService {
      let snapshot = await searchService.search(
        query: query,
        kinds: kinds,
        providerSources: .stocksOnly
      )
      results = snapshot
      return
    }
    results = staticFiatResults(for: query)
  }

  private func staticFiatResults(for query: String) -> [InstrumentSearchResult] {
    guard kinds.contains(.fiatCurrency) else { return [] }
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    return Instrument.commonFiatCodes
      .filter { code in
        trimmed.isEmpty
          || code.lowercased().contains(trimmed)
          || Instrument.localizedName(for: code).localizedCaseInsensitiveContains(trimmed)
      }
      .map { code in
        InstrumentSearchResult(
          instrument: Instrument.fiat(code: code),
          cryptoMapping: nil,
          isRegistered: true,
          requiresResolution: false
        )
      }
  }
}

extension InstrumentPickerStore {
  /// Empty-state description for the picker, phrased to the kinds the picker
  /// is filtering on (so a fiat-only picker doesn't tell the user about
  /// stocks or tokens). Surfaced by `InstrumentPickerSheet.listContent`.
  var noMatchesDescription: String {
    var parts: [String] = []
    if kinds.contains(.fiatCurrency) { parts.append("currencies") }
    if kinds.contains(.stock) { parts.append("stocks") }
    if kinds.contains(.cryptoToken) { parts.append("registered tokens") }
    let kindsLabel = parts.formatted(.list(type: .or))
    return "No matching \(kindsLabel) for \"\(query)\"."
  }
}
