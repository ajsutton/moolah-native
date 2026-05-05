// Shared/PriceCacheCap.swift

import Foundation

/// Clamps `date` to one UTC calendar day before `now()`.
///
/// All three price-cache services (FX rates, stock prices, crypto prices)
/// route same-day-as-now requests to the previous day so the cache only
/// ever stores finalised closes. Yahoo's `chart?interval=1d` endpoint
/// returns a partial bar for the still-running session whose `close` /
/// `adjclose` reflects the latest tick at the moment of the call;
/// persisting that as today's "close" then freezing it (cache hits never
/// re-fetch) was reproducing as VGS.AX showing a stale intraday print
/// even after the session settled.
///
/// We never need a live price — the analysis panel and reports happily
/// use yesterday's close, and avoiding the same-day fetch keeps a fresh
/// cache run from immediately re-poisoning itself.
///
/// `now` is a closure so tests can pin the clock; production passes
/// `Date.init`. The fallback `return date` is unreachable in practice
/// (`Calendar.date(byAdding:value:to:)` only fails for nonsensical
/// inputs) but keeps the helper non-throwing.
func cappedToYesterday(_ date: Date, now: () -> Date) -> Date {
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(identifier: "UTC") ?? .current
  let startOfToday = utc.startOfDay(for: now())
  guard let yesterday = utc.date(byAdding: .day, value: -1, to: startOfToday) else {
    return date
  }
  return min(date, yesterday)
}
