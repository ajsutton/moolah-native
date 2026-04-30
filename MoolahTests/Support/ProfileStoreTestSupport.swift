import Foundation
import Testing

@testable import Moolah

/// Drains every fire-and-forget Task tracked by the store. Used by
/// tests that mutate via the store and then assert immediately —
/// `addProfile` / `updateProfile` / `removeProfile` schedule the GRDB
/// write off-actor, and `loadCloudProfiles` schedules the read
/// off-actor too. Awaiting these tasks gives a deterministic point
/// where the GRDB row is on disk and any `onProfileChanged` /
/// `onProfileDeleted` callbacks have fired.
@MainActor
func drainPendingMutations(_ store: ProfileStore) async {
  while let task = store.pendingMutationTasks.first {
    await task.value
    // The bookkeeping Task that removes completed entries from
    // `pendingMutationTasks` runs on the main actor; yield once so
    // that bookkeeping commits before the next iteration.
    await Task.yield()
  }
}
