import Foundation
import OSLog
import Observation

/// Drives the Recently Added view. Thin wrapper around the transactions
/// repository that filters by `ImportOrigin.importedAt` within the chosen
/// window and groups by `importSessionId`.
@Observable
@MainActor
final class RecentlyAddedViewModel {

  enum Window: String, CaseIterable, Identifiable, Sendable {
    case last24Hours
    case last3Days
    case lastWeek
    case last2Weeks
    case lastMonth
    case all

    var id: String { rawValue }

    var label: String {
      switch self {
      case .last24Hours: return "Last 24 hours"
      case .last3Days: return "Last 3 days"
      case .lastWeek: return "Last week"
      case .last2Weeks: return "Last 2 weeks"
      case .lastMonth: return "Last month"
      case .all: return "All"
      }
    }

    func dateRange(now: Date = Date()) -> ClosedRange<Date>? {
      let day: TimeInterval = 86_400
      switch self {
      case .last24Hours: return (now.addingTimeInterval(-day))...now
      case .last3Days: return (now.addingTimeInterval(-3 * day))...now
      case .lastWeek: return (now.addingTimeInterval(-7 * day))...now
      case .last2Weeks: return (now.addingTimeInterval(-14 * day))...now
      case .lastMonth: return (now.addingTimeInterval(-30 * day))...now
      case .all: return nil
      }
    }
  }

  /// A group of transactions imported in the same session.
  struct SessionGroup: Identifiable, Sendable {
    let id: UUID
    let importedAt: Date
    let filenames: [String]
    let transactions: [Transaction]

    /// v1 proxy for "needs review": any transaction whose legs all lack a
    /// category. See the design doc.
    var needsReviewCount: Int {
      transactions.filter { tx in tx.legs.allSatisfy { $0.categoryId == nil } }.count
    }
  }

  private(set) var window: Window = .last24Hours
  private(set) var sessions: [SessionGroup] = []
  private(set) var badgeCount: Int = 0
  private(set) var isLoading = false

  private let backend: any BackendProvider
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "RecentlyAddedViewModel")

  init(backend: any BackendProvider) {
    self.backend = backend
  }

  func load(window: Window, now: Date = Date()) async {
    guard !isLoading else { return }
    self.window = window
    isLoading = true
    defer { isLoading = false }
    let pageSize = 500
    var all: [Transaction] = []
    do {
      var page = 0
      while true {
        let result = try await backend.transactions.fetch(
          filter: TransactionFilter(),
          page: page,
          pageSize: pageSize)
        if result.transactions.isEmpty { break }
        all.append(contentsOf: result.transactions)
        if result.transactions.count < pageSize { break }
        page += 1
        // Safety cap: don't fetch more than 5 pages to keep the view snappy
        // (2500 transactions max). Windowed recent views never need more.
        if page >= 5 { break }
      }
    } catch {
      logger.error("load failed: \(error.localizedDescription, privacy: .public)")
    }

    let filtered = Self.filter(all, window: window, now: now)
    sessions = Self.group(filtered)
    badgeCount =
      filtered.filter { tx in
        tx.legs.allSatisfy { $0.categoryId == nil }
      }.count
  }

  /// Exposed for tests and for the sidebar badge lookup — given a fully-fetched
  /// transaction list, return only those with an ImportOrigin within the
  /// window.
  static func filter(
    _ transactions: [Transaction],
    window: Window,
    now: Date = Date()
  ) -> [Transaction] {
    transactions.filter { tx in
      guard let origin = tx.importOrigin else { return false }
      if let range = window.dateRange(now: now) {
        return range.contains(origin.importedAt)
      }
      return true
    }
  }

  static func group(_ transactions: [Transaction]) -> [SessionGroup] {
    let dict = Dictionary(
      grouping: transactions,
      by: { $0.importOrigin?.importSessionId ?? UUID() })
    return dict.map { (id, txs) in
      let filenames = Array(
        Set(txs.compactMap { $0.importOrigin?.sourceFilename })
      ).sorted()
      let importedAt =
        txs.map { $0.importOrigin?.importedAt ?? .distantPast }.max()
        ?? .distantPast
      return SessionGroup(
        id: id,
        importedAt: importedAt,
        filenames: filenames,
        transactions: txs.sorted { $0.date > $1.date })
    }.sorted { $0.importedAt > $1.importedAt }
  }
}
