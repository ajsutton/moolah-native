# Swift Code Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Swift code guide, `@code-review` agent, SwiftLint tooling, and ancillary CLAUDE.md/BUGS.md updates as six independent PRs per the design in [`plans/2026-04-22-swift-code-guide-design.md`](./2026-04-22-swift-code-guide-design.md).

**Architecture:** Six independent PRs with explicit dependencies (rename must land first; step 5 depends on 2/3/4; step 6 depends on 5). Each PR gets its own worktree, branch, queue entry, and compliance review before the next step starts. Thresholds anchored on published Swift community best practice (SwiftLint defaults, Apple API Design Guidelines, NetNewsWire conventions), not the current codebase's percentiles.

**Tech Stack:** Swift 6.2, SwiftUI, swift-format (existing), SwiftLint (new), `just`, GitHub Actions, `gh` CLI, merge-queue skill.

---

## How to execute this plan

**Per-step workflow:**

1. Create a new worktree + branch for the step.
2. Execute the step's tasks in order, with TDD where applicable.
3. Run `just format` and `just format-check` before commit.
4. Commit with a message following the project's conventional-commit style (look at `git log --oneline -20` for examples).
5. Push, open the PR via `gh pr create`.
6. Add the PR to the merge queue via `~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <N>`.
7. **Strict-compliance review against this plan section before starting the next step.** Re-read the step's task list; verify every acceptance criterion; only then move on.

**Worktree rule:** every step uses its own worktree under `.worktrees/<branch-name-without-slashes>`. Never modify `main` directly.

**Ground rules:**

- Use `git -C <path>` — never `cd <path> && git ...` (see user memory `feedback_git_dash_c`).
- Use `just` targets — never raw `swift-format`, `xcodebuild`, or `swift test` (`feedback_use_just_targets`).
- PRs go through the merge queue — no manual merges (`feedback_prs_to_merge_queue`).
- Each PR is its own step; don't batch (`feedback_strict_compliance_review_per_step`).
- Plans and spec paths live in `plans/`, not `docs/superpowers/` (`feedback_specs_location`).

**Parent repo path:** `/Users/aj/Documents/code/moolah-project/moolah-native`. The design-doc worktree already exists at `.worktrees/swift-code-guide` on branch `docs/swift-code-guide-design`. Do **not** reuse it for any implementation step — each step gets a fresh worktree.

---

## Step 1 — Rename `STYLE_GUIDE.md` → `UI_GUIDE.md`

**Goal:** mechanical file rename plus every textual reference updated. No behaviour change.

**Branch:** `refactor/rename-style-guide-to-ui-guide`
**Worktree:** `.worktrees/rename-style-guide`

### Task 1.1: Create worktree

- [ ] **Step 1:** Create the worktree.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
  .worktrees/rename-style-guide \
  -b refactor/rename-style-guide-to-ui-guide
```

- [ ] **Step 2:** Verify clean baseline.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide status
```

Expected: `nothing to commit, working tree clean`.

### Task 1.2: Find every reference to `STYLE_GUIDE.md`

- [ ] **Step 1:** Enumerate references.

```bash
grep -rn 'STYLE_GUIDE\.md\|guides/STYLE_GUIDE\|Moolah UI Style Guide' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide \
  --include='*.md' --include='*.swift' --include='*.yml' --include='*.yaml' \
  --exclude-dir=.build --exclude-dir=.worktrees --exclude-dir=build
```

Expected hits: at minimum `CLAUDE.md`, `.claude/agents/ui-review.md`, possibly inside other guides. Note every file and line.

- [ ] **Step 2:** Confirm no hits inside `guides/STYLE_GUIDE.md` itself (the file's internal title is a separate change in Step 1.4 below).

### Task 1.3: Perform the git-mv rename

- [ ] **Step 1:** Rename the file via `git mv` (preserves history).

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide \
  mv guides/STYLE_GUIDE.md guides/UI_GUIDE.md
```

- [ ] **Step 2:** Verify.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide status
ls /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide/guides/
```

Expected: `renamed: guides/STYLE_GUIDE.md -> guides/UI_GUIDE.md`; the directory listing shows `UI_GUIDE.md`, no `STYLE_GUIDE.md`.

### Task 1.4: Update the file's internal title

- [ ] **Step 1:** Read the first 10 lines of `guides/UI_GUIDE.md` to locate the heading.

```bash
head -10 /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide/guides/UI_GUIDE.md
```

- [ ] **Step 2:** If the title is `# Moolah UI Style Guide`, leave it unchanged — it's still accurate. If you find any line inside the file that says `STYLE_GUIDE.md` or `guides/STYLE_GUIDE.md`, change it to `UI_GUIDE.md` / `guides/UI_GUIDE.md`.

### Task 1.5: Update `CLAUDE.md` references

- [ ] **Step 1:** Locate the UI section.

`CLAUDE.md` contains a section `## UI Design & Style Guide` with the line `- **Style Guide:** All UI work MUST follow \`guides/STYLE_GUIDE.md\`. This is not optional.` and `Before Shipping UI: Run the \`ui-review\` agent (see Agents section) to validate compliance with \`guides/STYLE_GUIDE.md\` and identify accessibility issues.`

- [ ] **Step 2:** Replace both occurrences of `guides/STYLE_GUIDE.md` with `guides/UI_GUIDE.md` inside that section. Also scan the whole file for other occurrences — for example the Agents section's `ui-review` entry also references `guides/STYLE_GUIDE.md`.

- [ ] **Step 3:** Verify zero residual references in the file.

```bash
grep -n 'STYLE_GUIDE\.md' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide/CLAUDE.md
```

Expected: no output.

### Task 1.6: Update `.claude/agents/ui-review.md`

- [ ] **Step 1:** Update the frontmatter `description` and any body references.

```bash
grep -n 'STYLE_GUIDE' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide/.claude/agents/ui-review.md
```

Replace every hit: `guides/STYLE_GUIDE.md` → `guides/UI_GUIDE.md`.

- [ ] **Step 2:** Verify.

```bash
grep -n 'STYLE_GUIDE' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide/.claude/agents/ui-review.md
```

Expected: no output.

### Task 1.7: Update any other guides that cross-reference

- [ ] **Step 1:** Scan all guides for cross-references.

```bash
grep -rn 'STYLE_GUIDE\.md\|guides/STYLE_GUIDE' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide/guides
```

- [ ] **Step 2:** For each hit, replace with `UI_GUIDE.md` / `guides/UI_GUIDE.md`.

### Task 1.8: Scan the whole tree one more time

- [ ] **Step 1:** Final check across the whole worktree (excluding build products and the old `.worktrees`).

```bash
grep -rn 'STYLE_GUIDE\.md\|guides/STYLE_GUIDE' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide \
  --include='*.md' --include='*.swift' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.sh' \
  --exclude-dir=.build --exclude-dir=.worktrees --exclude-dir=build --exclude-dir=Moolah.xcodeproj
```

Expected: no output. Any remaining hit is a bug — fix it.

### Task 1.9: Format, commit, push, PR, queue

- [ ] **Step 1:** Format check (this is a no-op — no Swift touched — but run it anyway to confirm).

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide && just format-check
```

- [ ] **Step 2:** Commit.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide add -A
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide commit -m "$(cat <<'EOF'
refactor(guides): rename STYLE_GUIDE.md to UI_GUIDE.md

The current "style guide" is exclusively a UI / SwiftUI / HIG
guide. A peer CODE_GUIDE.md is coming in a follow-up PR; renaming
this one makes the taxonomy unambiguous.

Updates every cross-reference in CLAUDE.md, the ui-review agent,
and any guide-to-guide link.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3:** Push + PR.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide push -u origin refactor/rename-style-guide-to-ui-guide
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/rename-style-guide && \
gh pr create --title "refactor(guides): rename STYLE_GUIDE.md to UI_GUIDE.md" --body "$(cat <<'EOF'
## Summary

Mechanical rename. The current `guides/STYLE_GUIDE.md` is exclusively a UI / SwiftUI / HIG guide despite its generic name. A peer `guides/CODE_GUIDE.md` is coming in a follow-up PR; this rename clarifies the taxonomy.

Updated cross-references:
- `CLAUDE.md` "UI Design & Style Guide" and "Agents" sections.
- `.claude/agents/ui-review.md` frontmatter and body.
- Any inter-guide crosslinks (none at time of writing).

Part of the body of work specified in `plans/2026-04-22-swift-code-guide-design.md`.

## Test plan

- [ ] `grep -r 'STYLE_GUIDE\.md' .` returns no hits in committed files (excluding `.build`, `.worktrees`, `Moolah.xcodeproj`).
- [ ] CI passes (`just format-check`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4:** Add to merge queue.

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-NUMBER-FROM-STEP-3>
```

### Task 1.10: Strict-compliance review

- [ ] **Step 1:** Re-read §6 step 1 of the design spec. Confirm:
   - [ ] File renamed.
   - [ ] `CLAUDE.md` updated (both UI-guide section and Agents section).
   - [ ] `.claude/agents/ui-review.md` updated (frontmatter and body).
   - [ ] Any other cross-references updated.
   - [ ] `grep` sweep returns zero hits.
- [ ] **Step 2:** Only after the above, proceed to Step 2 of this plan.

---

## Step 2 — Write `guides/CODE_GUIDE.md`

**Goal:** 400–600-line Swift code style guide grounded in the research cited in the design, covering every topic in §3.1 of the design.

**Branch:** `docs/code-guide`
**Worktree:** `.worktrees/code-guide`

### Task 2.1: Create worktree

- [ ] **Step 1:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
  .worktrees/code-guide \
  -b docs/code-guide
```

- [ ] **Step 2:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-guide status
```

### Task 2.2: Author `guides/CODE_GUIDE.md`

Write the guide in rule-form matching the tone of `guides/CONCURRENCY_GUIDE.md`. Target 400–600 lines.

**Required structure** (each section maps to §3.1.N of the design):

1. **Top-of-file header** — version, applies-to, relation to other guides. Style: same as `CONCURRENCY_GUIDE.md`'s header.

2. **Section 1 — Philosophy.** 3–5 sentences. Ground in: simplicity over cleverness; name per role; Apple guidelines as the canonical reference; NetNewsWire as a stylistic exemplar ("solve the problem, not more" — cite [NetNewsWire CodingGuidelines.md line 23](https://github.com/Ranchero-Software/NetNewsWire/blob/main/Technotes/CodingGuidelines.md)).

3. **Section 2 — File organization.** Covers design-§3.1.1. Rules: one primary type per file; filename matches primary type; delegate protocol co-located and declared *before* its delegator (cite NetNewsWire line 71); extension-per-protocol-conformance; trailing `private extension Self` for private helpers; `// MARK:` for sections in files > 300 lines. Include 1 short example showing the extension pattern.

4. **Section 3 — File size.** Covers design-§3.1.2. Include the threshold table (file 400/1000, type body 250/350, function body 50/100, complexity 10/20, nesting 1/2, line 100, identifier 3–40/2–60, large-tuple 2/3). Cite [SwiftLint defaults](https://realm.github.io/SwiftLint/rule-directory.html). Note: tests are exempt from file-length and function-length via `.swiftlint.yml` path exclusions. If a production file legitimately needs to exceed the threshold (e.g. exhaustive switch over a closed protocol), use a SwiftLint disable annotation with a brief comment explaining why.

5. **Section 4 — Naming.** Covers design-§3.1.3. Write this as rules with examples drawn from [Apple API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/): clarity at use site; omit needless words; name per role; preposition labels; mutating/nonmutating `-ed`/`-ing` pairs; factory `make…` prefix; uniform acronym casing (`URLFinder`, `htmlBodyContent`, `profileID`). State the suffix conventions: `Controller`, `ViewController`, `Delegate`, `Store` allowed; `Manager` sparingly; avoid `Helper`/`Utility`/`Factory` as type names. Avoid type-suffix in properties (`user.name`, not `user.userName`).

6. **Section 5 — Types: value vs reference.** Covers design-§3.1.4. `struct` by default; cite [Apple: Choosing Between Structures and Classes](https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes). `final class` always — cite NetNewsWire's 253:12 ratio. `enum` for closed sets; `indirect` for recursive. `actor` discussion deferred to `CONCURRENCY_GUIDE.md`.

7. **Section 6 — Protocol design.** Covers design-§3.1.5. Small, focused protocols; extension-based conformance; PATs over existentials for generics; `any P` required spelling — cite [SE-0335](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md); prefer `some P` for returns.

8. **Section 7 — Access control.** Covers design-§3.1.6. Default `internal`, don't write it; prefer `private` for members; `fileprivate` only when compiler requires; `public` only at module boundaries (`Domain/`).

9. **Section 8 — Error handling.** Covers design-§3.1.7. `throws` over `Result`; **don't** reach for typed throws — quote [SE-0413](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md)'s "untyped `throws` remains the better default" text; typed throws reserved for internal / generic-rethrow / Embedded Swift. No silent `try?` (link existing project memory by reference). Rollback pattern in stores — cross-reference CLAUDE.md "Thin Views, Testable Stores" section.

10. **Section 9 — Optionals.** Covers design-§3.1.8. `if let` / `guard let` / `??`; no force-unwrap/try/cast in production; allowed in tests (prefer `XCTUnwrap`/`try`); no implicitly unwrapped optionals outside IBOutlet patterns.

11. **Section 10 — Initializers.** Covers design-§3.1.9. Synthesized memberwise; custom init only for invariants; complex construction via `static func make(…)` factories.

12. **Section 11 — Extensions.** Covers design-§3.1.10. One extension per protocol conformance; trailing `private extension Self` for helpers; avoid extending Foundation types in feature code.

13. **Section 12 — Generics & opaque types.** Covers design-§3.1.11. Prefer `some P` for returns; generics when call site cares; type erasure only when necessary.

14. **Section 13 — Closures.** Covers design-§3.1.12. Trailing closure for last arg; `[weak self]` only for plausible retain cycles; explicit captures when semantics matter.

15. **Section 14 — Collection idioms.** Covers design-§3.1.13. `first(where:)` over `filter {}.first`; `contains(where:)`; `isEmpty` over `count == 0`; `reduce(into:)` over `reduce`; `for` over `forEach`.

16. **Section 15 — Control flow.** Covers design-§3.1.14. `switch` for closed sets; `guard` for early exit; > 3 nesting levels → extract function.

17. **Section 16 — Currency & sign.** Covers design-§3.1.15. Brief. Cross-reference CLAUDE.md "Currency" and "Monetary Sign Convention" sections and `guides/INSTRUMENT_CONVERSION_GUIDE.md`.

18. **Section 17 — Dependency injection.** Covers design-§3.1.16. `@Environment(BackendProvider.self)`; no singletons; no `UserDefaults.standard` outside a wrapper; `Date()` only at boundaries.

19. **Section 18 — SwiftUI-Swift idioms.** Covers design-§3.1.17. `@Observable` store shape; thin views; `EnvironmentValues` for services; `@State` only for local UI state; `@Binding` chains ≤ 1 level.

20. **Section 19 — Documentation.** Covers design-§3.1.18. `///` for public API; WHY not WHAT; DocC sections (`- Parameters:`, `- Returns:`, `- Throws:`); no block comments (`/* */`); no commented-out code. Cite [apple/swift DocumentationComments.md](https://github.com/apple/swift/blob/main/docs/DocumentationComments.md).

21. **Section 20 — TODOs and FIXMEs.** Covers design-§3.1.19. Every TODO/FIXME references a GitHub issue: `TODO(#N): reason — https://github.com/ajsutton/moolah-native/issues/N`. No bare `TODO:`. Reference [#249](https://github.com/ajsutton/moolah-native/issues/249) for CI enforcement.

22. **Section 21 — Imports.** Covers design-§3.1.20. `swift-format` orders; guide rule is *purpose*: Domain imports nothing from SwiftUI/SwiftData/URLSession/Backends; Features never import backend-specific types.

23. **Section 22 — Cross-references.** Brief list of non-goals pointing at the other guides (design §3.2).

24. **Section 23 — Further reading.** The full citation table from design §3.3.

**Acceptance:** 400–600 lines total. Every numeric threshold has an inline URL citation. Every normative rule is testable — either by SwiftLint, by the `@code-review` agent, or by a reader's common sense. No TBDs.

- [ ] **Step 1:** Write the file at `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-guide/guides/CODE_GUIDE.md` following the structure above.

- [ ] **Step 2:** Verify line count.

```bash
wc -l /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-guide/guides/CODE_GUIDE.md
```

Expected: 400 ≤ lines ≤ 650 (some flex, but flag if wildly over).

- [ ] **Step 3:** Scan for TBDs / placeholders.

```bash
grep -nE 'TBD|TODO[^(]|FIXME[^(]|placeholder|XXX' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-guide/guides/CODE_GUIDE.md
```

Expected: no output.

- [ ] **Step 4:** Render-check the URL-heavy sections — run a one-shot curl on 3 randomly-chosen URLs to confirm they 200 (catches typos).

### Task 2.3: Format, commit, push, PR, queue

- [ ] **Step 1:**

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-guide && just format-check
```

Expected: pass.

- [ ] **Step 2:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-guide add guides/CODE_GUIDE.md
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-guide commit -m "$(cat <<'EOF'
docs(guides): add CODE_GUIDE.md for Swift code style

Introduces a general Swift code style guide covering file
organisation, type choice, protocol design, error handling,
optionals, extensions, closures, collection idioms, naming,
documentation, and the TODO ↔ GitHub-issue rule.

Thresholds grounded in SwiftLint community defaults, Apple API
Design Guidelines, and NetNewsWire conventions — cited inline.
Cross-references existing guides for concurrency, testing, sync,
currency conversion, UI, and benchmarking.

Part of plans/2026-04-22-swift-code-guide-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-guide push -u origin docs/code-guide
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-guide && \
gh pr create --title "docs(guides): add CODE_GUIDE.md for Swift code style" --body "$(cat <<'EOF'
## Summary

Adds `guides/CODE_GUIDE.md` — the general Swift code style guide peer to the existing UI / concurrency / sync / test / instrument-conversion / benchmarking guides.

- ~500 lines, rule-form, scannable.
- Every numeric threshold cited inline to SwiftLint defaults, Apple API Design Guidelines, or NetNewsWire's `CodingGuidelines.md`.
- Cross-references out to the existing guides for topics they own (concurrency, testing, sync, conversion, UI, benchmarking).
- Introduces the `TODO(#N)` GitHub-issue reference rule enforced by CI via [#249](https://github.com/ajsutton/moolah-native/issues/249).

Part of `plans/2026-04-22-swift-code-guide-design.md`.

## Test plan

- [ ] Guide renders cleanly in GitHub preview.
- [ ] Spot-check 3 cited URLs resolve.
- [ ] CI passes (`just format-check`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4:** Add to merge queue.

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-NUMBER>
```

### Task 2.4: Strict-compliance review

- [ ] Re-read §3 of the design. For each of §3.1.1–§3.1.20, confirm the corresponding section exists in `CODE_GUIDE.md` with the cited URL. Confirm §3.2 non-goals are listed. Confirm §3.3 citation table is present. Only then proceed to Step 3.

---

## Step 3 — Add SwiftLint (`.swiftlint.yml` + baseline + `justfile` integration)

**Goal:** land SwiftLint alongside `swift-format` per design §4, with the baseline-based rollout, and one tracking issue per rule with baseline entries.

**Branch:** `chore/swiftlint-setup`
**Worktree:** `.worktrees/swiftlint`

### Task 3.1: Prerequisites

- [ ] **Step 1:** Verify SwiftLint is installed locally. If not, install.

```bash
which swiftlint || brew install swiftlint
swiftlint version
```

Expected: a version string (0.55 or later).

### Task 3.2: Create worktree

- [ ] **Step 1:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
  .worktrees/swiftlint \
  -b chore/swiftlint-setup
```

### Task 3.3: Create `.swiftlint.yml`

- [ ] **Step 1:** Create the config file with the exact contents below.

File: `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint/.swiftlint.yml`

```yaml
# SwiftLint configuration — complementary to swift-format.
# swift-format owns all layout/formatting rules. SwiftLint owns policy
# and idiom rules swift-format doesn't cover.
# See guides/CODE_GUIDE.md and plans/2026-04-22-swift-code-guide-design.md.

excluded:
  - .build
  - .worktrees
  - Moolah.xcodeproj
  - build
  - scripts
  - fastlane

disabled_rules:
  # swift-format territory — do not enable these.
  - line_length
  - trailing_comma
  - opening_brace
  - closure_spacing
  - colon
  - comma
  - operator_whitespace
  - return_arrow_whitespace
  - statement_position
  - trailing_whitespace
  - vertical_whitespace
  - sorted_imports

opt_in_rules:
  - array_init
  - attributes
  - closure_body_length
  - closure_end_indentation
  - collection_alignment
  - contains_over_filter_count
  - contains_over_filter_is_empty
  - contains_over_first_not_nil
  - contains_over_range_nil_comparison
  - convenience_type
  - discouraged_optional_boolean
  - discouraged_optional_collection
  - empty_collection_literal
  - empty_count
  - empty_string
  - enum_case_associated_values_count
  - explicit_init
  - fallthrough
  - fatal_error_message
  - file_header
  - file_name
  - first_where
  - flatmap_over_map_reduce
  - force_cast
  - force_try
  - force_unwrapping
  - identical_operands
  - implicit_return
  - implicitly_unwrapped_optional
  - joined_default_parameter
  - last_where
  - legacy_multiple
  - let_var_whitespace
  - literal_expression_end_indentation
  - lower_acl_than_parent
  - modifier_order
  - multiline_arguments
  - multiline_parameters
  - nimble_operator
  - operator_usage_whitespace
  - optional_enum_case_matching
  - overridden_super_call
  - pattern_matching_keywords
  - prefer_self_type_over_type_of_self
  - prefer_zero_over_explicit_init
  - private_action
  - private_outlet
  - prohibited_super_call
  - reduce_into
  - redundant_nil_coalescing
  - redundant_type_annotation
  - sorted_first_last
  - static_operator
  - strict_fileprivate
  - toggle_bool
  - unavailable_function
  - unneeded_parentheses_in_closure_argument
  - untyped_error_in_catch
  - unused_declaration
  - unused_import
  - vertical_parameter_alignment_on_call
  - yoda_condition

file_length:
  warning: 400
  error: 1000
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**

type_body_length:
  warning: 250
  error: 350
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**

function_body_length:
  warning: 50
  error: 100
  excluded:
    - MoolahTests/**
    - MoolahUITests_macOS/**

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
```

### Task 3.4: Update `justfile`

- [ ] **Step 1:** Open `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint/justfile` and modify the `format` and `format-check` recipes.

**New `format` recipe** — add SwiftLint autocorrect after `swift-format`:

```
# Apply swift-format formatting in place, then run SwiftLint autocorrect.
# Run this before committing; CI rejects unformatted files or new lint warnings.
format:
    swift-format format -i -r . --configuration .swift-format
    swiftlint lint --fix --quiet
```

**New `format-check` recipe** — add SwiftLint `--strict` with baseline after the existing loop:

```
# Verify that every tracked Swift file is formatted, and that no new lint
# warnings beyond the baseline exist. Non-destructive; used by CI.
format-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    while IFS= read -r file; do
        if ! cmp -s "$file" <(swift-format format --configuration .swift-format "$file"); then
            echo "::error file=$file::Not formatted; run 'just format' to fix"
            diff -u --label "$file" --label "$file (formatted)" \
                "$file" <(swift-format format --configuration .swift-format "$file") || true
            fail=1
        fi
    done < <(git ls-files '*.swift')
    if [ "$fail" -ne 0 ]; then
        echo
        echo "One or more files are not formatted correctly."
        echo "Run 'just format' and commit the result."
        exit 1
    fi
    echo "All Swift files are correctly formatted."
    swiftlint lint --baseline .swiftlint-baseline.yml --strict --quiet
```

- [ ] **Step 2:** Verify `just --list` still parses.

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint && just --list
```

### Task 3.5: Run `just format` (autocorrect pass)

- [ ] **Step 1:** Run the new `just format`.

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint && just format 2>&1 | tee .agent-tmp/format-output.txt
```

- [ ] **Step 2:** Inspect the diff.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint status --short | head -50
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint diff --stat | tail -20
```

Expected: some number of `.swift` files modified by autocorrect (trailing whitespace, redundant types, etc.). This is the "mechanical churn" the spec anticipates.

- [ ] **Step 3:** Confirm the tree still builds and tests pass after autocorrect.

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint && just test 2>&1 | tee .agent-tmp/test-output.txt
```

Expected: full test suite passes. If anything fails because of an autocorrect, revert just that file's autocorrect and file a tracking issue (see §4.8 tracking pattern).

### Task 3.6: Generate the baseline

- [ ] **Step 1:** Write the baseline.

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint && \
  swiftlint lint --write-baseline .swiftlint-baseline.yml 2>&1 | tee .agent-tmp/baseline-generate.txt
```

- [ ] **Step 2:** Verify the baseline exists and inspect its size.

```bash
ls -l /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint/.swiftlint-baseline.yml
wc -l /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint/.swiftlint-baseline.yml
```

- [ ] **Step 3:** Count violations per rule.

```bash
swiftlint lint --reporter json 2>/dev/null | python3 -c "
import json, sys, collections
data = json.load(sys.stdin)
counts = collections.Counter(v['rule_id'] for v in data)
for rule, n in counts.most_common():
    print(f'{n:>6}  {rule}')
" | tee .agent-tmp/violations-per-rule.txt
```

Expected: a list of rule IDs with violation counts, ordered largest-first.

### Task 3.7: Decide which rules full-disable vs baseline

Per design §4.8 threshold: if a rule has > 500 violations or its violations are not autocorrectable and require design refactors, move it to `disabled_rules:` with a tracking issue comment `# TODO(#N): enable once <criterion>`. Otherwise leave enabled and let the baseline suppress existing hits.

- [ ] **Step 1:** Inspect `.agent-tmp/violations-per-rule.txt`. For each rule with > 500 hits OR design-refactor-requiring violations (use judgement — e.g. `cyclomatic_complexity` at the error tier usually requires a refactor, not autocorrect):
  - Add the rule to `disabled_rules:` in `.swiftlint.yml`.
  - Regenerate the baseline (`swiftlint lint --write-baseline .swiftlint-baseline.yml`).

- [ ] **Step 2:** For each rule remaining in the baseline *and* each rule now in `disabled_rules:` for debt reasons (not `swift-format` territory), collect its info for issue creation in Task 3.8.

### Task 3.8: Create one tracking issue per baseline/disabled rule

For each rule identified in Task 3.7, open a GitHub issue:

- [ ] **Step 1:** For each rule `R` with `N` violations, create an issue:

```bash
gh issue create --repo ajsutton/moolah-native \
  --label 'tech-debt' --label 'swiftlint-cleanup' \
  --title "SwiftLint cleanup: <R>" \
  --body "$(cat <<'EOF'
## Rule

`<R>` — https://realm.github.io/SwiftLint/<R>.html

## Violations

Current violation count: **N**.

Top offending files (from the initial baseline snapshot):

- `<path/to/file1.swift>` — count
- `<path/to/file2.swift>` — count
- `<path/to/file3.swift>` — count

## Done when

- [ ] This rule's entries in `.swiftlint-baseline.yml` drop to zero (or the rule leaves `disabled_rules:`).
- [ ] Baseline file regenerated without the rule.
- [ ] Close this issue.
EOF
)"
```

Rely on the violations-per-rule output to populate N, and use `swiftlint lint --reporter json | python3 …` to get the top offending files per rule.

Bash helper to automate per-rule issue creation (optional but recommended):

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint

# Ensure labels exist
gh label create tech-debt --color ededed --description "Technical debt tracking" 2>/dev/null || true
gh label create swiftlint-cleanup --color fbca04 --description "SwiftLint baseline reduction" 2>/dev/null || true

# Run the full JSON report once
swiftlint lint --reporter json 2>/dev/null > .agent-tmp/lint-all.json

# For each rule with a baseline entry, create an issue
python3 - <<'PY'
import json, subprocess, collections

data = json.load(open(".agent-tmp/lint-all.json"))
by_rule = collections.defaultdict(list)
for v in data:
    by_rule[v["rule_id"]].append(v)

for rule, vs in sorted(by_rule.items(), key=lambda kv: -len(kv[1])):
    files = collections.Counter(v["file"] for v in vs)
    top_files = "\n".join(f"- `{p}` — {n}" for p, n in files.most_common(5))
    body = f"""## Rule

`{rule}` — https://realm.github.io/SwiftLint/{rule}.html

## Violations

Current violation count: **{len(vs)}**.

Top offending files (initial baseline snapshot):

{top_files}

## Done when

- [ ] This rule's entries in `.swiftlint-baseline.yml` drop to zero (or the rule leaves `disabled_rules:`).
- [ ] Baseline file regenerated without the rule.
- [ ] Close this issue.
"""
    subprocess.run([
        "gh", "issue", "create",
        "--repo", "ajsutton/moolah-native",
        "--label", "tech-debt",
        "--label", "swiftlint-cleanup",
        "--title", f"SwiftLint cleanup: {rule}",
        "--body", body,
    ], check=True)
PY
```

- [ ] **Step 2:** Record the issue numbers (they'll appear as URLs in each `gh issue create` output) in `.agent-tmp/swiftlint-cleanup-issues.txt` for the PR description.

- [ ] **Step 3:** Add an inline `# TODO(#N): enable once <criterion>` comment in `.swiftlint.yml` next to any rule placed in `disabled_rules:` for debt reasons.

### Task 3.9: Update README with the install step

- [ ] **Step 1:** Open `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint/README.md`. Locate the setup / tooling section (use `grep -n 'brew install' README.md` or similar). Add a line mentioning `brew install swiftlint`.

### Task 3.10: Run `just format-check` end-to-end

- [ ] **Step 1:**

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint && just format-check
```

Expected: both swift-format and swiftlint passes — no *new* lint violations beyond baseline.

### Task 3.11: Commit, push, PR, queue

- [ ] **Step 1:** Stage config + baseline + justfile + README + mechanical autocorrect in one commit (or split into two if the autocorrect churn is very large — use your judgement).

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint add .swiftlint.yml .swiftlint-baseline.yml justfile README.md
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint add -u  # pick up autocorrected .swift files
```

- [ ] **Step 2:** Commit.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint commit -m "$(cat <<'EOF'
chore(lint): introduce SwiftLint with baseline rollout

Adds .swiftlint.yml alongside swift-format (complementary, no
rule overlap — swift-format owns layout, SwiftLint owns policy).
Wires into `just format` (autocorrect) and `just format-check`
(--strict with --baseline .swiftlint-baseline.yml).

Existing violations snapshotted into .swiftlint-baseline.yml so
CI gates only new code. One tech-debt issue per rule tracks
baseline reduction (see PR body).

Includes the mechanical diff from the one-shot `just format` run.

Part of plans/2026-04-22-swift-code-guide-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3:** Push + PR. Include the list of tracking issues in the body.

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint push -u origin chore/swiftlint-setup
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/swiftlint && \
gh pr create --title "chore(lint): introduce SwiftLint with baseline rollout" --body "$(cat <<EOF
## Summary

Adds SwiftLint alongside swift-format, following design §4.

- \`.swiftlint.yml\` — rule set chosen to complement (not overlap with) swift-format.
- \`.swiftlint-baseline.yml\` — snapshot of existing violations so CI only gates new code.
- \`justfile\` updates — \`just format\` also runs \`swiftlint --fix\`; \`just format-check\` also runs \`swiftlint --baseline --strict\`.
- README gains \`brew install swiftlint\` step.
- One commit of mechanical autocorrect from the initial \`just format\` run.

## Per-rule tech-debt tracking issues

$(cat .agent-tmp/swiftlint-cleanup-issues.txt 2>/dev/null | sed 's|^|- |' || echo "(see linked issues on the tech-debt / swiftlint-cleanup labels)")

## Test plan

- [ ] \`just format-check\` passes.
- [ ] \`just test\` passes.
- [ ] Each tech-debt issue exists with a violation count and "done when" criterion.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4:** Add to merge queue.

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-NUMBER>
```

### Task 3.12: Strict-compliance review

Re-read §4 of the design. Confirm:

- [ ] Thresholds match §4.1 exactly.
- [ ] Disabled rules match §4.2 exactly (swift-format territory).
- [ ] Opt-in rules match §4.3 exactly.
- [ ] Per-rule relaxations match §4.4 (note the force-try/force-cast/force-unwrapping/implicitly-unwrapped-optional exclusions for tests).
- [ ] Path exclusions match §4.5.
- [ ] `just format` and `just format-check` behave per §4.6.
- [ ] Baseline file committed (§4.7).
- [ ] One issue created per rule with baseline or debt-disabled entries, per §4.8 — and §4.8's swift-format-owned disables got NO issues.
- [ ] README mentions `brew install swiftlint`.

Only then proceed to Step 4.

---

## Step 4 — Add `.claude/agents/code-review.md`

**Goal:** land the semantic reviewer agent per design §5.

**Branch:** `feat/code-review-agent`
**Worktree:** `.worktrees/code-review-agent`

### Task 4.1: Create worktree

- [ ] **Step 1:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
  .worktrees/code-review-agent \
  -b feat/code-review-agent
```

### Task 4.2: Write the agent file

- [ ] **Step 1:** Read an existing agent (e.g. `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-review-agent/.claude/agents/concurrency-review.md`) to pattern-match the structure.

- [ ] **Step 2:** Create `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-review-agent/.claude/agents/code-review.md` with the exact frontmatter from design §5.1 and a body following the structure of existing agents.

**Required structure** (mirrors `concurrency-review.md`):

1. Frontmatter (design §5.1 verbatim).
2. "You are an expert Swift reviewer. Your role is to review code for compliance with the project's `guides/CODE_GUIDE.md` and the architecture conventions in `CLAUDE.md`." opening paragraph.
3. "## Philosophy" — short paragraph summarising the agent's role: semantic review, complementary to SwiftLint's mechanical rules.
4. "## Review Process" — list, matches `concurrency-review.md`:
   1. Read `guides/CODE_GUIDE.md` first to understand the rules.
   2. Read `CLAUDE.md` for architecture conventions.
   3. Read the target file(s) completely before judging.
   4. Check each category below systematically.
5. "## What to Check" — five subsections matching design §5.2 A–E.
6. "## False Positives to Avoid" — list from design §5.3.
7. "## Non-Overlap with Existing Agents" — list from design §5.5.
8. "## Key References" — link to `CODE_GUIDE.md`, `CLAUDE.md`, Apple API Design Guidelines, SE-0413, SE-0335.
9. "## Output Format" — from design §5.4.

- [ ] **Step 3:** Line count sanity — target ~120–180 lines, matching existing agents.

```bash
wc -l /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-review-agent/.claude/agents/code-review.md
```

### Task 4.3: Smoke-test the agent

- [ ] **Step 1:** Invoke the agent against one known file (any production Swift file). Agent should produce a structured report in the §5.4 format.

```bash
# Via whatever invocation mechanism is live; if interactive, do so in a scratch session.
# Minimum sanity check: agent reads the guide and CLAUDE.md without error.
```

### Task 4.4: Format, commit, push, PR, queue

- [ ] **Step 1:**

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-review-agent && just format-check
```

- [ ] **Step 2:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-review-agent add .claude/agents/code-review.md
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-review-agent commit -m "$(cat <<'EOF'
feat(agents): add @code-review agent for CODE_GUIDE.md compliance

Semantic reviewer complementary to the mechanical SwiftLint
rules. Covers architectural conformance (domain isolation, thin
views, store shape, currency sign convention), Swift idioms
(naming, type choice, protocol design, error handling, optional
discipline, extension organisation), API surface, documentation,
and file organisation.

Non-overlapping with @concurrency-review, @ui-review,
@instrument-conversion-review, @sync-review, @ui-test-review,
@appstore-review.

Part of plans/2026-04-22-swift-code-guide-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-review-agent push -u origin feat/code-review-agent
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/code-review-agent && \
gh pr create --title "feat(agents): add @code-review agent for CODE_GUIDE.md compliance" --body "$(cat <<'EOF'
## Summary

Adds `.claude/agents/code-review.md` — a semantic Swift code reviewer complementary to the SwiftLint rules landed in the previous PR.

Checks architectural conformance (domain isolation, thin views, store shape, currency sign), Swift idioms (naming, type choice, protocol design, error handling, optionals, extensions), API surface, documentation, and file organisation.

Explicit non-overlap with the other review agents (`@concurrency-review`, `@ui-review`, `@instrument-conversion-review`, `@sync-review`, `@ui-test-review`, `@appstore-review`).

Depends on `guides/CODE_GUIDE.md` — land after that PR merges.

Part of `plans/2026-04-22-swift-code-guide-design.md`.

## Test plan

- [ ] Smoke-test: invoke `@code-review` on a representative production file and confirm the report matches the §5.4 format.
- [ ] CI passes (`just format-check`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4:** Add to merge queue.

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-NUMBER>
```

### Task 4.5: Strict-compliance review

- [ ] Re-read §5 of the design. Confirm each of §5.1–§5.5 is reflected in the agent file. Only then proceed to Step 5.

---

## Step 5 — Refresh `CLAUDE.md`

**Goal:** CLAUDE.md references every new artefact from Steps 1–4 plus the GitHub-issues-for-TODOs workflow.

**Branch:** `docs/claude-md-refresh`
**Worktree:** `.worktrees/claude-md-refresh`

### Task 5.1: Create worktree

- [ ] **Step 1:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
  .worktrees/claude-md-refresh \
  -b docs/claude-md-refresh
```

### Task 5.2: Update `CLAUDE.md`

Concrete edits to `/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/claude-md-refresh/CLAUDE.md`:

- [ ] **Step 1: Add a "Code Style & Idioms" section** just before the existing "UI Design & Style Guide" section. Contents:

```markdown
## Code Style & Idioms

- **Code Guide:** All Swift code MUST follow `guides/CODE_GUIDE.md`. This is not optional.
- **Tooling:** `swift-format` handles layout; SwiftLint handles policy. `just format` applies both; `just format-check` enforces them in CI.
- **Before Shipping Code:** Run the `code-review` agent (see Agents section) to validate compliance with `guides/CODE_GUIDE.md` and surface architectural issues.
```

- [ ] **Step 2: Update the "UI Design & Style Guide" section** — the rename from Step 1 should already be landed, but verify the first bullet reads `- **Style Guide:** All UI work MUST follow \`guides/UI_GUIDE.md\`.` If any reference still says `STYLE_GUIDE.md`, fix it.

- [ ] **Step 3: Replace the "Bug Tracking" section** entirely. New contents:

```markdown
## Bug Tracking

- **Known bugs and feature issues** are tracked as GitHub issues at https://github.com/ajsutton/moolah-native/issues.
- When fixing a bug, close the corresponding issue from the PR (e.g. `Fixes #123` in the commit or PR body).
- When adding a TODO/FIXME in Swift source, reference an open GitHub issue: `TODO(#N): reason — https://github.com/ajsutton/moolah-native/issues/N`. Bare `TODO:` is disallowed.
- CI blocks closing a GitHub issue while live `TODO(#N)` comments still reference it (tracked by issue [#249](https://github.com/ajsutton/moolah-native/issues/249)).
```

- [ ] **Step 4: Update the "Agents" section** to add the new `code-review` agent entry. Insert it as the first bullet in the agents list:

```markdown
- **`code-review`** — Reviews Swift code for `guides/CODE_GUIDE.md` compliance and architecture conventions in CLAUDE.md: naming, type choice, protocol design, error handling, optional discipline, extension organisation, thin-view discipline, TODO format. Use after writing or significantly modifying any production Swift file, before committing.
```

- [ ] **Step 5: Update the "Pre-Commit Checklist" section** step 1. Replace the current `just format` line with:

```markdown
1. **Format and lint Swift files**
   - Run `just format` to apply `swift-format` (layout) and `swiftlint --fix` (autocorrectable idioms). Uses `.swift-format` and `.swiftlint.yml` configs.
   - CI runs `just format-check` and **will fail** if any tracked `.swift` file is not in formatted form, or if new SwiftLint warnings appear beyond the baseline.
   - `just format-check` is non-destructive — run it locally to preview CI's result without mutating files.
   - Xcode's editor / format-on-save can silently reformat files to a layout that disagrees with `swift-format`. Always run `just format` immediately before `git commit` so CI doesn't kick the PR back.
```

### Task 5.3: Verify no stale references

- [ ] **Step 1:**

```bash
grep -nE 'STYLE_GUIDE\.md|BUGS\.md' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/claude-md-refresh/CLAUDE.md
```

Expected: no output.

### Task 5.4: Format, commit, push, PR, queue

- [ ] **Step 1:**

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/claude-md-refresh && just format-check
```

- [ ] **Step 2:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/claude-md-refresh add CLAUDE.md
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/claude-md-refresh commit -m "$(cat <<'EOF'
docs(CLAUDE): reference CODE_GUIDE.md, SwiftLint, @code-review, GitHub issues

Adds a "Code Style & Idioms" section, updates the UI section to
point at UI_GUIDE.md, replaces "Bug Tracking" with GitHub-issues
guidance (per issue #249), lists @code-review in Agents, and
updates the Pre-Commit Checklist to include SwiftLint.

Part of plans/2026-04-22-swift-code-guide-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/claude-md-refresh push -u origin docs/claude-md-refresh
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/claude-md-refresh && \
gh pr create --title "docs(CLAUDE): reference CODE_GUIDE, SwiftLint, @code-review, GitHub issues" --body "$(cat <<'EOF'
## Summary

Refreshes `CLAUDE.md` so it references the new Swift-code artefacts.

- Adds "Code Style & Idioms" section pointing at `guides/CODE_GUIDE.md` and tooling.
- Updates "UI Design & Style Guide" section to `guides/UI_GUIDE.md`.
- Replaces "Bug Tracking" section with GitHub-issues guidance and the `TODO(#N)` rule.
- Adds `@code-review` to the Agents section.
- Updates the Pre-Commit Checklist to include SwiftLint.

Depends on the four prior PRs in `plans/2026-04-22-swift-code-guide-design.md` — rename, CODE_GUIDE, SwiftLint, code-review agent — having landed.

## Test plan

- [ ] `grep 'STYLE_GUIDE\.md\|BUGS\.md' CLAUDE.md` returns no hits.
- [ ] CI passes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4:** Add to merge queue.

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-NUMBER>
```

### Task 5.5: Strict-compliance review

- [ ] Re-read §6 step 5 of the design. Confirm:
  - [ ] "Code Style & Idioms" section added pointing at CODE_GUIDE.md.
  - [ ] UI section points at UI_GUIDE.md.
  - [ ] Bug Tracking section rewritten around GitHub issues with TODO rule.
  - [ ] Agents section gains `@code-review`.
  - [ ] Pre-Commit Checklist gains SwiftLint.
- [ ] Only then proceed to Step 6.

---

## Step 6 — Retire `BUGS.md`

**Goal:** migrate every entry in `BUGS.md` to a GitHub issue, then delete the file.

**Branch:** `chore/retire-bugs-md`
**Worktree:** `.worktrees/retire-bugs-md`

### Task 6.1: Create worktree

- [ ] **Step 1:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add \
  .worktrees/retire-bugs-md \
  -b chore/retire-bugs-md
```

### Task 6.2: Read `BUGS.md` and enumerate entries

- [ ] **Step 1:** Read the file.

```bash
cat /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/retire-bugs-md/BUGS.md
```

- [ ] **Step 2:** For each entry, extract:
  - Title
  - Reproduction / description
  - Any severity / priority hints
  - Links to related commits or code paths

### Task 6.3: Create one GitHub issue per `BUGS.md` entry

- [ ] **Step 1:** For each entry in BUGS.md:

```bash
gh issue create --repo ajsutton/moolah-native \
  --label bug \
  --title "<entry title>" \
  --body "$(cat <<'EOF'
Migrated from BUGS.md as part of plans/2026-04-22-swift-code-guide-design.md §6.

## Description

<paste the entry body verbatim>

## Acceptance

- [ ] Reproduce
- [ ] Fix
- [ ] Add regression test if practical
EOF
)"
```

Ensure `bug` label exists; create it if not: `gh label create bug --color d73a4a --description "Something isn't working" 2>/dev/null || true`.

- [ ] **Step 2:** Record the created issue URLs in `.agent-tmp/bugs-md-migration.txt` for the PR body.

### Task 6.4: Delete `BUGS.md`

- [ ] **Step 1:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/retire-bugs-md rm BUGS.md
```

### Task 6.5: Verify no dangling references

- [ ] **Step 1:**

```bash
grep -rn 'BUGS\.md' \
  /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/retire-bugs-md \
  --include='*.md' --include='*.swift' --include='*.yml' --include='*.yaml' \
  --exclude-dir=.build --exclude-dir=.worktrees --exclude-dir=build --exclude-dir=plans
```

Expected: no hits. (Excluding `plans/` so the design doc's historical mention of BUGS.md stays.)

### Task 6.6: Format, commit, push, PR, queue

- [ ] **Step 1:**

```bash
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/retire-bugs-md && just format-check
```

- [ ] **Step 2:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/retire-bugs-md add -A
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/retire-bugs-md commit -m "$(cat <<'EOF'
chore: retire BUGS.md, move tracked bugs to GitHub issues

Completes the transition started in the CLAUDE.md refresh. Every
entry in BUGS.md was migrated to a GitHub issue (see PR body).
The file is deleted; CLAUDE.md already points readers at
https://github.com/ajsutton/moolah-native/issues.

Part of plans/2026-04-22-swift-code-guide-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3:**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/retire-bugs-md push -u origin chore/retire-bugs-md
cd /Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/retire-bugs-md && \
gh pr create --title "chore: retire BUGS.md, move tracked bugs to GitHub issues" --body "$(cat <<EOF
## Summary

Deletes \`BUGS.md\`. Every entry was migrated to a GitHub issue:

$(cat .agent-tmp/bugs-md-migration.txt 2>/dev/null | sed 's|^|- |')

CLAUDE.md already points readers at https://github.com/ajsutton/moolah-native/issues for bug tracking (landed in the prior PR).

Part of \`plans/2026-04-22-swift-code-guide-design.md\`.

## Test plan

- [ ] \`grep -rn 'BUGS\.md' .\` returns no hits outside \`plans/\` and \`.worktrees/\`.
- [ ] Each migrated issue exists and is linked above.
- [ ] CI passes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4:** Add to merge queue.

```bash
~/.claude/skills/merge-queue/scripts/merge-queue-ctl.sh add <PR-NUMBER>
```

### Task 6.7: Update user auto-memory

- [ ] **Step 1:** After the PR merges, update the `project_known_bugs.md` memory — either delete it (if GitHub issues now cover every entry) or shrink it to a pointer noting that bug tracking has moved to GitHub issues and this memory is historical.

### Task 6.8: Strict-compliance review

- [ ] Re-read §6 step 6 of the design. Confirm:
  - [ ] Every BUGS.md entry has a corresponding GitHub issue.
  - [ ] The file is deleted.
  - [ ] No references to BUGS.md remain (outside plans/ historical docs).
  - [ ] Memory file updated or deleted.

---

## Final verification (after all six steps merge)

- [ ] `guides/UI_GUIDE.md` exists; `guides/STYLE_GUIDE.md` does not.
- [ ] `guides/CODE_GUIDE.md` exists, 400–600 lines, cites the sources in design §3.3.
- [ ] `.swiftlint.yml` + `.swiftlint-baseline.yml` exist; `just format-check` passes.
- [ ] Every rule with baseline/debt-disabled entries has a `tech-debt`-labelled GitHub issue.
- [ ] `.claude/agents/code-review.md` exists; `@code-review` invokable.
- [ ] `CLAUDE.md` references CODE_GUIDE.md, UI_GUIDE.md, `@code-review`, SwiftLint, and GitHub-issues for bugs. No `STYLE_GUIDE.md` or `BUGS.md` references remain.
- [ ] `BUGS.md` is deleted; its entries exist as GitHub issues.
- [ ] [#249](https://github.com/ajsutton/moolah-native/issues/249) remains open for later CI work.

Close out the design doc by moving `plans/2026-04-22-swift-code-guide-design.md` and this implementation plan to `plans/completed/` once every PR has merged.
