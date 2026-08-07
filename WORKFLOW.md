# Harness Workflow

```text
NO_TASK
  -> INTAKE
  -> CLARIFICATION_REQUIRED (optional)
  -> IMPLEMENTING
  -> VERIFYING
  -> PASSED
  -> FINALIZED
```

Failure path:

```text
VERIFYING -> FAILED -> REMEDIATING -> VERIFYING
```

`state.conf` is run-state authority, `events.tsv` is the append-only hash chain,
and `current.md` plus `tasks/index.tsv` are generated projections. One active
run is allowed per detected Git worktree identity.

## Intake and understanding gate

Approval remains in `INTAKE` until the task has:

- goal, stakeholders, acceptance criteria, scope, and evidence coverage
- project mode, task profile, and risk classification
- structured repository evidence for brownfield work
- an inspection binding or an explicit human-reviewed skip reason
- entry points, data flow, dependencies, compatibility and impact analysis
- affected modules, resolved assumptions, implementation steps, and rollback
- a valid project contract for greenfield work
- applicable conventions, inventory policy, identity policy, and toolchain data

This is an approval prerequisite, not another lifecycle.

## Approval binding

Approval binds:

- normalized task and understanding contracts
- baseline inventory and optional baseline Git commit/tree
- project contract and inspection evidence
- conventions, exceptions, canonical examples, and inventory policy
- one ordered effective-check plan
- command configurations, executables, tools, trusted inputs, and environment keys
- resolved approval identities, identity-policy hash, and worktree identity

For externally verified approval, `task approval-subject` produces the exact
contract hash that signed evidence must bind.

Critical risk requires two distinct resolved principals. High and critical final
review must be independent from initial approvers.

## Verification

Each check runs in a fresh copy of the same immutable phase snapshot. A check
cannot mutate the workspace observed by another check. Only successful `PREPARE` checks may promote explicitly declared `EPHEMERAL`
outputs. `REQUIRED_IN_REPOSITORY` outputs must already match regenerated
content. All outputs must stay inside approved scope and outside exclusions and
trusted inputs.

```text
PREPARE -> STATIC -> BUILD -> TEST -> INTEGRATION -> MIGRATION
```

Blocking failures are collected within a phase; later phases are skipped.
Inventory, snapshot-copy, check-execution, and total timing are stored in
`verification-metrics.conf`.
`SHOULD` and `MAY` failures become reviewable warnings. Actual paths,
applicability, and exceptions are recalculated before execution.

Harness self-verification retains four public category gates. `fast` provides
short feedback. `lifecycle` exercises successful execution, failure,
remediation, review, finalization, package upgrade, and business-repository
flows. `adversarial` exercises denial, integrity, timeout, and recovery
boundaries. `release` executes every registered case; the historical `--full`
option is its compatibility alias. A filter is always intersected with the
selected gate, and an empty intersection is an error.

A deterministic mode layer reuses the same runner rather than introducing a
second test system. `focused` selects named cases or a subsystem suite,
`standard` combines the fast, lifecycle, and adversarial categories, and
`full` maps to release. `auto` evaluates Git-changed paths against
`policy/test-impact.tsv`; the strongest matching rule wins and an unmapped path
requires full testing. `--explain` reports the decision without execution.

During an approved harness self-update, `next` derives preliminary guidance
from writable scope and recalculates it from actual repository changes when a
baseline inventory is available. It recommends focused tests during editing
and states the minimum completion mode. This guidance does not replace the
registered checks used for normal business-repository tasks.

Public test output is summary-first. Complete unsuccessful output is retained
as a digest-bound artifact instead of entering the command response. Complete
transcripts require explicit `--verbose`.

## Final review and finalization

Only verification can produce `PASSED`. Required manual conventions and
advisory warnings are reviewed against the verified patch hash. Finalization
rejects repository drift, verifies final review, writes a run attestation, and
optionally appends its hash to either a hash-chained local anchor or a
hash-bound external anchor adapter. Local files improve detection but are not
immutable.

## Amendment and recovery

Approved contracts are superseded rather than edited in place. Amendment uses
idempotent journal phases:

```text
PREPARED
PREDECESSOR_TERMINATED
SUCCESSOR_CREATED
POINTER_SWITCHED
COMPLETED
```

`recover` has a deterministic action for every amendment phase and also repairs
same-host stale locks, interrupted verification, event/state projections,
convention journals, and interrupted finalization. Cross-host locks require an
identity-bound `--force-lock` operation with a recorded reason. Finalization
uses these idempotent phases:

```text
PREPARED
STATE_FINALIZED
TASK_MARKED
ATTESTED
ANCHORED
COMPLETED
```


## Package lifecycle

Package operations are separate from the task lifecycle and introduce no new
workflow authority:

```text
validate source package
  -> stage inside repository-confined operation directory
  -> preserve mutable harness state when upgrading
  -> publish `.agent-harness`
  -> run doctor and package identity checks
  -> COMPLETE or ROLL_BACK
```

Install never overwrites repository-owned files outside `.agent-harness`.
Upgrade is rejected while an active task is in progress. Recovery validates the
expected old or new package digest before completing or rolling back an
interrupted operation.
