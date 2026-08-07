#!/usr/bin/env bash

task_understanding_init() {
    local task_id project_mode directory
    task_id=$1; project_mode=$2; directory=$(task_dir "$task_id")
    {
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair PROJECT_MODE "$project_mode"
        conf_write_pair STATUS DRAFT
        conf_write_pair CURRENT_BEHAVIOR ""
        conf_write_pair ENTRY_POINTS ""
        conf_write_pair DATA_FLOW ""
        conf_write_pair DEPENDENCIES ""
        conf_write_pair INTERFACE_IMPACT ""
        conf_write_pair COMPATIBILITY_RISK ""
        conf_write_pair SCOPE_RATIONALE ""
        conf_write_pair CHECK_RATIONALE ""
        conf_write_pair ROLLBACK_PLAN ""
        conf_write_pair SECURITY_IMPACT ""
        conf_write_pair DATA_IMPACT ""
        conf_write_pair OPERATIONAL_IMPACT ""
        conf_write_pair NFR_IMPACT ""
        conf_write_pair UPDATED_BY ""
        conf_write_pair UPDATED_AT ""
    } | atomic_write "$directory/understanding.conf" || return 1
    : >"$directory/affected-modules.tsv"
    : >"$directory/assumptions.tsv"
    : >"$directory/implementation-plan.tsv"
    : >"$directory/understanding-evidence.tsv"
    {
        conf_write_pair STATUS UNBOUND
        conf_write_pair INSPECTION_HASH NONE
        conf_write_pair REPORT_HASH NONE
        conf_write_pair INSPECTED_TREE_HASH NONE
        conf_write_pair SKIP_REASON NONE
        conf_write_pair REVIEWED_BY NONE
        conf_write_pair REVIEWED_AT NONE
    } | atomic_write "$directory/inspection-binding.conf" || return 1
    {
        conf_write_pair STATUS UNBOUND
        conf_write_pair PROJECT_CONTRACT_HASH NONE
        conf_write_pair BOUND_AT NONE
    } | atomic_write "$directory/project-binding.conf" || return 1
}

understanding_evidence_type_valid() {
    case "$1" in ENTRY_POINT|SERVICE|REPOSITORY|TEST|ADR|CONFIG|SCHEMA|API|EVENT|DEPENDENCY|MODULE|OTHER) return 0 ;; esac
    return 1
}

task_understanding_validate() {
    local task_id directory file mode status risk module_id rationale extra assumption_id statement assumption_status step_id description claim_id claim_type claim_path claim_symbol claim_rationale binding_status skip_reason
    task_id=$1; directory=$(task_dir "$task_id"); file=$directory/understanding.conf
    [ -f "$file" ] || return 1
    [ "$(conf_get "$file" TASK_ID)" = "$task_id" ] || return 1
    mode=$(conf_get "$file" PROJECT_MODE 2>/dev/null || printf '')
    case "$mode" in brownfield|greenfield) ;; *) return 1 ;; esac
    status=$(conf_get "$file" STATUS 2>/dev/null || printf '')
    [ "$status" = "REVIEWED" ] || return 1
    for key in ENTRY_POINTS DATA_FLOW COMPATIBILITY_RISK SCOPE_RATIONALE CHECK_RATIONALE ROLLBACK_PLAN; do
        [ -n "$(trim_space "$(conf_get "$file" "$key" 2>/dev/null || printf '')")" ] || return 1
    done
    if [ "$mode" = "brownfield" ]; then
        [ -n "$(trim_space "$(conf_get "$file" CURRENT_BEHAVIOR 2>/dev/null || printf '')")" ] || return 1
    fi
    [ -s "$directory/affected-modules.tsv" ] || return 1
    awk -F '\t' 'NF { if (seen[$1]++) exit 1 }' "$directory/affected-modules.tsv" || return 1
    awk -F '\t' 'NF { if (seen[$1]++) exit 1 }' "$directory/implementation-plan.tsv" || return 1
    awk -F '\t' 'NF { if (seen[$1]++) exit 1 }' "$directory/assumptions.tsv" || return 1
    awk -F '\t' 'NF { if (seen[$1]++) exit 1 }' "$directory/understanding-evidence.tsv" || return 1
    while IFS=$'\t' read -r module_id rationale extra; do
        identifier_validate "$module_id" && [ -n "$(trim_space "$rationale")" ] && [ -z "$extra" ] || return 1
        case "$module_id" in repository) ;; *) if [ -s "$(convention_modules_file)" ]; then conventions_module_exists "$module_id" || return 1; fi ;; esac
    done <"$directory/affected-modules.tsv"
    [ -s "$directory/implementation-plan.tsv" ] || return 1
    while IFS=$'\t' read -r step_id description extra; do
        printf '%s\n' "$step_id" | grep -E '^STEP-[0-9]{3}$' >/dev/null 2>&1 || return 1
        [ -n "$(trim_space "$description")" ] && [ -z "$extra" ] || return 1
    done <"$directory/implementation-plan.tsv"
    while IFS=$'\t' read -r assumption_id statement assumption_status extra; do
        [ -n "$assumption_id$statement$assumption_status$extra" ] || continue
        printf '%s\n' "$assumption_id" | grep -E '^ASM-[0-9]{3}$' >/dev/null 2>&1 || return 1
        case "$assumption_status" in CONFIRMED|REJECTED) ;; OPEN) return 1 ;; *) return 1 ;; esac
        [ -n "$(trim_space "$statement")" ] && [ -z "$extra" ] || return 1
    done <"$directory/assumptions.tsv"
    if [ "$mode" = "brownfield" ]; then
        [ -s "$directory/understanding-evidence.tsv" ] || return 1
        while IFS=$'\t' read -r claim_id claim_type claim_path claim_symbol claim_rationale extra; do
            printf '%s\n' "$claim_id" | grep -E '^UND-[0-9]{3}$' >/dev/null 2>&1 || return 1
            understanding_evidence_type_valid "$claim_type" || return 1
            safe_relative_path "$claim_path" 0 >/dev/null || return 1
            path_is_harness_control "$claim_path" && return 1
            [ -n "$claim_symbol" ] && [ -n "$(trim_space "$claim_rationale")" ] && [ -z "$extra" ] || return 1
        done <"$directory/understanding-evidence.tsv"
        binding_status=$(conf_get "$directory/inspection-binding.conf" STATUS 2>/dev/null || printf '')
        case "$binding_status" in
            BOUND)
                [ "$(conf_get "$directory/inspection-binding.conf" INSPECTION_HASH 2>/dev/null || printf NONE)" != "NONE" ] || return 1
                [ "$(conf_get "$directory/inspection-binding.conf" INSPECTED_TREE_HASH 2>/dev/null || printf NONE)" != "NONE" ] || return 1
                ;;
            SKIPPED)
                skip_reason=$(conf_get "$directory/inspection-binding.conf" SKIP_REASON 2>/dev/null || printf NONE)
                [ "$skip_reason" != "NONE" ] && [ -n "$(trim_space "$skip_reason")" ] || return 1
                ;;
            *) return 1 ;;
        esac
    else
        project_contract_validate || return 1
    fi
    risk=$(conf_get "$directory/plan.conf" RISK 2>/dev/null || printf '')
    case "$risk" in low|medium|high|critical) ;; *) return 1 ;; esac
}

task_understanding_validate_against_inventory() {
    local task_id inventory directory mode claim_id claim_type claim_path claim_symbol claim_rationale extra module_id rationale module_root scope matched inspected_tree
    task_id=$1; inventory=$2; directory=$(task_dir "$task_id")
    mode=$(conf_get "$directory/understanding.conf" PROJECT_MODE)
    if [ "$mode" = "brownfield" ]; then
        while IFS=$'\t' read -r claim_id claim_type claim_path claim_symbol claim_rationale extra; do
            awk -F '\t' -v wanted="$claim_path" '$1 == wanted {found=1} END {exit found ? 0 : 1}' "$inventory" || return 1
        done <"$directory/understanding-evidence.tsv"
        if [ "$(conf_get "$directory/inspection-binding.conf" STATUS)" = "BOUND" ]; then
            inspected_tree=$(conf_get "$directory/inspection-binding.conf" INSPECTED_TREE_HASH)
            [ "$inspected_tree" = "$(inventory_hash "$inventory")" ] || return 1
        fi
    fi
    while IFS=$'\t' read -r module_id rationale; do
        [ "$module_id" = "repository" ] && continue
        module_root=$(conventions_module_root "$module_id") || return 1
        matched=0
        while IFS= read -r scope; do
            [ -n "$scope" ] || continue
            if conventions_patterns_overlap "$module_root" "$scope"; then matched=1; break; fi
        done <"$directory/scopes.txt"
        [ "$matched" -eq 1 ] || return 1
    done <"$directory/affected-modules.tsv"
}

task_bind_project_contract() {
    local task_id mode directory file status current_hash expected_hash bound_at
    task_id=$1; directory=$(task_dir "$task_id"); mode=$(conf_get "$directory/understanding.conf" PROJECT_MODE)
    file=$directory/project-binding.conf
    status=$(conf_get "$file" STATUS 2>/dev/null || printf UNBOUND)
    current_hash=$(conf_get "$file" PROJECT_CONTRACT_HASH 2>/dev/null || printf NONE)
    bound_at=$(conf_get "$file" BOUND_AT 2>/dev/null || printf NONE)
    if [ "$mode" = "greenfield" ]; then
        project_contract_validate || return 1
        expected_hash=$(project_contract_hash) || return 1
        if [ "$status" = BOUND ] && [ "$current_hash" = "$expected_hash" ] && [ "$bound_at" != NONE ]; then return 0; fi
        {
            conf_write_pair STATUS BOUND
            conf_write_pair PROJECT_CONTRACT_HASH "$expected_hash"
            conf_write_pair BOUND_AT "$(harness_now)"
        } | atomic_write "$file"
    else
        if [ "$status" = NOT_APPLICABLE ] && [ "$current_hash" = NONE ] && [ "$bound_at" != NONE ]; then return 0; fi
        {
            conf_write_pair STATUS NOT_APPLICABLE
            conf_write_pair PROJECT_CONTRACT_HASH NONE
            conf_write_pair BOUND_AT "$(harness_now)"
        } | atomic_write "$file"
    fi
}

task_record_understanding() {
    local task_id approved_by current_behavior entry_points data_flow dependencies interface_impact compatibility_risk scope_rationale check_rationale rollback_plan security_impact data_impact operational_impact nfr_impact modules assumptions steps evidence inspection_mode inspection_skip directory mode runtime_inspection run_id
    task_id=$1; approved_by=$2; current_behavior=$3; entry_points=$4; data_flow=$5; dependencies=$6; interface_impact=$7; compatibility_risk=$8
    scope_rationale=$9; shift 9
    check_rationale=$1; rollback_plan=$2; security_impact=$3; data_impact=$4; operational_impact=$5; nfr_impact=$6; modules=$7; assumptions=$8; steps=$9; shift 9
    evidence=$1; inspection_mode=$2; inspection_skip=$3
    acquire_lock "$HARNESS_GLOBAL_LOCK" task-understanding || return 2
    trap cleanup_common EXIT INT TERM
    run_id=$(active_run_id) || return 1
    [ "$(state_get "$run_id" STATE)" = "INTAKE" ] || return 3
    [ "$(state_get "$run_id" TASK_ID)" = "$task_id" ] || return 3
    directory=$(task_dir "$task_id"); mode=$(conf_get "$directory/understanding.conf" PROJECT_MODE)
    {
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair PROJECT_MODE "$mode"
        conf_write_pair STATUS REVIEWED
        conf_write_pair CURRENT_BEHAVIOR "$(printf '%s' "$current_behavior" | tr '\t\r\n' '   ')"
        conf_write_pair ENTRY_POINTS "$(printf '%s' "$entry_points" | tr '\t\r\n' '   ')"
        conf_write_pair DATA_FLOW "$(printf '%s' "$data_flow" | tr '\t\r\n' '   ')"
        conf_write_pair DEPENDENCIES "$(printf '%s' "$dependencies" | tr '\t\r\n' '   ')"
        conf_write_pair INTERFACE_IMPACT "$(printf '%s' "$interface_impact" | tr '\t\r\n' '   ')"
        conf_write_pair COMPATIBILITY_RISK "$(printf '%s' "$compatibility_risk" | tr '\t\r\n' '   ')"
        conf_write_pair SCOPE_RATIONALE "$(printf '%s' "$scope_rationale" | tr '\t\r\n' '   ')"
        conf_write_pair CHECK_RATIONALE "$(printf '%s' "$check_rationale" | tr '\t\r\n' '   ')"
        conf_write_pair ROLLBACK_PLAN "$(printf '%s' "$rollback_plan" | tr '\t\r\n' '   ')"
        conf_write_pair SECURITY_IMPACT "$(printf '%s' "$security_impact" | tr '\t\r\n' '   ')"
        conf_write_pair DATA_IMPACT "$(printf '%s' "$data_impact" | tr '\t\r\n' '   ')"
        conf_write_pair OPERATIONAL_IMPACT "$(printf '%s' "$operational_impact" | tr '\t\r\n' '   ')"
        conf_write_pair NFR_IMPACT "$(printf '%s' "$nfr_impact" | tr '\t\r\n' '   ')"
        conf_write_pair UPDATED_BY "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$directory/understanding.conf" || return 1
    cat "$modules" | atomic_write "$directory/affected-modules.tsv" || return 1
    cat "$assumptions" | atomic_write "$directory/assumptions.tsv" || return 1
    cat "$steps" | atomic_write "$directory/implementation-plan.tsv" || return 1
    cat "$evidence" | atomic_write "$directory/understanding-evidence.tsv" || return 1
    if [ "$mode" = "brownfield" ]; then
        if [ "$inspection_mode" = "CURRENT" ]; then
            runtime_inspection=$HARNESS_RUNTIME_DIR/inspection.conf
            [ -f "$runtime_inspection" ] || return 4
            {
                conf_write_pair STATUS BOUND
                conf_write_pair INSPECTION_HASH "$(conf_get "$runtime_inspection" INSPECTION_HASH)"
                conf_write_pair REPORT_HASH "$(conf_get "$runtime_inspection" REPORT_HASH)"
                conf_write_pair INSPECTED_TREE_HASH "$(conf_get "$runtime_inspection" INSPECTED_TREE_HASH)"
                conf_write_pair SKIP_REASON NONE
                conf_write_pair REVIEWED_BY "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')"
                conf_write_pair REVIEWED_AT "$(harness_now)"
            } | atomic_write "$directory/inspection-binding.conf" || return 1
        elif [ "$inspection_mode" = "SKIP" ] && [ -n "$(trim_space "$inspection_skip")" ]; then
            {
                conf_write_pair STATUS SKIPPED
                conf_write_pair INSPECTION_HASH NONE
                conf_write_pair REPORT_HASH NONE
                conf_write_pair INSPECTED_TREE_HASH NONE
                conf_write_pair SKIP_REASON "$(printf '%s' "$inspection_skip" | tr '\t\r\n' '   ')"
                conf_write_pair REVIEWED_BY "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')"
                conf_write_pair REVIEWED_AT "$(harness_now)"
            } | atomic_write "$directory/inspection-binding.conf" || return 1
        else
            return 4
        fi
    fi
    task_bind_project_contract "$task_id" || return 4
    task_understanding_validate "$task_id" || return 4
    release_lock
    trap - EXIT INT TERM
}

task_read_context_bytes() {
    local task_id inventory temporary pattern path kind mode digest size total
    task_id=$1; inventory=$2
    temporary=$(mktemp "${TMPDIR:-/tmp}/read-context-paths.XXXXXX") || return 1
    : >"$temporary"
    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        while IFS=$'\t' read -r path kind mode digest; do path_matches "$path" "$pattern" && printf '%s\n' "$path" >>"$temporary"; done <"$inventory"
    done <"$(task_dir "$task_id")/read-context.txt"
    total=0
    while IFS= read -r path; do
        [ -f "$HARNESS_REPO_ROOT/$path" ] || continue
        size=$(file_size "$HARNESS_REPO_ROOT/$path") || { rm -f "$temporary"; return 1; }
        total=$((total + size))
    done <<EOF_PATHS
$(LC_ALL=C sort -u "$temporary")
EOF_PATHS
    rm -f "$temporary"
    printf '%s\n' "$total"
}

task_acknowledge_hold() {
    local approved_by reason run_id hold
    approved_by=$1; reason=$2
    acquire_lock "$HARNESS_GLOBAL_LOCK" task-acknowledge || return 2
    trap cleanup_common EXIT INT TERM
    run_id=$(active_run_id) || return 1
    [ "$(state_get "$run_id" STATE)" = "REMEDIATING" ] || return 3
    hold=$(state_get "$run_id" HOLD 2>/dev/null || printf '')
    [ -n "$hold" ] || return 3
    {
        conf_write_pair PREVIOUS_HOLD "$hold"
        conf_write_pair ACKNOWLEDGED_BY "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')"
        conf_write_pair REASON "$(printf '%s' "$reason" | tr '\t\r\n' '   ')"
        conf_write_pair ACKNOWLEDGED_AT "$(harness_now)"
    } | atomic_write "$(run_dir "$run_id")/hold-acknowledgement.conf" || return 1
    set_run_hold "$run_id" "" || return 1
    release_lock
    trap - EXIT INT TERM
}

task_amend_journal_write() {
    local journal status old_run old_task new_task new_run approved_by reason
    journal=$1; status=$2; old_run=$3; old_task=$4; new_task=$5; new_run=$6; approved_by=$7; reason=$8
    {
        conf_write_pair STATUS "$status"
        conf_write_pair PREDECESSOR_RUN_ID "$old_run"
        conf_write_pair PREDECESSOR_TASK_ID "$old_task"
        conf_write_pair SUCCESSOR_TASK_ID "$new_task"
        conf_write_pair SUCCESSOR_RUN_ID "$new_run"
        conf_write_pair APPROVED_BY "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')"
        conf_write_pair REASON "$(printf '%s' "$reason" | tr '\t\r\n' '   ')"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$journal"
}

task_amend() {
    local approved_by reason old_run old_task old_dir new_task new_dir new_run journal
    approved_by=$1; reason=$2
    acquire_lock "$HARNESS_GLOBAL_LOCK" task-amend || return 2
    trap cleanup_common EXIT INT TERM
    old_run=$(active_run_id) || return 1
    case "$(state_get "$old_run" STATE)" in IMPLEMENTING|REMEDIATING) ;; *) return 3 ;; esac
    old_task=$(state_get "$old_run" TASK_ID); old_dir=$(task_dir "$old_task")
    new_task=$(new_id TASK); new_run=$(new_id RUN); new_dir=$(task_dir "$new_task")
    journal=$HARNESS_RUNTIME_DIR/supersede.conf
    task_amend_journal_write "$journal" PREPARED "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
    mkdir -p "$new_dir" || return 1
    cp "$old_dir"/* "$new_dir" 2>/dev/null || true
    sed "s/^TASK_ID=.*/TASK_ID=$new_task/; s/^STATUS=.*/STATUS=DRAFT/" "$old_dir/spec.conf" | atomic_write "$new_dir/spec.conf" || return 1
    sed "s/^TASK_ID=.*/TASK_ID=$new_task/; s/^STATUS=.*/STATUS=DRAFT/" "$old_dir/plan.conf" | atomic_write "$new_dir/plan.conf" || return 1
    sed "s/^TASK_ID=.*/TASK_ID=$new_task/; s/^STATUS=.*/STATUS=REVIEWED/" "$old_dir/understanding.conf" | atomic_write "$new_dir/understanding.conf" || return 1
    rm -f "$new_dir/approval.conf" "$new_dir/final-review.conf" "$new_dir/convention-review.tsv" "$new_dir/approval-identity.conf" "$new_dir/second-approval-identity.conf"
    : >"$new_dir/applicable-conventions.tsv"; : >"$new_dir/applicable-exceptions.tsv"
    transition_run "$old_run" CANCELLED human "superseded: $reason" || return 1
    sed 's/^STATUS=.*/STATUS=SUPERSEDED/' "$old_dir/spec.conf" | atomic_write "$old_dir/spec.conf" || return 1
    task_amend_journal_write "$journal" PREDECESSOR_TERMINATED "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
    create_run_with_id "$new_task" "$old_run" "$new_run" 0 || return 1
    task_amend_journal_write "$journal" SUCCESSOR_CREATED "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
    write_active_pointer "$new_task" "$new_run" || return 1
    task_amend_journal_write "$journal" POINTER_SWITCHED "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
    rebuild_task_index || return 1
    task_amend_journal_write "$journal" COMPLETED "$old_run" "$old_task" "$new_task" "$new_run" "$approved_by" "$reason" || return 1
    release_lock
    trap - EXIT INT TERM
    printf '%s\t%s\n' "$new_task" "$new_run"
}
