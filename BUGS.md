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

## General: Editing transaction drops fields, shows as earmark-only in web

- **Platform:** All
- **Description:** Editing a transaction in moolah-native causes it to appear as an earmark-only transaction in the web view. The edit is likely dropping important fields that aren't being preserved in the update payload.

## General: No UI to edit profile properties

- **Platform:** All
- **Description:** There is no UI to modify profile properties like currency. Only name and server URL can be edited.

