---
name: fixing-format-check
description: Use whenever `just format-check` fails — from a local run, a pre-commit/pre-push hook, or a PR's CI "format-check" job — and any time a change is about to touch `.swiftlint.yml`, `.swiftlint-baseline.yml`, a SwiftLint threshold, or a `// swiftlint:disable` comment. Also use on any `swift-format` diff output or `SwiftLint Violation` message, regardless of source.
---

# Fixing `just format-check` Errors

## When to use this skill

Load this skill **every time** you hit any of these:

- `just format-check` exits non-zero (local run, pre-commit hook, `git push` hook)
- a PR's CI "format-check" / lint job is failing
- any `swift-format` diff output or `SwiftLint Violation:` message, from any command
- you are about to edit `.swiftlint.yml`, `.swiftlint-baseline.yml`, or a SwiftLint threshold
- you are about to run `swiftlint --fix`, `swiftlint --write-baseline`, or add a `// swiftlint:disable` comment
- a user or reviewer tells you "the lint is failing" / "format-check is red"

Do not try to silence a format-check failure without reading this skill — the project's rule against re-baselining is strict, easy to violate unintentionally, and the user has standing feedback that it must be followed.

## What `just format-check` checks

Two gates, fixed differently:

1. **`swift-format`** — layout and formatting. Deterministic and mechanical. Fixed by running the formatter.
2. **`swiftlint lint --baseline .swiftlint-baseline.yml --strict`** — policy and idiom rules. Not mechanical. Every non-baselined violation is a real code-quality signal and is fixed in source.

The aim is **code that better matches `guides/CODE_GUIDE.md` and Apple's API Design Guidelines**, not the minimum diff needed to turn CI green. Treat each violation as a nudge to simplify or restructure, not a nuisance to silence.

## The Iron Rule

**Never modify `.swiftlint-baseline.yml`.** Not to regenerate it. Not to add a single entry. Not to re-key entries after a file split. Not "just this once."

The baseline is **pre-existing debt the team is paying down** — an allowlist that only ever shrinks. Anything SwiftLint flags that isn't in the baseline is a new violation by definition, and the fix is always in source code.

If (and only if) you genuinely cannot fix a specific violation without disproportionate scope (e.g. a 1500-line legacy type the current task shouldn't be refactoring), **stop and ask the user for explicit permission to add one specific baseline entry**. Do not infer permission from prior conversations. Do not bundle it in "while I'm here" cleanup.

**Red flags — STOP if any of these apply:**

- About to run `swiftlint --write-baseline` or `swiftlint --fix` with a baseline write
- About to hand-edit `.swiftlint-baseline.yml` to bump a reason string or line count
- Thinking "the file just got split, so the baseline needs a refresh"
- Thinking "this violation existed before, the baseline just didn't catch it under the old path"
- Thinking "the rule threshold is too strict, let me bump it in `.swiftlint.yml` instead"

All of these mean the fix belongs in source code, or the change is out of scope for the current task.

## Before Fixing

1. **Reproduce locally** and capture the full output:

   ```bash
   mkdir -p .agent-tmp
   just format-check 2>&1 | tee .agent-tmp/format-check.txt
   ```

2. **Split the output by failure type.** swift-format prints `::error file=...::Not formatted; run 'just format' to fix` with a unified diff. SwiftLint prints `path:line:col: warning/error: <Rule Name> Violation: <message> (rule_id)`. Separate the two lists — they get fixed differently.

3. **Read `guides/CODE_GUIDE.md`** (at least the sections for the rules you hit). The SwiftLint config in `.swiftlint.yml` encodes the same philosophy; the guide explains the *why*.

## Fixing swift-format Violations

One command. No judgement calls — `swift-format` is the authority on layout.

```bash
just format
```

That runs `swift-format format -i -r .` and then `swiftlint lint --fix --quiet` as a second pass for autocorrectable idioms.

Then:

- **Re-run `just format-check`** to confirm both gates pass.
- **Eyeball the diff.** Xcode's editor can re-indent on save in ways `swift-format` disagrees with; occasionally the formatter produces a change that rewraps a line you'd rather keep. If a specific layout is load-bearing, address it in source (shorter names, intermediate lets, etc.) — do not disable rules.
- **Audit `swiftlint --fix` output.** Some rules (e.g. `redundant_nil_coalescing`, `redundant_discardable_let`) are disabled in `.swiftlint.yml` because their autofix is known to produce broken code in this codebase; if you see those rule IDs showing up in fixed diffs, something is wrong and you should back out and re-diagnose.

## Fixing SwiftLint Violations

These are the ones that matter. Each violation is the linter telling you the code disagrees with the guide in a way a human reviewer would also flag.

### 1. Understand the rule, not just the message

Read the rule's rationale. Either `swiftlint rules <rule_id>` or the relevant section of `guides/CODE_GUIDE.md`. Some rules are obvious (`force_unwrapping`); others encode a design opinion (`convenience_type`, `implicit_return`, `file_header`) and the fix depends on understanding *what the rule is defending*.

### 2. Fix in source, preferring the design change over the local edit

Pick the fix that best aligns with `guides/CODE_GUIDE.md`, Apple's API Design Guidelines, and the architecture rules in `CLAUDE.md`. A SwiftLint violation is usually a symptom of a deeper issue; the better fix addresses that.

| Rule / symptom | Low-effort fix (often wrong) | Better fix |
|---|---|---|
| `file_length`, `type_body_length` | Split "random chunk" into a second file | Split along a semantic seam: extract a subtype, extract a protocol conformance into an extension, pull out a helper struct. See the "Extension organization" section of `CODE_GUIDE.md`. |
| `function_body_length`, `cyclomatic_complexity` | Extract a private `_impl` helper | Extract named steps that each do one thing; lift branches into an `enum`/switch; push multi-step orchestration into a store method per the Thin Views rule. |
| `force_unwrapping`, `force_try`, `force_cast` | Add `// swiftlint:disable:this` | Replace with `guard let`, typed throws, `#require` in tests, or a fallible initializer — whichever matches the semantics. Disabling masks a real runtime risk. |
| `identifier_name` (too short) | Lengthen by one letter to pass the minimum | Pick a name that reads as a sentence at the call site (Apple API Design Guidelines). If the loop variable is genuinely `i`/`x`/`y`, the existing `excluded:` list covers it. |
| `file_header` | Copy-paste the header | The project currently has no required header; if SwiftLint is flagging, the rule config changed — confirm with the user before mass-editing files. |
| `convenience_type` | Change `struct` to `enum`, leave otherwise untouched | Confirm the type really is a namespace (no stored state, no instances created) before converting. |
| `implicitly_unwrapped_optional` | Change `T!` to `T?` everywhere | Decide whether the value is truly always-set-before-use (then plain `let` + proper init) or genuinely optional (then `T?` and handle the nil path). |
| `unused_declaration`, `unused_import` | Delete the flagged line | Delete, but also check whether the declaration was *intended* to be used (dead feature? abandoned refactor?) — sometimes the right fix is wiring it up, not removing it. |

### 3. Beware the "file split re-keys the baseline" trap

When you split a file, SwiftLint's baseline is keyed by the old path. Violations migrating to new files look like new violations, and `format-check` fails loudly. **Do not regenerate the baseline** — fix each newly-flagged violation in the new file. This is exactly the case the Iron Rule is guarding against.

### 4. Beware the "just tweak the threshold" trap

Rule thresholds live in `.swiftlint.yml` (`file_length`, `type_body_length`, `cyclomatic_complexity`, etc.). Bumping a threshold is functionally the same as editing the baseline — it accumulates debt instead of paying it down. Don't raise a threshold to make a failure go away; fix the code. Threshold changes are a separate conversation with the user, with their own justification.

## Leverage the `code-review` Agent

Once the mechanical errors are gone and the tests still pass, run the project's code reviewer on the changed files:

```
@code-review  path/to/changed/file1.swift path/to/changed/file2.swift
```

Its job is exactly the kind of semantic review that catches a quick-fix masquerading as a real fix:

- A function hoisted into a private helper just to shorten the parent — same complexity, worse readability.
- A force-unwrap rewritten as `try! … as! T` — same runtime failure mode, now with a disabled rule.
- A file split along an arbitrary line rather than a semantic seam.
- A name padded out for `identifier_name` but no clearer at the call site.

Address every finding from the agent before re-running `just format-check`. If you genuinely disagree with a finding, push back in the conversation — don't silently ignore it. The user's standing feedback is to **take reviewer observations seriously, not rationalise them away**.

## After Fixing

Run the full gate from scratch:

```bash
just format-check 2>&1 | tee .agent-tmp/format-check.txt
```

It should print "All Swift files are correctly formatted." with no SwiftLint output. If anything still fails, loop back through the diagnosis step — don't reach for the baseline.

Then, before committing:

- `git -C . diff -- .swiftlint-baseline.yml .swiftlint.yml` — **this must be empty.** Any diff there is either your own violation of the Iron Rule, or a scope change that needs explicit user sign-off in this conversation.
- Run the broader test suite (`just test`) if the source changes went beyond pure formatting — a file split, an extracted helper, or an unforced-unwrap can break callers in ways SwiftLint will not notice.
- Clean up `.agent-tmp/format-check.txt` when you're done reviewing.

## Common Mistakes

- **Running `swiftlint --write-baseline` to "refresh" the baseline after refactoring.** Forbidden. The whole point of the baseline is to not refresh it.
- **Disabling a rule with `// swiftlint:disable` instead of fixing the code.** The disable comment needs a real justification; absent one, it's the same anti-pattern as editing the baseline.
- **Treating `file_length` as "split the file in half."** Splitting by line count produces two files with no coherent responsibility. Split along a type, a feature, or an extension.
- **Rewriting `!` as `try!`/`as!` to silence `force_unwrapping`.** That trades one forbidden rule for another. The fix is to handle the failure mode.
- **Bumping a `.swiftlint.yml` threshold to let the current violation through.** Same category as editing the baseline; accumulates debt instead of paying it down.
- **Skipping the `@code-review` pass because "it's just a lint fix."** The lint fix is the opportunity to improve the code; the review is how you know you did.
