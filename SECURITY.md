# Security and Assurance Boundary

The harness is repository-local and `AUDIT_ONLY`. It validates:

- package integrity and optional externally supplied manifest hash
- structured task understanding and greenfield project authority
- scope, baseline, Git ancestry, worktree identity, and approval identity
- conventions, exceptions, replacements, inventory policy, and history
- strict command schemas, executable and toolchain hashes, environment allowlists,
  trusted inputs, and declared output dispositions
- isolated check execution, mutation detection, warnings, evidence, and review
- state/event consistency, amendment recovery, attestation, and optional anchor

It is not an operating-system security boundary and cannot prevent an
unrestricted external process from bypassing repository-local controls.

## Verification isolation

Every check receives a fresh workspace. Failed or advisory checks cannot poison
later checks. Only successful `PREPARE` checks may promote declared `EPHEMERAL` outputs.
`REQUIRED_IN_REPOSITORY` outputs must regenerate without changing the submitted
repository snapshot. The verifier constructs a minimal approved `PATH`; tools invoked by checks must
be declared with `TOOL_n`. Controlled Git metadata uses a synthetic read-only
snapshot.

## Repository paths

Unsupported path serialization is rejected. Approved symlinks must resolve
inside the repository. Allowed hard links are explicit. Allowed submodules are
pinned/read-only and cannot overlap writable scope. Exclusions cannot hide
scope, read context, examples, local executables, tools, outputs, or trusted
inputs.

## Identity and integrity

`DECLARATIVE` identity provides audit labels only. `OS_USER` and
`ENVIRONMENT` bind identity to local execution context. `EXTERNAL_FILE` binds an
unsigned evidence file to the exact subject hash but does not authenticate its
issuer. `EXTERNAL_VERIFIED` invokes a hash-bound verifier outside the repository
to validate the issuer and evidence. Critical approval requires distinct resolved
principals.

Local manifests and event chains are not an external trust anchor. A local
anchor file adds locking and a hash chain but remains rewritable by its storage
administrator. Use signed release checksums, `HARNESS_EXPECTED_MANIFEST_HASH`,
CI attestations, or a protected external anchor adapter when stronger assurance
is required.

Command-output redaction and process-tree termination remain best-effort.
Semantic architecture, business, security, and compliance decisions still
require human review or trusted repository-specific checks.


## Configuration safety

Package, workflow, command, identity, and anchor configurations are validated
against explicit schemas. Duplicate keys, unknown keys, malformed indexed
fields, and indexed gaps are rejected. The shell entry points enable `pipefail`;
critical pipelines are also written to preserve individual failure status.

## Recovery assurance

Same-host stale locks are recovered through normal ownership checks. Cross-host
locks require `recover --force-lock`, a human reason, resolved identity, and an
audited recovery record. Automatic cross-host lock deletion is intentionally
forbidden.
