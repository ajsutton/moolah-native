# Background Sync for iCloud Backend

## Problem

Changes made right before closing the app may not be uploaded because CKSyncEngine's automatic scheduler hasn't had a chance to send them. Similarly, when the app is opened, data may be stale because remote changes weren't fetched while the app was suspended.

CKSyncEngine handles background push notifications internally, but the app currently has no mechanism to:
1. Flush pending uploads when entering the background
2. Ensure the sync engine is alive when the system delivers a background push notification

## Current State

- `remote-notification` background mode is declared in Info.plist (the only background mode)
- CKSyncEngine is created in `MoolahApp.init()` (index engine) and `ProfileSession.init()` (per-profile engine)
- No `AppDelegate` exists — the app is pure SwiftUI
- No use of `beginBackgroundTask`, `BGTaskScheduler`, or `performExpiringActivity`
- No `scenePhase` observation for sync lifecycle
- CKSyncEngine's automatic scheduling handles all fetch/send timing while the app is in the foreground

## Design

### 1. Flush Pending Changes on Background Entry

When the app moves to the background, explicitly tell CKSyncEngine to send any queued changes immediately rather than waiting for its next automatic scheduling window.

**Approach**: Observe `scenePhase` in `MoolahApp` and call `sendChanges()` on both sync engines when transitioning to `.background`.

```swift
// In MoolahApp body, on the WindowGroup:
.onChange(of: scenePhase) { oldPhase, newPhase in
    if newPhase == .background {
        Task {
            await flushPendingChanges()
        }
    }
}
```

`sendChanges()` is the correct API — it tells CKSyncEngine to send all pending record zone changes now. The system gives the app a few seconds of background execution time on transition, which is enough for CKSyncEngine to initiate the network requests. CloudKit's underlying `NSURLSession` background uploads will complete even if the app is suspended before the response arrives.

For **macOS**, the app is rarely "backgrounded" in the iOS sense — it stays running. But `scenePhase == .background` fires when all windows are closed (if the app remains in the dock), so the same code works.

### 2. Fetch Remote Changes on Foreground Entry

When the app returns to the foreground, explicitly fetch changes to pick up anything that arrived while suspended.

```swift
if newPhase == .active {
    Task {
        await fetchRemoteChanges()
    }
}
```

`fetchChanges()` tells CKSyncEngine to check for new server changes now. This supplements the automatic push-notification-driven fetches — it covers cases where a push was missed or the app wasn't launched in the background.

### 3. Background Push Notification Handling (iOS)

CKSyncEngine automatically subscribes to CloudKit push notifications for its zones. When a push arrives and the app has the `remote-notification` background mode, the system launches the app in the background. However, CKSyncEngine must exist at that point to process the notification.

Since `MoolahApp.init()` creates the `ProfileIndexSyncEngine` and the active `ProfileSession` creates the per-profile engine, a background launch should initialize both — **provided** the active profile is restored on launch. Verify that:

- `ProfileStore` restores the active profile ID from persistent storage during init (not lazily on first UI interaction)
- `ProfileSession` is created during init, not deferred to when the view body is first evaluated

If the sync engines are created during `App.init()`, no `AppDelegate` is needed — CKSyncEngine receives the push internally. If testing reveals that SwiftUI body evaluation is deferred during background launches, an `AppDelegate` adapter would be needed as a fallback (see Risks section).

### 4. Request Extra Background Time for Large Uploads

If the user made many changes, `sendChanges()` may not complete in the few seconds the system grants on background transition. Use `ProcessInfo.processInfo.performExpiringActivity` to request additional background time:

```swift
func flushPendingChanges() async {
    // Check if there are pending changes worth flushing
    guard hasPendingChanges else { return }
    
    ProcessInfo.processInfo.performExpiringActivity(
        reason: "Uploading pending sync changes"
    ) { expired in
        if expired {
            // System is reclaiming time — CKSyncEngine will resume next launch
            return
        }
        Task {
            await self.profileIndexSyncEngine.sendChanges()
            await self.activeProfileSyncEngine?.sendChanges()
        }
    }
}
```

`performExpiringActivity` works on both iOS and macOS. On iOS it requests background execution time (typically ~30 seconds). On macOS it prevents the system from sleeping. The `expired` callback fires if the system needs to reclaim the time — CKSyncEngine handles partial uploads gracefully by resuming from saved state on next launch.

## Implementation Steps

1. **Add `scenePhase` observation to MoolahApp** — store it as `@Environment(\.scenePhase)` and use `.onChange` to detect transitions.

2. **Expose `sendChanges()` and `fetchChanges()` on both sync engines** — thin wrappers that forward to the underlying `CKSyncEngine` instance. Guard against calling when the engine isn't running.

3. **Wire up background flush** — on `.background` transition, call `sendChanges()` on the index engine and the active profile's sync engine using `performExpiringActivity`.

4. **Wire up foreground fetch** — on `.active` transition, call `fetchChanges()` on both engines.

5. **Verify background launch behavior** — test that when a CloudKit push arrives while the app is suspended, `MoolahApp.init()` runs and the sync engines are created. If not, add `UIApplicationDelegateAdaptor` / `NSApplicationDelegateAdaptor` to ensure the engines exist.

6. **Test the full cycle**:
   - Make a change on device A, immediately background the app, verify the change appears on device B
   - Make a change on device B, open device A, verify the change appears immediately (not after a delay)

## Risks and Mitigations

**SwiftUI body not evaluated on background launch**: If the system launches the app for a push notification but SwiftUI defers body evaluation, the per-profile `ProfileSyncEngine` won't exist to process the push. Mitigation: move sync engine creation to `MoolahApp.init()` rather than relying on `ProfileSession` in the view hierarchy. Or add an `AppDelegate` that ensures engines are started.

**Background time too short for large batches**: `performExpiringActivity` gives ~30 seconds on iOS. If the user made hundreds of changes, not all may send. Mitigation: CKSyncEngine persists pending changes in its state serialization — they'll be sent on next launch. This is acceptable; the goal is best-effort immediate sync, not guaranteed delivery.

**Duplicate fetch on foreground**: Calling `fetchChanges()` on foreground entry while CKSyncEngine is already fetching (from a push notification) is harmless — CKSyncEngine coalesces concurrent fetch requests.

**macOS differences**: macOS apps rarely enter `.background` scene phase. The foreground fetch on `.active` still helps after the Mac wakes from sleep. For macOS, the main benefit is the explicit `sendChanges()` when windows close.

## Future Enhancement: BGAppRefreshTaskRequest

The current implementation only syncs when the app is in the foreground or transitioning to/from background. If the app hasn't been opened for a long time, no sync occurs until the user opens it — CloudKit push notifications only wake suspended apps, not terminated ones.

`BGAppRefreshTaskRequest` could fill this gap by letting the system periodically wake the app (roughly every 15–30 minutes, at system discretion) to fetch remote changes. This would keep local data fresher for users who don't open the app frequently. Requires adding the `fetch` background mode to Info.plist and registering/scheduling the task in `MoolahApp.init()`.
