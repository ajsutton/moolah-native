# Known Bugs

## Data not syncing correctly to iOS

Data changes are not syncing to iOS. Logs show a `Server Record Changed` (CKError 14/2004) oplock conflict on a profile-index record, which causes the accompanying record in the same batch to fail with `Batch Request Failed` (CKError 22/2024). The sync engine then re-queues but the conflict appears to repeat. Likely need to handle the oplock conflict by fetching the latest server record and retrying.

