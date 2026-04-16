# Known Bugs

## Current Total reverts after transaction amount change

When a transaction amount is changed, the "Current Total" briefly updates to the correct value then reverts back to the old (now incorrect) value.

## Earmark balance doesn't update when transaction amount changes

The earmark balance shown in the sidebar and transaction list doesn't update when an earmark transaction's amount is changed.

## iOS default view should be account list, not analysis

On iOS the app opens to the analysis view by default. It should open to the account list instead.

## Remove "Moolah" title from iOS account list

The top of the iOS account list currently displays "Moolah" as a title. This doesn't add value since the profile picker already shows the current profile. Remove it.

## Data not syncing correctly to iOS

Data changes are not syncing to iOS. Logs show a `Server Record Changed` (CKError 14/2004) oplock conflict on a profile-index record, which causes the accompanying record in the same batch to fail with `Batch Request Failed` (CKError 22/2024). The sync engine then re-queues but the conflict appears to repeat. Likely need to handle the oplock conflict by fetching the latest server record and retrying.

