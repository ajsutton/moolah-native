# Moolah Privacy Policy

**Effective date:** 2026-04-26
**Last updated:** 2026-04-26

Moolah is a personal finance app for iPhone, iPad, and Mac. This policy
explains exactly what data Moolah handles, where it is stored, and who can
see it.

The short version: **Moolah does not have a server, does not have user
accounts, and does not collect, transmit, or sell your financial data.** Your
records live on your device and, if you turn it on, in your own private
iCloud account. We — the developers — never see them.

---

## 1. Who is responsible for your data

Moolah is published by the developer listed on the App Store page for the
app ("we", "us"). For privacy questions, contact us at the support address
shown on the App Store listing or in the app's **About** screen.

For data stored in iCloud, **Apple Inc. is the data processor** under the
terms of your Apple ID and iCloud agreements. We do not have access to your
iCloud container.

---

## 2. What Moolah stores

When you use Moolah you may create the following records. All of them are
treated the same way — they live on your device and, if iCloud is enabled,
sync to your private iCloud database.

- **Profiles** — a name and display preferences (currency, financial-year
  start month) for each separate set of books you keep.
- **Accounts** — names, types (bank, credit card, asset, investment),
  currency or instrument, display order, and hidden/visible flag.
- **Transactions** — date, amount, payee/description, notes, account,
  category, earmark, recurrence rule, and any attached transaction legs
  (for transfers, multi-currency splits, and investment trades).
- **Categories** — names and parent/child hierarchy.
- **Earmarks (savings goals)** — names, target amounts, target dates, and
  budget line items.
- **Investments** — instrument identifiers (ticker symbols, crypto contract
  addresses), positions, cost-basis lots, and recorded values.
- **CSV import profiles and import rules** — column mappings, filename
  patterns, and any rules you define for auto-categorising imported
  transactions.
- **Instrument registry entries** — fiat, stock, and crypto instruments you
  have used, including any custom names you chose.

Moolah does **not** ask for, collect, or store: your name, email address,
phone number, postal address, government identifiers, bank login
credentials, contacts, photos, location, microphone, camera, health data,
or device advertising identifier.

Moolah does **not** connect to your bank. You enter your data manually or
import it from CSV files you provide.

---

## 3. Where your data is stored

### 3.1 On your device

Every piece of data described above is first written to a local database
(Apple's SwiftData / Core Data) inside the app's sandboxed container on
your device. If you never enable iCloud, the data never leaves the device.

### 3.2 In your iCloud account (if enabled)

If you sign in to iCloud on your device and have iCloud Drive enabled for
Moolah, the app uses **Apple CloudKit** to synchronise your records to the
private database of your personal iCloud container
(`iCloud.rocks.moolah.app.v2`). The private database is, by Apple's design,
visible only to you. We cannot read it, list it, or query it.

Your records sync to your other Apple devices that are signed in to the
same Apple ID and have Moolah installed.

CloudKit transmits and stores your data subject to **Apple's iCloud
security and privacy practices**:
<https://support.apple.com/en-us/HT202303>.

### 3.3 In your device's Keychain

If you choose to enter a personal CoinGecko API key (an optional setting
that improves crypto price coverage), Moolah stores it in the system
Keychain. With iCloud Keychain enabled, that entry syncs only to your own
devices, end-to-end encrypted by Apple. You can clear it at any time from
the app's settings.

Moolah stores **no other secrets, tokens, or credentials** — there is no
sign-in, no password, and no session cookie because there is no Moolah
server to sign in to.

---

## 4. What leaves your device, and to whom

To show prices and convert between currencies, Moolah looks up public
market data from third-party services. These requests carry **only the
identifier of the currency, stock, or crypto asset being priced** (for
example, the string `USD`, `AAPL`, or a token contract address) plus the
network metadata that any HTTPS request necessarily includes (your device's
IP address and a user-agent string). They do **not** carry your name, your
account names, your balances, your transactions, or any identifier that
links you across requests.

The services used are:

| Service | Purpose | Data sent | Provider's privacy policy |
|---|---|---|---|
| Apple iCloud / CloudKit | Sync of your records to your private iCloud database | Your encrypted record payloads | <https://www.apple.com/legal/privacy/> |
| Frankfurter (`api.frankfurter.app`) | Fiat exchange rates | Currency codes, dates | <https://www.frankfurter.app/docs/> |
| Yahoo Finance (`query2.finance.yahoo.com`) | Stock and ETF prices | Ticker symbols, date ranges | <https://legal.yahoo.com/us/en/yahoo/privacy/> |
| CoinGecko (`api.coingecko.com`) — *optional, only if you enter an API key* | Crypto prices and metadata | Coin IDs, contract addresses, your API key | <https://www.coingecko.com/en/privacy> |
| CryptoCompare (`min-api.cryptocompare.com`) | Crypto prices and reference data | Crypto symbols, contract addresses, dates | <https://www.cryptocompare.com/legal/privacy-policy/> |
| Binance (`api.binance.com`) | Crypto prices and exchange-pair listings | Crypto trading-pair symbols | <https://www.binance.com/en/about-legal/privacy-portal> |

These providers may, like any web service, log incoming requests and the
originating IP address. We have no relationship with them, do not pay them
on your behalf, and do not receive any data back about you. We never share
your data with them ourselves.

You can avoid these requests entirely by not using the multi-currency,
stock, or crypto features of the app.

---

## 5. What Moolah does **not** do

To be unambiguous:

- **No analytics, telemetry, or crash reporting** of our own. Moolah
  contains no third-party analytics, advertising, attribution, or tracking
  SDKs. Apple may collect anonymous crash and usage statistics if you have
  enabled "Share With App Developers" / "Improve Apple Services" at the
  system level; that data flows through Apple, not through Moolah, and is
  governed by Apple's privacy policy.
- **No advertising.** There are no ads in the app and no advertising
  identifiers are read.
- **No tracking across apps or websites** in the App Store sense. Moolah's
  App Privacy declaration is "Data Not Collected".
- **No selling, renting, or sharing of personal data.** We could not do so
  even if we wanted to: we do not have your data.
- **No machine-learning training on your data.** Your records are not
  uploaded to us or to any AI service.
- **No connection to your bank or any aggregator** (Plaid, Yodlee, etc.).

---

## 6. Children

Moolah is not directed to children under 13 (or the equivalent minimum age
in your jurisdiction). It is a general-audience personal finance utility.
We do not knowingly collect data from children; in fact, we do not
knowingly collect data from anyone, because we have no server.

---

## 7. Your choices and rights

Because we do not hold your data, the controls you need are on your own
device:

- **View or edit your data:** open the app. Everything Moolah has stored
  for you is shown there.
- **Export your data:** the app's **Export** feature writes your records
  to a file you control.
- **Delete a single profile and all its data:** in **Settings → Profiles**,
  choose **Delete**. This removes the profile's local database and, for
  iCloud profiles, deletes the corresponding records from your iCloud
  container (cascade delete via CloudKit).
- **Delete everything Moolah has on this device:** uninstall the app. On
  iOS/iPadOS, also remove its data from **Settings → Apple ID → iCloud →
  Manage Account Storage → Moolah** if you want to erase the iCloud copy
  as well.
- **Stop syncing:** sign out of iCloud, or disable iCloud Drive for
  Moolah, in your device's Settings. Your data will remain on the device
  but will no longer be uploaded to iCloud.
- **Revoke the optional CoinGecko key:** clear it from the app's settings.

If you are in a jurisdiction that grants statutory data-subject rights
(for example the EU/UK GDPR or the California CCPA), you may exercise
those rights against the data controller. For data in your iCloud account
that is Apple. We do not act as a controller of your records.

---

## 8. Security

- All network traffic from Moolah uses HTTPS / TLS.
- The on-device database lives inside the app's sandbox container,
  protected by the operating system and (on iOS/iPadOS) by the device
  passcode and Data Protection.
- iCloud sync is handled by CloudKit; transit and at-rest encryption are
  Apple's responsibility and are described at
  <https://support.apple.com/en-us/HT202303>.
- The optional CoinGecko API key is stored in the system Keychain, not in
  plaintext on disk.

No system is perfectly secure. If you become aware of a vulnerability in
Moolah, please report it to the contact address on the App Store listing.

---

## 9. International transfers

Moolah itself does not transfer your data internationally because it does
not transmit your data to us. iCloud sync may store your data in Apple
data centres in your region or elsewhere, as described in Apple's privacy
documentation. The third-party price services listed in §4 are operated
from various jurisdictions; only public market identifiers are sent to
them.

---

## 10. Changes to this policy

If we change this policy, the new version will be published with an
updated "Last updated" date. Material changes will be highlighted in the
app's release notes. The current version is always available in the app
under **Help → Privacy Policy** and at the URL listed on Moolah's App
Store page.

---

## 11. Contact

For privacy questions, use the support address shown on Moolah's App Store
page or in the app's **About** screen.
