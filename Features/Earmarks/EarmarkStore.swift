import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class EarmarkStore {
  private(set) var earmarks: Earmarks = Earmarks(from: [])
  private(set) var isLoading = false
  private(set) var error: Error?

  private let repository: EarmarkRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "EarmarkStore")

  init(repository: EarmarkRepository) {
    self.repository = repository
  }

  func load() async {
    guard !isLoading else { return }

    logger.debug("Loading earmarks...")
    isLoading = true
    error = nil

    do {
      earmarks = Earmarks(from: try await repository.fetchAll())
      logger.debug("Loaded \(self.earmarks.count) earmarks")
    } catch {
      logger.error("Failed to load earmarks: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }

  var visibleEarmarks: [Earmark] {
    earmarks.filter { !$0.isHidden }
  }

  var totalBalance: MonetaryAmount {
    visibleEarmarks.reduce(.zero) { $0 + $1.balance }
  }
}
