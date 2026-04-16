# Known Bugs

## Earmarked Total includes negative earmark balances

The "Earmarked Total" in the sidebar sums all earmark balances, including negative ones. It should use `max(earmarkBalance, 0)` per earmark so that negative earmarks (e.g., Investments at -$18,950) don't reduce the total. This also affects the "Available Funds" calculation which subtracts the earmarked total from the current accounts total.


