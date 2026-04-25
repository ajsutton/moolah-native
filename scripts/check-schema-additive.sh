#!/usr/bin/env bash
#
# Static additivity gate: compares CloudKit/schema.ckdb against the
# committed CloudKit/schema-prod-baseline.ckdb. Pure text — no CloudKit
# calls. Run by CI on every PR.
set -euo pipefail

swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen check-additive \
    --proposed CloudKit/schema.ckdb \
    --baseline CloudKit/schema-prod-baseline.ckdb
