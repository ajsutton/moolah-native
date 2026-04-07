import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class CategoryStore {
  private(set) var categories: Categories = Categories(from: [])
  private(set) var isLoading = false
  private(set) var error: Error?

  private let repository: CategoryRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "CategoryStore")

  init(repository: CategoryRepository) {
    self.repository = repository
  }

  func load() async {
    guard !isLoading else { return }

    logger.debug("Loading categories...")
    isLoading = true
    error = nil

    do {
      categories = Categories(from: try await repository.fetchAll())
      logger.debug("Loaded categories")
    } catch {
      logger.error("❌ Failed to load categories: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }
}
