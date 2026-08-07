#!/usr/bin/env bash

task_allows_manifest_self_update() {
    local task_id risk scopes
    task_id=$1
    risk=$(conf_get "$(task_dir "$task_id")/plan.conf" RISK 2>/dev/null || printf '')
    case "$risk" in medium|high|critical) ;; *) return 1 ;; esac
    scopes=$(task_dir "$task_id")/scopes.txt
    [ -f "$scopes" ] && grep -Fx '.agent-harness/manifest.tsv' "$scopes" >/dev/null 2>&1
}

approval_manifest_consistent() {
    local task_id approval approved_hash current_hash
    task_id=$1; approval=$2
    approved_hash=$(conf_get "$approval" POLICY_HASH) || return 1
    current_hash=$(sha256_file "$HARNESS_MANIFEST") || return 1
    [ "$approved_hash" = "$current_hash" ] && return 0
    task_allows_manifest_self_update "$task_id"
}

approval_consistency() {
    local task_id run_id directory approval bindings effective_checks effective_metadata toolchain_bindings check_id config_hash executable executable_hash trusted_hash extra resolved baseline_commit project_hash
    task_id=$1; run_id=$2
    package_integrity_check || return 1
    directory=$(task_dir "$task_id"); approval=$directory/approval.conf
    [ -f "$approval" ] || return 1
    [ "$(conf_get "$approval" TASK_ID)" = "$task_id" ] && [ "$(conf_get "$approval" RUN_ID)" = "$run_id" ] || return 1
    [ "$(conf_get "$approval" WORKTREE_ID 2>/dev/null || printf standalone)" = "$HARNESS_WORKTREE_ID" ] || return 1
    [ "$(conf_get "$approval" CONTRACT_HASH)" = "$(task_contract_hash "$task_id")" ] || return 1
    approval_manifest_consistent "$task_id" "$approval" || return 1
    conventions_validate || return 1
    [ "$(conf_get "$approval" CONVENTION_CONTRACT_HASH)" = "$(conventions_contract_hash)" ] || return 1
    [ "$(conf_get "$approval" INVENTORY_POLICY_HASH)" = "$(inventory_policy_hash)" ] || return 1
    [ "$(conf_get "$approval" IDENTITY_POLICY_HASH 2>/dev/null || printf '')" = "$(sha256_file "$(identity_policy_file)")" ] || return 1
    [ "$(conf_get "$approval" INSPECTION_BINDING_HASH)" = "$(sha256_file "$directory/inspection-binding.conf")" ] || return 1
    [ "$(conf_get "$approval" UNDERSTANDING_EVIDENCE_HASH)" = "$(sha256_file "$directory/understanding-evidence.tsv")" ] || return 1
    project_hash=$(conf_get "$approval" PROJECT_CONTRACT_HASH 2>/dev/null || printf NONE)
    if [ "$project_hash" != "NONE" ]; then project_contract_validate || return 1; [ "$project_hash" = "$(project_contract_hash)" ] || return 1; fi
    [ "$(conf_get "$approval" APPLICABLE_CONVENTIONS_HASH)" = "$(sha256_file "$directory/applicable-conventions.tsv")" ] || return 1
    [ "$(conf_get "$approval" APPLICABLE_EXCEPTIONS_HASH)" = "$(sha256_file "$directory/applicable-exceptions.tsv")" ] || return 1
    [ "$(conf_get "$approval" APPROVAL_IDENTITY_HASH)" = "$(sha256_file "$directory/approval-identity.conf")" ] || return 1
    if [ "$(conf_get "$approval" SECOND_APPROVAL_IDENTITY_HASH 2>/dev/null || printf NONE)" != "NONE" ]; then
        [ "$(conf_get "$approval" SECOND_APPROVAL_IDENTITY_HASH)" = "$(sha256_file "$directory/second-approval-identity.conf")" ] || return 1
    fi
    effective_checks=$(run_dir "$run_id")/artifacts/effective-checks.txt
    effective_metadata=$(run_dir "$run_id")/artifacts/effective-check-metadata.tsv
    bindings=$(run_dir "$run_id")/artifacts/command-bindings.tsv
    toolchain_bindings=$(run_dir "$run_id")/artifacts/toolchain-bindings.tsv
    [ -f "$effective_checks" ] && [ -f "$effective_metadata" ] && [ -f "$bindings" ] && [ -f "$toolchain_bindings" ] || return 1
    [ "$(conf_get "$approval" EFFECTIVE_CHECKS_HASH)" = "$(sha256_file "$effective_checks")" ] || return 1
    [ "$(conf_get "$approval" EFFECTIVE_CHECK_METADATA_HASH)" = "$(sha256_file "$effective_metadata")" ] || return 1
    [ "$(conf_get "$approval" COMMAND_BINDINGS_HASH)" = "$(sha256_file "$bindings")" ] || return 1
    [ "$(conf_get "$approval" TOOLCHAIN_BINDINGS_HASH)" = "$(sha256_file "$toolchain_bindings")" ] || return 1
    toolchain_bindings_current "$toolchain_bindings" || return 1
    baseline_commit=$(conf_get "$approval" GIT_BASELINE_COMMIT 2>/dev/null || printf '')
    if [ -n "$baseline_commit" ]; then
        command -v git >/dev/null 2>&1 || return 1
        git -C "$HARNESS_REPO_ROOT" cat-file -e "$baseline_commit^{commit}" >/dev/null 2>&1 || return 1
        git -C "$HARNESS_REPO_ROOT" merge-base --is-ancestor "$baseline_commit" HEAD >/dev/null 2>&1 || return 1
    fi
    while IFS=$'\t' read -r check_id config_hash executable executable_hash trusted_hash extra; do
        [ -z "$extra" ] || return 1
        [ "$(sha256_file "$(command_file "$check_id")")" = "$config_hash" ] || return 1
        [ -f "$executable" ] && [ -x "$executable" ] || return 1
        [ "$(sha256_file "$executable")" = "$executable_hash" ] || return 1
    done <"$bindings"
}

path_approved_by_scope() {
    local task_id path scopes pattern
    task_id=$1; path=$2; scopes=$(task_dir "$task_id")/scopes.txt
    while IFS= read -r pattern; do [ -n "$pattern" ] && path_matches "$path" "$pattern" && return 0; done <"$scopes"
    return 1
}

validate_changed_paths() {
    local task_id changed_file path
    task_id=$1; changed_file=$2
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        path_has_vcs_segment "$path" && ! inventory_policy_vcs_allowed "$path" && return 1
        if path_is_harness_control "$path"; then task_allows_manifest_self_update "$task_id" || return 1; fi
        path_approved_by_scope "$task_id" "$path" || return 1
    done <"$changed_file"
}

trusted_inputs_current_hash() {
    local check_id inventory patterns result status
    check_id=$1; inventory=$2; patterns=$(mktemp "${TMPDIR:-/tmp}/trusted.XXXXXX") || return 1
    command_trusted_inputs "$check_id" >"$patterns"
    result=$(hash_matching_inputs "$HARNESS_REPO_ROOT" "$patterns" "$inventory"); status=$?; rm -f "$patterns"
    [ "$status" -eq 0 ] || return "$status"; printf '%s\n' "$result"
}

redact_output() {
    local input output max_bytes redacted
    input=$1; output=$2; max_bytes=$(control_get MAXIMUM_COMMAND_OUTPUT_BYTES)
    redacted=$(mktemp "${TMPDIR:-/tmp}/harness-redacted.XXXXXX") || return 1
    if ! sed -E \
        -e 's/([Pp]assword|[Ss]ecret|[Tt]oken|[Aa]pi[_-]?[Kk]ey|[Aa]uthorization)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/\1=[REDACTED]/g' \
        -e 's/AKIA[0-9A-Z]{16}/[REDACTED_AWS_KEY]/g' \
        -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/[REDACTED_JWT]/g' \
        "$input" >"$redacted"; then
        rm -f "$redacted"
        return 1
    fi
    head -c "$max_bytes" "$redacted" | atomic_write "$output"
    local result=$?
    rm -f "$redacted"
    return "$result"
}

command_binding_executable() {
    local check_id bindings
    check_id=$1; bindings=$2
    awk -F '\t' -v wanted="$check_id" '$1 == wanted {print $3; exit}' "$bindings"
}

build_command_array() {
    local check_id workspace bindings executable configured argument
    check_id=$1; workspace=$2; bindings=$3
    configured=$(command_get "$check_id" EXECUTABLE)
    case "$configured" in
        */*) executable=$workspace/$configured ;;
        *) executable=$(command_binding_executable "$check_id" "$bindings") || return 1 ;;
    esac
    [ -n "$executable" ] || return 1
    COMMAND_ARRAY=("$executable")
    while IFS= read -r argument; do COMMAND_ARRAY+=("$argument"); done <<EOF_ARGS
$(command_args "$check_id")
EOF_ARGS
}

changes_match_declared_outputs() {
    local check_id changed path pattern matched
    check_id=$1; changed=$2
    [ -s "$changed" ] || return 1
    [ -n "$(command_outputs "$check_id")" ] || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        matched=0
        while IFS= read -r pattern; do [ -n "$pattern" ] && path_matches "$path" "$pattern" && { matched=1; break; }; done <<EOF_OUTPUTS
$(command_outputs "$check_id")
EOF_OUTPUTS
        [ "$matched" -eq 1 ] || return 1
    done <"$changed"
}

check_output_artifacts_hash() {
    local output_file error_file output_digest error_digest
    output_file=$1
    error_file=${2:-}
    if [ -z "$error_file" ]; then
        sha256_file "$output_file"
        return
    fi
    output_digest=$(sha256_file "$output_file") || return 1
    error_digest=$(sha256_file "$error_file") || return 1
    sha256_text "$output_digest:$error_digest"
}

run_check() {
    local check_id base_workspace artifacts command_bindings toolchain_bindings exceptions_file check_workspace timeout cwd environment_root raw_output raw_error stderr_artifact before after filtered_before filtered_after changed executable old_pwd runtime_path environment_key environment_value exit_code output_hash mutation promotion phase git_mode env_command output_schema output_disposition started finished duration selected_locale
    check_id=$1; base_workspace=$2; artifacts=$3; command_bindings=$4; toolchain_bindings=$5; exceptions_file=$6; check_workspace=$7
    started=$(harness_epoch_seconds)
    copy_workspace_tree "$base_workspace" "$check_workspace" || return 1
    mkdir -p "$check_workspace/.agent-harness/runtime"
    [ -n "$exceptions_file" ] && [ -f "$exceptions_file" ] && cp "$exceptions_file" "$check_workspace/.agent-harness/runtime/applicable-exceptions.tsv"
    git_mode=$(command_get "$check_id" GIT_MODE 2>/dev/null || printf '')
    git_mode=${git_mode:-NONE}
    workspace_git_snapshot "$check_workspace" "$git_mode" || return 1
    timeout=$(command_get "$check_id" TIMEOUT_SECONDS 2>/dev/null || printf '')
    timeout=${timeout:-$(control_get DEFAULT_TIMEOUT_SECONDS)}
    cwd=$(command_get "$check_id" CWD 2>/dev/null || printf '')
    cwd=${cwd:-.}
    phase=$(command_get "$check_id" PHASE 2>/dev/null || printf '')
    phase=${phase:-TEST}
    environment_root=$(make_temp_dir "harness-$check_id-env") || return 1
    mkdir -p "$environment_root/home" "$environment_root/tmp"
    raw_output=$(mktemp "${TMPDIR:-/tmp}/harness-command.XXXXXX") || { rm -rf "$environment_root"; return 1; }
    raw_error=""; stderr_artifact=""
    output_schema=$(command_get "$check_id" OUTPUT_SCHEMA 2>/dev/null || printf '')
    if [ -n "$output_schema" ]; then
        raw_error=$(mktemp "${TMPDIR:-/tmp}/harness-command-stderr.XXXXXX") || { rm -rf "$environment_root"; rm -f "$raw_output"; return 1; }
    fi
    before=$(mktemp "${TMPDIR:-/tmp}/before.XXXXXX") || return 1
    after=$(mktemp "${TMPDIR:-/tmp}/after.XXXXXX") || return 1
    filtered_before=$(mktemp "${TMPDIR:-/tmp}/before-filtered.XXXXXX") || return 1
    filtered_after=$(mktemp "${TMPDIR:-/tmp}/after-filtered.XXXXXX") || return 1
    changed=$artifacts/$check_id.changed-paths.txt
    cleanup_workspace_transients "$check_workspace"
    inventory_write "$check_workspace" "$before" || return 1
    inventory_filter_transient "$before" "$filtered_before" || return 1
    build_command_array "$check_id" "$check_workspace" "$command_bindings" || return 1
    executable=${COMMAND_ARRAY[0]}; [ -x "$executable" ] || return 127
    runtime_path=$(toolchain_path_for_check "$check_id" "$executable" "$toolchain_bindings" "$environment_root/toolchain-bin") || return 1
    old_pwd=$(pwd); cd "$check_workspace/$cwd" || return 1
    selected_locale=$(select_supported_locale)
    env_command=(env -i "PATH=$runtime_path" "HOME=$environment_root/home" "TMPDIR=$environment_root/tmp" "HARNESS_WORKTREE_ID=$HARNESS_WORKTREE_ID" "LANG=$selected_locale" "LC_ALL=$selected_locale")
    [ -z "${USER:-}" ] || env_command+=("USER=$USER")
    while IFS= read -r environment_key; do
        [ -n "$environment_key" ] || continue
        environment_value=$(printenv "$environment_key" 2>/dev/null || printf '')
        [ -z "$environment_value" ] || env_command+=("$environment_key=$environment_value")
    done <<EOF_ENV_ALLOW
$(command_environment_keys "$check_id")
EOF_ENV_ALLOW
    [ -z "$exceptions_file" ] || env_command+=("HARNESS_APPLICABLE_EXCEPTIONS_FILE=$check_workspace/.agent-harness/runtime/applicable-exceptions.tsv")
    if [ -n "$raw_error" ]; then
        run_with_timeout_split "$timeout" "$raw_output" "$raw_error" "${env_command[@]}" "${COMMAND_ARRAY[@]}"; exit_code=$?
    else
        run_with_timeout "$timeout" "$raw_output" "${env_command[@]}" "${COMMAND_ARRAY[@]}"; exit_code=$?
    fi
    cd "$old_pwd" || return 1
    redact_output "$raw_output" "$artifacts/$check_id.log" || return 1
    if [ -n "$raw_error" ]; then
        stderr_artifact=$artifacts/$check_id.stderr.log
        redact_output "$raw_error" "$stderr_artifact" || return 1
    fi
    output_hash=$(check_output_artifacts_hash "$artifacts/$check_id.log" "$stderr_artifact") || return 1
    rm -f "$raw_output"
    [ -z "$raw_error" ] || rm -f "$raw_error"
    cleanup_workspace_transients "$check_workspace"
    inventory_write "$check_workspace" "$after" || return 1
    inventory_filter_transient "$after" "$filtered_after" || return 1
    inventory_changed_paths "$filtered_before" "$filtered_after" "$changed" || return 1
    mutation=0; promotion=0
    output_disposition=$(command_get "$check_id" OUTPUT_DISPOSITION 2>/dev/null || printf '')
    output_disposition=${output_disposition:-EPHEMERAL}
    if [ -s "$changed" ]; then
        if [ "$phase" = "PREPARE" ] && changes_match_declared_outputs "$check_id" "$changed"; then
            if [ "$output_disposition" = "EPHEMERAL" ]; then
                promotion=1
            else
                mutation=1
                [ "$exit_code" -ne 0 ] || exit_code=125
                printf '\nHARNESS_POLICY: required generated outputs differ from the submitted repository. Regenerate and commit them before verification.\n' >>"$artifacts/$check_id.log"
                output_hash=$(check_output_artifacts_hash "$artifacts/$check_id.log" "$stderr_artifact") || return 1
            fi
        else
            mutation=1
            [ "$exit_code" -ne 0 ] || exit_code=125
            printf '\nHARNESS_POLICY: check modified undeclared or non-promotable repository content.\n' >>"$artifacts/$check_id.log"
            output_hash=$(check_output_artifacts_hash "$artifacts/$check_id.log" "$stderr_artifact") || return 1
        fi
    fi
    rm -rf "$environment_root"; rm -f "$before" "$after" "$filtered_before" "$filtered_after"
    finished=$(harness_epoch_seconds); duration=$((finished - started))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$check_id" "$exit_code" "$mutation" "$output_hash" "$promotion" "$duration"
    [ "$exit_code" -eq 0 ] && [ "$mutation" -eq 0 ]
}

verification_metrics_write() {
    local run_directory status total_started inventory_seconds copy_seconds checks_seconds check_count finished
    run_directory=$1; status=$2; total_started=$3; inventory_seconds=$4; copy_seconds=$5; checks_seconds=$6; check_count=$7
    finished=$(harness_epoch_seconds)
    {
        conf_write_pair STATUS "$status"
        conf_write_pair INVENTORY_SECONDS "$inventory_seconds"
        conf_write_pair WORKSPACE_COPY_SECONDS "$copy_seconds"
        conf_write_pair CHECK_EXECUTION_SECONDS "$checks_seconds"
        conf_write_pair CHECK_COUNT "$check_count"
        conf_write_pair TOTAL_SECONDS "$((finished - total_started))"
        conf_write_pair RECORDED_AT "$(harness_now)"
    } | atomic_write "$run_directory/artifacts/verification-metrics.conf"
}

verification_attempt_index() {
    printf '%s/artifacts/attempts.tsv\n' "$(run_dir "$1")"
}

verification_attempt_digest() {
    local directory listing path
    directory=$1
    listing=$(mktemp "${TMPDIR:-/tmp}/attempt-digest.XXXXXX") || return 1
    : >"$listing"
    (
        cd "$directory" || exit 1
        find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do
            printf '%s\t%s\n' "${path#./}" "$(sha256_file "$path")" || exit 1
        done
    ) >"$listing" || { rm -f "$listing"; return 1; }
    sha256_file "$listing"
    rm -f "$listing"
}

verification_attempt_begin() {
    local run_id task_id run_directory index last next_id directory approval started
    run_id=$1
    task_id=$2
    run_directory=$(run_dir "$run_id")
    index=$(verification_attempt_index "$run_id")
    mkdir -p "$run_directory/artifacts/attempts" || return 1
    [ -f "$index" ] || : >"$index"
    last=$(awk -F '\t' 'NF {value=$1} END {print value+0}' "$index")
    next_id=$(printf '%03d' "$((last + 1))")
    directory=$run_directory/artifacts/attempts/$next_id
    [ ! -e "$directory" ] || return 1
    mkdir -m 700 "$directory" || return 1
    approval=$(task_dir "$task_id")/approval.conf
    started=$(harness_now)
    {
        conf_write_pair ATTEMPT_ID "$next_id"
        conf_write_pair RUN_ID "$run_id"
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair STATUS STARTED
        conf_write_pair BASELINE_HASH "$(conf_get "$approval" BASELINE_TREE_HASH 2>/dev/null || printf '')"
        conf_write_pair APPROVAL_HASH "$(sha256_file "$approval")"
        conf_write_pair TOOLCHAIN_BINDINGS_HASH "$(sha256_file "$run_directory/artifacts/toolchain-bindings.tsv")"
        conf_write_pair CHECK_CONTRACT_HASH "$(sha256_file "$run_directory/artifacts/actual-effective-check-metadata.tsv")"
        conf_write_pair DECLARED_PACKAGE_DIGEST "${HARNESS_DECLARED_PACKAGE_DIGEST:-$HARNESS_EXECUTED_PACKAGE_DIGEST}"
        conf_write_pair EXECUTED_PACKAGE_DIGEST "$HARNESS_EXECUTED_PACKAGE_DIGEST"
        conf_write_pair STARTED_AT "$started"
    } | atomic_write "$directory/attempt.conf" || return 1
    printf '%s\n' "$next_id"
}

verification_attempt_complete() {
    local run_id attempt_id disposition run_directory directory index file started completed event_hash digest previous payload entry_hash
    run_id=$1
    attempt_id=$2
    disposition=$3
    run_directory=$(run_dir "$run_id")
    directory=$run_directory/artifacts/attempts/$attempt_id
    index=$(verification_attempt_index "$run_id")
    [ -d "$directory" ] && [ -f "$directory/attempt.conf" ] || return 1
    grep -F "$attempt_id"$'\t' "$index" >/dev/null 2>&1 && return 1
    for file in checks.tsv artifacts/blocking-failures.tsv artifacts/convention-warnings.tsv artifacts/skipped-checks.tsv artifacts/verification-metrics.conf verification.conf remediation.conf; do
        [ -f "$run_directory/$file" ] || continue
        cp "$run_directory/$file" "$directory/$(basename "$file")" || return 1
    done
    if [ -d "$run_directory/artifacts/checks" ]; then
        mkdir -p "$directory/checks" || return 1
        (cd "$run_directory/artifacts/checks" && tar -cf - .) | (cd "$directory/checks" && tar -xf -) || return 1
    fi
    started=$(conf_get "$directory/attempt.conf" STARTED_AT)
    completed=$(harness_now)
    event_hash=$(sha256_file "$(run_events_file "$run_id")") || return 1
    {
        conf_write_pair ATTEMPT_ID "$attempt_id"
        conf_write_pair RUN_ID "$run_id"
        conf_write_pair TASK_ID "$(state_get "$run_id" TASK_ID)"
        conf_write_pair STATUS "$disposition"
        conf_write_pair BASELINE_HASH "$(conf_get "$directory/attempt.conf" BASELINE_HASH)"
        conf_write_pair APPROVAL_HASH "$(conf_get "$directory/attempt.conf" APPROVAL_HASH)"
        conf_write_pair TOOLCHAIN_BINDINGS_HASH "$(conf_get "$directory/attempt.conf" TOOLCHAIN_BINDINGS_HASH)"
        conf_write_pair CHECK_CONTRACT_HASH "$(conf_get "$directory/attempt.conf" CHECK_CONTRACT_HASH)"
        conf_write_pair DECLARED_PACKAGE_DIGEST "$(conf_get "$directory/attempt.conf" DECLARED_PACKAGE_DIGEST)"
        conf_write_pair EXECUTED_PACKAGE_DIGEST "$(conf_get "$directory/attempt.conf" EXECUTED_PACKAGE_DIGEST)"
        conf_write_pair EVENT_CHAIN_HASH "$event_hash"
        conf_write_pair STARTED_AT "$started"
        conf_write_pair COMPLETED_AT "$completed"
    } | atomic_write "$directory/attempt.conf" || return 1
    digest=$(verification_attempt_digest "$directory") || return 1
    previous=$(awk -F '\t' 'NF {value=$6} END {print value}' "$index")
    previous=${previous:-GENESIS}
    payload=$(printf '%s\t%s\t%s\t%s\t%s' "$attempt_id" "$disposition" "$digest" "$previous" "$completed")
    entry_hash=$(sha256_text "$payload") || return 1
    printf '%s\t%s\n' "$payload" "$entry_hash" >>"$index"
}

verification_attempt_started_id() {
    local run_id directory id index
    run_id=$1
    index=$(verification_attempt_index "$run_id")
    for directory in "$(run_dir "$run_id")/artifacts/attempts"/*; do
        [ -d "$directory" ] || continue
        id=$(basename "$directory")
        [ "$(conf_get "$directory/attempt.conf" STATUS 2>/dev/null || printf '')" = STARTED ] || continue
        grep -F "$id"$'\t' "$index" >/dev/null 2>&1 || { printf '%s\n' "$id"; return 0; }
    done
    return 1
}

verification_attempt_history_validate() {
    local run_id index expected previous attempt_id disposition digest recorded_previous completed entry_hash directory actual_digest payload expected_entry directory_id
    run_id=$1
    index=$(verification_attempt_index "$run_id")
    [ -f "$index" ] || { [ ! -d "$(run_dir "$run_id")/artifacts/attempts" ] || return 1; return 0; }
    expected=1
    previous=GENESIS
    while IFS=$'\t' read -r attempt_id disposition digest recorded_previous completed entry_hash; do
        [ -n "$attempt_id" ] || continue
        [ "$attempt_id" = "$(printf '%03d' "$expected")" ] || return 1
        case "$disposition" in REMEDIATING|PASSED|INTERRUPTED|CANCELED|SUPERSEDED) ;; *) return 1 ;; esac
        [ "$recorded_previous" = "$previous" ] || return 1
        directory=$(run_dir "$run_id")/artifacts/attempts/$attempt_id
        [ -d "$directory" ] || return 1
        [ "$(conf_get "$directory/attempt.conf" STATUS 2>/dev/null || printf '')" = "$disposition" ] || return 1
        actual_digest=$(verification_attempt_digest "$directory") || return 1
        [ "$actual_digest" = "$digest" ] || return 1
        payload=$(printf '%s\t%s\t%s\t%s\t%s' "$attempt_id" "$disposition" "$digest" "$recorded_previous" "$completed")
        expected_entry=$(sha256_text "$payload") || return 1
        [ "$expected_entry" = "$entry_hash" ] || return 1
        previous=$entry_hash
        expected=$((expected + 1))
    done <"$index"
    for directory in "$(run_dir "$run_id")/artifacts/attempts"/*; do
        [ -d "$directory" ] || continue
        directory_id=$(basename "$directory")
        grep -F "$directory_id"$'\t' "$index" >/dev/null 2>&1 || return 1
    done
}

record_remediation() {
    local run_id attempt_id check_id exit_code output_hash file signature previous_signature same_count threshold budget failures hold
    run_id=$1; attempt_id=$2; check_id=$3; exit_code=$4; output_hash=$5; file=$(run_dir "$run_id")/remediation.conf
    signature=$(sha256_text "$check_id|$exit_code|$output_hash"); previous_signature=$(conf_get "$file" FAILURE_SIGNATURE 2>/dev/null || printf ''); same_count=$(conf_get "$file" SAME_SIGNATURE_COUNT 2>/dev/null || printf 0)
    if [ "$signature" = "$previous_signature" ]; then same_count=$((same_count + 1)); else same_count=1; fi
    threshold=$(control_get SAME_FAILURE_RETHINK_THRESHOLD); budget=$(control_get DEFAULT_ATTEMPT_BUDGET); failures=$(state_get "$run_id" FAILURE_COUNT); hold=""
    if [ "$failures" -ge "$budget" ]; then hold=ATTEMPT_BUDGET_EXCEEDED; elif [ "$same_count" -ge "$threshold" ]; then hold=RETHINK_REQUIRED; fi
    {
        conf_write_pair ATTEMPT_ID "$attempt_id"
        conf_write_pair FAILURE_SIGNATURE "$signature"; conf_write_pair FAILED_CHECK "$check_id"; conf_write_pair EXIT_CODE "$exit_code"; conf_write_pair OUTPUT_HASH "$output_hash"; conf_write_pair SAME_SIGNATURE_COUNT "$same_count"
        conf_write_pair DIAGNOSIS "Review all blocking failure artifacts and identify the smallest in-scope correction."
        conf_write_pair REPAIR_PLAN "Modify only approved paths, then rerun verification."
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$file" || return 1
    [ -z "$hold" ] || set_run_hold "$run_id" "$hold"
}

verify_task() {
    local run_id state task_id run_directory baseline current changed actual_conventions actual_exceptions actual_effective_checks actual_effective_metadata approved_effective_checks bindings toolchain_bindings check_id config_hash executable executable_hash trusted_hash actual_trusted workspace_base artifacts results failures_file warnings_file skipped_file failed_phase metadata level phase order source check_workspace result_line result exit_code output_hash promotion duration failure_check failure_exit failure_output current_hash approval_hash prepared_inventory generated_hash combined_exceptions total_started inventory_started inventory_finished inventory_seconds copy_started copy_finished copy_seconds checks_seconds check_count attempt_id
    acquire_lock "$HARNESS_GLOBAL_LOCK" verify || return 2
    total_started=$(harness_epoch_seconds); inventory_started=$total_started; checks_seconds=0; check_count=0
    trap cleanup_common EXIT INT TERM
    run_id=$(active_run_id) || return 1; state=$(state_get "$run_id" STATE)
    case "$state" in IMPLEMENTING|REMEDIATING) ;; *) return 3 ;; esac
    [ -z "$(state_get "$run_id" HOLD 2>/dev/null || printf '')" ] || return 3
    task_id=$(state_get "$run_id" TASK_ID); approval_consistency "$task_id" "$run_id" || return 4
    run_directory=$(run_dir "$run_id"); baseline=$run_directory/artifacts/baseline-inventory.tsv; current=$run_directory/artifacts/current-inventory.tsv; changed=$run_directory/artifacts/changed-paths.txt
    inventory_write "$HARNESS_REPO_ROOT" "$current" || return 4
    inventory_changed_paths "$baseline" "$current" "$changed" || return 1
    validate_changed_paths "$task_id" "$changed" || return 3
    actual_conventions=$run_directory/artifacts/actual-conventions.tsv; actual_exceptions=$run_directory/artifacts/actual-exceptions.tsv
    conventions_actual_for_changes "$task_id" "$baseline" "$current" "$changed" "$actual_conventions" "$actual_exceptions" || return 4
    conventions_actual_requires_reapproval "$(task_dir "$task_id")/applicable-conventions.tsv" "$actual_conventions" && return 3
    actual_effective_checks=$run_directory/artifacts/actual-effective-checks.txt
    actual_effective_metadata=$run_directory/artifacts/actual-effective-check-metadata.tsv
    conventions_write_effective_checks_for_file "$task_id" "$actual_conventions" "$actual_effective_checks" "$actual_effective_metadata" || return 4
    approved_effective_checks=$run_directory/artifacts/effective-checks.txt
    while IFS= read -r check_id; do grep -Fx "$check_id" "$approved_effective_checks" >/dev/null 2>&1 || return 3; done <"$actual_effective_checks"
    bindings=$run_directory/artifacts/command-bindings.tsv; toolchain_bindings=$run_directory/artifacts/toolchain-bindings.tsv
    while IFS=$'\t' read -r check_id config_hash executable executable_hash trusted_hash; do actual_trusted=$(trusted_inputs_current_hash "$check_id" "$current") || return 4; [ "$actual_trusted" = "$trusted_hash" ] || return 3; done <"$bindings"
    inventory_finished=$(harness_epoch_seconds); inventory_seconds=$((inventory_finished - inventory_started))
    transition_run "$run_id" VERIFYING verification "verification started" || return 1
    attempt_id=$(verification_attempt_begin "$run_id" "$task_id") || return 1
    copy_started=$(harness_epoch_seconds)
    workspace_base=$(make_temp_dir harness-verification-base) || return 1
    copy_repository_workspace "$workspace_base" "$current" || { rm -rf "$workspace_base"; return 1; }
    copy_finished=$(harness_epoch_seconds); copy_seconds=$((copy_finished - copy_started))
    artifacts=$run_directory/artifacts/checks; rm -rf "$artifacts"; mkdir -p "$artifacts"
    combined_exceptions=$run_directory/artifacts/combined-exceptions.tsv
    cat "$(task_dir "$task_id")/applicable-exceptions.tsv" "$actual_exceptions" 2>/dev/null | LC_ALL=C sort -u >"$combined_exceptions"
    results=$run_directory/checks.tsv; failures_file=$run_directory/artifacts/blocking-failures.tsv; warnings_file=$run_directory/artifacts/convention-warnings.tsv; skipped_file=$run_directory/artifacts/skipped-checks.tsv
    : >"$results"; : >"$failures_file"; : >"$warnings_file"; : >"$skipped_file"; failed_phase=""
    metadata=$actual_effective_metadata
    while IFS=$'\t' read -r check_id level phase order source; do
        [ -n "$check_id" ] || continue
        if [ -n "$failed_phase" ] && [ "$phase" != "$failed_phase" ]; then printf '%s\t%s\tblocked_by_%s\n' "$check_id" "$phase" "$failed_phase" >>"$skipped_file"; continue; fi
        check_workspace=$(make_temp_dir "harness-check-$check_id") || return 1
        result_line=$(run_check "$check_id" "$workspace_base" "$artifacts" "$bindings" "$toolchain_bindings" "$combined_exceptions" "$check_workspace"); result=$?
        printf '%s\t%s\t%s\t%s\n' "$result_line" "$level" "$phase" "$source" >>"$results"
        promotion=$(printf '%s' "$result_line" | awk -F '\t' '{print $5}')
        duration=$(printf '%s' "$result_line" | awk -F '\t' '{print $6}')
        case "$duration" in ''|*[!0-9]*) duration=0 ;; esac
        checks_seconds=$((checks_seconds + duration)); check_count=$((check_count + 1))
        if [ "$result" -eq 0 ] && [ "$promotion" = "1" ]; then
            rm -rf "$check_workspace/.git"; rm -f "$check_workspace/.agent-harness/runtime/applicable-exceptions.tsv"
            copy_workspace_tree "$check_workspace" "$workspace_base" || { rm -rf "$check_workspace"; return 1; }
        fi
        rm -rf "$check_workspace"
        if [ "$result" -ne 0 ]; then
            exit_code=$(printf '%s' "$result_line" | awk -F '\t' '{print $2}'); output_hash=$(printf '%s' "$result_line" | awk -F '\t' '{print $4}')
            case "$level" in
                MUST) printf '%s\t%s\t%s\t%s\t%s\n' "$check_id" "$exit_code" "$output_hash" "$phase" "$source" >>"$failures_file"; [ -n "$failed_phase" ] || failed_phase=$phase ;;
                SHOULD|MAY) printf '%s\t%s\t%s\n' "$check_id" "$level" "$source" >>"$warnings_file" ;;
            esac
        fi
    done <"$metadata"
    prepared_inventory=$run_directory/artifacts/prepared-inventory.tsv
    inventory_write "$workspace_base" "$prepared_inventory" || { rm -rf "$workspace_base"; return 1; }
    generated_hash=$(inventory_hash "$prepared_inventory") || return 1
    rm -rf "$workspace_base"
    if [ -s "$failures_file" ]; then
        verification_metrics_write "$run_directory" FAILED "$total_started" "$inventory_seconds" "$copy_seconds" "$checks_seconds" "$check_count" || return 1
        increment_failure_count "$run_id" || return 1
        failure_check=$(awk -F '\t' 'NR==1 {print $1}' "$failures_file"); failure_exit=$(awk -F '\t' 'NR==1 {print $2}' "$failures_file"); failure_output=$(awk -F '\t' 'NR==1 {print $3}' "$failures_file")
        transition_run "$run_id" FAILED verification "required checks failed" || return 1
        record_remediation "$run_id" "$attempt_id" "$failure_check" "$failure_exit" "$failure_output" || return 1
        transition_run "$run_id" REMEDIATING verification "remediation required" || return 1
        verification_attempt_complete "$run_id" "$attempt_id" REMEDIATING || return 1
        if command -v context_build_best_effort >/dev/null 2>&1; then context_build_best_effort "$run_id" "$task_id"; fi
        release_lock; trap - EXIT INT TERM; return 5
    fi
    current_hash=$(inventory_hash "$current") || return 1; approval_hash=$(sha256_file "$(task_dir "$task_id")/approval.conf") || return 1
    {
        conf_write_pair TASK_ID "$task_id"; conf_write_pair RUN_ID "$run_id"; conf_write_pair VERDICT PASSED; conf_write_pair VERIFIED_TREE_HASH "$current_hash"; conf_write_pair PREPARED_TREE_HASH "$generated_hash"
        conf_write_pair APPROVAL_HASH "$approval_hash"; conf_write_pair RESULTS_HASH "$(sha256_file "$results")"; conf_write_pair WARNINGS_HASH "$(sha256_file "$warnings_file")"
        conf_write_pair DECLARED_PACKAGE_DIGEST "${HARNESS_DECLARED_PACKAGE_DIGEST:-$HARNESS_EXECUTED_PACKAGE_DIGEST}"; conf_write_pair EXECUTED_PACKAGE_DIGEST "$HARNESS_EXECUTED_PACKAGE_DIGEST"
        conf_write_pair ACTUAL_CONVENTIONS_HASH "$(sha256_file "$actual_conventions")"; conf_write_pair ACTUAL_EXCEPTIONS_HASH "$(sha256_file "$actual_exceptions")"; conf_write_pair VERIFIED_AT "$(harness_now)"
    } | atomic_write "$run_directory/verification.conf" || return 1
    verification_metrics_write "$run_directory" PASSED "$total_started" "$inventory_seconds" "$copy_seconds" "$checks_seconds" "$check_count" || return 1
    set_run_hold "$run_id" "" || return 1; transition_run "$run_id" PASSED verification "all mandatory checks passed" || return 1
    verification_attempt_complete "$run_id" "$attempt_id" PASSED || return 1
    if command -v context_build_best_effort >/dev/null 2>&1; then context_build_best_effort "$run_id" "$task_id"; fi
    release_lock; trap - EXIT INT TERM
}

finalization_journal_file() {
    local run_id
    run_id=$1
    printf '%s/finalization-journal.conf\n' "$(run_dir "$run_id")"
}

finalization_journal_write() {
    local run_id status task_id journal
    run_id=$1; status=$2; task_id=$(state_get "$run_id" TASK_ID); journal=$(finalization_journal_file "$run_id")
    {
        conf_write_pair STATUS "$status"
        conf_write_pair RUN_ID "$run_id"
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$journal"
}

finalization_current_tree_matches() {
    local run_id finalization current current_hash expected
    run_id=$1; finalization=$(run_dir "$run_id")/finalization.conf
    [ -f "$finalization" ] || return 1
    current=$(mktemp "${TMPDIR:-/tmp}/recover-final-inventory.XXXXXX") || return 1
    inventory_write "$HARNESS_REPO_ROOT" "$current" || { rm -f "$current"; return 1; }
    current_hash=$(inventory_hash "$current"); rm -f "$current"
    expected=$(conf_get "$finalization" FINAL_TREE_HASH 2>/dev/null || printf '')
    [ -n "$expected" ] && [ "$current_hash" = "$expected" ]
}

recover_finalization_run() {
    local run_id journal status state task_id attestation active
    run_id=$1; journal=$(finalization_journal_file "$run_id")
    [ -f "$journal" ] || return 0
    status=$(conf_get "$journal" STATUS 2>/dev/null || printf '')
    case "$status" in COMPLETED|ROLLED_BACK) return 0 ;; esac
    repair_state_from_events "$run_id" || return 1
    task_id=$(state_get "$run_id" TASK_ID 2>/dev/null || printf '')
    [ -n "$task_id" ] || return 1
    state=$(state_get "$run_id" STATE 2>/dev/null || printf '')
    if [ "$status" = PREPARED ]; then
        if [ "$state" = PASSED ]; then
            if ! approval_consistency "$task_id" "$run_id" || ! finalization_current_tree_matches "$run_id"; then
                rm -f "$(run_dir "$run_id")/finalization.conf"
                finalization_journal_write "$run_id" ROLLED_BACK || return 1
                return 0
            fi
            transition_run "$run_id" FINALIZED finalization 'recovered finalization commit' || return 1
            state=FINALIZED
        fi
        [ "$state" = FINALIZED ] || return 1
        finalization_journal_write "$run_id" STATE_FINALIZED || return 1
        status=STATE_FINALIZED
    fi
    if [ "$status" = STATE_FINALIZED ]; then
        sed 's/^STATUS=.*/STATUS=FINALIZED/' "$(task_dir "$task_id")/spec.conf" | atomic_write "$(task_dir "$task_id")/spec.conf" || return 1
        finalization_journal_write "$run_id" TASK_MARKED || return 1
        status=TASK_MARKED
    fi
    if [ "$status" = TASK_MARKED ]; then
        attestation=$(run_dir "$run_id")/attestation.conf
        attestation_generate "$run_id" "$attestation" || return 1
        finalization_journal_write "$run_id" ATTESTED || return 1
        status=ATTESTED
    fi
    if [ "$status" = ATTESTED ]; then
        attestation=$(run_dir "$run_id")/attestation.conf
        external_anchor_append "$attestation" || return 1
        finalization_journal_write "$run_id" ANCHORED || return 1
        status=ANCHORED
    fi
    if [ "$status" = ANCHORED ]; then
        active=$(active_run_id 2>/dev/null || printf '')
        [ "$active" != "$run_id" ] || deactivate_run
        rebuild_task_index || return 1
        finalization_journal_write "$run_id" COMPLETED || return 1
        return 0
    fi
    return 1
}

recover_finalizations() {
    local directory run_id
    for directory in "$HARNESS_RUNS_DIR"/*; do
        [ -d "$directory" ] || continue
        [ -f "$directory/finalization-journal.conf" ] || continue
        run_id=$(basename "$directory")
        recover_finalization_run "$run_id" || return 1
    done
}

finalize_task() {
    local run_id task_id verification current current_hash expected approval review convention_review verified_tree finalization attestation
    acquire_lock "$HARNESS_GLOBAL_LOCK" finalize || return 2
    trap cleanup_common EXIT INT TERM
    run_id=$(active_run_id) || return 1
    [ "$(state_get "$run_id" STATE)" = "PASSED" ] && [ -z "$(state_get "$run_id" HOLD 2>/dev/null || printf '')" ] || return 3
    task_id=$(state_get "$run_id" TASK_ID); approval_consistency "$task_id" "$run_id" || return 4
    verification=$(run_dir "$run_id")/verification.conf; [ -f "$verification" ] || return 4
    current=$(mktemp "${TMPDIR:-/tmp}/final-inventory.XXXXXX") || return 1
    inventory_write "$HARNESS_REPO_ROOT" "$current" || { rm -f "$current"; return 4; }; current_hash=$(inventory_hash "$current"); rm -f "$current"
    expected=$(conf_get "$verification" VERIFIED_TREE_HASH)
    if [ "$current_hash" != "$expected" ]; then
        transition_run "$run_id" VERIFYING verification "repository changed after verification" || return 1
        transition_run "$run_id" FAILED verification "verification snapshot drift" || return 1
        transition_run "$run_id" REMEDIATING verification "reverification required" || return 1
        release_lock; trap - EXIT INT TERM; return 5
    fi
    approval=$(task_dir "$task_id")/approval.conf
    if [ "$(conf_get "$approval" FINAL_REVIEW_REQUIRED)" = "1" ]; then
        review=$(task_dir "$task_id")/final-review.conf; [ -f "$review" ] || return 3
        [ "$(conf_get "$review" VERIFICATION_HASH)" = "$(sha256_file "$verification")" ] || return 3
        [ "$(conf_get "$review" IDENTITY_HASH)" = "$(sha256_file "$(task_dir "$task_id")/final-review-identity.conf")" ] || return 3
        if conventions_has_review_obligations "$task_id" || [ -s "$(run_dir "$run_id")/artifacts/convention-warnings.tsv" ]; then
            convention_review=$(task_dir "$task_id")/convention-review.tsv; [ -f "$convention_review" ] || return 3
            [ "$(conf_get "$review" CONVENTION_REVIEW_HASH)" = "$(sha256_file "$convention_review")" ] || return 3
            verified_tree=$(conf_get "$verification" VERIFIED_TREE_HASH)
            awk -F '\t' -v expected="$verified_tree" 'NF && $7 != expected {bad=1} END {exit bad ? 1 : 0}' "$convention_review" || return 3
        fi
    fi
    finalization=$(run_dir "$run_id")/finalization.conf
    {
        conf_write_pair TASK_ID "$task_id"; conf_write_pair RUN_ID "$run_id"; conf_write_pair VERIFICATION_HASH "$(sha256_file "$verification")"; conf_write_pair FINAL_TREE_HASH "$current_hash"; conf_write_pair FINALIZED_AT "$(harness_now)"
    } | atomic_write "$finalization" || return 1
    finalization_journal_write "$run_id" PREPARED || return 1
    transition_run "$run_id" FINALIZED finalization "finalization committed" || return 1
    finalization_journal_write "$run_id" STATE_FINALIZED || return 1
    sed 's/^STATUS=.*/STATUS=FINALIZED/' "$(task_dir "$task_id")/spec.conf" | atomic_write "$(task_dir "$task_id")/spec.conf" || return 1
    finalization_journal_write "$run_id" TASK_MARKED || return 1
    attestation=$(run_dir "$run_id")/attestation.conf
    attestation_generate "$run_id" "$attestation" || return 1
    finalization_journal_write "$run_id" ATTESTED || return 1
    external_anchor_append "$attestation" || return 1
    finalization_journal_write "$run_id" ANCHORED || return 1
    deactivate_run; rebuild_task_index || return 1
    finalization_journal_write "$run_id" COMPLETED || return 1
    release_lock; trap - EXIT INT TERM
}
