# Known Bugs

## UI pause during migration import/save

**Location:** `Backends/CloudKit/Migration/CloudKitDataImporter.swift`

The migration importer runs on the main actor and saves all records atomically. With large datasets (thousands of transactions + investment values), the single `context.save()` call can briefly freeze the UI. This is a one-off operation during migration and atomicity is important for data integrity, so this is accepted behavior. The migration view shows a "Saving..." state during this step.

**Impact:** Brief UI unresponsiveness during a one-time migration. Not a recurring issue.
