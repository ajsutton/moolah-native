# Australian Stock Price Data — Source Research

## Goal

Identify a reliable, free (or cheap) source of daily closing prices — ideally with historical data — for Australian (ASX) shares. The use case is small: 5–10 stocks, updated daily.

## Context

This app already has infrastructure for exchange rates and cryptocurrency prices (see `exchange-rate-design.md` and `crypto-price-data-design.md`). The stock price source should follow similar patterns: a domain-layer model, a provider protocol, and a concrete backend that fetches from a remote API.

---

## Option 1: Yahoo Finance (via undocumented API) — RECOMMENDED

**Cost:** Free (unofficial)
**ASX support:** Yes — ticker format `BHP.AX`, `CBA.AX`, `VAS.AX`
**Historical data:** Full history (decades), daily/weekly/monthly intervals
**Rate limits:** Unofficial; generous for small-scale use

### How it works

Yahoo Finance exposes an undocumented JSON API at:

```
https://query2.finance.yahoo.com/v8/finance/chart/{symbol}
```

Parameters:
- `period1` / `period2` — Unix timestamps for date range
- `interval` — `1d`, `1wk`, `1mo`
- `events` — `div`, `splits` (optional)

Response structure:
```json
{
  "chart": {
    "result": [{
      "timestamp": [1712620800, ...],
      "indicators": {
        "quote": [{
          "open": [...],
          "high": [...],
          "low": [...],
          "close": [...],
          "volume": [...]
        }],
        "adjclose": [{
          "adjclose": [...]
        }]
      }
    }]
  }
}
```

### Swift libraries

Two Swift packages wrap this API:

1. **[SwiftYFinance](https://github.com/alexdremov/SwiftYFinance)** — iOS 13+, SPM, latest release v2.1.0 (March 2025). Provides `chartDataBy()` for OHLCV history and search. Both sync and async APIs.

2. **[XCAStocksAPI](https://github.com/alfianlosari/XCAStocksAPI)** — SPM, native `async/await` interface. Provides chart data for 1d through max, ticker search, quote fetching.

### Pros
- Completely free, no API key needed
- Covers all ASX-listed securities
- Deep historical data (20+ years)
- Existing Swift packages available
- JSON response is simple and well-understood
- Used by thousands of open-source projects (battle-tested)
- Includes adjusted close prices (accounts for dividends/splits)

### Cons
- **Undocumented and unofficial** — Yahoo could block or change it at any time
- Requires a `User-Agent` header for reliability
- Terms of service say "personal use only"
- Has broken before (2017 shutdown of the old API) though the v8 endpoint has been stable for years
- No SLA or support

### Verdict

Best option for a personal-use app with 5–10 stocks. The risk of it breaking is real but manageable — the data layer can be designed with a provider protocol so swapping to a paid source later is straightforward. The existing Swift packages mean minimal implementation effort.

---

## Option 2: EODHD (EOD Historical Data)

**Cost:** Free tier: 20 API calls/day. Paid: US$19.99/month (All World EOD)
**ASX support:** Yes — 2,000+ ASX securities. Ticker format: `BHP.AU`
**Historical data:** Global EOD data mostly from Jan 2000
**Rate limits:** Free: 20 calls/day. Paid: 1,000/minute

### API endpoint

```
https://eodhd.com/api/eod/{symbol}.AU?api_token={key}&fmt=json
```

### Pros
- Official, documented API with proper terms
- Direct exchange data contracts (including ASX)
- Covers fundamentals, dividends, splits in addition to prices
- US$19.99/month is reasonable if free sources break

### Cons
- Free tier is extremely limited (20 calls/day — enough for ~10 stocks but no room for retries or historical backfill)
- Paid tier required for any serious use
- Another API key to manage

### Verdict

Good fallback if Yahoo breaks. The $20/month "All World" tier covers everything needed. The free tier is technically sufficient for 5–10 daily updates but leaves no margin.

---

## Option 3: Marketstack

**Cost:** Free tier: 100 calls/month. Paid: US$9.99/month (10,000 calls)
**ASX support:** Yes — covers 70+ exchanges including ASX
**Historical data:** Yes, EOD data
**Rate limits:** Free: ~3 calls/day equivalent

### API endpoint

```
https://api.marketstack.com/v1/eod?access_key={key}&symbols=BHP.XASX
```

### Pros
- Simple REST API, well documented
- Cheap paid tier ($9.99/month)
- Covers ASX

### Cons
- Free tier is extremely limited (100 calls/month = ~3/day)
- Free tier is HTTP only (no HTTPS) — unacceptable for an iOS app without ATS exceptions
- Need to verify exact ASX ticker format

### Verdict

Possible but the free tier is too restrictive and the HTTP-only limitation on free is a dealbreaker. Only viable on a paid plan.

---

## Option 4: Twelve Data

**Cost:** Free tier: 800 calls/day (US stocks only). ASX requires Pro plan: US$229/month
**ASX support:** Yes, but only on Pro tier (delayed data)
**Historical data:** Yes, from 1982

### Pros
- High-quality, well-documented API
- Excellent historical depth

### Cons
- **ASX data requires US$229/month Pro plan** — far too expensive for this use case
- Free tier is US-only

### Verdict

Not viable. Way too expensive for 5–10 ASX stocks.

---

## Option 5: Google Sheets GOOGLEFINANCE()

**Cost:** Free
**ASX support:** Yes — format `ASX:BHP`
**Historical data:** Yes (daily/weekly/monthly)

### Usage

```
=GOOGLEFINANCE("ASX:CBA", "price")
=GOOGLEFINANCE("ASX:BHP", "close", DATE(2024,1,1), DATE(2024,12,31), "DAILY")
```

### Pros
- Completely free
- No API key
- Covers ASX

### Cons
- **Not accessible via API** — only works inside Google Sheets
- Historical data cannot be exported via Sheets API (returns `#N/A`)
- Not suitable for programmatic access from an iOS/macOS app
- Would require scraping a Google Sheet as a middleman — fragile and ugly

### Verdict

Not viable for an app. Useful as a manual reference or verification tool.

---

## Option 6: ASX.com.au Direct (Undocumented)

**Cost:** Free
**ASX support:** Obviously yes
**Historical data:** Limited (current prices only)

### Endpoints

```
https://www.asx.com.au/asx/1/share/{ticker}
https://asx.api.markitdigital.com/asx-research/1.0/companies/...
```

### Pros
- Direct from the exchange

### Cons
- ASX added CAPTCHA/security from Feb 2024 — automated access now blocked
- No historical data
- Undocumented and explicitly restricted
- Only current prices, no daily close history

### Verdict

No longer viable. ASX has actively blocked automated access.

---

## Option 7: Finnhub

**Cost:** Free tier: US stocks only. International: US$11.99–99.99/month
**ASX support:** Yes, on paid plans
**Historical data:** Yes

### Pros
- Good API, well documented
- Relatively cheap paid tiers

### Cons
- Free tier doesn't include ASX
- Still a paid service for Australian data

### Verdict

Possible if a paid source is needed, but EODHD is cheaper and more focused on EOD data.

---

## Option 8: iTick

**Cost:** Free tier: 5 REST calls/minute, 1 WebSocket connection
**ASX support:** Unclear — marketing mentions Australia but pricing page lists HK, US, A-shares
**Historical data:** Available via `/stock/kline` endpoint

### Pros
- Free tier exists
- REST + WebSocket

### Cons
- Australian coverage not confirmed on free tier
- Very new/unknown provider
- 5 calls/minute is fine for this use case but documentation quality is uncertain
- Primarily focused on Asian markets (HK, China)

### Verdict

Too uncertain. Would need to verify ASX coverage actually works before committing.

---

## Recommendation

### Primary: Yahoo Finance v8 API (Option 1)

For a personal-use app tracking 5–10 ASX stocks:

1. **Use the Yahoo Finance v8 API directly** (not through a third-party Swift package — they add dependency risk and may lag behind API changes). The endpoint is simple enough to call with `URLSession`.

2. **Ticker format:** `{ASX_CODE}.AX` (e.g., `BHP.AX`, `CBA.AX`, `WES.AX`)

3. **Daily update:** One API call per stock per day to fetch the latest close. For 10 stocks, that's 10 calls/day — trivially within any rate limit.

4. **Historical backfill:** On first add, fetch full history with `period1=0&period2={now}&interval=1d`. Cache locally.

5. **Design with a provider protocol** so the data source can be swapped to EODHD or another paid provider if Yahoo breaks.

### Fallback: EODHD at US$19.99/month (Option 2)

If Yahoo Finance becomes unreliable, EODHD's "All World" plan at ~US$20/month is the best paid alternative. Its free tier (20 calls/day) could also work as a secondary validation source.

### Implementation sketch

```swift
/// Domain layer
protocol StockPriceProvider: Sendable {
    func dailyClose(ticker: String, from: Date, to: Date) async throws -> [StockPrice]
    func latestClose(ticker: String) async throws -> StockPrice
}

struct StockPrice: Sendable, Codable {
    let date: Date
    let open: Decimal
    let high: Decimal
    let low: Decimal
    let close: Decimal
    let adjustedClose: Decimal
    let volume: Int
}

/// Yahoo Finance implementation
struct YahooFinanceProvider: StockPriceProvider {
    // GET https://query2.finance.yahoo.com/v8/finance/chart/{ticker}.AX
    //   ?period1={unix}&period2={unix}&interval=1d
    // Headers: User-Agent required
}
```

This follows the same provider-protocol pattern used for exchange rates and crypto prices in the existing codebase.
