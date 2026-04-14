# Known Bugs

## Balance Calculations Are Inconsistent

Multiple balance values disagree with each other:

1. The sidebar account balance differs from the running balance on the latest transaction.
2. The same iCloud profile viewed on a different device shows yet another balance.
3. All of these differ from the correct balance on the original remote profile that was migrated, even though no transactions have changed since migration.

This suggests the cached balance on the account record, the running balance computed from transactions, and the balance synced via CloudKit are all being calculated or propagated differently.

## Transaction Side Panel Should Be Full-Window Width

The transaction detail side panel currently appears only within the upcoming transactions panel. It should instead be a right-hand side panel of the whole window, using the full analysis panel size.
