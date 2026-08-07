#!/usr/bin/env bash

create_run_with_id() {
    local task_id predecessor run_id activate directory initial
    task_id=$1; predecessor=${2:-}; run_id=$3; activate=${4:-1}
    identifier_validate "$run_id" || return 1
    directory=$(run_dir "$run_id")
    [ ! -e "$directory" ] || return 1
    mkdir -p "$directory/artifacts" || return 1
    initial=$(workflow_initial_state)
    write_state "$run_id" "$task_id" "$initial" 0 "" "$predecessor" || return 1
    : >"$(run_events_file "$run_id")"
    append_event "$run_id" NO_TASK "$initial" system "run created" || return 1
    write_projection "$run_id" || return 1
    [ "$activate" -eq 0 ] || write_active_pointer "$task_id" "$run_id" || return 1
    printf '%s\n' "$run_id"
}

create_run() {
    local task_id predecessor run_id
    task_id=$1; predecessor=${2:-}; run_id=$(new_id RUN)
    create_run_with_id "$task_id" "$predecessor" "$run_id" 1
}

transition_run() {
    local run_id target owner reason state_file source required_owner task_id failures hold predecessor
    run_id=$1; target=$2; owner=$3; reason=$4
    state_file=$(run_state_file "$run_id"); [ -f "$state_file" ] || return 1
    source=$(conf_get "$state_file" STATE)
    workflow_transition_allowed "$source" "$target" || return 2
    required_owner=$(workflow_owner "$target" 2>/dev/null || printf '')
    [ -z "$required_owner" ] || [ "$required_owner" = "$owner" ] || return 3
    task_id=$(conf_get "$state_file" TASK_ID); failures=$(conf_get "$state_file" FAILURE_COUNT)
    hold=$(conf_get "$state_file" HOLD 2>/dev/null || printf ''); predecessor=$(conf_get "$state_file" PREDECESSOR_RUN_ID 2>/dev/null || printf '')
    append_event "$run_id" "$source" "$target" "$owner" "$reason" || return 1
    write_state "$run_id" "$task_id" "$target" "$failures" "$hold" "$predecessor" || return 1
    write_projection "$run_id"
}

set_run_hold() {
    local run_id hold state_file task_id state failures predecessor
    run_id=$1; hold=$2; state_file=$(run_state_file "$run_id")
    task_id=$(conf_get "$state_file" TASK_ID); state=$(conf_get "$state_file" STATE); failures=$(conf_get "$state_file" FAILURE_COUNT)
    predecessor=$(conf_get "$state_file" PREDECESSOR_RUN_ID 2>/dev/null || printf '')
    write_state "$run_id" "$task_id" "$state" "$failures" "$hold" "$predecessor" || return 1
    write_projection "$run_id"
}

increment_failure_count() {
    local run_id state_file task_id state failures hold predecessor
    run_id=$1; state_file=$(run_state_file "$run_id")
    task_id=$(conf_get "$state_file" TASK_ID); state=$(conf_get "$state_file" STATE); failures=$(conf_get "$state_file" FAILURE_COUNT); failures=$((failures + 1))
    hold=$(conf_get "$state_file" HOLD 2>/dev/null || printf ''); predecessor=$(conf_get "$state_file" PREDECESSOR_RUN_ID 2>/dev/null || printf '')
    write_state "$run_id" "$task_id" "$state" "$failures" "$hold" "$predecessor" || return 1
    write_projection "$run_id"
}

workflow_status() {
    local run_id state_file task_id state failures hold pointer_status
    active_pointer_validate >/dev/null 2>&1
    pointer_status=$?
    if [ "$pointer_status" -eq 1 ]; then
        if [ "$HARNESS_JSON_MODE" = "1" ]; then printf '{"state":"NO_TASK","active":false,"worktree_id":"%s"}\n' "$(json_escape "$HARNESS_WORKTREE_ID")"; else printf 'State: NO_TASK\nWorktree: %s\n' "$HARNESS_WORKTREE_ID"; fi
        return 0
    fi
    [ "$pointer_status" -eq 0 ] || return 4
    run_id=$(active_run_id) || return 4
    state_file=$(run_state_file "$run_id"); task_id=$(conf_get "$state_file" TASK_ID); state=$(conf_get "$state_file" STATE); failures=$(conf_get "$state_file" FAILURE_COUNT); hold=$(conf_get "$state_file" HOLD 2>/dev/null || printf '')
    if [ "$HARNESS_JSON_MODE" = "1" ]; then
        printf '{"state":"%s","active":true,"task_id":"%s","run_id":"%s","failure_count":%s,"hold":"%s","worktree_id":"%s"}\n' "$(json_escape "$state")" "$(json_escape "$task_id")" "$(json_escape "$run_id")" "$failures" "$(json_escape "$hold")" "$(json_escape "$HARNESS_WORKTREE_ID")"
    else
        printf 'Task: %s\nRun: %s\nState: %s\nFailures: %s\nWorktree: %s\n' "$task_id" "$run_id" "$state" "$failures" "$HARNESS_WORKTREE_ID"; [ -z "$hold" ] || printf 'Hold: %s\n' "$hold"
    fi
}

workflow_packet_string_array() {
    local file first value
    file=$1
    first=1
    printf '['
    [ -f "$file" ] && while IFS= read -r value; do
        [ -n "$value" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '"%s"' "$(json_escape "$value")"
        first=0
    done <"$file"
    printf ']'
}

workflow_packet_criteria() {
    local file first criterion_id description extra
    file=$1
    first=1
    printf '['
    while IFS=$'\t' read -r criterion_id description extra; do
        [ -n "$criterion_id" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '{"id":"%s","description":"%s"}' "$(json_escape "$criterion_id")" "$(json_escape "$description")"
        first=0
    done <"$file"
    printf ']'
}

workflow_packet_coverage() {
    local file first criterion_id check_id evidence rationale extra
    file=$1
    first=1
    printf '['
    while IFS=$'\t' read -r criterion_id check_id evidence rationale extra; do
        [ -n "$criterion_id" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '{"criterion_id":"%s","check_id":"%s","evidence_type":"%s","rationale":"%s"}' \
            "$(json_escape "$criterion_id")" "$(json_escape "$check_id")" "$(json_escape "$evidence")" "$(json_escape "$rationale")"
        first=0
    done <"$file"
    printf ']'
}

workflow_packet_modules() {
    local file first module_id rationale extra
    file=$1
    first=1
    printf '['
    while IFS=$'\t' read -r module_id rationale extra; do
        [ -n "$module_id" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '{"id":"%s","rationale":"%s"}' "$(json_escape "$module_id")" "$(json_escape "$rationale")"
        first=0
    done <"$file"
    printf ']'
}

workflow_packet_steps() {
    local file first step_id description extra
    file=$1
    first=1
    printf '['
    while IFS=$'\t' read -r step_id description extra; do
        [ -n "$step_id" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '{"id":"%s","description":"%s"}' "$(json_escape "$step_id")" "$(json_escape "$description")"
        first=0
    done <"$file"
    printf ']'
}

workflow_packet_assumptions() {
    local file first assumption_id statement status extra
    file=$1
    first=1
    printf '['
    while IFS=$'\t' read -r assumption_id statement status extra; do
        [ -n "$assumption_id" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '{"id":"%s","statement":"%s","status":"%s"}' "$(json_escape "$assumption_id")" "$(json_escape "$statement")" "$(json_escape "$status")"
        first=0
    done <"$file"
    printf ']'
}

workflow_packet_id_array() {
    local file first identifier rest
    file=$1
    first=1
    printf '['
    [ -f "$file" ] && while IFS=$'\t' read -r identifier rest; do
        [ -n "$identifier" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '"%s"' "$(json_escape "$identifier")"
        first=0
    done <"$file"
    printf ']'
}

workflow_packet_checks() {
    local task_id run_id metadata first check_id level phase order source evidence
    task_id=$1
    run_id=$2
    metadata=$(run_dir "$run_id")/artifacts/effective-check-metadata.tsv
    first=1
    printf '['
    if [ -f "$metadata" ]; then
        while IFS=$'\t' read -r check_id level phase order source; do
            [ -n "$check_id" ] || continue
            evidence=$(command_get "$check_id" EVIDENCE_TYPE 2>/dev/null || printf '')
            level=${level:-MUST}; phase=${phase:-TEST}; order=${order:-100}
            [ "$first" -eq 1 ] || printf ','
            printf '{"id":"%s","evidence_type":"%s","level":"%s","phase":"%s","order":%s}' \
                "$(json_escape "$check_id")" "$(json_escape "$evidence")" "$(json_escape "$level")" "$(json_escape "$phase")" "$order"
            first=0
        done <"$metadata"
    else
        while IFS= read -r check_id; do
            [ -n "$check_id" ] || continue
            evidence=$(command_get "$check_id" EVIDENCE_TYPE 2>/dev/null || printf '')
            phase=$(command_get "$check_id" PHASE 2>/dev/null || printf '')
            order=$(command_get "$check_id" ORDER 2>/dev/null || printf '')
            phase=${phase:-TEST}; order=${order:-100}
            [ "$first" -eq 1 ] || printf ','
            printf '{"id":"%s","evidence_type":"%s","level":"MUST","phase":"%s","order":%s}' \
                "$(json_escape "$check_id")" "$(json_escape "$evidence")" "$(json_escape "$phase")" "$order"
            first=0
        done <"$(task_dir "$task_id")/checks.txt"
    fi
    printf ']'
}

workflow_packet_failures() {
    local file first check_id exit_code output_hash phase source extra
    file=$1
    first=1
    printf '['
    [ -f "$file" ] && while IFS=$'\t' read -r check_id exit_code output_hash phase source extra; do
        [ -n "$check_id" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '{"check_id":"%s","exit_code":%s,"output_hash":"%s","phase":"%s","evidence":"artifacts/checks/%s.log"}' \
            "$(json_escape "$check_id")" "$exit_code" "$(json_escape "$output_hash")" "$(json_escape "$phase")" "$(json_escape "$check_id")"
        first=0
    done <"$file"
    printf ']'
}

workflow_next_action_resolve() {
    local state hold approval task_id final_review_required
    state=$1
    hold=$2
    task_id=$3
    WORKFLOW_NEXT_COMMAND='harness audit'
    WORKFLOW_NEXT_DESCRIPTION='Inspect the invalid or unknown workflow state.'
    WORKFLOW_NEXT_TEXT='Unknown state. Run: harness audit'
    case "$state" in
        NO_TASK)
            WORKFLOW_NEXT_COMMAND='harness task create'
            WORKFLOW_NEXT_DESCRIPTION='Create and review one task contract.'
            WORKFLOW_NEXT_TEXT='Create a task with: harness task create ...'
            ;;
        INTAKE)
            WORKFLOW_NEXT_COMMAND='harness approve --by <name>'
            WORKFLOW_NEXT_DESCRIPTION='Complete repository understanding and approve the task contract.'
            WORKFLOW_NEXT_TEXT='Complete repository understanding and the task contract, then run: harness approve --by <name>'
            ;;
        CLARIFICATION_REQUIRED)
            WORKFLOW_NEXT_COMMAND='harness task answer --id <id> --answer <text>'
            WORKFLOW_NEXT_DESCRIPTION='Answer the unresolved blocking question.'
            WORKFLOW_NEXT_TEXT='Answer the blocking question with: harness task answer --id <id> --answer <text>'
            ;;
        IMPLEMENTING)
            WORKFLOW_NEXT_COMMAND='harness verify'
            WORKFLOW_NEXT_DESCRIPTION='Implement only within approved scope, then verify.'
            WORKFLOW_NEXT_TEXT='Implement only within the approved scope, then run: harness verify'
            ;;
        VERIFYING|FAILED)
            WORKFLOW_NEXT_COMMAND='harness recover'
            WORKFLOW_NEXT_DESCRIPTION='Recover the interrupted or failed workflow transition.'
            WORKFLOW_NEXT_TEXT='Run: harness recover'
            ;;
        REMEDIATING)
            if [ -n "$hold" ]; then
                WORKFLOW_NEXT_COMMAND='harness task acknowledge --by <name> --reason <text>'
                WORKFLOW_NEXT_DESCRIPTION='Acknowledge the active hold before retrying.'
                WORKFLOW_NEXT_TEXT='Acknowledge the active hold with: harness task acknowledge --by <name> --reason <text>'
            else
                WORKFLOW_NEXT_COMMAND='harness verify'
                WORKFLOW_NEXT_DESCRIPTION='Apply the current repair guidance within scope, then verify again.'
                WORKFLOW_NEXT_TEXT='Apply the repair plan within scope, then run: harness verify'
            fi
            ;;
        PASSED)
            approval=$(task_dir "$task_id")/approval.conf
            final_review_required=$(conf_get "$approval" FINAL_REVIEW_REQUIRED 2>/dev/null || printf 0)
            if [ "$final_review_required" = 1 ] && [ ! -f "$(task_dir "$task_id")/final-review.conf" ]; then
                WORKFLOW_NEXT_COMMAND='harness approve --final --by <name>'
                WORKFLOW_NEXT_DESCRIPTION='Complete required final review.'
                WORKFLOW_NEXT_TEXT='Run: harness approve --final --by <name>'
            else
                WORKFLOW_NEXT_COMMAND='harness finalize'
                WORKFLOW_NEXT_DESCRIPTION='Finalize the verified run.'
                WORKFLOW_NEXT_TEXT='Run: harness finalize'
            fi
            ;;
        FINALIZED|CANCELLED)
            WORKFLOW_NEXT_COMMAND='harness task create'
            WORKFLOW_NEXT_DESCRIPTION='The run is terminal; create a new task.'
            WORKFLOW_NEXT_TEXT='The run is terminal. Create a new task.'
            ;;
    esac
}


workflow_packet_testing() {
    local task_id
    task_id=$1
    if test_selection_resolve_task "$task_id" >/dev/null 2>&1; then
        test_selection_json true
    else
        test_selection_json false
    fi
}

workflow_testing_text() {
    local task_id
    task_id=$1
    if test_selection_resolve_task "$task_id" >/dev/null 2>&1; then
        printf 'Recommended development tests: %s\n' "$(test_selection_recommended_command)"
        printf 'Required completion tests: %s\n' "$(test_selection_required_command)"
        printf 'Selection reasons: %s\n' "${TEST_SELECTION_REASONS:-none}"
    fi
}

workflow_packet_next_action() {
    workflow_next_action_resolve "$1" "$2" "$3"
    printf '{"command":"%s","description":"%s"}' "$(json_escape "$WORKFLOW_NEXT_COMMAND")" "$(json_escape "$WORKFLOW_NEXT_DESCRIPTION")"
}

workflow_packet_json_full() {
    local run_id state_file task_id task_directory run_directory state failures hold contract_hash approval baseline_hash approval_hash remediation attempt_id attempt_count pointer_status
    active_pointer_validate >/dev/null 2>&1
    pointer_status=$?
    if [ "$pointer_status" -eq 1 ]; then
        printf '{"schema_version":"1","state":"NO_TASK","active":false,"worktree_id":"%s","next_action":' "$(json_escape "$HARNESS_WORKTREE_ID")"
        workflow_packet_next_action NO_TASK '' ''
        printf '}\n'
        return 0
    fi
    [ "$pointer_status" -eq 0 ] || return 4
    run_id=$(active_run_id) || return 4
    validate_run_state "$run_id" || return 4
    state_file=$(run_state_file "$run_id")
    task_id=$(conf_get "$state_file" TASK_ID)
    validate_task_contract "$task_id" || return 4
    task_directory=$(task_dir "$task_id")
    run_directory=$(run_dir "$run_id")
    state=$(conf_get "$state_file" STATE)
    failures=$(conf_get "$state_file" FAILURE_COUNT)
    hold=$(conf_get "$state_file" HOLD 2>/dev/null || printf '')
    contract_hash=$(task_contract_hash "$task_id") || return 4
    approval=$task_directory/approval.conf
    baseline_hash=''
    approval_hash=''
    if [ -f "$approval" ]; then
        approval_consistency "$task_id" "$run_id" || return 4
        baseline_hash=$(conf_get "$approval" BASELINE_TREE_HASH 2>/dev/null || printf '')
        approval_hash=$(sha256_file "$approval") || return 4
    fi
    remediation=$run_directory/remediation.conf
    printf '{"schema_version":"1","state":"%s","active":true,"task_id":"%s","run_id":"%s","failure_count":%s,"hold":"%s","worktree_id":"%s",' \
        "$(json_escape "$state")" "$(json_escape "$task_id")" "$(json_escape "$run_id")" "$failures" "$(json_escape "$hold")" "$(json_escape "$HARNESS_WORKTREE_ID")"
    printf '"title":"%s","goal":"%s","stakeholders":"%s","profile":"%s","risk":"%s","project_mode":"%s",' \
        "$(json_escape "$(conf_get "$task_directory/spec.conf" TITLE)")" "$(json_escape "$(conf_get "$task_directory/spec.conf" GOAL)")" \
        "$(json_escape "$(conf_get "$task_directory/spec.conf" STAKEHOLDERS)")" "$(json_escape "$(conf_get "$task_directory/plan.conf" PROFILE)")" \
        "$(json_escape "$(conf_get "$task_directory/plan.conf" RISK)")" "$(json_escape "$(conf_get "$task_directory/understanding.conf" PROJECT_MODE)")"
    printf '"acceptance_criteria":'; workflow_packet_criteria "$task_directory/criteria.tsv"
    printf ',"coverage":'; workflow_packet_coverage "$task_directory/coverage.tsv"
    printf ',"writable_scopes":'; workflow_packet_string_array "$task_directory/scopes.txt"
    printf ',"read_context_scopes":'; workflow_packet_string_array "$task_directory/read-context.txt"
    printf ',"affected_modules":'; workflow_packet_modules "$task_directory/affected-modules.tsv"
    printf ',"applicable_conventions":'; workflow_packet_id_array "$task_directory/applicable-conventions.tsv"
    printf ',"applicable_exceptions":'; workflow_packet_id_array "$task_directory/applicable-exceptions.tsv"
    printf ',"implementation_steps":'; workflow_packet_steps "$task_directory/implementation-plan.tsv"
    printf ',"resolved_assumptions":'; workflow_packet_assumptions "$task_directory/assumptions.tsv"
    printf ',"required_checks":'; workflow_packet_checks "$task_id" "$run_id"
    printf ',"task_contract_hash":"%s","baseline_hash":"%s","approval_hash":"%s",' \
        "$(json_escape "$contract_hash")" "$(json_escape "$baseline_hash")" "$(json_escape "$approval_hash")"
    printf '"blocking_failures":'; workflow_packet_failures "$run_directory/artifacts/blocking-failures.tsv"
    if [ -f "$remediation" ]; then
        attempt_id=$(conf_get "$remediation" ATTEMPT_ID 2>/dev/null || printf '')
        attempt_count=$(wc -l <"$(verification_attempt_index "$run_id")" 2>/dev/null | tr -d ' ' || printf 0)
        attempt_count=${attempt_count:-0}
        printf ',"remediation":{"attempt_id":"%s","attempt_count":%s,"failure_signature":"%s","same_signature_count":%s,"diagnosis":"%s","repair_plan":"%s"}' \
            "$(json_escape "$attempt_id")" "$attempt_count" \
            "$(json_escape "$(conf_get "$remediation" FAILURE_SIGNATURE 2>/dev/null || printf '')")" \
            "$(conf_get "$remediation" SAME_SIGNATURE_COUNT 2>/dev/null || printf 0)" \
            "$(json_escape "$(conf_get "$remediation" DIAGNOSIS 2>/dev/null || printf '')")" \
            "$(json_escape "$(conf_get "$remediation" REPAIR_PLAN 2>/dev/null || printf '')")"
    else
        printf ',"remediation":null'
    fi
    printf ',"testing":'; workflow_packet_testing "$task_id"
    printf ',"next_action":'; workflow_packet_next_action "$state" "$hold" "$task_id"
    printf '}\n'
}

workflow_packet_json() {
    local since details raw packet digest bytes maximum public_max pointer_status run_id state_file task_id state hold contract_path summary
    since=${1:-}
    details=${2:-0}
    raw=$(mktemp "${TMPDIR:-/tmp}/workflow-packet-raw.XXXXXX") || return 4
    packet=$(mktemp "${TMPDIR:-/tmp}/workflow-packet-final.XXXXXX") || { rm -f "$raw"; return 4; }
    workflow_packet_json_full >"$raw" || { rm -f "$raw" "$packet"; return 4; }
    digest=$(sha256_file "$raw") || { rm -f "$raw" "$packet"; return 4; }
    sed 's/}$/,"packet_digest":"'"$digest"'"}/' "$raw" >"$packet" || { rm -f "$raw" "$packet"; return 4; }
    rm -f "$raw"

    active_pointer_validate >/dev/null 2>&1
    pointer_status=$?
    if [ "$pointer_status" -eq 1 ]; then
        state=NO_TASK; task_id=''; run_id=''; hold=''; contract_path=''
    elif [ "$pointer_status" -eq 0 ]; then
        run_id=$(active_run_id) || { rm -f "$packet"; return 4; }
        state_file=$(run_state_file "$run_id")
        task_id=$(conf_get "$state_file" TASK_ID)
        state=$(conf_get "$state_file" STATE)
        hold=$(conf_get "$state_file" HOLD 2>/dev/null || printf '')
        contract_path=.agent-harness/tasks/$task_id
    else
        rm -f "$packet"
        return 4
    fi

    if [ -n "$since" ] && [ "$since" = "$digest" ]; then
        printf '{"schema_version":"1","state":"%s","active":%s,"unchanged":true,"packet_digest":"%s","next_action":' \
            "$(json_escape "$state")" "$([ "$state" = NO_TASK ] && printf false || printf true)" "$digest"
        workflow_packet_next_action "$state" "$hold" "$task_id"
        printf '}\n'
        rm -f "$packet"
        return 0
    fi

    bytes=$(wc -c <"$packet" | tr -d ' ')
    maximum=$(control_get WORKFLOW_PACKET_MAXIMUM_BYTES) || { rm -f "$packet"; return 4; }
    if [ "$details" -eq 1 ] || [ "$bytes" -le "$maximum" ]; then
        cat "$packet"
        rm -f "$packet"
        return 0
    fi

    summary=$(mktemp "${TMPDIR:-/tmp}/workflow-packet-summary.XXXXXX") || { rm -f "$packet"; return 4; }
    printf '{"schema_version":"1","state":"%s","active":%s,"task_id":"%s","run_id":"%s","packet_digest":"%s","truncated":true,"original_bytes":%s,"maximum_bytes":%s,"contract_path":"%s","testing":' \
        "$(json_escape "$state")" "$([ "$state" = NO_TASK ] && printf false || printf true)" \
        "$(json_escape "$task_id")" "$(json_escape "$run_id")" "$digest" "$bytes" "$maximum" "$(json_escape "$contract_path")" >"$summary"
    workflow_packet_testing "$task_id" >>"$summary"
    printf ',"next_action":' >>"$summary"
    workflow_packet_next_action "$state" "$hold" "$task_id" >>"$summary"
    printf '}\n' >>"$summary"
    public_max=$(control_get PUBLIC_RESULT_MAXIMUM_BYTES) || { rm -f "$packet" "$summary"; return 4; }
    [ "$(wc -c <"$summary" | tr -d ' ')" -le "$public_max" ] || { rm -f "$packet" "$summary"; return 4; }
    cat "$summary"
    rm -f "$packet" "$summary"
}

workflow_next() {
    local run_id state task_id hold pointer_status since details
    since=''; details=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --since) [ "$#" -ge 2 ] || return 2; since=$2; shift 2 ;;
            --details) details=1; shift ;;
            *) return 2 ;;
        esac
    done
    if [ -n "$since" ]; then
        printf '%s\n' "$since" | grep -E '^[0-9a-f]{64}$' >/dev/null 2>&1 || return 2
    fi
    if [ "$HARNESS_JSON_MODE" = "1" ]; then workflow_packet_json "$since" "$details"; return $?; fi
    [ -z "$since" ] && [ "$details" -eq 0 ] || return 2
    active_pointer_validate >/dev/null 2>&1
    pointer_status=$?
    if [ "$pointer_status" -eq 1 ]; then
        workflow_next_action_resolve NO_TASK '' ''
        printf '%s\n' "$WORKFLOW_NEXT_TEXT"
        return 0
    fi
    [ "$pointer_status" -eq 0 ] || return 4
    run_id=$(active_run_id) || return 4
    state=$(state_get "$run_id" STATE)
    task_id=$(state_get "$run_id" TASK_ID)
    hold=$(state_get "$run_id" HOLD 2>/dev/null || printf '')
    workflow_next_action_resolve "$state" "$hold" "$task_id"
    printf '%s\n' "$WORKFLOW_NEXT_TEXT"
    case "$state" in
        IMPLEMENTING) workflow_testing_text "$task_id" ;;
        REMEDIATING) [ -n "$hold" ] || workflow_testing_text "$task_id" ;;
    esac
}

validate_run_state() {
    local run_id state_file expected task_id state failures hold result
    run_id=$1; state_file=$(run_state_file "$run_id"); [ -f "$state_file" ] || return 1
    [ "$(conf_get "$state_file" WORKTREE_ID 2>/dev/null || printf standalone)" = "$HARNESS_WORKTREE_ID" ] || return 1
    validate_event_chain "$run_id" || return 1
    expected=$(mktemp "${TMPDIR:-/tmp}/projection.XXXXXX") || return 1
    task_id=$(conf_get "$state_file" TASK_ID); state=$(conf_get "$state_file" STATE); failures=$(conf_get "$state_file" FAILURE_COUNT); hold=$(conf_get "$state_file" HOLD 2>/dev/null || printf '')
    {
        printf '# Harness Run\n\n'; printf -- '- Task: `%s`\n' "$task_id"; printf -- '- Run: `%s`\n' "$run_id"; printf -- '- State: `%s`\n' "$state"; printf -- '- Failures: `%s`\n' "$failures"; [ -z "$hold" ] || printf -- '- Hold: `%s`\n' "$hold"
    } >"$expected"
    cmp -s "$expected" "$(run_dir "$run_id")/current.md"; result=$?; rm -f "$expected"; return "$result"
}

recover_supersede() {
    local journal status old_run old_task new_task new_run approved_by reason state
    journal=$HARNESS_RUNTIME_DIR/supersede.conf; [ -f "$journal" ] || return 0
    status=$(conf_get "$journal" STATUS 2>/dev/null || printf '')
    case "$status" in COMPLETED|ROLLED_BACK) return 0 ;; esac
    old_run=$(conf_get "$journal" PREDECESSOR_RUN_ID 2>/dev/null || printf '')
    old_task=$(conf_get "$journal" PREDECESSOR_TASK_ID 2>/dev/null || printf '')
    new_task=$(conf_get "$journal" SUCCESSOR_TASK_ID 2>/dev/null || printf '')
    new_run=$(conf_get "$journal" SUCCESSOR_RUN_ID 2>/dev/null || printf '')
    approved_by=$(conf_get "$journal" APPROVED_BY 2>/dev/null || printf recovery)
    reason=$(conf_get "$journal" REASON 2>/dev/null || printf amendment)
    if [ "$status" = "PREPARED" ]; then
        [ -d "$(run_dir "$old_run")" ] || return 1
        state=$(state_get "$old_run" STATE)
        if ! workflow_is_terminal "$state"; then
            rm -rf "$(task_dir "$new_task")" "$(run_dir "$new_run")"
            task_amend_journal_write "$journal" ROLLED_BACK "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
            write_active_pointer "$old_task" "$old_run" || return 1
            return 0
        fi
        task_amend_journal_write "$journal" PREDECESSOR_TERMINATED "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
        status=PREDECESSOR_TERMINATED
    fi
    if [ "$status" = "PREDECESSOR_TERMINATED" ]; then
        [ -d "$(task_dir "$new_task")" ] || return 1
        if [ ! -d "$(run_dir "$new_run")" ]; then create_run_with_id "$new_task" "$old_run" "$new_run" 0 >/dev/null || return 1; fi
        task_amend_journal_write "$journal" SUCCESSOR_CREATED "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
        status=SUCCESSOR_CREATED
    fi
    if [ "$status" = "SUCCESSOR_CREATED" ]; then
        write_active_pointer "$new_task" "$new_run" || return 1
        task_amend_journal_write "$journal" POINTER_SWITCHED "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
        status=POINTER_SWITCHED
    fi
    if [ "$status" = "POINTER_SWITCHED" ]; then
        rebuild_task_index || return 1
        task_amend_journal_write "$journal" COMPLETED "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
        return 0
    fi
    return 1
}

record_forced_lock_recovery() {
    local reason approved_by evidence owner owner_hash directory event identity_file
    reason=$1; approved_by=$2; evidence=${3:-}
    [ -n "$(trim_space "$reason")" ] && [ -n "$(trim_space "$approved_by")" ] || return 1
    owner=$HARNESS_GLOBAL_LOCK/owner.conf
    if [ -f "$owner" ]; then owner_hash=$(sha256_file "$owner") || return 1; else owner_hash=$(sha256_text MISSING_OWNER) || return 1; fi
    directory=$HARNESS_RUNTIME_DIR/forced-lock-recoveries
    mkdir -p "$directory" || return 1
    event=$directory/$(date -u '+%Y%m%d%H%M%S')-$$.conf
    identity_file=$event.identity.conf
    identity_capture "$approved_by" "$evidence" "$owner_hash" FORCE_LOCK_RECOVERY "$identity_file" || return 1
    {
        conf_write_pair OWNER_HASH "$owner_hash"
        conf_write_pair PREVIOUS_HOST "$(conf_get "$owner" HOST 2>/dev/null || printf unknown)"
        conf_write_pair PREVIOUS_PID "$(conf_get "$owner" PID 2>/dev/null || printf unknown)"
        conf_write_pair PREVIOUS_OPERATION "$(conf_get "$owner" OPERATION 2>/dev/null || printf unknown)"
        conf_write_pair REASON "$(printf '%s' "$reason" | tr '\t\r\n' '   ')"
        conf_write_pair IDENTITY_HASH "$(sha256_file "$identity_file")"
        conf_write_pair RECOVERED_AT "$(harness_now)"
    } | atomic_write "$event"
}

recover_workflow() {
    local run_id state force_lock reason approved_by identity_evidence attempt_id pointer_status
    force_lock=${1:-0}; reason=${2:-}; approved_by=${3:-}; identity_evidence=${4:-}
    if [ -d "$HARNESS_GLOBAL_LOCK" ]; then
        if lock_is_stale "$HARNESS_GLOBAL_LOCK"; then
            rm -rf "$HARNESS_GLOBAL_LOCK"
        elif [ "$force_lock" = "1" ]; then
            record_forced_lock_recovery "$reason" "$approved_by" "$identity_evidence" || return 3
            rm -rf "$HARNESS_GLOBAL_LOCK" || return 1
        else
            return 2
        fi
    fi
    acquire_lock "$HARNESS_GLOBAL_LOCK" recover || return 2
    trap cleanup_common EXIT INT TERM
    conventions_recover_update || return 1
    recover_supersede || return 1
    recover_finalizations || return 1
    active_pointer_validate >/dev/null 2>&1
    pointer_status=$?
    [ "$pointer_status" -ne 2 ] || return 4
    if [ "$pointer_status" -eq 0 ]; then
        run_id=$(active_run_id) || return 4
        repair_state_from_events "$run_id" || return 1
        state=$(state_get "$run_id" STATE)
        if [ "$state" = "VERIFYING" ]; then
            attempt_id=$(verification_attempt_started_id "$run_id" 2>/dev/null || printf '')
            increment_failure_count "$run_id" || return 1
            transition_run "$run_id" FAILED verification "verification interrupted" || return 1
            transition_run "$run_id" REMEDIATING verification "recovery opened remediation" || return 1
            [ -z "$attempt_id" ] || verification_attempt_complete "$run_id" "$attempt_id" INTERRUPTED || return 1
        fi
        write_projection "$run_id" || return 1
    fi
    rebuild_task_index || return 1
    release_lock
    trap - EXIT INT TERM
}
