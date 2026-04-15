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

  /// Re-fetches categories without showing loading state or clearing errors.
  /// Used when CloudKit delivers remote changes — avoids UI flicker.
  func reloadFromSync() async {
    let start = ContinuousClock.now
    do {
      let freshList = try await repository.fetchAll()
      let fetchMs = (ContinuousClock.now - start).inMilliseconds
      let fresh = Categories(from: freshList)
      let freshCategories = fresh.flattenedByPath().map(\.category)
      let currentCategories = categories.flattenedByPath().map(\.category)
      if freshCategories != currentCategories {
        categories = fresh
        logger.debug("Sync: updated categories")
      }
      let totalMs = (ContinuousClock.now - start).inMilliseconds
      if totalMs > 16 {
        logger.warning(
          "⚠️ PERF: categoryStore.reloadFromSync took \(totalMs)ms (fetch: \(fetchMs)ms, diff+assign: \(totalMs - fetchMs)ms)"
        )
      }
    } catch {
      logger.error("Sync reload failed: \(error.localizedDescription)")
    }
  }

  func create(_ category: Category) async -> Category? {
    logger.debug("Creating category: \(category.name)")
    error = nil

    do {
      let created = try await repository.create(category)
      // Reload to get fresh state
      await load()
      return created
    } catch {
      logger.error("❌ Failed to create category: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }

  func update(_ category: Category) async -> Category? {
    logger.debug("Updating category: \(category.name)")
    error = nil

    do {
      let updated = try await repository.update(category)
      // Reload to get fresh state
      await load()
      return updated
    } catch {
      logger.error("❌ Failed to update category: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async -> Bool {
    logger.debug("Deleting category \(id)")
    error = nil

    do {
      try await repository.delete(id: id, withReplacement: replacementId)
      // Reload to get fresh state
      await load()
      return true
    } catch {
      logger.error("❌ Failed to delete category: \(error.localizedDescription)")
      self.error = error
      return false
    }
  }
}
