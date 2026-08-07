#!/usr/bin/env bash

task_contract_hash() {
    local task_id directory payload name file normalized digest
    task_id=$1
    directory=$(task_dir "$task_id")
    payload=""
    for name in spec.conf plan.conf understanding.conf affected-modules.tsv assumptions.tsv implementation-plan.tsv understanding-evidence.tsv inspection-binding.conf project-binding.conf criteria.tsv scopes.txt read-context.txt checks.txt coverage.tsv applicable-conventions.tsv applicable-exceptions.tsv; do
        file=$directory/$name
        [ -f "$file" ] || return 1
        if [ "$name" = "spec.conf" ] || [ "$name" = "plan.conf" ]; then
            normalized=$(awk '!/^STATUS=/' "$file")
            digest=$(sha256_text "$normalized") || return 1
        else
            digest=$(sha256_file "$file") || return 1
        fi
        payload=$payload$name:$digest';'
    done
    sha256_text "$payload"
}

validate_task_contract() {
    local task_id directory spec plan profile risk pattern first protected check_id purpose criterion_id description extra found coverage_id evidence rationale rest command_evidence
    task_id=$1
    directory=$(task_dir "$task_id")
    spec=$directory/spec.conf
    plan=$directory/plan.conf
    [ -f "$spec" ] && [ -f "$plan" ] || return 1
    [ "$(conf_get "$spec" TASK_ID)" = "$task_id" ] || return 1
    [ "$(conf_get "$plan" TASK_ID)" = "$task_id" ] || return 1
    [ -n "$(trim_space "$(conf_get "$spec" TITLE)")" ] || return 1
    [ -n "$(trim_space "$(conf_get "$spec" GOAL)")" ] || return 1
    [ -n "$(trim_space "$(conf_get "$spec" STAKEHOLDERS)")" ] || return 1
    profile=$(conf_get "$plan" PROFILE)
    case "$profile" in bugfix|feature|refactor|migration|review-only) ;; *) return 1 ;; esac
    risk=$(conf_get "$plan" RISK 2>/dev/null || printf '')
    case "$risk" in low|medium|high|critical) ;; *) return 1 ;; esac
    [ -f "$directory/understanding.conf" ] && [ -f "$directory/affected-modules.tsv" ] && [ -f "$directory/assumptions.tsv" ] && [ -f "$directory/implementation-plan.tsv" ] && [ -f "$directory/understanding-evidence.tsv" ] && [ -f "$directory/inspection-binding.conf" ] && [ -f "$directory/project-binding.conf" ] || return 1
    [ -s "$directory/criteria.tsv" ] || return 1
    [ -s "$directory/scopes.txt" ] || return 1
    [ -s "$directory/checks.txt" ] || return 1
    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        glob_validate "$pattern" || return 1
        # Broad top-level wildcard scopes can include harness controls and are denied.
        first=${pattern%%/*}
        case "$first" in *'*'*|*'?'*) return 1 ;; esac
        for protected in '.agent-harness/harness' 'AGENTS.md' 'WORKFLOW.md' 'CONTEXT.md'; do
            if path_matches "$protected" "$pattern"; then return 1; fi
        done
    done <"$directory/scopes.txt"
    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        glob_validate "$pattern" || return 1
    done <"$directory/read-context.txt"
    while IFS= read -r check_id; do
        [ -n "$check_id" ] || continue
        identifier_validate "$check_id" || return 1
        command_validate "$check_id" || return 1
        purpose=$(command_get "$check_id" PURPOSE 2>/dev/null || printf '')
        [ "${purpose:-VERIFICATION}" = "VERIFICATION" ] || return 1
    done <"$directory/checks.txt"
    conventions_validate_task_file "$task_id" || return 1
    # Every acceptance criterion requires explicit mapped evidence.
    awk -F '\t' 'NF { if (seen[$1]++) exit 1 }' "$directory/criteria.tsv" || return 1
    awk 'NF { if (seen[$0]++) exit 1 }' "$directory/checks.txt" || return 1
    awk -F '\t' 'NF { key=$1 SUBSEP $2; if (seen[key]++) exit 1 }' "$directory/coverage.tsv" || return 1
    while IFS=$'\t' read -r coverage_id check_id evidence rationale rest; do
        [ -z "$rest" ] && [ -n "$coverage_id" ] && [ -n "$check_id" ] && [ -n "$evidence" ] && [ -n "$(trim_space "$rationale")" ] || return 1
        awk -F '\t' -v wanted="$coverage_id" '$1 == wanted {found=1} END {exit found ? 0 : 1}' "$directory/criteria.tsv" || return 1
        grep -Fx "$check_id" "$directory/checks.txt" >/dev/null 2>&1 || return 1
        command_evidence=$(command_get "$check_id" EVIDENCE_TYPE 2>/dev/null || printf '')
        [ "$command_evidence" = "$evidence" ] || return 1
    done <"$directory/coverage.tsv"
    while IFS=$'\t' read -r criterion_id description extra; do
        identifier_validate "$criterion_id" && [ -n "$description" ] && [ -z "$extra" ] || return 1
        found=0
        while IFS=$'\t' read -r coverage_id check_id evidence rationale rest; do
            [ -z "$rest" ] || return 1
            if [ "$coverage_id" = "$criterion_id" ]; then
                found=1
                grep -Fx "$check_id" "$directory/checks.txt" >/dev/null 2>&1 || return 1
                command_evidence=$(command_get "$check_id" EVIDENCE_TYPE)
                [ "$command_evidence" = "$evidence" ] || return 1
                [ -n "$(trim_space "$rationale")" ] || return 1
            fi
        done <"$directory/coverage.tsv"
        [ "$found" -eq 1 ] || return 1
    done <"$directory/criteria.tsv"
    return 0
}

task_create_from_files() {
    local title goal stakeholders profile criteria_file scopes_file read_file checks_file coverage_file predecessor project_mode risk task_id directory run_id
    title=$1
    goal=$2
    stakeholders=$3
    profile=$4
    criteria_file=$5
    scopes_file=$6
    read_file=$7
    checks_file=$8
    coverage_file=$9
    predecessor=${10:-}
    project_mode=${11:-brownfield}
    risk=${12:-medium}
    if ! active_pointer_absent; then return 2; fi
    task_id=$(new_id TASK)
    directory=$(task_dir "$task_id")
    mkdir -p "$directory" || return 1
    {
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair TITLE "$title"
        conf_write_pair GOAL "$goal"
        conf_write_pair STAKEHOLDERS "$stakeholders"
        conf_write_pair STATUS DRAFT
        conf_write_pair CREATED_AT "$(harness_now)"
    } | atomic_write "$directory/spec.conf" || return 1
    {
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair PROFILE "$profile"
        conf_write_pair STATUS DRAFT
        conf_write_pair RISK "$risk"
    } | atomic_write "$directory/plan.conf" || return 1
    cp "$criteria_file" "$directory/criteria.tsv" || return 1
    cp "$scopes_file" "$directory/scopes.txt" || return 1
    cp "$read_file" "$directory/read-context.txt" || return 1
    cp "$checks_file" "$directory/checks.txt" || return 1
    cp "$coverage_file" "$directory/coverage.tsv" || return 1
    : >"$directory/applicable-conventions.tsv"
    : >"$directory/applicable-exceptions.tsv"
    : >"$directory/questions.tsv"
    task_understanding_init "$task_id" "$project_mode" || return 1
    validate_task_contract "$task_id" || { rm -rf "$directory"; return 3; }
    run_id=$(create_run "$task_id" "$predecessor") || { rm -rf "$directory"; return 1; }
    rebuild_task_index || return 1
    printf '%s\t%s\n' "$task_id" "$run_id"
}

task_request_clarification() {
    local question run_id task_id question_id
    question=$1
    acquire_lock "$HARNESS_GLOBAL_LOCK" clarification || return 2
    trap cleanup_common EXIT INT TERM
    run_id=$(active_run_id) || return 1
    [ "$(state_get "$run_id" STATE)" = "INTAKE" ] || return 3
    task_id=$(state_get "$run_id" TASK_ID)
    question_id=$(new_id Q)
    printf '%s\t%s\t\n' "$question_id" "$(printf '%s' "$question" | tr '\t\r\n' '   ')" >>"$(task_dir "$task_id")/questions.tsv"
    transition_run "$run_id" CLARIFICATION_REQUIRED human "clarification requested" || return 1
    release_lock
    trap - EXIT INT TERM
    printf '%s\n' "$question_id"
}

task_answer_clarification() {
    local question_id answer run_id task_id file temporary found id question old_answer unanswered
    question_id=$1
    answer=$2
    acquire_lock "$HARNESS_GLOBAL_LOCK" clarification-answer || return 2
    trap cleanup_common EXIT INT TERM
    run_id=$(active_run_id) || return 1
    [ "$(state_get "$run_id" STATE)" = "CLARIFICATION_REQUIRED" ] || return 3
    task_id=$(state_get "$run_id" TASK_ID)
    file=$(task_dir "$task_id")/questions.tsv
    temporary=$(mktemp "${TMPDIR:-/tmp}/questions.XXXXXX") || return 1
    found=0
    while IFS=$'\t' read -r id question old_answer; do
        if [ "$id" = "$question_id" ]; then
            printf '%s\t%s\t%s\n' "$id" "$question" "$(printf '%s' "$answer" | tr '\t\r\n' '   ')" >>"$temporary"
            found=1
        else
            printf '%s\t%s\t%s\n' "$id" "$question" "$old_answer" >>"$temporary"
        fi
    done <"$file"
    [ "$found" -eq 1 ] || { rm -f "$temporary"; return 4; }
    cat "$temporary" | atomic_write "$file" || { rm -f "$temporary"; return 1; }
    rm -f "$temporary"
    unanswered=$(awk -F '\t' 'NF < 3 || $3 == "" {count++} END {print count+0}' "$file")
    if [ "$unanswered" -eq 0 ]; then transition_run "$run_id" INTAKE human "clarification answered" || return 1; fi
    release_lock
    trap - EXIT INT TERM
}

hash_matching_inputs() {
    local root patterns_file inventory temporary digest pattern path kind mode file_digest
    root=$1
    patterns_file=$2
    inventory=$3
    temporary=$(mktemp "${TMPDIR:-/tmp}/trusted-inputs.XXXXXX") || return 1
    : >"$temporary"
    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        while IFS=$'\t' read -r path kind mode file_digest; do
            if path_matches "$path" "$pattern"; then printf '%s\t%s\n' "$path" "$file_digest" >>"$temporary"; fi
        done <"$inventory"
    done <"$patterns_file"
    digest=$(sha256_text "$(LC_ALL=C sort -u "$temporary")") || { rm -f "$temporary"; return 1; }
    rm -f "$temporary"
    printf '%s\n' "$digest"
}

write_command_bindings() {
    local task_id inventory output checks_file temporary check_id config config_hash executable executable_hash trusted_file trusted_hash result
    task_id=$1
    inventory=$2
    output=$3
    checks_file=${4:-$(task_dir "$task_id")/checks.txt}
    temporary=$(mktemp "${TMPDIR:-/tmp}/command-bindings.XXXXXX") || return 1
    : >"$temporary"
    while IFS= read -r check_id; do
        [ -n "$check_id" ] || continue
        config=$(command_file "$check_id")
        config_hash=$(sha256_file "$config") || { rm -f "$temporary"; return 1; }
        executable=$(command_resolve_executable "$check_id") || { rm -f "$temporary"; return 2; }
        executable_hash=$(sha256_file "$executable") || { rm -f "$temporary"; return 1; }
        trusted_file=$(mktemp "${TMPDIR:-/tmp}/trusted-patterns.XXXXXX") || { rm -f "$temporary"; return 1; }
        command_trusted_inputs "$check_id" >"$trusted_file"
        trusted_hash=$(hash_matching_inputs "$HARNESS_REPO_ROOT" "$trusted_file" "$inventory") || { rm -f "$temporary" "$trusted_file"; return 1; }
        rm -f "$trusted_file"
        printf '%s\t%s\t%s\t%s\t%s\n' "$check_id" "$config_hash" "$executable" "$executable_hash" "$trusted_hash" >>"$temporary"
    done <"$checks_file"
    cat "$temporary" | atomic_write "$output"
    result=$?
    rm -f "$temporary"
    return "$result"
}

task_prepare_approval_subject() {
    local run_id task_id directory
    acquire_lock "$HARNESS_GLOBAL_LOCK" approval-subject || return 2
    trap cleanup_common EXIT INT TERM
    package_integrity_check || return 4
    run_id=$(active_run_id) || return 1
    [ "$(state_get "$run_id" STATE)" = INTAKE ] || return 3
    task_id=$(state_get "$run_id" TASK_ID)
    directory=$(task_dir "$task_id")
    conventions_validate || return 4
    inventory_policy_validate || return 4
    identity_policy_validate || return 4
    task_understanding_validate "$task_id" || return 3
    task_bind_project_contract "$task_id" || return 3
    conventions_refresh_task_contract "$task_id" || return 4
    validate_task_contract "$task_id" || return 3
    task_contract_hash "$task_id"
    release_lock
    trap - EXIT INT TERM
}

approve_task() {
    local approved_by second_approved_by identity_evidence second_identity_evidence run_id task_id directory unanswered inventory inventory_path inventory_kind inventory_mode inventory_digest baseline_hash context_bytes warning_context maximum_context contract_hash effective_checks effective_metadata bindings toolchain_bindings policy_hash convention_contract_hash inventory_policy_hash identity_policy_hash applicable_conventions_hash applicable_exceptions_hash git_baseline_commit git_baseline_tree profile risk review_required project_hash inspection_hash evidence_hash
    approved_by=$1; second_approved_by=${2:-}; identity_evidence=${3:-}; second_identity_evidence=${4:-}
    [ -n "$(trim_space "$approved_by")" ] || return 3
    acquire_lock "$HARNESS_GLOBAL_LOCK" approve || return 2
    trap cleanup_common EXIT INT TERM
    package_integrity_check || return 4
    run_id=$(active_run_id) || return 1
    [ "$(state_get "$run_id" STATE)" = "INTAKE" ] || return 3
    task_id=$(state_get "$run_id" TASK_ID); directory=$(task_dir "$task_id")
    unanswered=$(awk -F '\t' 'NF < 3 || $3 == "" {count++} END {print count+0}' "$directory/questions.tsv"); [ "$unanswered" -eq 0 ] || return 3
    conventions_validate || return 4
    inventory_policy_validate || return 4
    identity_policy_validate || return 4
    task_understanding_validate "$task_id" || return 3
    task_bind_project_contract "$task_id" || return 3
    inventory_policy_conflicts_with_task "$task_id" && return 3
    conventions_refresh_task_contract "$task_id" || return 4
    validate_task_contract "$task_id" || return 3
    inventory=$(run_dir "$run_id")/artifacts/baseline-inventory.tsv
    inventory_write "$HARNESS_REPO_ROOT" "$inventory" || return 4
    task_understanding_validate_against_inventory "$task_id" "$inventory" || return 3
    while IFS=$'\t' read -r inventory_path inventory_kind inventory_mode inventory_digest; do
        if path_has_vcs_segment "$inventory_path" && ! inventory_policy_vcs_allowed "$inventory_path"; then return 4; fi
    done <"$inventory"
    baseline_hash=$(inventory_hash "$inventory") || return 1
    context_bytes=$(task_read_context_bytes "$task_id" "$inventory") || return 4
    warning_context=$(control_get CONTEXT_WARNING_BYTES); maximum_context=$(control_get CONTEXT_MAXIMUM_BYTES)
    if [ "$context_bytes" -gt "$maximum_context" ]; then
        harness_warn "selected read context is ${context_bytes} bytes; compact context bundles will be generated instead of blocking approval"
    elif [ "$context_bytes" -gt "$warning_context" ]; then
        harness_warn "selected context is ${context_bytes} bytes; warning threshold is ${warning_context} and hard limit is ${maximum_context}"
    fi
    contract_hash=$(task_contract_hash "$task_id") || return 1
    effective_checks=$(run_dir "$run_id")/artifacts/effective-checks.txt
    effective_metadata=$(run_dir "$run_id")/artifacts/effective-check-metadata.tsv
    conventions_write_effective_checks "$task_id" "$effective_checks" "$effective_metadata" || return 4
    inventory_policy_conflicts_with_verification "$task_id" "$effective_checks" && return 3
    inventory_outputs_conflict_with_task "$task_id" "$effective_checks" && return 3
    bindings=$(run_dir "$run_id")/artifacts/command-bindings.tsv
    write_command_bindings "$task_id" "$inventory" "$bindings" "$effective_checks" || return 4
    toolchain_bindings=$(run_dir "$run_id")/artifacts/toolchain-bindings.tsv
    write_toolchain_bindings "$effective_checks" "$toolchain_bindings" || return 4
    policy_hash=$(sha256_file "$HARNESS_MANIFEST") || return 1
    convention_contract_hash=$(conventions_contract_hash) || return 1
    inventory_policy_hash=$(inventory_policy_hash) || return 1
    identity_policy_hash=$(sha256_file "$(identity_policy_file)") || return 1
    applicable_conventions_hash=$(sha256_file "$directory/applicable-conventions.tsv") || return 1
    applicable_exceptions_hash=$(sha256_file "$directory/applicable-exceptions.tsv") || return 1
    git_baseline_commit=""; git_baseline_tree=""
    if command -v git >/dev/null 2>&1 && git -C "$HARNESS_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git_baseline_commit=$(git -C "$HARNESS_REPO_ROOT" rev-parse HEAD 2>/dev/null || printf '')
        git_baseline_tree=$(git -C "$HARNESS_REPO_ROOT" rev-parse HEAD^{tree} 2>/dev/null || printf '')
    fi
    profile=$(conf_get "$directory/plan.conf" PROFILE); risk=$(conf_get "$directory/plan.conf" RISK); review_required=0
    case "$profile" in migration|review-only) review_required=1 ;; esac
    case "$risk" in high|critical) review_required=1 ;; esac
    if [ "$risk" = "critical" ]; then [ -n "$(trim_space "$second_approved_by")" ] && [ "$second_approved_by" != "$approved_by" ] || return 3; fi
    conventions_has_review_obligations "$task_id" && review_required=1
    identity_capture "$approved_by" "$identity_evidence" "$contract_hash" TASK_APPROVAL "$directory/approval-identity.conf" || return 3
    if [ "$risk" = "critical" ]; then
        identity_capture "$second_approved_by" "$second_identity_evidence" "$contract_hash" SECOND_TASK_APPROVAL "$directory/second-approval-identity.conf" || return 3
        [ "$(conf_get "$directory/approval-identity.conf" PRINCIPAL)" != "$(conf_get "$directory/second-approval-identity.conf" PRINCIPAL)" ] || return 3
    else
        rm -f "$directory/second-approval-identity.conf"
    fi
    project_hash=$(conf_get "$directory/project-binding.conf" PROJECT_CONTRACT_HASH 2>/dev/null || printf NONE)
    inspection_hash=$(sha256_file "$directory/inspection-binding.conf") || return 1
    evidence_hash=$(sha256_file "$directory/understanding-evidence.tsv") || return 1
    {
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair RUN_ID "$run_id"
        conf_write_pair WORKTREE_ID "$HARNESS_WORKTREE_ID"
        conf_write_pair CONTRACT_HASH "$contract_hash"
        conf_write_pair BASELINE_TREE_HASH "$baseline_hash"
        conf_write_pair CONTEXT_BYTES "$context_bytes"
        conf_write_pair CONTEXT_WARNING "$([ "$context_bytes" -gt "$warning_context" ] && printf 1 || printf 0)"
        conf_write_pair CONTEXT_OVERFLOW "$([ "$context_bytes" -gt "$maximum_context" ] && printf 1 || printf 0)"
        conf_write_pair POLICY_HASH "$policy_hash"
        conf_write_pair PROJECT_CONTRACT_HASH "$project_hash"
        conf_write_pair CONVENTION_CONTRACT_HASH "$convention_contract_hash"
        conf_write_pair INVENTORY_POLICY_HASH "$inventory_policy_hash"
        conf_write_pair IDENTITY_POLICY_HASH "$identity_policy_hash"
        conf_write_pair INSPECTION_BINDING_HASH "$inspection_hash"
        conf_write_pair UNDERSTANDING_EVIDENCE_HASH "$evidence_hash"
        conf_write_pair APPLICABLE_CONVENTIONS_HASH "$applicable_conventions_hash"
        conf_write_pair APPLICABLE_EXCEPTIONS_HASH "$applicable_exceptions_hash"
        conf_write_pair EFFECTIVE_CHECK_METADATA_HASH "$(sha256_file "$effective_metadata")"
        conf_write_pair EFFECTIVE_CHECKS_HASH "$(sha256_file "$effective_checks")"
        conf_write_pair COMMAND_BINDINGS_HASH "$(sha256_file "$bindings")"
        conf_write_pair TOOLCHAIN_BINDINGS_HASH "$(sha256_file "$toolchain_bindings")"
        conf_write_pair GIT_BASELINE_COMMIT "$git_baseline_commit"
        conf_write_pair GIT_BASELINE_TREE "$git_baseline_tree"
        conf_write_pair APPROVAL_IDENTITY_HASH "$(sha256_file "$directory/approval-identity.conf")"
        conf_write_pair SECOND_APPROVAL_IDENTITY_HASH "$([ -f "$directory/second-approval-identity.conf" ] && sha256_file "$directory/second-approval-identity.conf" || printf NONE)"
        conf_write_pair APPROVED_BY "$approved_by"
        conf_write_pair SECOND_APPROVED_BY "$([ -n "$second_approved_by" ] && printf '%s' "$second_approved_by" || printf NONE)"
        conf_write_pair APPROVED_AT "$(harness_now)"
        conf_write_pair FINAL_REVIEW_REQUIRED "$review_required"
    } | atomic_write "$directory/approval.conf" || return 1
    sed 's/^STATUS=.*/STATUS=LOCKED/' "$directory/spec.conf" | atomic_write "$directory/spec.conf" || return 1
    sed 's/^STATUS=.*/STATUS=APPROVED/' "$directory/plan.conf" | atomic_write "$directory/plan.conf" || return 1
    transition_run "$run_id" IMPLEMENTING approval "contract approved" || return 1
    if command -v context_build_best_effort >/dev/null 2>&1; then context_build_best_effort "$run_id" "$task_id"; fi
    rebuild_task_index || return 1
    release_lock
    trap - EXIT INT TERM
}

approve_final_review() {
    local approved_by review_input identity_evidence run_id task_id approval verification convention_review_hash verification_hash risk
    approved_by=$1; review_input=${2:-}; identity_evidence=${3:-}
    acquire_lock "$HARNESS_GLOBAL_LOCK" final-review || return 2
    trap cleanup_common EXIT INT TERM
    run_id=$(active_run_id) || return 1
    [ "$(state_get "$run_id" STATE)" = "PASSED" ] || return 3
    task_id=$(state_get "$run_id" TASK_ID); approval=$(task_dir "$task_id")/approval.conf
    [ "$(conf_get "$approval" FINAL_REVIEW_REQUIRED)" = "1" ] || return 3
    verification=$(run_dir "$run_id")/verification.conf; [ -f "$verification" ] || return 3
    risk=$(conf_get "$(task_dir "$task_id")/plan.conf" RISK 2>/dev/null || printf medium)
    if [ "$(control_get REQUIRE_INDEPENDENT_FINAL_REVIEW_FOR_HIGH_RISK 2>/dev/null || printf 1)" = 1 ]; then
        case "$risk" in
            high|critical)
                [ "$approved_by" != "$(conf_get "$approval" APPROVED_BY)" ] || return 3
                [ "$approved_by" != "$(conf_get "$approval" SECOND_APPROVED_BY 2>/dev/null || printf NONE)" ] || return 3
                ;;
        esac
    fi
    convention_review_hash=""
    if conventions_has_review_obligations "$task_id" || [ -s "$(run_dir "$run_id")/artifacts/convention-warnings.tsv" ]; then
        [ -n "$review_input" ] && [ -f "$review_input" ] || return 3
        conventions_validate_manual_review_input "$task_id" "$run_id" "$review_input" || return 3
        conventions_write_manual_review "$task_id" "$run_id" "$approved_by" "$review_input" || return 1
        convention_review_hash=$(sha256_file "$(task_dir "$task_id")/convention-review.tsv") || return 1
    elif [ -n "$review_input" ] && [ -s "$review_input" ]; then return 3; fi
    verification_hash=$(sha256_file "$verification") || return 1
    identity_capture "$approved_by" "$identity_evidence" "$verification_hash" FINAL_REVIEW "$(task_dir "$task_id")/final-review-identity.conf" || return 3
    {
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair RUN_ID "$run_id"
        conf_write_pair VERIFICATION_HASH "$verification_hash"
        conf_write_pair CONVENTION_REVIEW_HASH "$convention_review_hash"
        conf_write_pair IDENTITY_HASH "$(sha256_file "$(task_dir "$task_id")/final-review-identity.conf")"
        conf_write_pair APPROVED_BY "$approved_by"
        conf_write_pair APPROVED_AT "$(harness_now)"
    } | atomic_write "$(task_dir "$task_id")/final-review.conf" || return 1
    release_lock
    trap - EXIT INT TERM
}

task_cancel() {
    local reason run_id state task_id
    reason=$1
    acquire_lock "$HARNESS_GLOBAL_LOCK" cancel || return 2
    trap cleanup_common EXIT INT TERM
    run_id=$(active_run_id) || return 1
    state=$(state_get "$run_id" STATE)
    workflow_is_terminal "$state" && return 3
    transition_run "$run_id" CANCELLED human "$reason" || return 1
    task_id=$(state_get "$run_id" TASK_ID)
    sed 's/^STATUS=.*/STATUS=CANCELLED/' "$(task_dir "$task_id")/spec.conf" | atomic_write "$(task_dir "$task_id")/spec.conf" || return 1
    deactivate_run
    rebuild_task_index
    release_lock
    trap - EXIT INT TERM
}
