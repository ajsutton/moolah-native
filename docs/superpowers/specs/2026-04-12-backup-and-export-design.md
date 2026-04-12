# Backup and Export Design

## Overview

Two related features that share infrastructure:

1. **Automatic backup** (macOS only) — daily copy of per-profile SwiftData store files as an internal safety net against data corruption. Not user-visible.
2. **User-facing import/export** — JSON-based export of all profile data via domain models. Shares code with the existing migration feature. Works on both iOS and macOS, any backend type.

## Feature 1: Automatic Backup (macOS only)

### Mechanism

Uses `NSPersistentStoreCoordinator.replacePersistentStore(at:withPersistentStoreFrom:type:)` on a **temporary coordinator** to copy each per-profile SwiftData store file. This acquires SQLite-level read locks, serializes safely with active CloudKit sync, produces a single consistent `.store` file, and loads nothing into memory.

### Storage Location

```
~/Library/Application Support/Moolah/Backups/
  {profileId}/
    2026-04-12.store
    2026-04-11.store
    ...
```

Persistent (not cache), not synced across devices.

### Scope

Only iCloud profiles — they have local store files. Remote profiles store data on the server.

### Trigger

Two paths, both idempotent (date-stamped filenames prevent duplicates):

1. **On app launch** — run backup check immediately after `ProfileContainerManager` initializes.
2. **Daily timer** — `Timer.scheduledTimer` with a 24-hour interval starting from app launch. Handles the case where the app stays open for days.

### Retention

Keep the last 7 daily backups per profile. Delete older backups on each run. Time Machine covers the longer tail.

### Backup Flow

For each iCloud profile:
1. Check if `{profileId}/{today's date}.store` already exists — skip if so.
2. Get the profile's store URL from `ProfileContainerManager`.
3. Create a temporary `NSPersistentStoreCoordinator` (needs an `NSManagedObjectModel`).
4. Call `replacePersistentStore(at: backupURL, withPersistentStoreFrom: storeURL, type: .sqlite)`.
5. Scan the profile's backup directory, delete any `.store` files older than 7 days.

### Restore

Not automated in this initial implementation. This is an emergency safety net. If needed, the user or support would manually replace the store file. A restore UI can be added later.

### Platform Gating

`#if os(macOS)` on the `StoreBackupManager` type and its call site in `MoolahApp`.

### New Type

`StoreBackupManager` — needs access to:
- `ProfileContainerManager` for store URLs and the list of iCloud profiles.
- An `NSManagedObjectModel` for constructing the temporary `NSPersistentStoreCoordinator`. This can be obtained via `NSManagedObjectModel.mergedModel(from: [Bundle.main])` if SwiftData generates a `.momd` in the bundle, or constructed from the known data schema. The model only needs to be compatible enough for the coordinator to operate on the SQLite file — it does not load any data.

## Feature 2: User-Facing Import/Export

### Shared Infrastructure (Refactoring Migration)

The existing migration code exports from a remote backend and imports into CloudKit/SwiftData. This refactoring generalizes the export side to work with any backend and reuses the import side for JSON imports.

#### ExportedData

Moves from `Backends/CloudKit/Migration/` to a shared location (e.g. `Shared/` or `Domain/`). Gains `Codable` conformance and metadata fields:

```swift
struct ExportedData: Codable, Sendable {
    let version: Int  // 1
    let exportedAt: Date
    let profileLabel: String
    let currencyCode: String
    let financialYearStartMonth: Int
    let accounts: [Account]
    let categories: [Category]
    let earmarks: [Earmark]
    let earmarkBudgets: [UUID: [EarmarkBudgetItem]]
    let transactions: [Transaction]
    let investmentValues: [UUID: [InvestmentValue]]
}
```

`ExportedData` is already effectively `Codable` since all member types conform to `Codable`.

#### DataExporter (renamed from ServerDataExporter)

Renamed and moved out of `Backends/CloudKit/Migration/`. The code is unchanged — it already reads through repository protocols (`BackendProvider`), not server-specific APIs. Accepts a `BackendProvider` directly instead of individual repositories.

Works for any backend type: remote, CloudKit, or future backends.

#### CloudKitDataImporter (stays, updated for per-profile stores)

Keeps its current approach of writing SwiftData records directly — this is efficient for bulk insertion and handles the required ordering:

1. Categories (no dependencies)
2. Accounts (no dependencies)
3. Earmarks (no dependencies)
4. Earmark budget items (references earmarks + categories)
5. Transactions (references accounts, categories, earmarks)
6. Investment values (references accounts)

Updated to work with per-profile stores (drops `profileId` parameter, per the per-profile-stores design).

Import always creates a new profile — avoids conflicts with existing data.

#### MigrationCoordinator (gains import-from-file capability)

Orchestrates all three flows:

| Flow | Source | Destination |
|---|---|---|
| Migration | `DataExporter(remoteBackend)` | New iCloud profile |
| User import | JSON file → `ExportedData` | New iCloud profile |
| User export | `DataExporter(anyBackend)` → JSON file | User-chosen file |

The coordinator gains:
- `importFromFile(url:profileStore:modelContainer:)` — parses JSON, creates profile, imports, verifies.
- `exportToFile(url:backend:profile:)` — exports via `DataExporter`, encodes to JSON, writes to file.

The existing `migrate()` method is updated to use `DataExporter` (renamed from `ServerDataExporter`).

### JSON File Format

```json
{
  "version": 1,
  "exportedAt": "2026-04-12T10:30:00Z",
  "profileLabel": "Personal",
  "currencyCode": "AUD",
  "financialYearStartMonth": 7,
  "accounts": [...],
  "categories": [...],
  "earmarks": [...],
  "earmarkBudgets": { "<earmark-uuid>": [...] },
  "transactions": [...],
  "investmentValues": { "<account-uuid>": [...] }
}
```

- ISO 8601 dates, sorted keys, pretty-printed for human readability.
- Monetary amounts serialized as domain `MonetaryAmount` (cents + currency) via existing `Codable` conformance.
- `.json` file extension — no custom UTType needed.
- `version` field for future format evolution.

### Export Flow

1. User triggers export (File menu on macOS, profile list on iOS).
2. `DataExporter` reads all data from the current backend via repositories → `ExportedData`.
3. `ExportedData` encoded with `JSONEncoder` (pretty-printed, sorted keys, ISO 8601 dates).
4. File save dialog — `NSSavePanel` (macOS) / `fileExporter` (SwiftUI) — user picks location.

### Import Flow

1. User triggers import (File menu on macOS, profile list on both platforms).
2. File picker (`NSOpenPanel` / `fileImporter`) to select JSON file.
3. Parse JSON → `ExportedData`. Validate `version` field.
4. Create new iCloud profile using metadata from the export (`currencyCode`, `financialYearStartMonth`, `profileLabel`).
5. `CloudKitDataImporter` writes data into the new profile's store (ordered for referential integrity).
6. Verification (count match + balance reconciliation, same as migration).
7. New profile appears in profile list.

### UI

**macOS:**
- File > Export Profile... (exports current profile)
- File > Import Profile... (opens file picker, creates new profile)
- Profile list screen also shows import/export actions

**iOS:**
- Profile list screen shows import and export actions

Progress reporting reuses existing `MigrationCoordinator` state machine — export and import of large profiles will take a few seconds.

## File Changes Summary

### New Files

| File | Purpose |
|---|---|
| `Shared/StoreBackupManager.swift` | macOS automatic backup — store file copy + retention |
| `Shared/ExportedData.swift` | Shared data format (moved from migration) |
| `Shared/DataExporter.swift` | Backend-agnostic export (renamed from ServerDataExporter) |

### Modified Files

| File | Change |
|---|---|
| `Backends/CloudKit/Migration/MigrationCoordinator.swift` | Add `importFromFile` and `exportToFile` methods, use `DataExporter` |
| `Backends/CloudKit/Migration/CloudKitDataImporter.swift` | Update for per-profile stores (drop `profileId`) |
| `Backends/CloudKit/Migration/ServerDataExporter.swift` | Deleted (replaced by `Shared/DataExporter.swift`) |
| `App/MoolahApp.swift` | Initialize `StoreBackupManager`, add macOS File menu commands |
| `Features/Profiles/` | Add import/export UI to profile list |

### Dependencies

This feature depends on the **per-profile stores** work (in progress in a separate worktree):
- `StoreBackupManager` needs per-profile store URLs from `ProfileContainerManager`
- `CloudKitDataImporter` updates align with the `profileId` removal

The `DataExporter` rename and `ExportedData` move can be done independently.
