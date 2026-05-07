import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class CategoryStore {
  private(set) var categories = Categories(from: [])
  private(set) var error: Error?

  private let repository: CategoryRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "CategoryStore")

  /// The single observation `Task` that runs the `withTaskGroup` of
  /// child tasks subscribing to `repository.observeAll()` and
  /// `repository.observeErrors()`. Spawned from `init`, torn down by
  /// `stopObserving()` (called from `ProfileSession.cleanupSync`) or by
  /// `deinit` as a safety net. Categories carry no converted balances,
  /// so the group only has the two repository streams — there is no
  /// conversion-service subscription as in `AccountStore` /
  /// `EarmarkStore`.
  private var observationTask: Task<Void, Never>?

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in `apply(categories:)`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  init(repository: CategoryRepository) {
    self.repository = repository
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation

    // Strong `self` capture is intentional: the store is `@MainActor`,
    // the task already holds an implicit strong reference, and
    // `stopObserving()` (called from `cleanupSync`) is the sole lifetime
    // gate. A weak capture would just add a nil-check hazard without
    // preventing the retain — and `guard let self else { return }` would
    // mask cancellation-propagation bugs by silently exiting.
    observationTask = Task { await self.observe() }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed (e.g. an
    // early-error tear-down path that drops the ProfileSession without
    // calling cleanupSync). Cancels the strongly-held observation Task
    // so it does not retain `self` and a stale GRDB connection forever.
    // Under normal lifecycle, `stopObserving()` runs first via
    // `cleanupSync` and this is a no-op. Swift 6 makes `deinit`
    // nonisolated; reading `@MainActor`-isolated state requires
    // `MainActor.assumeIsolated`. The store is owned by main-actor
    // code (`ProfileSession`), so the assumption holds in practice.
    MainActor.assumeIsolated {
      observationTask?.cancel()
      testObservationTickContinuation.finish()
    }
  }

  /// Subscribes to the two reactive streams in parallel via a
  /// `TaskGroup`. The child tasks run nonisolated; each per-emission
  /// body awaits a `@MainActor`-isolated method on `self` so state
  /// assignments happen on the main actor. Capturing the streams
  /// locally (instead of `self.repository.observeAll()` inside the
  /// `addTask` closure) lets the region-based isolation checker reason
  /// about Sendable-ness.
  private func observe() async {
    let categoriesStream = repository.observeAll()
    let categoryErrors = repository.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await fresh in categoriesStream {
          await self.apply(categories: fresh)
        }
      }
      group.addTask { [self] in
        for await error in categoryErrors {
          await self.surface(error: error)
        }
      }
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  /// Applies a fresh categories snapshot from `observeAll()`. Wrapped in
  /// the reactive-store signpost interval so benchmarks and Instruments
  /// traces can attribute `mainThreadMs` to this method.
  private func apply(categories fresh: [Moolah.Category]) async {
    await withReactiveStoreSignpost("category-store-apply") {
      self.categories = Categories(from: fresh)
      testObservationTickContinuation.yield(())
    }
  }

  private func surface(error: any Error) {
    logger.error("CategoryStore observation error: \(error.localizedDescription)")
    self.error = error
  }

  /// Tears down the observation task. Idempotent. Called from
  /// `ProfileSession.cleanupSync(coordinator:)` AFTER any
  /// `deleteAllLocalData()` call so the empty-state transition is
  /// emitted to subscribed views before cancellation.
  func stopObserving() {
    observationTask?.cancel()
    observationTask = nil
  }

  // MARK: - Mutations
  //
  // Mutations are pass-through under the reactive design: every method
  // calls the repository, the GRDB write commits, and
  // `repository.observeAll()` delivers the authoritative state via the
  // observation task spawned in `init`. There is no optimistic insert /
  // rollback path — the reactive emission IS the state update.
  //
  // Return shapes (`Category?` for create/update, `Bool` for delete) are
  // preserved from the pre-reactive store so existing call sites
  // (`if await categoryStore.update(updated) != nil { … }`,
  // `if await categoryStore.delete(id:withReplacement:) { … }`) compile
  // unchanged.

  /// Pass-through create. The reactive observation delivers the new
  /// category via `observeAll()` shortly after the GRDB write commits;
  /// no optimistic insert is needed and there is nothing to roll back
  /// because no local state was mutated. Errors surface on `self.error`
  /// and the method returns `nil` for the caller.
  func create(_ category: Moolah.Category) async -> Moolah.Category? {
    error = nil
    do {
      let created = try await repository.create(category)
      logger.debug("Created category: \(created.name)")
      return created
    } catch {
      logger.error("Failed to create category: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }

  /// Pass-through update. See `create(_:)` for the rationale; the
  /// reactive observation delivers the updated category.
  func update(_ category: Moolah.Category) async -> Moolah.Category? {
    error = nil
    do {
      let updated = try await repository.update(category)
      logger.debug("Updated category: \(updated.name)")
      return updated
    } catch {
      logger.error("Failed to update category: \(error.localizedDescription)")
      self.error = error
      return nil
    }
  }

  /// Pass-through re-categorisation delete. `withReplacement:` reassigns
  /// transaction legs / budget items from the deleted category to
  /// `replacementId` (or sets them `nil` when `replacementId == nil`)
  /// inside a single GRDB transaction; orphaned child categories are
  /// re-parented to `nil`. The reactive observation delivers the
  /// post-delete category list once the write commits.
  func delete(id: UUID, withReplacement replacementId: UUID?) async -> Bool {
    error = nil
    do {
      try await repository.delete(id: id, withReplacement: replacementId)
      logger.debug("Deleted category \(id)")
      return true
    } catch {
      logger.error("Failed to delete category: \(error.localizedDescription)")
      self.error = error
      return false
    }
  }
}
