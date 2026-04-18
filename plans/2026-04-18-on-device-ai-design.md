# On-Device AI — Design Spec

Viability study and architecture for two on-device AI capabilities:

1. **Auto-categorization of imported transactions**, including proposing rules to identify similar transactions in future.
2. **Personalized insights** into the user's finances — meaningful observations, anomalies, trends, and a conversational assistant.

**Privacy is non-negotiable.** All inference and any learning must happen on-device. No network calls, no Private Cloud Compute, no server-side aggregation of user data. This constraint drives every technology choice below.

## Goals

- Auto-suggest a category for every imported transaction, learning from user corrections with no training-pipeline cost.
- Let the user turn an accepted category assignment into a durable rule (substring or regex) that applies to future imports.
- Surface meaningful personalized insights — anomalies, trends, subscription changes, budget burndown, forecasts — ranked to minimise notification fatigue.
- Ship a conversational assistant that answers natural-language questions over the user's actual transaction data ("how much did I spend on coffee last month?") with zero hallucinated numbers.
- Degrade gracefully on devices without Apple Intelligence — the core classifier and the statistical insights must work on any iOS 26 / macOS 26 device.

## Non-Goals

- Server-side ML pipelines or Private Cloud Compute. Full stop.
- Fine-tuning Apple's on-device LLM via the Foundation Models Adapter Training Toolkit (~160 MB adapters, per-OS-version retrain, separate Apple entitlement, Background Assets distribution — not worth the operational cost for a small-team app).
- Federated learning or differentially-private peer comparisons (interesting but out of scope).
- Proactive push notifications for insights in v1 — insights render in-app on open; a notification channel can be added later, gated on fatigue controls.
- Conversational mutations (let the LLM re-categorize transactions or change budgets). Read-only assistant in v1.

## Technology Stack

| Layer | Framework | Role |
|---|---|---|
| Deterministic rules | Swift + `MLGazetteer` | User-authored substring / dictionary match. Fastest, fully explainable. |
| Personal classifier | `NLEmbedding.sentenceEmbedding` + k-NN over SwiftData | Primary categorizer. No training step; adapts instantly to user corrections. |
| Cold-start classifier | `MLTextClassifier` (maxEnt) | ~500 KB `.mlmodelc` seeded from public dataset, used until the user has enough labelled history. |
| Structured generation | `FoundationModels` (`@Generable`, `@Guide`) | Optional fallback for low-confidence k-NN, and for rule synthesis from examples. |
| Conversational assistant | `FoundationModels` + `Tool` protocol | Tool-calling agent over typed finance queries. Apple Intelligence devices only. |
| Statistical detectors | Pure Swift | All insight computation — anomalies, trends, subscriptions, forecasts. Runs on every device. |

### Why this split

The Foundation Models framework (iOS 26+/macOS 26+, ~3B param on-device LLM, 4096-token context) is excellent for three things: structured output via `@Generable`, tool-calling with typed arguments, and natural-language narration of structured facts. It is **bad** as an arithmetic engine and **unavailable** on roughly 30–40% of shipping iPhones (pre-A17 Pro). Any feature that must work for every user cannot depend on it.

The classical Apple ML stack (`CreateML`, `NaturalLanguage`, `CoreML`) works everywhere, is deterministic, and has been production-hardened for years. `NLEmbedding.sentenceEmbedding` ships with the OS (512-d, zero download, 7 languages) and is ideal for k-NN classification over a small per-user corpus. `CreateML` is available at runtime on iOS, so a `MLTextClassifier` can be retrained on-device.

The hybrid approach: classical ML owns the hot paths (classification, insight detection); Foundation Models owns the polish layer (rule synthesis, narration, conversation).

### Availability gating

Every Foundation Models touchpoint must check `SystemLanguageModel.default.availability` and handle:

- `.available` — use.
- `.unavailable(.deviceNotEligible)` — permanently hide LLM-only affordances (assistant panel, "suggest a smarter rule" button).
- `.unavailable(.appleIntelligenceNotEnabled)` — show a one-time nudge linking to Settings, then hide.
- `.unavailable(.modelNotReady)` — **transient**: retry later, do not permanently disable.
- `@unknown default` — treat as unavailable.

---

## Use Case 1 — Auto-categorization & Rule Building

### Architecture

Four layers, evaluated in order. First hit wins; later layers produce suggestions not auto-applies.

**Layer 1 — Deterministic rules (`MLGazetteer`).** User-authored. Substring / token match on the normalised payee string. Fastest, fully explainable, zero ML. Every accepted auto-categorization offers the user a one-tap "always categorize `STARBUCKS*` as Coffee" rule. Rules are persisted, editable, and round-trip through CloudKit via the existing `Category` / `Transaction` repositories.

**Layer 2 — k-NN over sentence embeddings.** Compute a 512-d vector per transaction via `NLEmbedding.sentenceEmbedding(for:)` at import time and persist it alongside the category assignment in SwiftData (new `TransactionEmbedding` entity keyed on transaction id, indexed on account to bound search space). New transactions classify as the majority vote of the top-k (k=3–5) nearest labelled neighbours by cosine similarity, weighted by inverse distance. This is the primary classifier.

Why k-NN wins here:
- No training step. Adapts instantly to every user correction.
- Explainable ("looks like these three transactions you labelled Coffee").
- Works with any number of per-category examples, including 1.
- Robust to category taxonomy changes — renaming a category doesn't invalidate anything.
- Embeddings survive across OS versions (unlike an LLM adapter).

Implementation notes:
- Normalise payee strings first (strip trailing numerics, lowercase, collapse whitespace) before embedding — reduces noise from merchant IDs.
- Embedding compute is fast (milliseconds per transaction on Apple Silicon); batch on import, off-main, publish results via a `@MainActor` store per `guides/CONCURRENCY_GUIDE.md`.
- Cosine similarity over ≤10k vectors is trivial; no need for ANN indexing. If the corpus grows past that, consider a Vamana/HNSW wrapper later.
- Store the embedding as `Data` (float32 × 512 = 2 KB per transaction). At 100k transactions that's 200 MB — acceptable, but consider float16 (1 KB each) if SwiftData pressure becomes an issue.

**Layer 3 — Seed `MLTextClassifier` (cold start).** Ship a ~500 KB maxEnt text classifier trained offline (Create ML app on Mac) against a remapped public dataset (`DoDataThings/us-bank-transaction-categories-v2` on HuggingFace, 68k rows, 17 categories remapped to the app's default category set). Used as the suggestion source until the user has labelled ~20 transactions in an account; after that, k-NN takes over. The seed model remains available as a fallback if k-NN returns no close neighbour (all distances above a threshold).

**Layer 4 — Foundation Models for low-confidence fallback and rule synthesis.** Two distinct uses:

- *Low-confidence fallback.* When both k-NN and the seed classifier produce confidence below threshold, call Foundation Models with the user's category list as a `@Generable` enum and the transaction payee + amount as prompt. Constrained decoding guarantees a valid category. Gated on availability; skipped on unsupported devices (user sees "Uncategorized" and can pick manually — same as today).

- *Rule synthesis.* When the user accepts a category suggestion, offer a "suggest a smarter rule" action. Call Foundation Models with 3–5 examples of similarly-categorized transactions and a `@Generable` struct:
  ```swift
  @Generable struct ProposedRule {
      @Guide(description: "A Swift-compatible regex that matches the payee in all examples.")
      @Guide(.regex(#"^[\p{L}\d\s\*\.\-\|\\/]+$"#))
      let pattern: String
      @Guide(description: "Plain-English description of what this rule matches.")
      let description: String
  }
  ```
  Present the proposed rule to the user for review before saving. User edits before confirm. This is where the LLM earns its keep — novel regex synthesis is painful by hand and trivial for a language model.

### Data flow on import

1. CSV parser produces `Transaction` candidates (existing flow).
2. For each, normalise payee → compute embedding → k-NN lookup in the user's labelled corpus.
3. If match confidence above threshold → suggest category, mark as "auto".
4. If below threshold and seed classifier confidence above threshold → suggest from seed model, mark as "auto (cold)".
5. If still below threshold and Foundation Models available → call LLM with `@Generable` enum, mark as "auto (ai)".
6. Otherwise leave uncategorized.
7. User reviews; accept/edit writes back, updating embeddings store and (optionally) proposing a new rule.

### Bundle and runtime cost

- Seed `.mlmodelc`: ~500 KB.
- `NLEmbedding.sentenceEmbedding`: zero bundle cost (OS asset).
- Foundation Models: zero bundle cost (OS asset).
- Per-transaction storage: +2 KB embedding in SwiftData.
- Per-transaction import cost: ~1 ms embedding + ~1 ms k-NN lookup on M-series; roughly 10× on iPhone. A 500-row CSV import adds <1 s.

---

## Use Case 2 — Personalized Insights (Deep Dive)

The core product insight: **most of what users want from "AI insights" is statistical, not generative.** The heavy lifting is deterministic detectors over existing data (transactions, daily balances, earmarks, scheduled transactions, investment positions — all of which already exist in stores surveyed below). The LLM is a narration and conversation layer on top, not a source of truth.

### Data available

The app already exposes a rich substrate via existing stores:

- `TransactionStore` — transactions with legs, categories, payees, earmarks, types, recur fields.
- `AccountStore` — bank/credit/asset/investment accounts with multi-instrument positions.
- `CategoryStore` — hierarchical categories with path helpers.
- `EarmarkStore` — named budgets with savings goals, date windows, line items per category, saved/spent positions.
- `AnalysisStore` — daily balances with balance/earmarked/available/investment/net-worth breakdowns, actuals + forecast, extrapolation.
- `ReportingStore` — monthly income/expense aggregates, category trends over time, capital gains result.
- `InvestmentStore` / `TradeStore` — positions, per-instrument P&L, capital gain events with CGT holding-period logic.

This is more than enough to build a strong insights layer without any new data acquisition. The work is in detection, ranking, and presentation.

### Insight Catalog

Each entry lists the insight, the detection technique, the required data, the difficulty, and whether it needs Apple Intelligence.

#### A. Recurring & Subscription Management

1. **Subscription detection** — cluster transactions by (normalised payee, ~stable amount, periodicity). Technique: normalise payee string → group → within each group, compute inter-arrival gap histogram → flag clusters with ≥3 occurrences, amount variance ≤5–10%, and a dominant period near {7, 14, 30, 90, 365} days. Plaid's published approach and BBVA's weighted DBSCAN are references. **Data**: transactions. **Difficulty**: Medium (weeks). **LLM**: no.

2. **Price-hike detection** — within a confirmed subscription stream, flag latest amount > rolling median + tolerance. **Data**: output of (1). **Difficulty**: Easy. **LLM**: no (narration optional).

3. **Duplicate subscription** — cluster active subscription streams by category + price proximity (e.g., two ~$15/mo streaming subs). **Data**: output of (1) + categories. **Difficulty**: Easy. **LLM**: no.

4. **Subscription cancellation candidate** — flag streams with declining usage signal (proxy: transaction cadence lengthening, or no associated merchant activity in N months for bundled services). **Data**: (1). **Difficulty**: Medium; signal is weak without usage data.

5. **New recurring detected** — a subscription stream matured (≥3 occurrences) this week. **Data**: (1). **Difficulty**: Easy. **LLM**: no.

#### B. Anomaly / Surprise Spending

6. **Category anomaly ("dining up 40% this month")** — STL decomposition of monthly category series (seasonal + trend + remainder); flag |remainder| > k·σ(remainder). STL handles recurring seasonal bumps (December, summer travel) automatically. **Data**: `ReportingStore` monthly aggregates. **Difficulty**: Medium. **LLM**: no (narration optional).

7. **Large-transaction anomaly** — per-category MAD-z score (Median Absolute Deviation, 3.5× threshold). Robust to outliers, unlike raw z-score. Bayesian shrinkage toward a global prior for sparse categories. **Data**: transactions grouped by category. **Difficulty**: Easy. **LLM**: no.

8. **New-merchant alert** — set difference of this week's payees against all prior history, filtered by amount in top decile. Simple novelty × magnitude. **Data**: transactions. **Difficulty**: Easy. **LLM**: no.

9. **Unusual day-of-month / day-of-week spend** — histogram of spend by DoM/DoW; flag spikes. Useful for "you spent 3× your typical Sunday today". **Data**: transactions. **Difficulty**: Easy. **LLM**: no.

#### C. Trends & Period Comparisons

10. **Monotonic category trend ("dining has been rising for 4 months")** — Mann-Kendall non-parametric trend test + Sen's slope over last N months. Preferred over linear regression because it makes no distributional assumption and handles small N. Apply Benjamini–Hochberg correction across all categories to avoid alert spam from testing 30 categories. **Data**: monthly category aggregates. **Difficulty**: Medium (multiple-comparisons correction matters). **LLM**: narration optional.

11. **Month-over-month / year-over-year deltas** — direct comparison against same period last month/year, by category or overall. **Data**: existing aggregates. **Difficulty**: Easy. **LLM**: no.

12. **Category-mix shift** — change in each category's share-of-wallet between periods. Surface categories whose share moved >N percentage points. **Data**: aggregates. **Difficulty**: Easy. **LLM**: no.

#### D. Cash Flow & Forecasting

13. **Upcoming-bill cash warning** — forecast account balance via `AnalysisStore` (which already does this); flag any day where projected balance < upcoming bill amount, or drops below a user-configurable buffer. **Data**: scheduled transactions + daily balance forecast. **Difficulty**: Easy. **LLM**: no.

14. **Paycheck timing pattern** — detect recurring income streams (same subscription algorithm on positive-amount transactions with payroll-shaped categories); project next paycheck date + amount. **Data**: transactions. **Difficulty**: Medium. **LLM**: no.

15. **Projected month-end balance with confidence** — deterministic: opening balance + scheduled + projected recurring + category-mean drift + error bars from historical residuals. ARIMA and Prophet are overkill for single-user event-driven cash flow. **Data**: existing forecast + residuals. **Difficulty**: Medium. **LLM**: no.

16. **Savings-rate trend** — rolling (income - expenses) / income over N months, with trend test. **Data**: monthly aggregates. **Difficulty**: Easy.

17. **Runway estimate** — at current burn rate, how long does liquid cash last. **Data**: current balance + rolling monthly net outflow. **Difficulty**: Easy.

#### E. Budget Performance (Earmarks)

18. **Earmark burndown projection** — linear extrapolation of spend vs time remaining in earmark window; flag "at current rate, you'll exceed by $X on day Y". **Data**: `EarmarkStore`. **Difficulty**: Easy.

19. **Earmark under-spend ("room to spare")** — positive-framed counterpart. Critical for avoiding scold-app feel. **Data**: `EarmarkStore`. **Difficulty**: Easy.

20. **Savings goal ETA** — at current contribution rate, when is the target reached. **Data**: `EarmarkStore.savingsGoal` + contribution history. **Difficulty**: Easy.

#### F. Savings Opportunities

21. **Idle cash alert** — checking balance persistently above k × 30-day outflow, for > N days. **Data**: `AccountStore` + transaction flow. **Difficulty**: Easy.

22. **Fee spend** — sum of transactions in bank-fee categories over trailing 12 months; benchmark against zero. **Data**: categories + transactions. **Difficulty**: Easy (requires a "fees" tax-category or equivalent tag).

23. **Subscription overspend** — total monthly subscription cost as % of income; flag if > user-configurable threshold. **Data**: (1) + income detection. **Difficulty**: Easy.

#### G. Net Worth & Investments

24. **Net-worth milestone** — crossing round numbers (±10k, 25k, 100k steps), or XX% YoY. **Data**: `AnalysisStore.netWorth`. **Difficulty**: Easy.

25. **Investment concentration risk** — flag single instrument > N% of investable assets. **Data**: `InvestmentStore` positions + valuations. **Difficulty**: Easy.

26. **Top/bottom performer this period** — rank `InstrumentProfitLoss` by unrealized return over period. **Data**: existing. **Difficulty**: Easy.

27. **Capital gains tax-harvest opportunity** — at year-end, identify lots where realising would either zero out gains against losses or use remaining CGT discount room. **Data**: `ReportingStore.capitalGainsResult` + `CapitalGainEvent`. **Difficulty**: Hard (correctness across jurisdictions is effectively a compliance product).

28. **Allocation drift from target** — requires a user-declared target allocation (not yet modelled). **Difficulty**: Medium *after* target-allocation feature ships.

#### H. Income Analysis

29. **Income stability score** — coefficient of variation of detected paycheck amounts + period variance. Used internally to set forecast confidence bands. **Data**: (14). **Difficulty**: Medium.

30. **Missing-paycheck alert** — expected paycheck not received within N days of predicted date. **Data**: (14). **Difficulty**: Easy.

#### I. Conversational Assistant

31. **Natural-language Q&A** — "how much did I spend on coffee last month?" / "show me large grocery runs last summer" / "what's my biggest expense this quarter?" Foundation Models `LanguageModelSession` with tool-calling. Tools (read-only v1):

    - `query_transactions(filter, period, limit)`
    - `compute_total(category?, merchant?, account?, period)`
    - `compare_periods(metric, periodA, periodB, groupBy?)`
    - `list_categories(parent?)` / `list_accounts()` / `list_merchants(period?)`
    - `list_subscriptions(status?, minAmount?)`
    - `forecast_balance(account, horizon)`
    - `net_worth(asOf)`
    - `spending_by_dimension(dimension, period)`
    - `find_unusual_transactions(period, zMin)`
    - `explain_insight(insightID)`

    **Discipline:** the system prompt forbids the LLM from producing any numeric fact except via a tool call. Structured output validates this. Every rendered number in the response carries a citation handle to the tool call that produced it, surfaced as a tap-to-expand source chip. **Data**: all existing stores, exposed as `Tool` conformers. **Difficulty**: Medium-Hard (tool plumbing + prompt hardening + evaluation). **LLM**: yes, required.

32. **Insight explanation** — user taps "why?" on any surfaced insight. LLM turns the raw stats ("dining: $640 vs 6-mo median $410, MAD-z 3.1") into plain English. **Difficulty**: Easy once assistant is built.

33. **Weekly recap narrative** — after candidate insights are detected and ranked, the top 3–5 go to the LLM for a 2-sentence narrative paragraph. Fallback to template strings if LLM unavailable. **Difficulty**: Easy once detectors + ranker ship. **LLM**: optional polish.

#### J. Search & Discovery

34. **Intent-parsed search** — LLM rewrites "large grocery runs last summer" into the existing `TransactionFilter` struct (which is already `@Generable`-friendly). **Difficulty**: Easy. **LLM**: yes.

### Insight Ranking & Fatigue

With N candidate insights per surface refresh, we need a ranker. Without one, the feature becomes a notification spambot — the research is unambiguous that 39% of users disable notifications on apps that over-signal. The scoring model:

```
score(insight) = w_surprise  · statistical_strength
               + w_action    · actionability        // 0/0.5/1
               + w_magnitude · log(|$ impact| + 1)
               + w_recency   · exp(-age / τ)
               + w_interest  · declared_interest
               - w_fatigue   · recent_dismissals(type)
```

- **Surprise**: the z-score / MAD-z / trend test statistic itself, normalised.
- **Actionability**: "cancel this" = 1, "review this" = 0.5, "noted" = 0. Kill non-actionable insights; they are the single biggest fatigue source.
- **Magnitude**: log dollars. A $5 anomaly at 4σ is statistically interesting but useless.
- **Recency**: exponential decay, τ ≈ 7 days.
- **Declared interest**: user pinned categories / earmarks.
- **Fatigue**: per-insight-type decay after recent dismissal. This is the single most important anti-annoyance lever.

Display cap: 3–5 per surface. **Guarantee one positive-framed insight per week** ("you under-spent groceries", "net worth crossed $X", "savings goal 80% reached") to avoid the app becoming a scold.

### Where LLM Is Load-Bearing vs Cosmetic

**Load-bearing (Foundation Models is required):**
- Conversational Q&A (31) — the whole point is natural-language intent + tool use.
- Intent-parsed search (34) — same reason.
- Rule synthesis in categorization — LLM produces the regex.

**Cosmetic polish (better with FM, acceptable without):**
- Weekly recap narrative (33) — template string fallback is fine.
- Insight explanation (32) — same.
- Merchant-name cleanup — can be done with rules, LLM is slicker.

**Not LLM work (do not put the model on the hot path):**
- Any insight detection. Period. The model cannot be trusted to "find trends" — it will confabulate. Deterministic detectors produce candidates; the LLM only narrates.
- Any arithmetic. Ever. Tool-call, then narrate.
- Ranking. A scoring function beats prompt-engineered "pick the best" every time for cost and reproducibility.

### Discoverability & Surfaces

Where insights live in the UI (out of scope to design here, but relevant to the architecture):

- **Dashboard "For You" panel** — top 3–5 ranked insights, refreshed on open.
- **Per-category detail view** — category-scoped anomalies and trends when drilling in.
- **Per-account view** — cash-flow forecast + upcoming-bill warnings.
- **Assistant sheet/pane** — conversational Q&A, surfaced from toolbar or ⌘-K.
- **Weekly recap** — opt-in, rendered on Monday open of the week after.

No push notifications in v1. Fatigue controls first, then notifications.

---

## Implementation Phasing

Phasing aligns with difficulty and dependencies.

### Phase 1 — Foundations (deterministic, ships to every device)

1. Categorization: rules layer + k-NN embeddings + seed `MLTextClassifier`. No Foundation Models yet.
2. Insight detectors (Easy tier): MoM/YoY (11), large-tx anomaly (7), new-merchant (8), upcoming-bill warning (13), idle-cash (21), net-worth milestone (24), earmark burndown (18), earmark under-spend (19), savings goal ETA (20), concentration risk (25), top/bottom performer (26), category-mix shift (12), new recurring detected (5, once subscription detector lands — see Phase 2).
3. Ranking + fatigue layer. Ship with the detectors; do not ship detectors without a ranker.
4. Dashboard "For You" panel as the sole surface.
5. Template-string narration (no LLM yet).

### Phase 2 — Subscriptions & Statistical Rigor

6. Subscription detection (1) + price-hike (2) + duplicate (3) + new-recurring (5).
7. Paycheck detection (14) + missing-paycheck (30).
8. Category STL anomaly (6).
9. Mann-Kendall trend detection (10) with BH correction.
10. Forecast with confidence bands (15).
11. Runway (17), savings-rate trend (16), subscription overspend (23), fee spend (22).

### Phase 3 — Foundation Models Integration

12. Availability gating infrastructure.
13. Rule synthesis in categorization.
14. Low-confidence fallback classifier.
15. Weekly recap narrative (optional polish layer).
16. Insight explanation ("why?").

### Phase 4 — Conversational Assistant

17. Tool protocol conformers for existing stores.
18. `LanguageModelSession` wiring with tool serialization.
19. Citation/provenance rendering.
20. Intent-parsed search.
21. Safety & eval harness (prompt regressions per OS point release).

### Phase 5 — Advanced (only if telemetry justifies)

22. Allocation drift (28) — blocked on target-allocation feature.
23. Capital-gains tax-harvest (27) — defer until AU + US CGT logic proven; effectively compliance work.
24. Notification channel (opt-in, frequency controls first).

---

## Privacy & Security

- All inference on-device. No transaction data leaves the device for any AI feature.
- No telemetry on categorization accuracy or insight dismissals by default. If added later, must be aggregate, opt-in, and free of merchant names / amounts.
- Foundation Models never receives raw transactions in prompts for narration — only pre-aggregated statistics. Raw transactions only reach the assistant via typed tool return values, never as prompt text.
- Embeddings, labels, and rules stored in the existing SwiftData backing store and sync via CloudKit like any other user data. No separate backend.
- When Foundation Models is unavailable, no fallback calls any external service. The feature simply hides.

## Risks & Mitigations

- **Device eligibility skew.** ~30–40% of supported iPhones lack A17 Pro/A18. Mitigation: every LLM feature is additive; core classifier and core insights work everywhere.
- **Model-version drift.** FM outputs may differ subtly across OS point releases. Mitigation: pin snapshot tests per release; prompt changes go through CI with fixed seeds.
- **Insight fatigue.** The biggest product risk. Mitigation: ranker + fatigue penalty from day one, display cap, guaranteed positive framing weekly, no notifications in v1.
- **Conversational hallucination.** LLM inventing numbers is the feature-killer. Mitigation: system-prompt rule forbidding un-tool-sourced numerics; citation chips on every numeric claim; read-only tools only; evaluation harness with adversarial prompts.
- **Multi-currency correctness.** Insight math must respect the instrument-conversion rules in `guides/INSTRUMENT_CONVERSION_GUIDE.md`. A rate-failure on a conversion must mark the insight unavailable, not produce a partial total. Mitigation: route all aggregations through `InstrumentConversionService`; add conversion-failure tests per insight detector.
- **Sign convention.** Per `CLAUDE.md`, never `abs()` amounts. Detectors must handle refunds (positive expense) correctly. Mitigation: dedicated tests on sign-edge cases (refund mixed with purchase, chargebacks, etc.).
- **Concurrency.** All inference and batch computation runs off-main; state lands on `@MainActor` stores. Follow `guides/CONCURRENCY_GUIDE.md`.

## Starting Points

- **Seed classifier dataset**: `DoDataThings/us-bank-transaction-categories-v2` (HuggingFace, ~68k rows, 17 categories, realistic noise).
- **Alternative/larger**: `mitulshah/transaction-categorization` (4.5M rows, 10 categories, 5 countries).
- **Reference implementations**: `eli-goodfriend/banking-class`, `j-convey/BankTextCategorizer` for feature-engineering patterns.
- **Embedding store**: `SimilaritySearchKit` (ZachNagengast) if we outgrow a SwiftData-backed linear scan.
- **Apple reference sessions**: WWDC25 286/301/259 (Foundation Models), WWDC23 10044 (Create ML enhancements), WWDC22 10019 (Create ML Components), WWDC23 10042 (Natural Language multilingual).

## Open Questions

- Ranker weights: start hand-tuned, revisit once we have dismissal telemetry (opt-in, aggregate).
- Embedding storage format: float32 vs float16 — decide after measuring real-world corpus size impact on SwiftData.
- Category taxonomy for seed classifier: mapping public dataset's 17 categories onto the app's user-defined hierarchy needs a default-mapping design (per-user customisable).
- Assistant memory across sessions: v1 is stateless (new `LanguageModelSession` per conversation); decide later whether to persist transcripts, and how that interacts with CloudKit sync and privacy.
- Weekly recap delivery: in-app only v1; push notification is a Phase 5 question pending fatigue controls.
