# Known Bugs

## Custom transaction per-leg category uses dropdown Picker instead of autocomplete
The sub-transaction sections use a plain `Picker` for category selection instead of the `CategoryAutocompleteField` typeahead used in the simple form. This was done to avoid preference key conflicts (the overlay system uses a single `CategoryPickerAnchorKey`). Need to either use keyed preference keys per leg or find another approach so users can type to search categories in custom mode.

## No banner when iCloud storage is full
When the iCloud quota is exceeded, sync silently fails. Should show a non-modal banner at the top of the content area informing the user that iCloud storage is full and some changes can't sync. The `SyncCoordinator.isQuotaExceeded` state is already tracked — just needs a UI banner. Previous attempt caused OOM crash because `SyncStatusBanner` read `@Environment(SyncCoordinator.self)` which wasn't injected at the right level in the view hierarchy.

## Transfer leg sign convention is wrong in custom mode
Custom mode transfer legs show an "Outflow"/"Inflow" direction picker with `isOutflow` bool, which is wrong on multiple levels:
- "Outflow" and "Inflow" are complex finance terms that don't match the brand guide's plain-spoken tone.
- The sign convention should match the simple form: the user enters a positive amount to reduce the account balance (transfer out) or a negative amount to increase it (transfer in). For scheduled transactions, positive = from account to to-account, negative = reverse.
- The `isOutflow` field on `LegDraft` and the direction picker should be removed. Instead, transfer legs should use the same sign-from-amount convention as the simple form — the user controls sign by entering positive or negative values directly.
