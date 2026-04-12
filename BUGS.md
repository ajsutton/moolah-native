# Known Bugs

## iCloud Profile Deletion Does Not Propagate to Other Devices

Deleting an iCloud profile only removes local SQLite files and the `ProfileRecord` from the index store. The CloudKit zone and its records remain on Apple's servers, so other devices keep the data indefinitely. See [plans/icloud-profile-deletion-sync.md](plans/icloud-profile-deletion-sync.md) for analysis and proposed solutions.
