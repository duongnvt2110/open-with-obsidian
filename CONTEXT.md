# Context Boundary

The locked task separates:

- writable scope
- bounded recommended read context
- canonical convention examples
- structured repository-understanding evidence
- inspection and project-contract bindings
- trusted verification inputs and declared tools

Evidence paths must exist in the approved baseline inventory. Canonical examples
may extend read context but never write scope. Broad read-context size is recorded
and warned on, but it no longer blocks approval. The harness generates a compact
base packet plus bounded source bundles under `runs/<run-id>/context/current/`.
Oversized excerpts remain available by path and digest rather than being silently
truncated.

Generated inspection observations remain runtime evidence and do not change
repository authority. Inventory exclusions cannot hide writable scope, read
context, examples, local executables, declared outputs, tools, or trusted inputs.

This repository-local harness records and validates boundaries; it does not
technically prevent an unrestricted process from reading files outside them.


## Compact context commands

```bash
./.agent-harness/harness context build
./.agent-harness/harness context show
```

`context build` is provider-neutral. It uses byte limits, exact source excerpts,
bounded failure summaries, and a replaceable working-memory file. Budget overflow
produces `CHUNKED` or `INCOMPLETE` context status without changing the task
lifecycle. Full source files and verification logs remain authoritative.


The persistent selection file is:

```text
.agent-harness/runs/<run-id>/context/selections.tsv
```

Each row is `path<TAB>start_line<TAB>end_line<TAB>reason`. `0<TAB>0` means
the whole file. Large whole-file selections are retained as path-and-digest
references instead of being embedded. `context show` verifies source hashes and
reports `SOURCE_STATUS=STALE` when a selected file or working-memory artifact changed after generation. Generated context is digest-validated before display, and task-contract drift preserves the previous approved generation instead of rebuilding from unapproved content.

The default safety limits also cap context to four source bundles and fifty unique selections. Duplicate selections are retained once, oversized working memory is referenced by path and digest, and parent-directory symlink escapes are rejected.

The machine-readable worker packet follows the same bounded-output principle.
`harness next --json` includes `packet_digest`; passing that value through
`--since` returns an unchanged summary without repeating task tables. When the
rendered packet exceeds `WORKFLOW_PACKET_MAXIMUM_BYTES`, the default response
contains task/run identity, original size, digest, next action, and the
authoritative task-contract path. `--details` is the explicit unbounded view.

Public harness tests also keep complete unsuccessful output outside the
caller response. The default result contains only gate or mode, exit status,
artifact path, byte count, and digest. This limits transport size; it does not
change the authoritative verification evidence or guarantee a
provider-specific token count.

For harness self-update tasks, the worker packet includes deterministic testing
guidance: affected suites, focused cases, reason codes, a recommended focused
command, and the minimum required completion mode. The selection is repository
policy, not caller discretion. Normal repository tasks remain governed by
their approved registered checks.
