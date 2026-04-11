# Crypto Ownership & Transaction Tracking

Automatic tracking of cryptocurrency holdings and transaction history across self-custody wallets (Ethereum, OP Mainnet) and the CoinStash exchange.

## Goals

- See current portfolio value per crypto account (wallet or exchange)
- Track every transaction for a complete historical record suitable for future tax reporting
- Auto-discover tokens held in wallets and on exchanges
- Sync automatically while the app is running, with minimal user intervention

## Non-Goals

- Tax reporting / cost basis calculation (future project — builds on this transaction data)
- Account groups / aggregate views (tracked in `plans/FEATURE_IDEAS.md`)
- Background push notifications / server-side polling
- NFT display
- DEX swap correlation (swaps appear as individual token transfers)
- Additional chains beyond Ethereum and OP Mainnet
- Additional exchanges beyond CoinStash

## Dependencies

- **Per-transaction currency**: The exchange rate design (`plans/exchange-rate-design.md`) and crypto price data design (`plans/crypto-price-data-design.md`) must be implemented. Transaction amounts are stored in the token's currency and converted via exchange rates for display.

---

## Data Model

### Crypto Account Type

A new `crypto` account type is added alongside the existing `bank`, `creditCard`, `asset`, and `investment` types. When creating a crypto account, the user specifies:

- **Name** (e.g., "Hardware Wallet - Ethereum")
- **Data source**: Ethereum Mainnet / OP Mainnet / CoinStash
- **Wallet address** (for chain accounts, validated 0x... format) or **CoinStash account ID** (for exchange accounts)

Multiple accounts can share the same wallet address on different chains, or track different addresses on the same chain.

### Transaction Model Extensions

The existing Transaction model gains:

- **Per-transaction currency** (already planned) — each crypto token is treated as a currency. A BTC purchase is a transaction with `currency: BTC`, an ETH gas fee is an expense with `currency: ETH`.
- **txHash** (optional String) — blockchain transaction hash or CoinStash transaction ID. Used for deduplication and linking to block explorers.
- **counterpartyAddress** (optional String) — the other party's wallet/contract address. Useful for tax reporting context (identifying exchanges, DeFi protocols, known addresses).

Gas fees are recorded as **separate expense transactions** in the native chain token (ETH on Ethereum, ETH on Optimism), since they are genuinely separate spends.

### Token Spam Registry (Global)

A global set of token identifiers (contract address + chain) marked as spam. Not per-account — marking a token as spam hides it across all accounts.

When a token is marked spam:
- Its transactions are hidden from all account views
- Its balance is excluded from portfolio valuation
- Transactions remain in the database for completeness
- Spam status can be toggled back

The spam token registry will integrate with token price fetching infrastructure (details to be determined based on implementation order of crypto price data).

### API Credentials (Synced Keychain)

All credentials stored in synced Keychain (`kSecAttrSynchronizable`):

| Credential | Scope | Required For |
|---|---|---|
| Alchemy API key | Global (all wallet accounts) | Ethereum + OP Mainnet transaction/balance fetching |
| Etherscan API key | Global (all wallet accounts) | Supplementary token metadata, fallback |
| CoinStash bearer token | Per CoinStash account | CoinStash balance/transaction fetching |

---

## Sync Engine

### Trigger Conditions

- **App launch**: Check all crypto accounts, sync any not synced in the last 24 hours.
- **Manual refresh**: Pull-to-refresh or sync button on a crypto account.
- **Periodic while running**: If the app stays open, re-sync any account that becomes stale (>24h since last sync).

### Ethereum / OP Mainnet Wallet Sync

1. Fetch `getAssetTransfers` from Alchemy since last synced block number (stored per account).
   - Two calls: one for outgoing (`fromAddress`), one for incoming (`toAddress`).
   - Covers: ETH, ERC-20, ERC-721, ERC-1155, internal transactions.
2. Fetch `getTokenBalances` for current portfolio snapshot.
3. For each new transaction:
   - Deduplicate by txHash (skip if already exists).
   - Look up token currency (create currency entry if new token discovered).
   - Check spam registry — store transaction but mark hidden if spam token.
   - Gas fees: create a separate expense transaction for the native token spend.
   - Record counterparty address.
4. Update investment value from current balances (converted to profile currency via exchange rates).
5. Store the latest block number as sync checkpoint.

### CoinStash Sync

1. Call `accountTransactions` via GraphQL, filtered by `fromDate` since last sync timestamp.
2. Call `accountBalances` for current holdings.
3. For each new transaction:
   - Deduplicate by CoinStash `transactionId` (stored as txHash).
   - Map CoinStash categories to Moolah transaction types (see mapping below).
   - Trade fees (TRADEFEE, SWAPFEE) as separate expense transactions.
4. Update investment value from balance data.
5. Store latest sync timestamp.

### CoinStash Category Mapping

| CoinStash Category | Moolah Type | Notes |
|---|---|---|
| DEPOSIT | income | Crypto deposited into CoinStash |
| WITHDRAW | expense | Crypto withdrawn from CoinStash |
| TRADE (BUY) | income | Acquired crypto |
| TRADE (SELL) | expense | Sold crypto |
| SWAP | transfer | Token-to-token exchange |
| TRADEFEE / SWAPFEE | expense | Fee in relevant token |
| AWARD / COMMISSION | income | Staking rewards, referral bonuses |
| TRANSFER | transfer | Internal movement |

### Error Handling

- **Network failures**: Show last-synced timestamp, allow manual retry.
- **Invalid API key**: Surface error in account view, prompt to update in preferences.
- **Rate limiting**: Back off and retry with exponential delay.

---

## API Costs

### Alchemy

| Plan | Price | Included | Rate Limit |
|---|---|---|---|
| Free | $0/mo | 300M compute units/mo | 330 CU/sec |
| Growth | $49/mo | 400M CU/mo | 660 CU/sec |

Cost per sync cycle (one wallet, one chain): ~450 CU (two `getAssetTransfers` calls + `getTokenBalances`).

Monthly estimate for typical usage (2 wallets x 2 chains = 4 accounts, daily sync): ~54,000 CU/month. Well within free tier. Even hourly syncing while the app is open stays under 1M CU/month.

**Free tier is more than sufficient for personal use.**

### Etherscan / Optimistic Etherscan

| Plan | Price | Rate Limit | Daily Limit |
|---|---|---|---|
| Free | $0 | 5 calls/sec | 100k calls/day |

Only used as supplementary source (token metadata, fallback). Free tier is fine.

### CoinStash

API access is free with any CoinStash account. No published rate limits — at daily sync frequency, risk of hitting limits is negligible.

### Total Expected Cost

**$0/month** for typical personal use across all three APIs.

---

## UI

### Account Creation Flow

When creating a new account, a `crypto` type is available. Selecting it presents:

- **Data source picker**: Ethereum Mainnet / OP Mainnet / CoinStash
- For chain accounts: text field for wallet address (validated 0x... format, 42 characters)
- For CoinStash: text field for bearer token (stored to synced Keychain), then fetches account list for selection

### API Key Management (Preferences)

New section in Preferences:

- **Alchemy API Key**: text field, stored in synced Keychain
- **Etherscan API Key**: text field, stored in synced Keychain
- Status indicator per key (valid / invalid / not set)

CoinStash bearer tokens are per-account, managed in account settings rather than global preferences.

### Spam Token Management (Preferences)

New section in Preferences:

- List of all discovered tokens across all accounts
- Each row: token symbol, token name, contract address (truncated), chain
- Toggle to mark as spam / not spam
- Spam tokens shown in a distinct style (greyed out or separate section)
- Will integrate with token price fetching infrastructure (details TBD based on implementation order)

### Account View

Crypto accounts display:

- **Portfolio summary**: total value in profile currency, breakdown by token with quantities and fiat values
- **Transaction list**: standard Moolah transaction list, with currency shown per transaction
- **Last synced**: timestamp with manual refresh button
- **Sync status**: indicator when sync is in progress

### Transaction Detail

Crypto transactions show standard Moolah fields plus:

- **txHash**: tappable — opens block explorer in browser (etherscan.io for Ethereum, optimistic.etherscan.io for OP Mainnet)
- **Counterparty address**: truncated display, copyable

---

## Privacy & Security

### API Key Storage

- All API keys and bearer tokens stored in synced Keychain (`kSecAttrSynchronizable`).
- Keys are never written to disk, UserDefaults, or CloudKit records.
- Keys are never logged or included in error reports.

### Wallet Address Privacy

- Wallet addresses are public blockchain data. Storing them in the normal account model is acceptable.
- API calls go directly from device to Alchemy/Etherscan/CoinStash — no intermediary sees the association between user identity and wallet address.
- Alchemy/Etherscan see the device's IP associated with wallet queries. Acceptable trade-off for personal use.

### CoinStash Token Security

- Bearer tokens grant read access to the user's full CoinStash account.
- Account setup UI includes guidance to create **read-only** API keys (trade + withdraw permissions disabled in CoinStash settings).

---

## Implementation Order

1. Per-transaction currency + exchange rate infrastructure (if not already done)
2. `crypto` account type + domain model extensions (`txHash`, `counterpartyAddress`)
3. API key management (Preferences + synced Keychain)
4. Sync engine — CoinStash first (simpler: GraphQL, single auth token, structured categories)
5. Sync engine — Ethereum + OP Mainnet wallets (more complex: multiple call types, gas fee splitting, token discovery)
6. Spam token management (Preferences)
7. Account creation UI for crypto accounts
8. Portfolio valuation display
