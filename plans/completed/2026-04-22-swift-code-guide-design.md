# Swift Code Guide, Code-Review Agent, and SwiftLint Adoption — Design

**Date:** 2026-04-22
**Status:** Approved design, pending implementation plan
**Tracking:** this doc; related issue [#249](https://github.com/ajsutton/moolah-native/issues/249) (CI TODO-issue enforcement)

---

## 1. Motivation

The project has eight guides totalling ~4,300 lines, but none cover general Swift code style. The existing `guides/STYLE_GUIDE.md` is actually a UI / SwiftUI / HIG guide despite its generic name. There is no reviewer agent for Swift code style, no SwiftLint, and the codebase has grown without a written style policy.

This design introduces:

1. A general Swift code style guide (`guides/CODE_GUIDE.md`) scoped tightly and grounded in published community best practice — not in the current codebase's percentiles.
2. A `@code-review` agent that enforces the guide semantically, complementary to (not overlapping with) SwiftLint.
3. SwiftLint, configured to complement (not overlap with) `swift-format`, with autocorrect wired into `just format` and a baseline-based rollout so the adoption doesn't block on a codebase-wide refactor.
4. Incidental renames and cross-reference updates to make the guide taxonomy unambiguous.
5. A shift from `BUGS.md` to GitHub issues for TODO tracking, with CI enforcement that referenced issues stay open (tracked separately as issue [#249](https://github.com/ajsutton/moolah-native/issues/249)).

## 2. Deliverables

- **Rename** `guides/STYLE_GUIDE.md` → `guides/UI_GUIDE.md`. Update every reference in `CLAUDE.md`, `.claude/agents/ui-review.md`, and any inter-guide crosslinks.
- **New** `guides/CODE_GUIDE.md` — 400–600 lines, rule-form, cited.
- **New** `.claude/agents/code-review.md` — matches the shape of existing review agents.
- **New** `.swiftlint.yml` + `.swiftlint-baseline.yml`.
- **Updated** `justfile` — `just format` and `just format-check` run both tools; `just lint` remains a `format` alias.
- **Updated** `CLAUDE.md` — new "Code Style & Idioms" section, "UI Design & Style Guide" section points at `UI_GUIDE.md`, "Bug Tracking" section replaced with GitHub-issues guidance, "Agents" section gains `@code-review`, "Pre-Commit Checklist" gains SwiftLint step.
- **Retire** `BUGS.md` — migrate entries to GitHub issues, delete the file.

Six independent PRs, merged in the order listed (rename → guide → SwiftLint → agent → CLAUDE.md refresh → BUGS.md retirement).

## 3. `guides/CODE_GUIDE.md` — scope

Target length: 400–600 lines. Tone and structure match existing `CONCURRENCY_GUIDE.md` (rule-form, scannable, examples only where ambiguous, explicit cross-references out for non-scope topics).

### 3.1 In scope

1. **File organization** — one primary type per file (exceptions: DTO families, co-located delegate protocols); `// MARK:` sectioning in large files; extension-per-protocol-conformance; trailing `private extension Self` for private helpers; delegate protocol declared *before* its delegator when co-located.
2. **File size thresholds** (SwiftLint defaults, community-consensus): file length warn 400 / error 1000; type body warn 250 / error 350; function body warn 50 / error 100; cyclomatic complexity warn 10 / error 20; nesting: type ≤ 1, function/statement ≤ 2; line length 100 (already in `.swift-format`); identifier length warn 3–40 / error 2–60; large-tuple warn 2 / error 3. Tests exempt from file-length and function-length limits.
3. **Naming** — Apple API Design Guidelines verbatim on clarity at use site, omit needless words, name per role not type, preposition phrases for side effects, mutating/nonmutating `-ed`/`-ing` pairs, factory-method `make…` prefix, uniform acronym casing (`URLFinder`, `htmlBodyContent`, `profileID`). Project suffix conventions: `Controller`, `ViewController`, `Delegate`, `Store` (already the `@Observable` convention) are fine; `Manager` sparingly; avoid `Helper`, `Utility`, `Factory` as type names. Avoid type-suffix in properties (`user.name`, not `user.userName`).
4. **Types — value vs reference** — `struct` by default (cite Apple's "Choosing Between Structures and Classes"); `class` only for identity / shared mutable state / Obj-C interop; `final class` always (NetNewsWire convention, 253 `final class` vs 12 bare). `enum` for closed sets; `indirect enum` for recursive. `actor` discussion deferred to `CONCURRENCY_GUIDE.md`.
5. **Protocol design** — small, focused protocols; extension-based conformance; PATs (`associatedtype`) preferred over existentials for generic abstractions; `any P` is mandatory spelling (Swift 6 / SE-0335) and reserved for heterogeneous storage / type erasure; prefer `some P` for returns.
6. **Access control** — language default is `internal`; don't write `internal` explicitly; prefer `private` for members; `fileprivate` only when the compiler requires (file-scoped declarations fall through `swift-format`'s `fileScopedDeclarationPrivacy`); `public` only at module boundaries (currently `Domain/`).
7. **Error handling** — `throws` over `Result`; **do not** reach for typed throws `throws(E)` as a default — [SE-0413 explicitly states untyped `throws` remains the better default](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md). Typed throws reserved for module-internal code that handles every case, for generic rethrowing, and Embedded Swift. No silent `try?` without logging. Rollback pattern in stores (cross-reference CLAUDE.md).
8. **Optionals** — `if let` / `guard let` / `??`; no force-unwrap, force-try, or `as!` in production; allowed in tests, preferring `XCTUnwrap`/`try`; no implicitly unwrapped optionals outside IBOutlet edge cases (effectively none in this codebase).
9. **Initializers** — synthesized memberwise for data types; custom init only for invariants; complex construction via `static func make(…)` factories.
10. **Extensions** — one extension per protocol conformance; trailing `private extension Self` for private helpers; avoid extending Foundation / standard-library types from feature code.
11. **Generics & opaque types** — prefer `some P` for returns where ergonomics allow; generics when the call site cares about the concrete type; type erasure (`AnyFoo`) only when necessary.
12. **Closures** — trailing closure for the last argument; `[weak self]` only when capturing a reference type with a plausible retain cycle; explicit captures when semantics matter.
13. **Collection idioms** — `first(where:)` over `filter { }.first`; `contains(where:)`; `isEmpty` over `count == 0`; `reduce(into:)` over `reduce`; `for` over `forEach` for side-effecting loops.
14. **Control flow** — `switch` for closed sets; `guard` for early exit; avoid > 3 levels of nesting (extract function).
15. **Currency & sign convention** — cross-reference CLAUDE.md: `Int` cents; preserve sign; no `abs()`; `MonetaryAmount.parseCents(from:)` is the single parser.
16. **Dependency injection** — `@Environment(BackendProvider.self)`; no singletons; no `UserDefaults.standard` outside a wrapper; `Date()` only at boundaries (tests inject).
17. **SwiftUI-Swift idioms** (non-overlap with `UI_GUIDE.md`) — `@Observable` store shape; thin views; `EnvironmentValues` for services; `@State` only for local UI state; `@Binding` pass-through chains ≤ 1 level.
18. **Documentation** — `///` for public/domain API; WHY not WHAT; DocC-compatible sections (`- Parameters:`, `- Returns:`, `- Throws:`); no block comments; no commented-out code.
19. **TODOs and FIXMEs** — every `TODO` or `FIXME` must reference a GitHub issue using the form `TODO(#N):` or `FIXME(#N):` plus the full URL; bare `TODO:` disallowed. Enforcement: CI blocks closing an issue while live TODOs still reference it (tracked by [#249](https://github.com/ajsutton/moolah-native/issues/249)).
20. **Imports** — `swift-format` orders them; guide rule is about *purpose* (no `SwiftUI` / `SwiftData` / `URLSession` / `Backends/` imports in `Domain/`; no backend-specific imports in `Features/`).

### 3.2 Explicit non-goals — cross-reference only

- Concurrency, `Sendable`, actor isolation, `Task` hygiene → `CONCURRENCY_GUIDE.md`.
- Test structure, fixtures, seeds → `TEST_GUIDE.md` / `UI_TEST_GUIDE.md`.
- CKSyncEngine, change tracking → `SYNC_GUIDE.md`.
- Currency conversion correctness → `INSTRUMENT_CONVERSION_GUIDE.md`.
- SwiftUI layout, colors, typography → `UI_GUIDE.md`.
- Signpost / performance work → `BENCHMARKING_GUIDE.md`.
- App Store metadata, entitlements, icons → `@appstore-review` agent + `scripts/validate-appstore.sh`.

### 3.3 Citations

The guide cites primary sources inline. Full list:

| Source | URL | Used for |
|---|---|---|
| Apple Swift API Design Guidelines | https://www.swift.org/documentation/api-design-guidelines/ | Naming, labels, side-effect grammar, factories |
| Apple: Choosing Between Structures and Classes | https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes | Struct-by-default |
| SE-0413 Typed Throws | https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md | Untyped `throws` remains default |
| SE-0335 Introduce existential any | https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md | Explicit `any P` |
| WWDC 2015 Session 408 (POP) | https://developer.apple.com/videos/play/wwdc2015/408/ | Protocol-oriented design |
| WWDC 2015 Session 414 (Value Types) | https://developer.apple.com/videos/play/wwdc2015/414/ | Value-type rationale |
| Apple swift-format Configuration | https://github.com/apple/swift-format/blob/main/Documentation/Configuration.md | Formatter baseline |
| apple/swift DocumentationComments.md | https://github.com/apple/swift/blob/main/docs/DocumentationComments.md | DocC conventions |
| SwiftLint Rule Directory | https://realm.github.io/SwiftLint/rule-directory.html | Every numeric threshold |
| NetNewsWire CodingGuidelines.md | https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/CodingGuidelines.md | Final class, extension organization, delegate ordering |
| NetNewsWire `.swiftlint.yml` | https://github.com/Ranchero-Software/NetNewsWire/blob/main/.swiftlint.yml | Real-world rule subset |
| Google Swift Style Guide | https://google.github.io/swift/ | Line length, access control |
| Airbnb Swift Style Guide | https://github.com/airbnb/swift | Formatter-first approach |
| Kodeco Swift Style Guide | https://github.com/kodecocodes/swift-style-guide | Naming, access control |
| LinkedIn Swift Style Guide | https://github.com/linkedin/swift-style-guide | Force-unwrap stance, section-numbered rules |
| Brent Simmons — How NetNewsWire Handles Threading | https://inessential.com/2021/03/20/how_netnewswire_handles_threading.html | Main-thread-by-default philosophy |
| SonarSource Cognitive Complexity | https://www.sonarsource.com/blog/cognitive-complexity-because-testability-understandability/ | Cyclomatic ≤ 10, cognitive ≤ 15 |

## 4. `.swiftlint.yml` — configuration

Division of responsibilities:

- `swift-format` owns all *layout and formatting* rules (line length, trailing commas, brace placement, spacing, import ordering). Authoritative for those.
- SwiftLint owns *policy and idiom* rules that `swift-format` doesn't cover (body sizes, complexity, force-unwrap, collection idioms, naming length, etc.).

### 4.1 Thresholds

```yaml
file_length:
  warning: 400
  error: 1000
type_body_length:
  warning: 250
  error: 350
function_body_length:
  warning: 50
  error: 100
cyclomatic_complexity:
  warning: 10
  error: 20
nesting:
  type_level:
    warning: 1
  function_level:
    warning: 2
identifier_name:
  min_length:
    warning: 3
    error: 2
  max_length:
    warning: 40
    error: 60
  excluded: [id, x, y, i, j, n, ok, to]
large_tuple:
  warning: 2
  error: 3
```

### 4.2 Disabled rules — `swift-format` territory

`line_length`, `trailing_comma`, `opening_brace`, `closure_spacing`, `colon`, `comma`, `operator_whitespace`, `return_arrow_whitespace`, `statement_position`, `trailing_whitespace`, `vertical_whitespace`, `sorted_imports`.

### 4.3 Opt-in rules enabled

`array_init`, `attributes`, `closure_body_length`, `closure_end_indentation`, `collection_alignment`, `contains_over_filter_count`, `contains_over_filter_is_empty`, `contains_over_first_not_nil`, `contains_over_range_nil_comparison`, `convenience_type`, `discouraged_optional_boolean`, `discouraged_optional_collection`, `empty_collection_literal`, `empty_count`, `empty_string`, `enum_case_associated_values_count`, `explicit_init`, `fallthrough`, `fatal_error_message`, `file_header`, `file_name`, `first_where`, `flatmap_over_map_reduce`, `force_cast`, `force_try`, `force_unwrapping`, `identical_operands`, `implicit_return`, `implicitly_unwrapped_optional`, `joined_default_parameter`, `last_where`, `legacy_multiple`, `let_var_whitespace`, `literal_expression_end_indentation`, `lower_acl_than_parent`, `modifier_order`, `multiline_arguments`, `multiline_parameters`, `nimble_operator`, `operator_usage_whitespace`, `optional_enum_case_matching`, `overridden_super_call`, `pattern_matching_keywords`, `prefer_self_type_over_type_of_self`, `prefer_zero_over_explicit_init`, `private_action`, `private_outlet`, `prohibited_super_call`, `reduce_into`, `redundant_nil_coalescing`, `redundant_type_annotation`, `sorted_first_last`, `static_operator`, `strict_fileprivate`, `toggle_bool`, `unavailable_function`, `unneeded_parentheses_in_closure_argument`, `untyped_error_in_catch`, `unused_declaration`, `unused_import`, `vertical_parameter_alignment_on_call`, `yoda_condition`.

### 4.4 Per-rule relaxations

```yaml
force_try:
  severity: warning
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**
    - MoolahBenchmarks/**
    - UITestSupport/**
force_cast:
  severity: warning
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**
    - MoolahBenchmarks/**
    - UITestSupport/**
force_unwrapping:
  severity: warning
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**
    - MoolahBenchmarks/**
    - UITestSupport/**
implicitly_unwrapped_optional:
  severity: warning
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**
file_length:
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**
type_body_length:
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**
function_body_length:
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**
```

### 4.5 Path exclusions

```yaml
excluded:
  - .build
  - .worktrees
  - Moolah.xcodeproj
  - build
  - scripts
  - fastlane
```

### 4.6 Tooling integration

- **Install:** `brew install swiftlint`; added to README and project bootstrap docs.
- **`just format`** runs `swift-format` first (layout normalization), then `swiftlint lint --fix` (semantic autocorrect).
- **`just format-check`** runs `swift-format`'s existing diff check, then `swiftlint lint --baseline .swiftlint-baseline.yml --strict` (fails on any *new* warning beyond the baseline, preventing drift).
- **CI** — no new workflow; existing `just format-check` step is updated to install SwiftLint.

### 4.7 Baseline-based rollout

Introducing SwiftLint to a ~80k-line codebase will generate many violations day one. We use SwiftLint's built-in baseline feature to gate new code without blocking on a codebase-wide refactor:

1. Land `.swiftlint.yml` + tooling wiring.
2. Run `just format` once; commit the autocorrected diff.
3. Generate `.swiftlint-baseline.yml` via `swiftlint lint --write-baseline`.
4. CI runs `swiftlint lint --baseline .swiftlint-baseline.yml --strict` — only *new* violations fail.
5. Violation cleanup is tracked as per-rule tech-debt issues (see §4.8).

When a rule's baseline entries drop to zero, it is removed from the baseline file by regenerating against a clean tree — the baseline only shrinks over time.

### 4.8 Tech-debt tracking for deferred rules

After generating the initial baseline, for every rule that has at least one baseline entry *or* has been explicitly placed in `disabled_rules:` because the existing violation volume is unmanageable:

- Open a GitHub issue titled `SwiftLint cleanup: <rule_name>`.
- Body: violation count, a sample of the top offending files, and a "done when" criterion (baseline empty → remove from baseline file; or: `disabled_rules:` entry removed once <criterion>).
- Labels: `tech-debt`, `swiftlint-cleanup`.
- Reference the issue number as a comment next to the rule in `.swiftlint-baseline.yml` (or in `disabled_rules:`), so the lineage is visible from the config.

**Out of scope for this tracking:** rules disabled because `swift-format` owns the concern (§4.2). Those are configuration, not debt.

**Threshold for full-disable vs baseline:** if a rule has > 500 violations, or its violations aren't autocorrectable and require design-level refactors, prefer putting it in `disabled_rules:` with a tracking issue rather than a massive baseline entry. This is a judgement call made when the baseline is first generated.

## 5. `.claude/agents/code-review.md` — agent design

Invoked as `@code-review`. Style matches existing agents (`concurrency-review`, `ui-review`).

### 5.1 Frontmatter

```yaml
---
name: code-review
description: Reviews Swift code for compliance with guides/CODE_GUIDE.md and project
  architecture conventions in CLAUDE.md. Checks naming, API design, type choice,
  protocol design, error handling, optional discipline, extension organization,
  and thin-view discipline. Use after writing or significantly modifying any
  production Swift file, before committing, or when investigating design smells.
tools: Read, Grep, Glob, Bash
model: sonnet
color: blue
---
```

### 5.2 Checklist

**A — Architectural conformance (from CLAUDE.md):**
- Domain isolation (`Domain/` imports nothing from SwiftUI/SwiftData/URLSession/Backends).
- Repository access only via `@Environment(BackendProvider.self)` + protocols.
- Thin views — no multi-step async, no error formatting, no aggregations, no parsing in view methods.
- Store shape — `@MainActor @Observable`, state rollback on failure, error surfaced.
- Currency sign convention — no `abs()` on monetary values, sign preserved through arithmetic.
- Singleton / global sniffing — flags `UserDefaults.standard`, non-boundary `Date()`, static mutable state.

**B — Swift-idiom quality (from CODE_GUIDE.md):**
- Naming — Apple-guideline violations (type-name-in-property, cryptic abbreviations, `Helper`/`Utility`/`Factory` containers, missing prepositions, assertion-form booleans).
- Type choice — `class` where `struct` would do; missing `final`; `enum` missed for closed sets.
- Protocol design — fat protocols, gratuitous existentials, inline conformance bodies.
- Error handling — silent `try?`, typed throws where untyped is cleaner, `Result` where `async throws` would be.
- Optional discipline — force-unwraps or `as!` in production (contextual cases SwiftLint may miss).
- Extension organization — multiple unrelated conformances in one extension; private helpers scattered.
- Closure captures — `[weak self]` missing where cycle possible, or gratuitous where cycle impossible.
- Generics — gratuitous `<T>`, missed `some P`.
- Dead / commented-out code.
- TODO/FIXME without `(#N)` GitHub-issue reference.

**C — API surface:**
- Access control leakage (`public` on module-internal, accidental re-export).
- Parameter label quality (does the call site read?).
- Default-argument opportunities to collapse overload families.
- Initializer ergonomics — hand-written memberwise, non-trivial work in init.

**D — Documentation:**
- Missing `///` on public domain types/methods.
- WHAT-describing docstrings (should be WHY).
- Malformed DocC sections.
- `// MARK:` missing in files > 300 lines.

**E — File organization:**
- Filename mismatch with primary type (beyond what SwiftLint `file_name` catches).
- Delegate protocol co-location (should be in same file, before its delegator, when single-consumer).
- Unrelated types stuffed together.

### 5.3 Pre-declared false-positives

- `UserDefaults.standard` inside a dedicated wrapper type.
- `Date()` in views for display-only formatting.
- `@unchecked Sendable` on `CloudKitBackend` (concurrency-review exemption).
- `MonetaryAmount(cents: max(0, -serverAmount.cents))` — documented sign pattern from CLAUDE.md.
- Large-file exemptions granted in `.swiftlint.yml` are valid.

### 5.4 Output format

```markdown
### Issues Found
**Critical:** domain imports, thin-view violations, sign dropping, force-unwrap in production.
**Important:** naming against Apple guidelines, class-where-struct, protocol design, error-swallowing, dead code.
**Minor:** docstring hygiene, `// MARK:` missing in large files, missed default-argument opportunities.

Each issue: `file:line`, rule violated, current behaviour, correct behaviour (with code example).

### Positive Highlights
Specific patterns worth preserving.

### Follow-ups
Out-of-scope items worth filing as issues.
```

### 5.5 Non-overlap with existing agents

- Concurrency / `Sendable` / actor isolation → `@concurrency-review`.
- SwiftUI layout / colors / typography → `@ui-review`.
- Currency conversion correctness → `@instrument-conversion-review`.
- CloudKit sync correctness → `@sync-review`.
- UI test driver invariants → `@ui-test-review`.
- App Store validation → `@appstore-review`.

A complete pre-merge review invokes `@code-review` plus whichever specialists touched the change set. This remains on-demand, not automated.

## 6. Sequencing and PRs

Each step is its own PR, merged to `main` in order:

1. **Rename `STYLE_GUIDE.md` → `UI_GUIDE.md`.** Update references in `CLAUDE.md`, `.claude/agents/ui-review.md`, and any cross-linked guide. Mechanical; small PR.
2. **Write `guides/CODE_GUIDE.md`.** 400–600 lines, per §3.
3. **Add `.swiftlint.yml` + `.swiftlint-baseline.yml`, integrate into `justfile` and CI.** Run `just format` once, commit the autocorrect diff as part of the same PR so reviewers can see the mechanical churn separately from the new config. **Sub-step before merging:** per §4.8, generate one `tech-debt` issue per rule with a non-empty baseline (or each rule full-disabled for volume reasons). List those issue numbers in the PR description.
4. **Add `.claude/agents/code-review.md`.** Per §5.
5. **Refresh `CLAUDE.md`:** new "Code Style & Idioms" section pointing at `CODE_GUIDE.md`; "UI Design & Style Guide" section points at `UI_GUIDE.md`; "Bug Tracking" section rewritten around GitHub issues; "Agents" section gains `@code-review`; "Pre-Commit Checklist" gains the SwiftLint lint step.
6. **Retire `BUGS.md`.** Migrate tracked entries to GitHub issues (currently includes the reports refresh loop per auto-memory). Delete the file. No `CLAUDE.md` change here — that landed in step 5.

**Dependencies:**

- Step 1 must land first. Every later step would otherwise reference a mid-flight rename.
- Steps 2 (CODE_GUIDE), 3 (SwiftLint) are independent of each other.
- Step 4 (code-review agent) depends on step 2 — the agent prompt reads `CODE_GUIDE.md`.
- Step 5 (CLAUDE.md refresh) depends on steps 2, 3, and 4 — it adds references to all three.
- Step 6 (retire `BUGS.md`) depends on step 5 — the "Bug Tracking" section of CLAUDE.md must already point at GitHub issues before the file is deleted.

## 7. Risks and mitigations

- **Baseline volume is unexpectedly large.** After step 3 generation, if any single rule produces > 500 violations or the total baseline is > 2,000 entries, pause and assess whether that rule should be full-disabled with a tracking issue instead. Applies at design-landing time, not as ongoing policy.
- **Autocorrect produces a large diff in step 3.** Expected. The diff is committed in the same PR as the config so it's easy to isolate and review. Reviewers should focus on the config file; the autocorrected `.swift` diff is mechanical.
- **Cross-references to `STYLE_GUIDE.md` missed in the rename.** `grep -r 'STYLE_GUIDE\.md\|guides/STYLE_GUIDE' .` after step 1; any remaining hit is a bug.
- **The guide drifts from the enforcing agent.** Mitigation: the agent's frontmatter `description` references `CODE_GUIDE.md` directly; any review invocation re-reads the guide. Guide edits propagate.
- **SwiftLint adoption breaks existing CI.** `just format-check` is currently pass-or-fail; the baseline feature ensures SwiftLint failures are only *new* violations. Confirmed in §4.7.

## 8. Success criteria

- `guides/CODE_GUIDE.md` exists, under 600 lines, cites primary sources, readable end-to-end by `@code-review` in a single pass.
- `.swiftlint.yml` + `.swiftlint-baseline.yml` land. `just format` / `just format-check` run both tools. CI passes without weakening the ruleset.
- Every rule with non-empty baseline entries has a `tech-debt`-labelled GitHub issue.
- `@code-review` agent invokable on any Swift file, producing a report in the format in §5.4.
- `CLAUDE.md` references the new guide, agent, tooling, and GitHub-issues workflow accurately.
- `BUGS.md` is gone; cross-references removed; migrated issues exist on GitHub.

## 9. Out of scope for this design

- The CI check enforcing TODO ↔ GitHub-issue consistency. Tracked separately as [#249](https://github.com/ajsutton/moolah-native/issues/249). Land or defer independently.
- Any refactor to shrink existing oversized files (tracked via per-rule baseline-cleanup issues from §4.8).
- SwiftUI-specific Swift idioms beyond the brief §3.1.17 rules — these belong in `UI_GUIDE.md` if they grow.
