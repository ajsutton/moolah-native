# CloudKit Sync — Enabling Cross-Device Data Sync

**Date:** 2026-04-11
**Status:** Draft
**Prerequisite:** iCloud backend and data migration (complete)

## Current State

SwiftData iCloud profiles work **locally only**. The `ModelContainer` is created with a default `Schema` and no CloudKit configuration. Data is stored in a local SQLite database. There are no CloudKit entitlements, no iCloud container, and no sync.

## What Needs to Happen

### 1. Apple Developer Portal Setup

- Create an iCloud container (e.g., `iCloud.rocks.moolah.app`) in the Apple Developer portal
- This is a one-time manual step in the portal

### 2. Xcode Entitlements

Add entitlements file(s) with:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.rocks.moolah.app</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
```

This can be configured in `project.yml` under each target's settings:

```yaml
entitlements:
  path: App/Moolah.entitlements
```

Both `Moolah_iOS` and `Moolah_macOS` targets need matching entitlements.

### 3. ModelContainer Configuration

Change `MoolahApp.init()` to use a CloudKit-enabled `ModelConfiguration`:

```swift
// Current (local only):
container = try ModelContainer(for: schema)

// Needed (CloudKit sync):
let config = ModelConfiguration(
    cloudKitDatabase: .private("iCloud.rocks.moolah.app")
)
container = try ModelContainer(for: schema, configurations: [config])
```

The `.private` database stores data in the user's private iCloud — not shared, not public. SwiftData handles all sync automatically.

### 4. CloudKit Schema Initialization

On first run with CloudKit enabled, SwiftData automatically:
- Creates the CloudKit record types matching the `@Model` classes
- Creates indexes for `@Attribute` properties used in predicates
- Sets up the sync engine

In development, run the app with the `com.apple.CoreData.CloudKitDebug` launch argument set to `1` to see sync activity in the console.

The CloudKit schema must be **deployed to production** from the CloudKit Dashboard before the first release. Development schema is auto-created but production requires explicit deployment.

### 5. `#Unique` Constraints

Our `@Model` classes use `#Unique<...>([\.id])` to enforce uniqueness on the `id` field. SwiftData/CloudKit uses these for **conflict resolution** during sync — if two devices create records with the same `id`, the framework merges them using last-writer-wins.

### 6. Auth Provider Changes

`CloudKitAuthProvider` already guards `CKContainer.default()` calls behind an `NSUbiquitousContainers` entitlement check. Once entitlements are added, the guard passes and `CKContainer.default().accountStatus()` works normally. No code changes needed.

### 7. Profile Sync

`ProfileRecord` is already a SwiftData `@Model` stored in the same container. Once CloudKit sync is enabled, profiles created on one device will appear on all devices automatically. `ProfileStore` already observes `.NSPersistentStoreRemoteChange` notifications and calls `loadCloudProfiles()` on change.

### 8. Sync Status UI (Optional)

Consider showing a sync indicator in the UI. SwiftData/CloudKit posts `NSPersistentStoreRemoteChange` notifications when data arrives from other devices. The existing `ProfileStore` already observes these for profile changes. Account/transaction data changes would be picked up on the next `load()` or could trigger a refresh.

## Risks & Considerations

| Topic | Notes |
|-------|-------|
| **First sync** | All local data uploads to iCloud on first enable. For large datasets (10K+ transactions), this takes time. No progress UI from SwiftData. |
| **Conflict resolution** | Last-writer-wins (CloudKit default). Acceptable for single-user financial data. |
| **Schema migration** | Adding/removing `@Model` fields requires careful handling. SwiftData handles lightweight migrations automatically. |
| **iCloud storage quota** | Financial data is small. 5 years of heavy use ≈ 10-20 MB — well within free tier. |
| **Offline** | SwiftData works fully offline. Changes sync when connectivity resumes. |
| **Testing** | CloudKit sync can only be tested with real iCloud accounts. Use separate development and production containers. |
| **Rate limits** | CloudKit has per-user rate limits. Batch operations during migration should respect these. The migration already uses a single atomic save, which SwiftData batches into CloudKit operations. |

## Implementation Order

1. Create iCloud container in Apple Developer portal
2. Add entitlements files for iOS and macOS targets
3. Update `project.yml` with entitlement paths
4. Change `ModelContainer` init to use `cloudKitDatabase: .private(...)`
5. Test locally — verify data appears in CloudKit Dashboard
6. Test cross-device — verify data syncs between Mac and iPhone
7. Deploy CloudKit schema to production
8. (Optional) Add sync status indicator

## Estimated Effort

Most of the work is configuration, not code:
- Portal + entitlements: configuration task
- ModelContainer change: ~5 lines of code
- Testing: manual cross-device verification
- Sync status UI: optional enhancement
