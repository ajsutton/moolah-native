# Feature Ideas

Future feature ideas to explore. Each item is a potential project that needs its own design and implementation plan.

## Account Groups
Aggregate view across multiple accounts. Primary use cases:
- Group crypto accounts (same wallet across chains) into a single summary view
- Group multicurrency bank accounts to see total value in a base currency
- Custom groupings (e.g., "Retirement", "Trading") for dashboard-level totals

## Import Transactions from Online Banking (Share Sheet)
Allow users to share a banking webpage to Moolah via the iOS/macOS share sheet. Moolah receives the HTML, parses and interprets the transaction table, and imports the transactions into the selected account. Avoids the need for bank API integrations or CSV wrangling.

## Collapsible Sub-transaction Cards
Compact disclosure-based UI for complex transaction editing. Each sub-transaction shows as a summary row (type badge + account + amount + category) that expands inline to reveal editable fields. Collapsed by default so users can see all sub-transactions at a glance and only expand the one they want to edit. More polished than flat sections but harder to implement with native SwiftUI Form — would likely need a custom layout.

## Selectable Instrument Per Sub-transaction
Currently each sub-transaction's instrument is derived from the selected account. Allow users to explicitly pick the instrument (currency/asset) per sub-transaction leg, independent of the account. This would support scenarios like holding multiple currencies in a single account, or recording transactions in a different denomination than the account's default.

## Sync Progress Indicator
Show sync status in the UI — progress during bulk sync, error states (e.g., iCloud storage full), and last-synced timestamp. Would replace the current invisible sync behaviour with visible feedback. Could be a persistent status bar, toolbar item, or sidebar footer element.
