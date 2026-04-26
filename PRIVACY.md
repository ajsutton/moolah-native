# Moolah Privacy Policy

**Effective date:** 2026-04-26
**Last updated:** 2026-04-26

Moolah is a personal finance app for iPhone, iPad, and Mac. This policy
explains what Moolah does — and, more importantly, what it does **not**
do — with the information you enter into it.

The short version:

> **We do not run a server. We do not have user accounts. We never see,
> collect, or transmit your financial data to ourselves or to anyone
> else. Everything you enter stays on your device, and is synchronised
> only through your own private iCloud account if you choose to enable
> iCloud.**

---

## 1. Who is responsible for your data

Moolah is published by the developer listed on the app's App Store page
("we", "us"). For privacy questions, use the contact details shown on the
App Store listing or in the app's **About** screen.

For data that is synchronised through iCloud, **Apple Inc. is the
operator of that service** under the terms of your Apple ID and iCloud
agreements. We have no access to, and no contractual relationship with
Apple in respect of, the contents of your iCloud account.

---

## 2. Information you provide to Moolah

Moolah is a personal finance organiser. To use it, you enter information
about your own money — for example records of your accounts, your
income and spending, the categories or savings goals you want to track,
your investment holdings, and the rules and preferences you set up to
help organise that information. This may include free-form text you type
in fields such as descriptions, payee names, and notes.

We treat **everything you enter** as your private content. The
categories above are illustrative, not exhaustive: anything you type or
import into the app is handled the same way and described by this
policy, including any future fields added in later versions.

Moolah does **not** ask for, request, or store:

- your real name, email address, phone number, or postal address;
- any government identifier (SSN, tax file number, driver's licence);
- any bank, brokerage, or exchange login credentials;
- access to your contacts, photos, location, microphone, camera,
  health, or fitness data;
- any device advertising identifier.

Moolah does **not** connect to your bank, brokerage, or any account
aggregator. You enter your data manually, or you import files (such as
CSV exports) that you have obtained yourself.

---

## 3. Where your information is stored

### 3.1 On your device

Everything you enter is first written to the app's private storage area
on the device you are using. This area is sandboxed by the operating
system and is not readable by other apps. If you never turn on iCloud,
nothing you enter ever leaves the device.

### 3.2 In your private iCloud account (only if you enable it)

If you sign in to iCloud on your device and allow Moolah to use it,
Moolah uses **Apple's CloudKit framework** to synchronise your records
to the **private database** of your personal iCloud account. By Apple's
design, the private database of your iCloud account is visible only to
you. We cannot read it, list it, search it, or recover it.

Through CloudKit, your records sync to your other Apple devices that
are signed in to the same Apple ID and have Moolah installed.

The transmission, storage, and encryption of data in iCloud is handled
by Apple under **Apple's iCloud security and privacy practices**:
<https://support.apple.com/en-us/HT202303>.

### 3.3 In your device's Keychain

Moolah uses the system Keychain only to store small, optional secrets
that you have explicitly chosen to provide — for example, an optional
third-party API key for crypto pricing (see §4). With iCloud Keychain
enabled, those entries are end-to-end encrypted by Apple and synchronise
only to your other Apple devices. You can clear them at any time from
within the app's settings.

There is no Moolah account, no Moolah password, and no Moolah session
token — there is no Moolah server to sign in to.

---

## 4. What leaves your device, and to whom

To display prices and convert between currencies, Moolah looks up
**public market data** from a small number of third-party services. The
only information sent to those services is the identifier of the
currency, stock, or crypto asset being priced (for example, the strings
`USD`, `AAPL`, or a token's contract address) plus the network metadata
that any HTTPS request inherently carries (your device's IP address and
a generic user-agent string).

These requests do **not** include your name, your account names, your
balances, your transactions, your notes, or any identifier that would
let a recipient link multiple requests back to you as a person.

| Service | Purpose | Provider's privacy policy |
|---|---|---|
| Apple iCloud / CloudKit | Synchronising your records to your own private iCloud database | <https://www.apple.com/legal/privacy/> |
| Frankfurter | Fiat currency exchange rates | <https://www.frankfurter.app/docs/> |
| Yahoo Finance | Stock and ETF prices | <https://legal.yahoo.com/us/en/yahoo/privacy/> |
| CryptoCompare | Crypto prices and reference data | <https://www.cryptocompare.com/legal/privacy-policy/> |
| Binance | Crypto prices and exchange-pair listings | <https://www.binance.com/en/about-legal/privacy-portal> |
| CoinGecko *(optional — only if you supply your own API key)* | Additional crypto pricing and metadata | <https://www.coingecko.com/en/privacy> |

Like any web service, these providers may log incoming requests and the
originating IP address under their own policies. We have no business
relationship with them, do not pay them on your behalf, and receive
nothing back about you. We never share your information with them
ourselves.

You can avoid these requests entirely by not using the multi-currency,
stock, or crypto features of the app.

---

## 5. What Moolah does **not** do

To be unambiguous:

- **No analytics, telemetry, or crash reporting of our own.** Moolah
  contains no third-party analytics, advertising, attribution, or
  tracking SDKs. Apple may collect anonymous, aggregated crash and
  usage statistics if you have enabled "Share With App Developers" /
  "Improve Apple Services" at the system level; that data flows through
  Apple, not through Moolah, and is governed by Apple's privacy policy.
- **No advertising.** No ads, and no advertising identifier is read.
- **No tracking** in the sense defined by Apple's App Tracking
  Transparency framework. Moolah's App Store privacy disclosure is
  "Data Not Collected".
- **No selling, renting, or sharing of personal data.** We could not do
  so even if we wanted to: we do not have your data.
- **No machine-learning training on your data.** Your records are not
  uploaded to us or to any AI service.
- **No connection to your bank** or any financial-account aggregator
  (Plaid, Yodlee, Finicity, etc.).

---

## 6. Children

Moolah is not directed to children under 13 (or the equivalent minimum
age in your jurisdiction) and is offered as a general-audience personal
finance utility. We do not knowingly collect data from children — in
fact, we do not knowingly collect data from anyone, because we have no
server.

---

## 7. Your choices and rights

Because we never receive your information, the controls you need are on
your own device:

- **View or edit** your information by opening the app — everything
  Moolah holds for you is shown there.
- **Export** your information using the app's export feature, which
  writes your records to a file you control.
- **Delete a single profile** and all of its information from inside
  the app's settings. For a profile that is synced to iCloud, this
  also removes the corresponding records from your iCloud account.
- **Delete everything Moolah holds on this device** by uninstalling the
  app. To also remove the iCloud copy, on iPhone or iPad go to
  **Settings → \[your name\] → iCloud → Manage Account Storage →
  Moolah** and choose **Delete Data**.
- **Stop syncing** by signing out of iCloud or disabling iCloud Drive
  for Moolah in the device's system settings. Your records remain on
  the device but are no longer uploaded.
- **Revoke any optional third-party API key** you have entered, from
  the app's settings.

If you live in a jurisdiction that grants statutory data-subject rights
(for example the EU/UK GDPR or the California CCPA), those rights apply
against the party that is acting as the controller of the relevant
data. For the data inside your iCloud account, that party is Apple. We
do not act as a controller of your records.

---

## 8. Security

- All network traffic from Moolah uses HTTPS / TLS.
- Information stored on your device is held inside the app's sandboxed
  storage area, protected by the operating system and (on iPhone and
  iPad) by your device passcode and Apple's Data Protection.
- Sync to iCloud is performed by Apple's CloudKit; transit and at-rest
  protection is Apple's responsibility and is described at
  <https://support.apple.com/en-us/HT202303>.
- Optional secrets, such as a user-provided API key, are stored in the
  system Keychain rather than in plain files on disk.

No system is perfectly secure. If you become aware of a vulnerability
in Moolah, please report it to the contact address shown on the App
Store listing.

---

## 9. International transfers

Moolah itself does not transfer your information across borders,
because it does not transmit your information to us. If you use iCloud,
Apple may store your data in data centres in your region or elsewhere,
as described in Apple's privacy documentation. Where the third-party
price services in §4 are operated from is each provider's own matter;
only public market identifiers are sent to them.

---

## 10. Changes to this policy

If we change this policy, the new version will be published with an
updated "Last updated" date. Material changes will be highlighted in
the app's release notes. The current version is always available
through the app and at the URL listed on Moolah's App Store page.

---

## 11. Contact

For privacy questions, use the support address shown on Moolah's App
Store page or in the app's **About** screen.
