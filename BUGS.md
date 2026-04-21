# Known Bugs

## TransactionDetailView default focus on open

When the user opens a transaction (or the inspector first appears), the
payee field should receive keyboard focus per
`defaultFocus($focusedField, isSimpleEarmarkOnly ? .amount : .payee)` in
`TransactionDetailView`. Today the macOS first-responder grabs the
transaction list's toolbar search field instead, leaving the payee field
focusable but not focused. The user has to click into payee before they
can start typing.

The first UI test (`TransactionDetailFocusTests.testOpeningTradeFocusesPayee`)
works around this by tapping the payee field explicitly before asserting
focus. When this bug is fixed, that `.tap()` step can be deleted.

