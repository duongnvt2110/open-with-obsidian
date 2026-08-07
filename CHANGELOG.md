# Changelog

## 3.6.0-guarded

- Add deterministic `focused`, `standard`, `full`, and `auto` self-test modes while preserving the existing gate interface.
- Add a closed, Bash-readable test-impact policy with conservative full-suite fallback for unknown paths.
- Add `--suite`, `--since`, and non-mutating `--explain` test-selection controls.
- Add self-update testing guidance to text and JSON `harness next` packets while leaving ordinary repository verification unchanged.
- Add compatibility and selector regression tests without introducing caching, dynamic tracing, or a second test runner.

## 3.5.0-guarded

- Make public harness tests summary-by-default and retain complete unsuccessful output as a byte-counted, SHA-256-bound artifact.
- Add explicit fast, lifecycle, adversarial, and release test gates while preserving `--full` as the release alias.
- Add exact worker-packet digests, compact `--since` responses, and configured overflow summaries with explicit `--details` access.
- Bind public-result and worker-packet byte ceilings in the closed policy schema.
- Add public-interface regressions for artifact integrity, gate routing, unchanged packets, and oversized valid task contracts.

## 3.4.15-guarded

- Forward `--filter` through the public `harness test` interface and reject empty test selections instead of reporting a false PASS.
- Normalize unsupported caller locales once at startup so child commands use a supported deterministic locale.
- Derive text and JSON next-action guidance from one resolver, including human-acknowledgement holds.
- Keep obsolete predecessor `manifest.json` metadata out of the source root and clean business-repository exports.
- Register 144 current cases: 54 fast and 90 full-only.

## 3.4.14-guarded

- Bound compact-context bundle and selection counts while preserving non-fatal lifecycle behavior.
- Validate approved task bindings before context generation and preserve the previous valid generation on drift.
- Confine selected files by canonical parent path to reject repository escapes through replaced directories.
- Verify generated context integrity before display and during audit.
- Guarantee the base packet hard limit, reference oversized working memory, and deduplicate selections.
- Avoid materializing oversized source selections, use collision-safe Markdown fences, and recover interrupted publication.
- Add adversarial regression coverage for context drift, tampering, symlink escape, overflow, duplication, and recovery.

## 3.4.13-guarded

- Added provider-neutral compact context generations with one bounded base packet and bounded source bundles.
- Changed broad read-context overflow from approval failure to a warning plus graceful chunking.
- Added exact source selection, reference-only fallback for oversized excerpts, bounded working memory, and bounded failure summaries.
- Preserved previous context during rebuild failures and kept context status separate from lifecycle authority.
- Added read-only `context show` and explicit `context build` commands.

## 3.4.12-guarded

- Complete timeout escalation after the process-group leader exits on `TERM`.
- Discover the actual `setsid` process group instead of assuming PID and PGID are identical.
- Keep full-source distributions audit-clean by separating generated operational history.
- Normalize source permissions for cross-user extraction and verification.
- Certify 126 registered cases: 125 passed, one expected external-repository skip.

## 3.4.11-guarded

- Fail closed on malformed or foreign active pointers.
- Block package evolution whenever an active pointer exists.
- Close task, understanding, manual-review, and project table contracts.
- Require strictly closed source packages for install and upgrade.
- Validate package recovery journals and repository binding.
- Keep status read-only and return controlled errors for missing option values.
- Remove trusted-input pipeline false negatives and test temporary leaks.


## Unreleased

- Added strict package closure validation and declared-versus-executed byte binding.
- Added deterministic standalone export that does not require Git or macOS-specific `stat` behavior.
- Added non-destructive install, state-preserving upgrade, rollback, and repository-confined recovery journals.
- Blocked package upgrades while a task is active and validated both replacement and rollback package identities.
- Made `audit` and `doctor` read-only on clean packages and added audit duration/run/task metrics.
- Fixed invalid `next --json` output when optional check phase/order metadata is omitted.
- Added installed-locale selection and process-group timeout cleanup with TERM/KILL escalation.
- Added direct `--full`, `--json`, and `--filter` parsing to the test runner.
- Reduced the default context ceiling to 64 KiB with a 48 KiB warning threshold.
- Expanded regression coverage to 117 registered cases, including install, upgrade, recovery,
  package tampering, greenfield lifecycle, native brownfield checks, and operation-path confinement.


- Rejected duplicate, unknown, malformed, and non-contiguous command and policy configuration keys.
- Added explicit `EPHEMERAL` and `REQUIRED_IN_REPOSITORY` generated-output dispositions.
- Added `EXTERNAL_VERIFIED` identity with a hash-bound verifier and trusted issuer.
- Added hash-chained local anchors and hash-bound external anchor adapters.
- Added audited cross-host forced lock recovery with resolved identity and reason.
- Replaced polling timeouts with a watchdog model and added verification timing metrics.
- Enabled shell `pipefail` and hardened pipelines that could mask upstream failures.
- Added adversarial tests for configuration ambiguity, generation drift, verified identity,
  anchor adapters and tampering, forced recovery, and metrics.

- Isolated every verification check in a fresh immutable workspace.
- Added controlled promotion of successful, declared `PREPARE` outputs.
- Allowed implementation commits and staging while preserving approved baseline ancestry.
- Added controlled read-only Git snapshots for Git-dependent checks.
- Added structured brownfield evidence and explicit inspection binding/skip decisions.
- Added a complete greenfield project contract with architecture, NFR, decision, and interface records.
- Added minimal toolchain `PATH` binding and hashes for declared tools and interpreters.
- Added `OS_USER`, `ENVIRONMENT`, and external evidence identity policies.
- Added independent high/critical review and distinct-principal critical approval.
- Added finalization attestations, optional external anchors, and external manifest binding.
- Added worktree identity, path serialization checks, approved inventory exclusions,
  and controlled symlink, hard-link, and read-only submodule policies.
- Added observation-backed convention candidates, promotion, exceptions, expiry,
  revocation, conflict detection, applicability dimensions, deprecation, and replacement.
- Split the convention implementation into store, authority, applicability, review,
  and inspection modules.
- Added idempotent task-amendment and finalization journal phases with deterministic recovery.
- Added per-test process isolation, duration reporting, and adversarial regression tests
  for workspace poisoning, generated outputs, Git workflows, identity, evidence,
  toolchain drift, path safety, submodule writes, amendment/finalization recovery, and attestations.
- Preserved a Bash 3.2-compatible, Python-free, `jq`-free consumer runtime.
