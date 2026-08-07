#!/usr/bin/env bash

audit_add_issue() {
    printf '%s\n' "$1" >>"$AUDIT_ISSUES"
}

audit_add_warning() {
    printf '%s\n' "$1" >>"$AUDIT_WARNINGS"
}

validate_finalized_run() {
    local run_id state task_id verification finalization attestation
    run_id=$1
    state=$(state_get "$run_id" STATE)
    [ "$state" = "FINALIZED" ] || return 1
    task_id=$(state_get "$run_id" TASK_ID)
    verification=$(run_dir "$run_id")/verification.conf
    finalization=$(run_dir "$run_id")/finalization.conf
    [ -f "$verification" ] && [ -f "$finalization" ] || return 1
    [ "$(conf_get "$verification" VERDICT)" = "PASSED" ] || return 1
    [ "$(conf_get "$finalization" VERIFICATION_HASH)" = "$(sha256_file "$verification")" ] || return 1
    [ "$(conf_get "$finalization" FINAL_TREE_HASH)" = "$(conf_get "$verification" VERIFIED_TREE_HASH)" ] || return 1
    [ "$(conf_get "$verification" APPROVAL_HASH)" = "$(sha256_file "$(task_dir "$task_id")/approval.conf")" ] || return 1
    [ "$(conf_get "$(finalization_journal_file "$run_id")" STATUS 2>/dev/null || printf '')" = COMPLETED ] || return 1
    attestation=$(run_dir "$run_id")/attestation.conf
    [ -f "$attestation" ] && attestation_verify "$attestation" || return 1
    external_anchor_contains "$attestation" || return 1
}

validate_terminal_approval() {
    local task_id run_id directory approval run_directory state baseline second_identity
    task_id=$1
    run_id=$2
    directory=$(task_dir "$task_id")
    approval=$directory/approval.conf
    run_directory=$(run_dir "$run_id")
    [ -f "$approval" ] && [ -d "$run_directory" ] || return 1
    state=$(state_get "$run_id" STATE 2>/dev/null || printf '')
    workflow_is_terminal "$state" || return 1
    [ "$(conf_get "$approval" TASK_ID)" = "$task_id" ] || return 1
    [ "$(conf_get "$approval" RUN_ID)" = "$run_id" ] || return 1
    [ "$(conf_get "$approval" WORKTREE_ID 2>/dev/null || printf standalone)" = "$(conf_get "$run_directory/state.conf" WORKTREE_ID 2>/dev/null || printf standalone)" ] || return 1
    [ "$(conf_get "$approval" CONTRACT_HASH)" = "$(task_contract_hash "$task_id")" ] || return 1
    baseline=$run_directory/artifacts/baseline-inventory.tsv
    [ -f "$baseline" ] && [ "$(conf_get "$approval" BASELINE_TREE_HASH)" = "$(inventory_hash "$baseline")" ] || return 1
    [ "$(conf_get "$approval" INSPECTION_BINDING_HASH)" = "$(sha256_file "$directory/inspection-binding.conf")" ] || return 1
    [ "$(conf_get "$approval" UNDERSTANDING_EVIDENCE_HASH)" = "$(sha256_file "$directory/understanding-evidence.tsv")" ] || return 1
    [ "$(conf_get "$approval" APPLICABLE_CONVENTIONS_HASH)" = "$(sha256_file "$directory/applicable-conventions.tsv")" ] || return 1
    [ "$(conf_get "$approval" APPLICABLE_EXCEPTIONS_HASH)" = "$(sha256_file "$directory/applicable-exceptions.tsv")" ] || return 1
    [ "$(conf_get "$approval" APPROVAL_IDENTITY_HASH)" = "$(sha256_file "$directory/approval-identity.conf")" ] || return 1
    second_identity=$(conf_get "$approval" SECOND_APPROVAL_IDENTITY_HASH 2>/dev/null || printf NONE)
    if [ "$second_identity" != NONE ]; then
        [ "$second_identity" = "$(sha256_file "$directory/second-approval-identity.conf")" ] || return 1
    fi
    [ "$(conf_get "$approval" EFFECTIVE_CHECKS_HASH)" = "$(sha256_file "$run_directory/artifacts/effective-checks.txt")" ] || return 1
    [ "$(conf_get "$approval" EFFECTIVE_CHECK_METADATA_HASH)" = "$(sha256_file "$run_directory/artifacts/effective-check-metadata.tsv")" ] || return 1
    [ "$(conf_get "$approval" COMMAND_BINDINGS_HASH)" = "$(sha256_file "$run_directory/artifacts/command-bindings.tsv")" ] || return 1
    [ "$(conf_get "$approval" TOOLCHAIN_BINDINGS_HASH)" = "$(sha256_file "$run_directory/artifacts/toolchain-bindings.tsv")" ] || return 1
}

audit_repository() {
    local audit_started audit_finished audit_seconds run_count finalized_run_count task_count expected_files managed_directory managed_file relative current_inventory path kind mode digest active directory run_id state task_id approval expected_index status policy_type policy_pattern policy_reason policy_by policy_at exception_id rule_id path_pattern task_scope expires_at approved_by reason warning_status category level source module_id trigger enforcement check_id example rule_text issue_count warning_count first warning identity_mode anchor_file attestation_hash baseline context_directory context_marker
    audit_started=$(harness_epoch_seconds)
    AUDIT_ISSUES=$(mktemp "${TMPDIR:-/tmp}/audit-issues.XXXXXX") || return 1
    AUDIT_WARNINGS=$(mktemp "${TMPDIR:-/tmp}/audit-warnings.XXXXXX") || { rm -f "$AUDIT_ISSUES"; return 1; }
    : >"$AUDIT_ISSUES"
    : >"$AUDIT_WARNINGS"

    package_integrity_check || audit_add_issue package_integrity_failed
    repository_paths_supported "$HARNESS_REPO_ROOT" || audit_add_issue unsupported_repository_path
    policy_validate || audit_add_issue policy_or_convention_invalid
    identity_policy_validate || audit_add_issue identity_policy_invalid
    external_anchor_validate || audit_add_issue external_anchor_invalid
    [ ! -s "$(project_contract_file)" ] || project_contract_validate || audit_add_issue project_contract_invalid
    [ -x "$HARNESS_DIR/harness" ] || audit_add_issue harness_not_executable
    find "$HARNESS_DIR" -type f -name '*.py' -print | grep . >/dev/null 2>&1 && audit_add_issue python_runtime_present
    find "$HARNESS_DIR" -type l -print | grep . >/dev/null 2>&1 && audit_add_issue harness_symlink_present
    find "$HARNESS_RUNTIME_DIR" -mindepth 1 -print | while IFS= read -r path; do
        relative=${path#"$HARNESS_REPO_ROOT/"}
        printf '%s\n' "$relative" | grep -E '(^|[-_/])v[0-9]+($|[-_. /])' >/dev/null 2>&1 || continue
        audit_add_issue "unknown_versioned_runtime:$relative"
    done
    if [ -f "$HARNESS_RUNTIME_DIR/migration.conf" ]; then
        status=$(conf_get "$HARNESS_RUNTIME_DIR/migration.conf" STATUS 2>/dev/null || printf '')
        case "$status" in COMPLETED) ;; *) audit_add_issue "runtime_migration_recovery_required:$status" ;; esac
    fi

    expected_files=$(mktemp "${TMPDIR:-/tmp}/expected-files.XXXXXX") || return 1
    awk -F '\t' '{print $1}' "$HARNESS_MANIFEST" | LC_ALL=C sort >"$expected_files"
    for managed_directory in "$HARNESS_DIR/lib" "$HARNESS_DIR/policy" "$HARNESS_DIR/tests"; do
        find "$managed_directory" -type f -print | while IFS= read -r managed_file; do
            relative=${managed_file#"$HARNESS_REPO_ROOT/"}
            grep -Fx "$relative" "$expected_files" >/dev/null 2>&1 || audit_add_issue "unmanaged_core_file:$relative"
        done
    done
    rm -f "$expected_files"

    current_inventory=$(mktemp "${TMPDIR:-/tmp}/audit-inventory.XXXXXX") || return 1
    if inventory_write "$HARNESS_REPO_ROOT" "$current_inventory"; then
        while IFS=$'\t' read -r path kind mode digest; do
            if path_has_vcs_segment "$path" && ! inventory_policy_vcs_allowed "$path"; then audit_add_issue "nested_vcs_metadata:$path"; fi
        done <"$current_inventory"
    else
        audit_add_issue repository_inventory_invalid
    fi
    rm -f "$current_inventory"

    active=""
    if [ -e "$HARNESS_ACTIVE_POINTER" ]; then
        if active_pointer_validate; then active=$(active_run_id)
        else audit_add_issue active_pointer_invalid; fi
    fi

    for directory in "$HARNESS_RUNS_DIR"/*; do
        [ -d "$directory" ] || continue
        run_id=$(basename "$directory")
        if ! validate_run_state "$run_id"; then audit_add_issue "run_invalid:$run_id"; continue; fi
        verification_attempt_history_validate "$run_id" || audit_add_issue "attempt_history_invalid:$run_id"
        context_marker=$(context_publication_marker "$run_id")
        [ ! -f "$context_marker" ] || audit_add_issue "context_publication_recovery_required:$run_id"
        context_directory=$(context_effective_current_dir "$run_id" 2>/dev/null || printf '')
        if [ -n "$context_directory" ] && ! context_validate_generation_digest "$context_directory"; then
            audit_add_issue "context_generation_integrity_invalid:$run_id"
        fi
        [ "$(state_get "$run_id" WORKTREE_ID 2>/dev/null || printf standalone)" = "$HARNESS_WORKTREE_ID" ] || audit_add_issue "run_worktree_mismatch:$run_id"
        state=$(state_get "$run_id" STATE)
        if [ -f "$directory/finalization-journal.conf" ]; then
            status=$(conf_get "$directory/finalization-journal.conf" STATUS 2>/dev/null || printf '')
            case "$status" in COMPLETED|ROLLED_BACK) ;; *) audit_add_issue "finalization_recovery_required:$run_id:$status" ;; esac
        fi
        if ! workflow_is_terminal "$state" && [ "$run_id" != "$active" ]; then audit_add_issue "orphan_nonterminal_run:$run_id"; fi
        if [ "$state" = "FINALIZED" ] && ! validate_finalized_run "$run_id"; then audit_add_issue "finalization_invalid:$run_id"; fi
    done

    for directory in "$HARNESS_TASKS_DIR"/*; do
        [ -d "$directory" ] || continue
        task_id=$(basename "$directory")
        if ! validate_task_contract "$task_id"; then audit_add_issue "task_contract_invalid:$task_id"; continue; fi
        conventions_validate_task_file "$task_id" || audit_add_issue "task_conventions_invalid:$task_id"
        approval=$directory/approval.conf
        if [ -f "$approval" ]; then
            task_understanding_validate "$task_id" || audit_add_issue "task_understanding_invalid:$task_id"
            run_id=$(conf_get "$approval" RUN_ID 2>/dev/null || printf '')
            baseline="$(run_dir "$run_id")/artifacts/baseline-inventory.tsv"
            [ -f "$baseline" ] && task_understanding_validate_against_inventory "$task_id" "$baseline" || audit_add_issue "task_understanding_evidence_invalid:$task_id"
            if [ -z "$run_id" ]; then
                audit_add_issue "approval_invalid:$task_id"
            elif workflow_is_terminal "$(state_get "$run_id" STATE 2>/dev/null || printf '')"; then
                validate_terminal_approval "$task_id" "$run_id" || audit_add_issue "approval_invalid:$task_id"
            elif ! approval_consistency "$task_id" "$run_id"; then
                audit_add_issue "approval_invalid:$task_id"
            fi
        fi
    done

    expected_index=$(mktemp "${TMPDIR:-/tmp}/expected-index.XXXXXX") || return 1
    render_task_index "$expected_index" || audit_add_issue index_projection_failed
    if [ ! -f "$HARNESS_TASKS_DIR/index.tsv" ] || ! cmp -s "$expected_index" "$HARNESS_TASKS_DIR/index.tsv"; then
        audit_add_issue task_index_projection_stale
    fi
    rm -f "$expected_index"

    if [ -d "$HARNESS_GLOBAL_LOCK" ]; then audit_add_issue operation_lock_present; fi
    if [ -f "$(convention_update_journal)" ]; then audit_add_issue convention_update_recovery_required; fi
    if [ -f "$HARNESS_RUNTIME_DIR/supersede.conf" ]; then
        status=$(conf_get "$HARNESS_RUNTIME_DIR/supersede.conf" STATUS 2>/dev/null || printf '')
        case "$status" in COMPLETED|ROLLED_BACK) ;; *) audit_add_issue "supersede_recovery_required:$status" ;; esac
    fi

    while IFS=$'\t' read -r policy_type policy_pattern policy_reason policy_by policy_at; do
        [ -n "$policy_type$policy_pattern$policy_reason$policy_by$policy_at" ] || continue
        [ "$policy_type" = "EXCLUDE" ] && audit_add_warning "inventory_exclusion_active:$policy_pattern"
    done <"$(inventory_policy_file)"
    while IFS=$'\t' read -r exception_id rule_id path_pattern task_scope expires_at approved_by reason status; do
        [ "$status" = "ACTIVE" ] || continue
        audit_add_warning "convention_exception_active:$exception_id:$rule_id:$path_pattern:$expires_at"
    done <"$(convention_exceptions_file)"
    while IFS=$'\t' read -r rule_id category level warning_status source module_id path_pattern trigger enforcement check_id example rule_text; do
        case "$warning_status" in DEPRECATED|REPLACED) audit_add_warning "convention_rule_$warning_status:$rule_id" ;; esac
    done <"$(convention_rules_file)"
    identity_mode=$(conf_get "$(identity_policy_file)" MODE 2>/dev/null || printf DECLARATIVE)
    case "$identity_mode" in
        DECLARATIVE) audit_add_warning identity_assurance_declarative ;;
        EXTERNAL|EXTERNAL_FILE) audit_add_warning identity_external_evidence_not_cryptographically_verified ;;
    esac
    [ -n "${HARNESS_EXPECTED_MANIFEST_HASH:-}" ] || audit_add_warning external_package_manifest_anchor_not_configured
    if [ ! -s "$(external_anchor_file)" ]; then
        audit_add_warning external_integrity_anchor_not_configured
    elif [ "$(conf_get "$(external_anchor_file)" MODE 2>/dev/null || printf '')" = LOCAL_FILE ]; then
        audit_add_warning external_anchor_local_file_not_immutable
    fi

    issue_count=$(wc -l <"$AUDIT_ISSUES" | tr -d ' ')
    warning_count=$(wc -l <"$AUDIT_WARNINGS" | tr -d ' ')
    run_count=$(find "$HARNESS_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | wc -l | tr -d ' ')
    task_count=$(find "$HARNESS_TASKS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | wc -l | tr -d ' ')
    finalized_run_count=0
    for directory in "$HARNESS_RUNS_DIR"/*; do
        [ -d "$directory" ] || continue
        [ "$(conf_get "$directory/state.conf" STATE 2>/dev/null || printf '')" = FINALIZED ] && finalized_run_count=$((finalized_run_count + 1))
    done
    audit_finished=$(harness_epoch_seconds); audit_seconds=$((audit_finished - audit_started))
    if [ "$HARNESS_JSON_MODE" = "1" ]; then
        printf '{"result":"%s","issue_count":%s,"warning_count":%s,"duration_seconds":%s,"run_count":%s,"finalized_run_count":%s,"task_count":%s,"issues":[' \
            "$([ "$issue_count" -eq 0 ] && printf PASS || printf FAIL)" "$issue_count" "$warning_count" "$audit_seconds" "$run_count" "$finalized_run_count" "$task_count"
        first=1
        while IFS= read -r issue; do
            [ -n "$issue" ] || continue
            [ "$first" -eq 1 ] || printf ','
            printf '"%s"' "$(json_escape "$issue")"
            first=0
        done <"$AUDIT_ISSUES"
        printf '],"warnings":['
        first=1
        while IFS= read -r warning; do
            [ -n "$warning" ] || continue
            [ "$first" -eq 1 ] || printf ','
            printf '"%s"' "$(json_escape "$warning")"
            first=0
        done <"$AUDIT_WARNINGS"
        printf '],"enforcement_mode":"AUDIT_ONLY"}\n'
    else
        if [ "$issue_count" -eq 0 ]; then printf 'Audit: PASS\n'; else
            printf 'Audit: FAIL (%s issues)\n' "$issue_count"
            sed 's/^/- /' "$AUDIT_ISSUES"
        fi
        if [ "$warning_count" -gt 0 ]; then
            printf 'Warnings: %s\n' "$warning_count"
            sed 's/^/- /' "$AUDIT_WARNINGS"
        fi
        printf 'Metrics: duration_seconds=%s runs=%s finalized_runs=%s tasks=%s
' "$audit_seconds" "$run_count" "$finalized_run_count" "$task_count"
    fi
    rm -f "$AUDIT_ISSUES" "$AUDIT_WARNINGS"
    [ "$issue_count" -eq 0 ]
}

doctor_repository() {
    local issues command_name bash_major bash_minor file id identity_mode
    issues=0
    for command_name in bash awk sed grep find sort mktemp tar tail; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf 'MISSING: %s\n' "$command_name"
            issues=$((issues + 1))
        fi
    done
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        printf 'MISSING: SHA-256 utility (sha256sum or shasum)\n'
        issues=$((issues + 1))
    fi
    bash_major=${BASH_VERSINFO[0]}
    bash_minor=${BASH_VERSINFO[1]}
    if [ "$bash_major" -lt 3 ] || { [ "$bash_major" -eq 3 ] && [ "$bash_minor" -lt 2 ]; }; then
        printf 'UNSUPPORTED: Bash %s.%s; Bash 3.2+ required\n' "$bash_major" "$bash_minor"
        issues=$((issues + 1))
    fi
    repository_paths_supported "$HARNESS_REPO_ROOT" || { printf 'INVALID: unsupported repository path (control characters or leading hyphen)\n'; issues=$((issues + 1)); }
    policy_validate || { printf 'INVALID: policy or command registry\n'; issues=$((issues + 1)); }
    identity_policy_validate || { printf 'INVALID: identity policy\n'; issues=$((issues + 1)); }
    external_anchor_validate || { printf 'INVALID: external anchor configuration\n'; issues=$((issues + 1)); }
    [ ! -s "$(project_contract_file)" ] || project_contract_validate || { printf 'INVALID: project contract\n'; issues=$((issues + 1)); }
    package_integrity_check || { printf 'INVALID: installed package integrity\n'; issues=$((issues + 1)); }
    for file in "$HARNESS_COMMAND_DIR"/*.conf; do
        [ -f "$file" ] || continue
        id=$(basename "$file" .conf)
        if ! command_resolve_executable "$id" >/dev/null 2>&1; then
            printf 'MISSING EXECUTABLE: %s\n' "$id"
            issues=$((issues + 1))
        fi
    done
    if [ -d "$HARNESS_GLOBAL_LOCK" ]; then
        if lock_is_stale "$HARNESS_GLOBAL_LOCK"; then printf 'STALE LOCK: run harness recover\n'; else printf 'ACTIVE LOCK: another operation is running\n'; fi
        issues=$((issues + 1))
    fi
    if [ "$issues" -eq 0 ]; then printf 'Doctor: PASS\n'; else printf 'Doctor: FAIL (%s issues)\n' "$issues"; fi
    [ "$issues" -eq 0 ]
}
