# CloudKit Schema as Source of Truth — Design

**Date:** 2026-04-25
**Status:** Design, pending implementation plan
**Supersedes:** the prior plan that lived only on the `feat/cloudkit-schema-as-source` branch (still pinned to legacy `CD_*`-prefixed record names and incomplete relative to the current Swift code).

---

## 1. Motivation

`CloudKit/schema.ckdb` is meant to be the canonical CloudKit schema, but in practice today it is:

- Dramatically out of date. `RecordTypeRegistry.allTypes` lists 11 record types; the committed manifest declares only four (`AccountRecord`, `ProfileRecord`, `TransactionLegRecord`, `TransactionRecord`) plus the system `Users` type.
- Internally inconsistent. Three of the four declared types are missing fields the running code already writes (e.g. `TransactionRecord` is missing `notes`, `recurPeriod`, `recurEvery`, and the entire `importOrigin*` family).
- Indexed inconsistently. Only `AccountRecord` declares `"___recordID" REFERENCE QUERYABLE`, so the other types cannot be looked up by `recordName` in the iCloud Console.
- Hand-edited with no enforcement. There is no gate that a field added to `*Record+CloudKit.swift` must also be added to `schema.ckdb`, and no gate that a field declared in `schema.ckdb` is actually used.

The pipeline today treats CloudKit Development as the de facto source of truth (lazy field creation through Debug builds), with `schema.ckdb` lagging behind as a stale export. That is exactly inverted: a Release build that writes a field never exercised in Debug will silently stall on first sync because Production does not declare it.

This design inverts the pipeline. `CloudKit/schema.ckdb` becomes the canonical source of truth, hand-edited and reviewed in PRs. A code generator produces the Swift wire layer from it. CloudKit Development and Production are derived environments populated by `cktool`. Adding a field is a one-place edit in `.ckdb`; the wire struct, the `cktool import-schema` push to Dev/Prod, and the iCloud Console all flow from that.

## 2. Deliverables

- **Rewrite** `CloudKit/schema.ckdb` to declare all 11 current record types with bare names, complete field sets, and `___recordID REFERENCE QUERYABLE` on every type.
- **New** `CloudKit/schema-prod-baseline.ckdb` — committed snapshot of the current Production schema; updated automatically after every `promote-schema` run.
- **New** SPM package `tools/CKDBSchemaGen/` — standalone Swift executable that parses `schema.ckdb` and emits the Swift wire layer. Also exposes a `check-additive` mode used by CI.
- **New** generated directory `Backends/CloudKit/Sync/Generated/` (gitignored) — one `<RecordType>CloudKitFields.swift` per non-system record type.
- **Refactored** all 11 hand-written `Backends/CloudKit/Sync/*Record+CloudKit.swift` files to construct/consume the generated wire structs and own only the domain-type mapping (UUID ↔ String, Bool ↔ Int64, recordID strategy, defaults).
- **Updated** `Justfile`:
  - `just generate` now runs `ckdb-schema-gen` before `xcodegen`, so the generated wire structs exist before Xcode project generation.
  - `just check-schema-additive` — pure-text additivity check used by PR-time CI.
  - `just verify-schema` — manual local convenience: import `.ckdb` to a personal Dev container with `--validate`. Not in CI.
  - `just dryrun-promote-schema` — manual local convenience: `reset-schema && import-schema --validate` against personal Dev. Not in CI.
  - `just promote-schema` — server-side; runs in the release-tag CI workflow only. Imports `.ckdb` to Production with `--validate`, then exports Production into `schema-prod-baseline.ckdb` and opens a follow-up PR with the refreshed baseline.
- **New** project skill `.claude/skills/modifying-cloudkit-schema/SKILL.md` — instructions for future agents (and humans) on adding/removing/modifying fields and record types, what is and is not permitted, and which `just` targets to use.
- **Updated** `guides/SYNC_GUIDE.md` — replace the "Schema Evolution" section with a description of the new pipeline.
- **Updated** `CLAUDE.md` — short pointer in the Build & Test section to the new pipeline and the skill.
- **Updated** CI workflow that currently runs `just verify-schema` — point it at `just check-schema-additive` instead. Add a release-tag job that runs `just promote-schema`.

Single PR. The new `.ckdb`, the generator, the wire structs, the refactored adapters, the baseline, the skill, the docs, and the CI changes ship together to avoid leaving `main` half-migrated.

## 3. Architecture overview

```
                       hand-edited
CloudKit/schema.ckdb  ─────────────┐
        │                          │
        │ cktool import-schema     │ ckdb-schema-gen (generate)
        │ (release-tag CI)         │ (just generate)
        ▼                          ▼
   CloudKit Production      Backends/CloudKit/Sync/Generated/
        │                       <RecordType>CloudKitFields.swift
        │ cktool export-schema      │
        │ (after promote)           │ used by
        ▼                           ▼
CloudKit/schema-prod-baseline.ckdb  Backends/CloudKit/Sync/<RecordType>+CloudKit.swift
        │                                   (hand-written, thin)
        │
        │ static additivity check
        ▼
just check-schema-additive (PR-time CI)
```

**Two derived artefacts from one source.** `schema.ckdb` is the only file a developer hand-edits when a CloudKit field changes. The Swift wire layer and CloudKit's live schemas are both downstream of it.

**One additional source of truth: `schema-prod-baseline.ckdb`.** This is a snapshot of what is currently in Production. It is not edited by hand; it is only ever rewritten by `promote-schema` after a successful `cktool import-schema --environment production`. It is the comparison target for PR-time additivity checks. Committing it to the repo (rather than fetching live in CI) gives us:

- A static, deterministic CI check with no CloudKit credentials in PR pipelines.
- A historical audit trail: `git log CloudKit/schema-prod-baseline.ckdb` shows the schema state at every release.
- No race condition between concurrent CI runs.

## 4. Components

### 4.1 `CloudKit/schema.ckdb` — canonical manifest

Hand-authored. Reviewed in PRs as plain text. Conventions:

- Record type names are bare (`AccountRecord`, not `CD_AccountRecord`). The CD\_ prefix was a SwiftData mirror artefact; current sync code writes bare names.
- Every record type declares the standard system-field block:
  ```
  "___createTime" TIMESTAMP,
  "___createdBy"  REFERENCE,
  "___etag"       STRING,
  "___modTime"    TIMESTAMP,
  "___modifiedBy" REFERENCE,
  "___recordID"   REFERENCE QUERYABLE,
  ```
  The `QUERYABLE` on `___recordID` is required so every type can be looked up by `recordName` in the iCloud Console.
- User-defined fields use this index policy by default:
  - `STRING` → `QUERYABLE SEARCHABLE SORTABLE`
  - `INT64` → `QUERYABLE SORTABLE`
  - `TIMESTAMP` → `QUERYABLE SORTABLE`
  - `BYTES` → no indexes (CloudKit cannot index bytes anyway)
  Per-field overrides may narrow this, but never broaden — once an index ships in Production, removing it is brittle.
- Every record type declares the standard grants:
  ```
  GRANT WRITE TO "_creator",
  GRANT CREATE TO "_icloud",
  GRANT READ TO "_world"
  ```
- The `Users` system type stays declared (matches what `cktool export-schema` emits) with `roles LIST<INT64>`.
- `//` comments are used to annotate intent. The most important is:
  ```
  // DEPRECATED: replaced by foo, kept for additive-only Production compatibility.
  oldFieldName STRING QUERYABLE SEARCHABLE SORTABLE,
  ```
  The generator skips deprecated lines (so the wire struct does not expose the field), but `cktool import-schema` still uploads them, which preserves the additive-only Production invariant.

### 4.2 `tools/CKDBSchemaGen/` — standalone SPM executable

Lives outside the main app's build graph because the main app imports the wire structs the tool generates; the tool must build first.

Layout:

```
tools/CKDBSchemaGen/
├── Package.swift
├── Sources/
│   └── CKDBSchemaGen/
│       ├── Parser.swift          // .ckdb → Schema (in-memory model)
│       ├── Schema.swift          // record types, fields, indexes, deprecation flag
│       ├── Generator.swift       // Schema → Swift source
│       ├── Additivity.swift      // proposed Schema vs baseline Schema → diff result
│       └── main.swift            // CLI: generate | check-additive
└── Tests/
    └── CKDBSchemaGenTests/
        ├── ParserTests.swift
        ├── GeneratorTests.swift
        └── AdditivityTests.swift
```

Two CLI subcommands:

- `ckdb-schema-gen generate --input <schema.ckdb> --output <Generated/>`
  Parses the manifest, writes one `<RecordType>CloudKitFields.swift` per non-system, non-deprecated record type. Skips `Users`.
- `ckdb-schema-gen check-additive --proposed <schema.ckdb> --baseline <schema-prod-baseline.ckdb>`
  Parses both. Exits non-zero with a diagnostic if the proposed manifest violates any of:
  - Removes a record type present in baseline (deprecation marker on the type itself counts as present).
  - Removes a field present in baseline (`// DEPRECATED` line counts as present).
  - Changes a field's type.
  - Removes an index from a field.

The parser handles only the subset of the schema language we use: `DEFINE SCHEMA`, `RECORD TYPE Name (...)` blocks, field declarations, `GRANT` lines, `LIST<…>`, and `//` line comments. It does not need to round-trip arbitrary `.ckdb` files. If `cktool` ever introduces new constructs we do not handle, the parser fails fast on the first schema-touching PR — explicit failure beats silent skipping.

### 4.3 Generated wire structs — `Backends/CloudKit/Sync/Generated/<RecordType>CloudKitFields.swift`

One file per non-system record type. Header marks it as auto-generated. Files are gitignored — same convention as `Moolah.xcodeproj`.

Shape:

```swift
// THIS FILE IS GENERATED. Do not edit by hand.
// Source: CloudKit/schema.ckdb. Regenerate with: just generate.

import CloudKit
import Foundation

struct AccountRecordCloudKitFields {
  var name: String?
  var type: String?
  var instrumentId: String?
  var position: Int64?
  var isHidden: Int64?

  static let allFieldNames: [String] = [
    "name", "type", "instrumentId", "position", "isHidden",
  ]

  init(
    name: String? = nil,
    type: String? = nil,
    instrumentId: String? = nil,
    position: Int64? = nil,
    isHidden: Int64? = nil
  ) {
    self.name = name
    self.type = type
    self.instrumentId = instrumentId
    self.position = position
    self.isHidden = isHidden
  }

  init(from record: CKRecord) {
    self.name = record["name"] as? String
    self.type = record["type"] as? String
    self.instrumentId = record["instrumentId"] as? String
    self.position = record["position"] as? Int64
    self.isHidden = record["isHidden"] as? Int64
  }

  func write(to record: CKRecord) {
    if let name { record["name"] = name as CKRecordValue }
    if let type { record["type"] = type as CKRecordValue }
    if let instrumentId { record["instrumentId"] = instrumentId as CKRecordValue }
    if let position { record["position"] = position as CKRecordValue }
    if let isHidden { record["isHidden"] = isHidden as CKRecordValue }
  }
}
```

Rules:

- Only CloudKit-native types (`String?`, `Int64?`, `Date?`, `Data?`) appear. Domain richness (UUID, Bool, enum raw values) is the adapter's job.
- Every property is optional — CloudKit considers all fields optional at the storage level, and the adapter is the layer that decides what defaults to use.
- The struct is `internal` (default access). It is not part of the public Domain API.
- No equality, no `Sendable`, no extensions. Every behaviour beyond field reading and writing belongs in the hand-written adapter.

### 4.4 Hand-written adapters — `Backends/CloudKit/Sync/<RecordType>+CloudKit.swift`

Refactored to be thin. They own:

- The recordID strategy (UUID vs `recordName`) — `InstrumentRecord` is keyed by `recordName`, every other current type by UUID.
- The wire-to-domain conversions (UUID ↔ `uuidString`, Bool ↔ `Int64` 0/1, enum raw values, defaults for missing fields).
- Conformance to `CloudKitRecordConvertible` and `IdentifiableRecord` / `SystemFieldsCacheable`.

Sketch (after refactor):

```swift
extension AccountRecord: CloudKitRecordConvertible {
  static let recordType = "AccountRecord"

  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    AccountRecordCloudKitFields(
      name: name,
      type: type,
      instrumentId: instrumentId,
      position: Int64(position),
      isHidden: isHidden ? 1 : 0
    ).write(to: record)
    return record
  }

  static func fieldValues(from record: CKRecord) -> AccountRecord? {
    guard let id = record.recordID.uuid else { return nil }
    let fields = AccountRecordCloudKitFields(from: record)
    return AccountRecord(
      id: id,
      name: fields.name ?? "",
      type: fields.type ?? "bank",
      instrumentId: fields.instrumentId ?? "AUD",
      position: Int(fields.position ?? 0),
      isHidden: (fields.isHidden ?? 0) != 0
    )
  }
}
```

Compilation guarantees:

- A field declared in `.ckdb` but not used by the adapter compiles cleanly (the wire struct has the property; the adapter just does not populate it). On upload, the field is absent from the CKRecord, which is acceptable under additive-only semantics. PR review should still catch this.
- A field used by the adapter but not declared in `.ckdb` does not compile (the wire struct has no property of that name). This catches the most common drift mistake.
- A wire-type/domain-type mismatch is caught at the construction site (e.g. assigning a `String` to an `Int64?` property fails).

### 4.5 `CloudKit/schema-prod-baseline.ckdb` — committed Production snapshot

A plain text file at `CloudKit/schema-prod-baseline.ckdb`. Not hand-edited. Always the verbatim output of `cktool export-schema --environment production` against the live container, in cktool's canonical form (alphabetised fields, no comments). It will not be byte-identical to the hand-authored `schema.ckdb` even when they describe the same schema; the additivity check operates on parsed schemas, not byte diffs.

- Initial value at PR time: the export of v2 Production today (which is empty / Users-only because v2 has never been promoted). Captured once during bootstrap (§6 step 3) and committed.
- After the first successful `promote-schema`: the export of v2 Production after the first import — i.e. the same set of record types, fields, types, and indexes as `schema.ckdb` minus the `// DEPRECATED` comments and any other source-level metadata.
- After every subsequent `promote-schema`: the export of the new Production schema after the import.

Comment loss in the baseline is intentional and harmless: deprecated fields are *live fields in Production* (that is the entire point of the deprecation marker), so the baseline correctly lists them as present. The Swift wire layer's view of "deprecated = skip" is a source-only concept that does not need to round-trip through cktool.

`promote-schema` opens a follow-up PR titled `chore(cloudkit): refresh schema-prod-baseline after release vX.Y` containing only the baseline diff. The merge-queue handles it like any other PR.

### 4.6 `Justfile` targets

Updated and new targets, ordered by the workflow each one fits into.

| Target | Run by | Touches CloudKit? | Purpose |
|---|---|---|---|
| `generate` | developer, CI | no | Runs `ckdb-schema-gen generate` then `xcodegen`. Both are deterministic. |
| `check-schema-additive` | PR-time CI | no | `ckdb-schema-gen check-additive --proposed CloudKit/schema.ckdb --baseline CloudKit/schema-prod-baseline.ckdb`. Pure text comparison. |
| `verify-schema` | developer (manual) | yes — Dev | `cktool import-schema --environment development --validate --file CloudKit/schema.ckdb`. Local belt-and-braces verification on the developer's personal Dev container. Not in CI. |
| `dryrun-promote-schema` | developer (manual) | yes — Dev (destructive) | Apple's recommended Production-equivalent dry-run: `cktool reset-schema && cktool import-schema --environment development --validate`. Wipes the developer's personal Dev container; intentional. Not in CI. |
| `promote-schema` | release-tag CI | yes — Production | `cktool import-schema --environment production --validate`, then `cktool export-schema --environment production --output-file CloudKit/schema-prod-baseline.ckdb`, then open a follow-up PR with the refreshed baseline. |
| `verify-prod-matches-baseline` | release-tag CI (pre-promote) | yes — Production (read-only) | `cktool export-schema --environment production`, diff against committed `schema-prod-baseline.ckdb`. Catches manual dashboard edits or partial prior promotes. Halts the release on mismatch. |

The only CI-time CloudKit calls happen on a release tag, in a serialized release workflow, against Production only. PR-time CI never touches CloudKit.

### 4.7 `.claude/skills/modifying-cloudkit-schema/SKILL.md`

Skill name: `modifying-cloudkit-schema`. Frontmatter description triggers on:

- Adding, removing, renaming, or retyping a CloudKit field.
- Adding or removing a `CloudKitRecordConvertible` record type.
- Compile errors against the generated wire structs ("value of type 'AccountRecordCloudKitFields' has no member 'foo'", "extra argument 'foo' in call" against a wire struct's memberwise init).
- Anything mentioning `.ckdb`, `cktool`, `schema-prod-baseline`, or `Backends/CloudKit/Sync/Generated/`.

Content:

1. **The pipeline.** `.ckdb` → `ckdb-schema-gen` → wire struct → hand-written adapter → CKRecord. One source, two consumers.
2. **Adding a field.** Edit `.ckdb`. Run `just generate`. Wire struct now has the property. Update the adapter to populate it on write and consume it on read. Build, test, commit (only the `.ckdb` change — generated files are gitignored).
3. **Removing a field.** Add `// DEPRECATED: <reason>` on its own line immediately above the field declaration and leave the field's own line in place. Production is additive-only forever; deletion is impossible. Regenerate, remove references in the adapter. The build fails until every reference is cleaned up. Commit.
4. **Renaming a field.** A rename is a deprecation plus an addition. Add the new field, deprecate the old, migrate data in the adapter (read both, write only the new), and only after the adapter is fully migrated mark the old one deprecated. Never edit the old line in place.
5. **Changing a field's type.** Not allowed. Same rule as rename: add a new field with the new type, deprecate the old.
6. **Adding a record type.** Declare the type in `.ckdb` with the standard system-field block + `___recordID REFERENCE QUERYABLE` + standard grants. Regenerate. Add the domain type and its `*Record+CloudKit.swift` adapter. Register it in `RecordTypeRegistry.allTypes`. Add a round-trip test under `MoolahTests/Backends/CloudKit/`.
7. **Errors and what they mean.**
   - "value of type 'XCloudKitFields' has no member 'foo'" or "extra argument 'foo' in call" against a wire struct → `.ckdb` does not declare the field. Either add it (if it should exist) or remove the reference from the adapter.
   - `just check-schema-additive` failure → you are removing/changing a field that exists in Production. Use `// DEPRECATED` instead.
   - `cktool import-schema` failure → the manifest is syntactically invalid or conflicts with the destination's schema in a non-additive way. Read the cktool message; do not silence with `--force`.
8. **The just targets.** Always go through `just`. Never invoke `cktool`, `xcodegen`, `swift-format`, or `ckdb-schema-gen` directly for routine work. Never edit files in `Backends/CloudKit/Sync/Generated/`. Never edit `Moolah.xcodeproj`.
9. **The additive-only invariant.** Production schema only grows. Once a field is in Production, it is in Production forever. The wire-layer-deletion path is `// DEPRECATED`, not a line removal.

The skill also lists the relevant project-level invariants (CD\_ prefix is dead, every record type needs `___recordID QUERYABLE`, only Production is locked — Development is your scratch pad).

### 4.8 `guides/SYNC_GUIDE.md` updates

Replace the current "Schema Evolution" section with one titled "Schema Management" describing the inverted pipeline, the additive-only invariant, the role of `schema-prod-baseline.ckdb`, the just targets, and a pointer to the `modifying-cloudkit-schema` skill for the procedural details. Keep it short — the skill is the procedural reference, the guide is the architectural reference.

### 4.9 `CLAUDE.md` updates

Short paragraph in the Build & Test section pointing at `guides/SYNC_GUIDE.md` §Schema Management and the `modifying-cloudkit-schema` skill. No procedural detail in `CLAUDE.md` itself.

## 5. Workflows

### 5.1 Developer adds a field

1. Edit `CloudKit/schema.ckdb`, add the field declaration to the right `RECORD TYPE` block.
2. `just generate`.
3. Generated wire struct now has the property. The adapter file does not yet construct or consume it.
4. Edit the corresponding `Backends/CloudKit/Sync/<RecordType>+CloudKit.swift`:
   - In `toCKRecord`, populate the new wire struct field from the domain model.
   - In `fieldValues(from:)`, read it back out and populate the domain model.
5. Update the round-trip test for that record type.
6. `just format`, `just test`, commit (only `schema.ckdb` and the adapter — generated files are gitignored).

### 5.2 Developer removes a field

1. Edit `CloudKit/schema.ckdb`. Above the field's line, add `// DEPRECATED: <reason>`. Do not delete the line.
2. `just generate`. Wire struct no longer exposes the field.
3. Build fails on every reference in the adapter. Remove the references; the adapter no longer reads or writes the field.
4. `just format`, `just test`, commit.

The deprecated declaration stays in `.ckdb` indefinitely. `cktool import-schema` continues to declare the field on Production, satisfying the additive-only invariant. The Swift code forgets it ever existed.

### 5.3 Developer adds a record type

1. Declare the new type in `.ckdb` with the standard block.
2. `just generate`. New wire struct exists.
3. Add the domain type (`Domain/Models/`) and the SwiftData `@Model` (`Backends/CloudKit/Models/`) if applicable.
4. Add `Backends/CloudKit/Sync/<RecordType>+CloudKit.swift` with `CloudKitRecordConvertible` conformance.
5. Add the type to `RecordTypeRegistry.allTypes`.
6. Add round-trip tests.
7. Commit.

### 5.4 PR-time CI

1. Checkout. `just generate` (parses `.ckdb`, generates wire structs, regenerates `Moolah.xcodeproj`).
2. `just check-schema-additive`. Pure-text check: is proposed `.ckdb` additive over committed `schema-prod-baseline.ckdb`?
3. `just format-check`.
4. `just test`. Includes per-record round-trip tests.

No CloudKit credentials. No CloudKit calls. Concurrent CI runs are independent.

### 5.5 Release-tag CI

1. `just verify-prod-matches-baseline`. Reads live Production schema, diffs against committed `schema-prod-baseline.ckdb`. Fails the release on mismatch (manual dashboard edit, partial prior promote — needs human attention before continuing).
2. `just promote-schema`. `cktool import-schema --environment production --validate`.
3. After successful promote: `cktool export-schema --environment production --output-file CloudKit/schema-prod-baseline.ckdb`, commit, open follow-up PR via `gh pr create`. The PR is auto-queued in the merge queue.
4. TestFlight build proceeds.

The release pipeline runs serially. The baseline-refresh follow-up PR is mechanical (only `schema-prod-baseline.ckdb` differs) and merges quickly. The next schema-touching PR opens against the refreshed baseline.

## 6. Bootstrap

Today's `schema.ckdb` is too far out of date to be a useful starting point and v2 Production has never been promoted, so there is no live source either. Bootstrap is one-time and manual:

1. Hand-derive the field inventory by reading every `Backends/CloudKit/Sync/*Record+CloudKit.swift`. The shape is regular enough that this is mechanical.
2. Write the new `CloudKit/schema.ckdb` with all 11 types, complete fields, `___recordID REFERENCE QUERYABLE` everywhere, and the standard grants and indexes per §4.1.
3. Run `cktool export-schema --environment production --output-file CloudKit/schema-prod-baseline.ckdb` against v2 once and commit the result as the initial baseline. Per the prior plan's investigation v2 Production has never been promoted, so this should be empty / Users-only — but use the actual export rather than hand-authoring an "empty" schema, so format matches whatever cktool produces. The first `promote-schema` after merge will publish the entire manifest as the initial Production schema, and the post-promote export becomes the first non-trivial baseline.
4. Build the generator and the wire structs.
5. Refactor the 11 adapters.
6. Ship.

The first post-merge release runs `promote-schema` against an empty v2 Production, which makes the new manifest the entire schema. The post-promote export then equals the manifest, and `verify-prod-matches-baseline` becomes meaningful from the second release onward.

We do not write a one-shot bootstrap tool. The synthetic-record approach the prior design considered for bootstrapping has the same risk that motivated this redesign — incomplete optionals masking missing fields — and it would be discarded immediately afterwards. Hand-deriving the inventory is a finite, reviewable cost.

## 7. Constraints

- **Production is additive-only forever.** Fields and record types never leave Production. The Swift wire layer can forget about a field by way of `// DEPRECATED`, but the `.ckdb` line stays.
- **No type changes.** Once a field is `STRING`, it stays `STRING`. To "change" a type, add a new field, deprecate the old, migrate data in the adapter.
- **No retroactive index narrowing.** Indexes are easy to add and brittle to remove in Production. The default index policy in §4.1 is intentionally generous.
- **The wire layer uses only CloudKit-native types.** `String?`, `Int64?`, `Date?`, `Data?`. Domain richness lives in adapters.
- **`.ckdb` is the single editable source.** Do not regenerate it from CloudKit, do not infer it from Swift, do not edit `schema-prod-baseline.ckdb` by hand.
- **Generated files are gitignored** and regenerated by `just generate`.

## 8. Testing

- **`tools/CKDBSchemaGen/Tests/`** — unit tests for the parser (comments, deprecated lines, `LIST<…>`, `Users` system type, malformed input), the generator (per-type emission, deprecation skipping, system-type skipping), and the additivity checker (each forbidden change category).
- **`MoolahTests/Backends/CloudKit/RoundTripTests.swift`** (per type or one consolidated suite) — for each `CloudKitRecordConvertible`, build a fully-populated domain instance, call `toCKRecord(in:)`, call `fieldValues(from:)`, assert equality on every domain property. Catches adapter bugs.
- **`just check-schema-additive`** in CI catches non-promotable schema changes.
- **Build itself** catches wire-struct/adapter drift.

There are intentionally no synthetic-CKRecord coverage tests. Coverage is structural (the wire struct is generated from `.ckdb`), not asserted via samples.

## 9. What this design does NOT do

- **No SwiftSyntax.** The generator parses `.ckdb`, not Swift.
- **No runtime introspection.** No reading `record.allKeys()` to infer schema.
- **No macros.** No `@CloudKitRecord` annotation.
- **No CI-only CloudKit container.** The PR-time additivity check is static, so a separate container is unnecessary.
- **No automatic enforcement that every declared field is consumed by the adapter.** Declaring an unused field is a sync no-op (extra storage capacity, harmless) and obvious in PR review.
- **No automatic baseline refresh on every CI run.** Only `promote-schema` updates the baseline; PR-time CI uses the committed baseline as-is.
- **No rewriting of the SwiftData `@Model` types.** Their shape is decided by domain needs, not CloudKit. The adapter is the bridge.

## 10. Open questions / follow-ups

1. **Direct push vs PR for baseline refresh.** Default in this design: open a PR via `gh pr create` and let the merge queue handle it. If that proves clunky in practice (e.g. baseline-refresh PRs piling up behind ordinary PRs), an alternative is to grant the release-CI bot a branch-protection exception on `CloudKit/schema-prod-baseline.ckdb` only. Defer.
2. **`cktool` comment preservation.** `//` comments in `.ckdb` survive `cktool import-schema` (the importer does not round-trip them). The generator preserves them in source. We never feed `cktool export-schema` output back through the generator, so comment loss on export is a non-issue. Verify on first run regardless.
3. **Concurrent release tags.** Two releases tagged in quick succession could race on `promote-schema` and the baseline-refresh PR. Releases are serialised by the existing release pipeline, so this is not expected in practice. If it becomes an issue, add an explicit lock around the release-tag job.
4. **Branch protection on `CloudKit/schema-prod-baseline.ckdb`.** Once the file is in place, consider requiring that human-authored PRs do not touch it (only the release bot can). Out of scope for this design.

## 11. Why this design vs. the alternatives considered

- **vs. hand-author + validate (the prior plan).** The prior plan kept `schema.ckdb` hand-written and asserted on it from a Swift coverage test that walked synthetic records. The synthetic-record approach has a structural hole: a missed optional in the synthetic instance hides a missing manifest declaration. The inverted approach generates Swift from the manifest, so a missed declaration produces a compile error rather than a silent gap.
- **vs. SwiftSyntax-driven extraction.** Walking `*Record+CloudKit.swift` ASTs to derive the schema is brittle (helper functions, `if let` patterns, encoding tricks like `value ? 1 : 0`) and adds a SwiftSyntax dependency to the build. Inverted direction is simpler.
- **vs. runtime introspection of `record.allKeys()`.** Same hole as synthetic records: depends on every optional being populated.
- **vs. macros.** Macros could derive both `toCKRecord` and the schema from a single declaration, but the macro infrastructure is heavy for what we get. The wire struct + thin adapter pattern is conceptually similar with less machinery.
- **vs. shared CI CloudKit container with destructive dry-run.** Concurrent CI races on `cktool reset-schema`, and the dev's local Dev state is wiped on every PR run. Static additivity check sidesteps both.
- **vs. separate CI CloudKit container.** A CI-only container has its own Production, which can drift from real Production — so a dry-run that passes against CI Prod could still fail against real Prod. The static check against the committed baseline is the only gate that compares against actual Production.
