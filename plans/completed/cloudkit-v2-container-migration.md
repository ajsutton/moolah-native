# CloudKit v2 Container Migration

## Background

The Phase 1 multi-instrument refactor changed the SwiftData schema significantly:
- `TransactionRecord` no longer stores financial data directly (amount, type, accountId)
- New `TransactionLegRecord` and `InstrumentRecord` tables added
- `AccountRecord.balance` changed from Int (cents) to Int64 (scaled by 10^8)

The existing CloudKit container (`iCloud.rocks.moolah.app`) has the old schema deployed. CloudKit schema changes are **additive only** — you cannot remove or rename columns. The old columns will remain as dead weight, but the new records and columns will be added automatically on first sync.

## What Needs Doing

### 1. Evaluate Whether a New Container Is Actually Needed

CloudKit handles additive schema migration automatically. The key question is whether the old data can coexist:

- **New columns on existing records**: Added automatically. Old clients ignore them, new clients populate them. OK.
- **New record types** (`TransactionLegRecord`, `InstrumentRecord`): Created automatically. Old clients ignore them. OK.
- **Removed columns** (`TransactionRecord.amount`, `.type`, `.accountId`, etc.): CloudKit never removes columns. They stay in the schema as unused. New clients stop writing to them. **Old clients will see empty financial data** if they sync a record written by a new client.

If backward compatibility with the old app version is not required (no staged rollout), the existing container works fine with dead columns. A new container is only needed if:
- You want a clean schema without dead columns
- You need to support both old and new app versions simultaneously

### 2. If Switching to a New Container

1. **Create the container** in Apple Developer portal: `iCloud.rocks.moolah.app.v2`
2. **Update entitlements**: `App/Moolah.entitlements` — change container identifier
3. **Update SwiftData configuration**: Check `ModelContainer` configuration in `ProfileSession.swift` and any CloudKit container references
4. **Update `project.yml`**: If entitlements are referenced there
5. **Data migration**: Users lose cloud-synced data unless a migration path is provided:
   - Option A: One-time import from v1 container (read old, write new)
   - Option B: Ship a transitional build that reads both containers
   - Option C: Accept data loss (only viable for pre-release/TestFlight users)

### 3. If Keeping the Existing Container

1. **No entitlements change needed**
2. **Verify additive migration**: Deploy to a test device, confirm new records sync correctly alongside old dead columns
3. **Document dead columns**: Note which `TransactionRecord` columns are no longer written to, so future developers don't rely on them

## Recommendation

For a pre-release app with TestFlight-only users, keeping the existing container is simplest. The dead columns are harmless. Switch to a v2 container only if you want a clean slate or need to support old+new app versions simultaneously.

## Files to Change (if switching)

- `App/Moolah.entitlements` — container identifier
- `App/ProfileSession.swift` — verify ModelContainer configuration
- `project.yml` — if entitlements path is referenced
- Apple Developer portal — create new container, configure for development + production
