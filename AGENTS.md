# Harness Instructions

Before implementation, run:

```bash
./.agent-harness/harness status
./.agent-harness/harness next
```

Read the complete active contract:

```text
spec.conf
plan.conf
understanding.conf
understanding-evidence.tsv
inspection-binding.conf
project-binding.conf
affected-modules.tsv
assumptions.tsv
implementation-plan.tsv
criteria.tsv
scopes.txt
read-context.txt
checks.txt
coverage.tsv
applicable-conventions.tsv
applicable-exceptions.tsv
```

Do not edit outside approved scopes. Read-context and canonical examples are not
write permission. Do not manually edit harness, task, run, approval, convention,
inventory-policy, identity, evidence, review, history, or attestation records.

Do not edit `.agent-harness/**`, `AGENTS.md`, `WORKFLOW.md`, or `CONTEXT.md` as a
normal task. Authority changes use dedicated harness commands and are denied
while a task is active.

Only verification may produce `PASSED`. Only finalization may produce
`FINALIZED`. If actual impact introduces new scope, modules, conventions,
outputs, or checks, amend and reapprove the task instead of bypassing the locked
contract.
