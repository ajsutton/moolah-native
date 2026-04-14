# Known Bugs

## ~~iCloud Profile Deletion Does Not Propagate to Other Devices~~

**Status:** Fixed. The deleting device deletes the CloudKit zone (`ProfileContainerManager.deleteCloudKitZone`) and the `ProfileRecord` from the index. When other devices receive the `ProfileRecord` deletion via `ProfileIndexSyncEngine`, `ProfileStore.loadCloudProfiles` now detects the removed profile and calls `containerManager.deleteStore` to clean up local files. `SessionManager` is notified via `onProfileRemoved` to tear down the cached `ProfileSession`.

## Sign Out Option Shown for iCloud Backend

The Sign Out option is available for iCloud-backed profiles, but it shouldn't be — there's no authentication session to sign out of. iCloud profiles authenticate via the device's iCloud account, not via a server login. The Sign Out option should be hidden when the active profile uses the CloudKit backend.

## Category Not Filled When Autocompleting a Payee

When selecting an autocomplete suggestion for a payee, the category field is not automatically populated. It should autofill with the category from the most recent transaction with that payee.

## Balance Doesn't Update When a Transaction Is Added

After adding a new transaction, the account balance does not update to reflect the change. The balance should refresh immediately after a transaction is created.

## Transaction Side Panel Should Be Full-Window Width

The transaction detail side panel currently appears only within the upcoming transactions panel. It should instead be a right-hand side panel of the whole window, using the full analysis panel size.

## Profile Index serverRecordChanged Conflict on Fresh Device

A freshly installed device with no local changes triggers `serverRecordChanged` (code 14) when sending the profile record to the profile-index zone. The iPhone logs: `Failed to send profile record: "client oplock error updating record"`. Since the device hasn't made any changes, it shouldn't be uploading — the `queueAllExistingRecords` or synthetic sign-in path may be unnecessarily re-uploading the profile record that was just fetched from CloudKit.
