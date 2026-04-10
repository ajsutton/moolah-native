# Known Bugs

## iOS: Can't dismiss detail panels

- **Platform:** iOS
- **Description:** After selecting a transaction to view its details, there is no way to hide the detail panel and return to the list. Check all detail panels that slide in from the right (transactions, categories, etc.).

## iOS: Valuation chart is too small

- **Platform:** iOS
- **Description:** The valuation chart and valuations table need to be on separate rows instead of side by side. The chart is too small in the current layout.

## iOS: Add full-screen support for all charts

- **Platform:** iOS
- **Description:** All charts on iOS should support being viewed full screen.

## iOS: Analysis panel is too wide

- **Platform:** iOS
- **Description:** The analysis panel takes up too much horizontal space on iPhone screens.

## iOS: Reports shouldn't use side-by-side layout

- **Platform:** iOS
- **Description:** Reports use a side-by-side layout that is too wide for the iPhone screen. Should use a stacked layout instead.

## General: Editing transaction causes earmark-only display in web UI

- **Platform:** All
- **Description:** Editing a transaction in moolah-native causes the web UI's edit panel to show only earmark fields. Root cause: Swift's `UUID.uuidString` produces uppercase UUIDs, overwriting the server's lowercase UUIDs in the database. The web UI's `EditTransaction.vue` does a case-sensitive account lookup that fails on the uppercase ID, making `isEarmarkAccount` return true.
- **Plan:** `plans/2026-04-10-transaction-edit-uuid-fix.md`

## macOS: Sidebar account balance colors hard to read when selected but unfocused

- **Platform:** macOS
- **Description:** The lighter green and red balance colors in the sidebar are hard to read when an account row is selected but the sidebar is not focused (grey selection background instead of blue).

## macOS: Payee autocomplete popup doesn't dismiss on tab

- **Platform:** macOS
- **Description:** When typing in the payee field, the autocomplete suggestion popup remains visible after tabbing to the next field. It should dismiss on focus loss, keeping whatever text has been typed.

## General: No UI to edit profile properties

- **Platform:** All
- **Description:** There is no UI to modify profile properties like currency. Only name and server URL can be edited.

