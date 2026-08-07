#!/usr/bin/env bash
# Deterministic, repository-local test-mode selection. Bash 3.2 compatible.

TEST_SELECTION_MODE=focused
TEST_SELECTION_SUITES=''
TEST_SELECTION_CASES=''
TEST_SELECTION_REASONS=''
TEST_SELECTION_UNKNOWN=''
TEST_SELECTION_MATCHES=''
TEST_SELECTION_SOURCE=''

_test_selection_csv_add() {
    local current value
    current=$1
    value=$2
    [ -n "$value" ] || { printf '%s\n' "$current"; return 0; }
    case ",$current," in
        *",$value,"*) printf '%s\n' "$current" ;;
        *)
            if [ -n "$current" ]; then printf '%s,%s\n' "$current" "$value"; else printf '%s\n' "$value"; fi
            ;;
    esac
}

test_mode_valid() {
    case "$1" in focused|standard|full|auto) return 0 ;; esac
    return 1
}

test_mode_rank() {
    case "$1" in focused) printf '1\n' ;; standard) printf '2\n' ;; full) printf '3\n' ;; *) return 1 ;; esac
}

test_mode_stronger() {
    local left right left_rank right_rank
    left=$1
    right=$2
    left_rank=$(test_mode_rank "$left") || return 1
    right_rank=$(test_mode_rank "$right") || return 1
    if [ "$right_rank" -gt "$left_rank" ]; then printf '%s\n' "$right"; else printf '%s\n' "$left"; fi
}

test_impact_policy_file() {
    printf '%s/test-impact.tsv\n' "$HARNESS_POLICY_DIR"
}

test_impact_policy_validate() {
    local file pattern suite mode cases reason extra case_name old_ifs
    file=$(test_impact_policy_file)
    [ -f "$file" ] || return 1
    while IFS=$'\t' read -r pattern suite mode cases reason extra; do
        [ -n "$pattern$suite$mode$cases$reason$extra" ] || continue
        case "$pattern" in \#*) continue ;; esac
        [ -z "$extra" ] && [ -n "$pattern" ] && [ -n "$suite" ] && [ -n "$mode" ] && [ -n "$cases" ] && [ -n "$reason" ] || return 1
        glob_validate "$pattern" || return 1
        identifier_validate "$suite" || return 1
        case "$mode" in focused|standard|full) ;; *) return 1 ;; esac
        printf '%s\n' "$reason" | grep -E '^[A-Z][A-Z0-9_]*$' >/dev/null 2>&1 || return 1
        old_ifs=$IFS
        IFS=','
        set -- $cases
        IFS=$old_ifs
        for case_name in "$@"; do identifier_validate "$case_name" || return 1; done
    done <"$file"
}

_test_selection_pattern_prefix() {
    local pattern prefix
    pattern=$1
    prefix=$(printf '%s\n' "$pattern" | sed 's/[?*].*$//; s#/$##')
    printf '%s\n' "$prefix"
}

test_patterns_overlap() {
    local left right left_prefix right_prefix
    left=$1
    right=$2
    glob_validate "$left" || return 2
    glob_validate "$right" || return 2

    case "$left" in *'*'*|*'?'*) ;; *) path_matches "$left" "$right" && return 0 ;; esac
    case "$right" in *'*'*|*'?'*) ;; *) path_matches "$right" "$left" && return 0 ;; esac

    left_prefix=$(_test_selection_pattern_prefix "$left")
    right_prefix=$(_test_selection_pattern_prefix "$right")
    [ -n "$left_prefix" ] || return 0
    [ -n "$right_prefix" ] || return 0
    case "$left_prefix/" in "$right_prefix/"*) return 0 ;; esac
    case "$right_prefix/" in "$left_prefix/"*) return 0 ;; esac
    return 1
}

test_selection_reset() {
    TEST_SELECTION_MODE=focused
    TEST_SELECTION_SUITES=''
    TEST_SELECTION_CASES=''
    TEST_SELECTION_REASONS=''
    TEST_SELECTION_UNKNOWN=''
    TEST_SELECTION_MATCHES=''
    TEST_SELECTION_SOURCE=''
}

_test_selection_add_cases() {
    local cases old_ifs case_name
    cases=$1
    old_ifs=$IFS
    IFS=','
    set -- $cases
    IFS=$old_ifs
    for case_name in "$@"; do
        TEST_SELECTION_CASES=$(_test_selection_csv_add "$TEST_SELECTION_CASES" "$case_name")
    done
}

_test_selection_add_match() {
    local input pattern suite mode cases reason
    input=$1; pattern=$2; suite=$3; mode=$4; cases=$5; reason=$6
    TEST_SELECTION_MODE=$(test_mode_stronger "$TEST_SELECTION_MODE" "$mode") || return 1
    TEST_SELECTION_SUITES=$(_test_selection_csv_add "$TEST_SELECTION_SUITES" "$suite")
    TEST_SELECTION_REASONS=$(_test_selection_csv_add "$TEST_SELECTION_REASONS" "$reason")
    _test_selection_add_cases "$cases"
    if [ -n "$TEST_SELECTION_MATCHES" ]; then TEST_SELECTION_MATCHES=$TEST_SELECTION_MATCHES$'\n'; fi
    TEST_SELECTION_MATCHES=$TEST_SELECTION_MATCHES$input$'\t'$pattern$'\t'$suite$'\t'$mode$'\t'$reason
}

test_selection_resolve_file() {
    local input_file input_kind policy input matched pattern suite mode cases reason extra status
    input_file=$1
    input_kind=${2:-path}
    case "$input_kind" in path|pattern) ;; *) return 2 ;; esac
    [ -f "$input_file" ] || return 2
    test_impact_policy_validate || return 2
    policy=$(test_impact_policy_file)
    test_selection_reset
    TEST_SELECTION_SOURCE=$input_kind

    while IFS= read -r input; do
        [ -n "$input" ] || continue
        while [ "${input#./}" != "$input" ]; do input=${input#./}; done
        matched=0
        while IFS=$'\t' read -r pattern suite mode cases reason extra; do
            [ -n "$pattern$suite$mode$cases$reason$extra" ] || continue
            case "$pattern" in \#*) continue ;; esac
            if [ "$input_kind" = path ]; then
                path_matches "$input" "$pattern"; status=$?
            else
                test_patterns_overlap "$input" "$pattern"; status=$?
            fi
            [ "$status" -ne 2 ] || return 2
            if [ "$status" -eq 0 ]; then
                _test_selection_add_match "$input" "$pattern" "$suite" "$mode" "$cases" "$reason" || return 2
                matched=1
            fi
        done <"$policy"
        if [ "$matched" -eq 0 ]; then
            TEST_SELECTION_MODE=full
            TEST_SELECTION_REASONS=$(_test_selection_csv_add "$TEST_SELECTION_REASONS" UNKNOWN_PATH)
            TEST_SELECTION_UNKNOWN=$(_test_selection_csv_add "$TEST_SELECTION_UNKNOWN" "$input")
        fi
    done <"$input_file"

    if [ -z "$TEST_SELECTION_CASES" ]; then
        TEST_SELECTION_CASES='bash32,package_validate_strict'
        TEST_SELECTION_REASONS=$(_test_selection_csv_add "$TEST_SELECTION_REASONS" EMPTY_CHANGE_SET_SENTINELS)
    fi
}

test_selection_resolve_suite() {
    local wanted policy pattern suite mode cases reason extra found
    wanted=$1
    identifier_validate "$wanted" || return 2
    test_impact_policy_validate || return 2
    policy=$(test_impact_policy_file)
    test_selection_reset
    TEST_SELECTION_SOURCE=suite
    found=0
    while IFS=$'\t' read -r pattern suite mode cases reason extra; do
        [ -n "$pattern$suite$mode$cases$reason$extra" ] || continue
        case "$pattern" in \#*) continue ;; esac
        [ "$suite" = "$wanted" ] || continue
        _test_selection_add_match "$wanted" "$pattern" "$suite" focused "$cases" "$reason" || return 2
        found=1
    done <"$policy"
    [ "$found" -eq 1 ] || return 2
    TEST_SELECTION_MODE=focused
}

test_selection_changed_paths_since() {
    local since output temporary
    since=${1:-HEAD}
    output=$2
    command -v git >/dev/null 2>&1 || return 2
    git -C "$HARNESS_REPO_ROOT" rev-parse --verify "$since^{commit}" >/dev/null 2>&1 || return 2
    temporary=$(mktemp "${TMPDIR:-/tmp}/test-selection-paths.XXXXXX") || return 2
    : >"$temporary"
    git -C "$HARNESS_REPO_ROOT" diff --name-only "$since" -- >>"$temporary" 2>/dev/null || { rm -f "$temporary"; return 2; }
    git -C "$HARNESS_REPO_ROOT" ls-files --others --exclude-standard >>"$temporary" 2>/dev/null || { rm -f "$temporary"; return 2; }
    LC_ALL=C sort -u "$temporary" | atomic_write "$output"
    local result=$?
    rm -f "$temporary"
    return "$result"
}

test_selection_scope_is_self_update() {
    local scope
    scope=$1
    case "$scope" in
        .agent-harness/harness|.agent-harness/harness.sh|.agent-harness/VERSION|.agent-harness/manifest.tsv|.agent-harness/release-files.txt) return 0 ;;
        .agent-harness/lib/*|.agent-harness/policy/*|.agent-harness/tests/*|.agent-harness/examples/*) return 0 ;;
        AGENTS.md|WORKFLOW.md|CONTEXT.md|README.md|CHANGELOG.md|SECURITY.md|LICENSE) return 0 ;;
    esac
    return 1
}

test_selection_path_is_runtime_data() {
    local path
    path=$1
    if command -v path_is_harness_data >/dev/null 2>&1 && path_is_harness_data "$path"; then return 0; fi
    case "$path" in
        .agent-harness/config|.agent-harness/config/*|.agent-harness/project|.agent-harness/project/*|.harness-operations|.harness-operations/*) return 0 ;;
    esac
    return 1
}

test_selection_filter_changed_paths() {
    local input output path
    input=$1
    output=$2
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        test_selection_path_is_runtime_data "$path" && continue
        printf '%s\n' "$path"
    done <"$input" | atomic_write "$output"
}

test_selection_task_applicable() {
    local task_id scope
    task_id=$1
    [ -f "$(task_dir "$task_id")/scopes.txt" ] || return 1
    while IFS= read -r scope; do
        [ -n "$scope" ] || continue
        test_selection_scope_is_self_update "$scope" && return 0
    done <"$(task_dir "$task_id")/scopes.txt"
    return 1
}

test_selection_merge_current() {
    local mode suites cases reasons unknown matches old_ifs item
    mode=$1; suites=$2; cases=$3; reasons=$4; unknown=$5; matches=$6
    TEST_SELECTION_MODE=$(test_mode_stronger "$TEST_SELECTION_MODE" "$mode") || return 1

    old_ifs=$IFS; IFS=','; set -- $suites; IFS=$old_ifs
    for item in "$@"; do [ -n "$item" ] && TEST_SELECTION_SUITES=$(_test_selection_csv_add "$TEST_SELECTION_SUITES" "$item"); done
    old_ifs=$IFS; IFS=','; set -- $cases; IFS=$old_ifs
    for item in "$@"; do [ -n "$item" ] && TEST_SELECTION_CASES=$(_test_selection_csv_add "$TEST_SELECTION_CASES" "$item"); done
    old_ifs=$IFS; IFS=','; set -- $reasons; IFS=$old_ifs
    for item in "$@"; do [ -n "$item" ] && TEST_SELECTION_REASONS=$(_test_selection_csv_add "$TEST_SELECTION_REASONS" "$item"); done
    old_ifs=$IFS; IFS=','; set -- $unknown; IFS=$old_ifs
    for item in "$@"; do [ -n "$item" ] && TEST_SELECTION_UNKNOWN=$(_test_selection_csv_add "$TEST_SELECTION_UNKNOWN" "$item"); done

    if [ -n "$matches" ]; then
        if [ -n "$TEST_SELECTION_MATCHES" ]; then TEST_SELECTION_MATCHES=$TEST_SELECTION_MATCHES$'\n'; fi
        TEST_SELECTION_MATCHES=$TEST_SELECTION_MATCHES$matches
    fi
}


test_selection_resolve_task() {
    local task_id scopes preliminary_mode preliminary_suites preliminary_cases preliminary_reasons preliminary_unknown preliminary_matches
    local run_id baseline current changed filtered_changed actual_mode actual_suites actual_cases actual_reasons actual_unknown actual_matches
    task_id=$1
    test_selection_task_applicable "$task_id" || return 1
    scopes=$(task_dir "$task_id")/scopes.txt
    test_selection_resolve_file "$scopes" pattern || return 2
    preliminary_mode=$TEST_SELECTION_MODE
    preliminary_suites=$TEST_SELECTION_SUITES
    preliminary_cases=$TEST_SELECTION_CASES
    preliminary_reasons=$TEST_SELECTION_REASONS
    preliminary_unknown=$TEST_SELECTION_UNKNOWN
    preliminary_matches=$TEST_SELECTION_MATCHES

    run_id=$(active_run_id 2>/dev/null || printf '')
    if [ -n "$run_id" ]; then
        baseline=$(run_dir "$run_id")/artifacts/baseline-inventory.tsv
        if [ -f "$baseline" ]; then
            current=$(mktemp "${TMPDIR:-/tmp}/test-selection-current.XXXXXX") || return 2
            changed=$(mktemp "${TMPDIR:-/tmp}/test-selection-changed.XXXXXX") || { rm -f "$current"; return 2; }
            filtered_changed=$(mktemp "${TMPDIR:-/tmp}/test-selection-filtered.XXXXXX") || { rm -f "$current" "$changed"; return 2; }
            if inventory_write "$HARNESS_REPO_ROOT" "$current" && inventory_changed_paths "$baseline" "$current" "$changed" && test_selection_filter_changed_paths "$changed" "$filtered_changed"; then
                test_selection_resolve_file "$filtered_changed" path || { rm -f "$current" "$changed" "$filtered_changed"; return 2; }
                actual_mode=$TEST_SELECTION_MODE
                actual_suites=$TEST_SELECTION_SUITES
                actual_cases=$TEST_SELECTION_CASES
                actual_reasons=$TEST_SELECTION_REASONS
                actual_unknown=$TEST_SELECTION_UNKNOWN
                actual_matches=$TEST_SELECTION_MATCHES
                test_selection_reset
                TEST_SELECTION_SOURCE=task
                test_selection_merge_current "$preliminary_mode" "$preliminary_suites" "$preliminary_cases" "$preliminary_reasons" "$preliminary_unknown" "$preliminary_matches" || { rm -f "$current" "$changed" "$filtered_changed"; return 2; }
                test_selection_merge_current "$actual_mode" "$actual_suites" "$actual_cases" "$actual_reasons" "$actual_unknown" "$actual_matches" || { rm -f "$current" "$changed" "$filtered_changed"; return 2; }
                rm -f "$current" "$changed" "$filtered_changed"
                return 0
            fi
            rm -f "$current" "$changed" "$filtered_changed"
        fi
    fi
    TEST_SELECTION_MODE=$preliminary_mode
    TEST_SELECTION_SUITES=$preliminary_suites
    TEST_SELECTION_CASES=$preliminary_cases
    TEST_SELECTION_REASONS=$preliminary_reasons
    TEST_SELECTION_UNKNOWN=$preliminary_unknown
    TEST_SELECTION_MATCHES=$preliminary_matches
    TEST_SELECTION_SOURCE=task
}

test_selection_recommended_command() {
    printf '.agent-harness/harness test --mode focused --filter %s\n' "$TEST_SELECTION_CASES"
}

test_selection_required_command() {
    printf '.agent-harness/harness test --mode %s\n' "$TEST_SELECTION_MODE"
}

test_selection_json() {
    local applicable
    applicable=${1:-true}
    if [ "$applicable" != true ]; then
        printf '{"applicable":false,"reason":"BUSINESS_REPOSITORY_TASK_USES_REGISTERED_CHECKS"}'
        return 0
    fi
    printf '{"applicable":true,"recommended_mode":"focused","required_mode":"%s","affected_suites":[' "$(json_escape "$TEST_SELECTION_MODE")"
    _test_selection_json_csv "$TEST_SELECTION_SUITES"
    printf '],"focused_cases":['
    _test_selection_json_csv "$TEST_SELECTION_CASES"
    printf '],"reason_codes":['
    _test_selection_json_csv "$TEST_SELECTION_REASONS"
    printf '],"unknown_paths":['
    _test_selection_json_csv "$TEST_SELECTION_UNKNOWN"
    printf '],"recommended_command":"%s","required_command":"%s"}' \
        "$(json_escape "$(test_selection_recommended_command)")" \
        "$(json_escape "$(test_selection_required_command)")"
}

_test_selection_json_csv() {
    local csv old_ifs item first
    csv=$1
    old_ifs=$IFS; IFS=','; set -- $csv; IFS=$old_ifs
    first=1
    for item in "$@"; do
        [ -n "$item" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '"%s"' "$(json_escape "$item")"
        first=0
    done
}

test_selection_explain_text() {
    printf 'Selected mode: %s\n' "$TEST_SELECTION_MODE"
    printf 'Affected suites: %s\n' "${TEST_SELECTION_SUITES:-none}"
    printf 'Focused cases: %s\n' "${TEST_SELECTION_CASES:-none}"
    printf 'Reason codes: %s\n' "${TEST_SELECTION_REASONS:-none}"
    [ -z "$TEST_SELECTION_UNKNOWN" ] || printf 'Unknown paths: %s\n' "$TEST_SELECTION_UNKNOWN"
    printf 'Recommended command: %s\n' "$(test_selection_recommended_command)"
    printf 'Required command: %s\n' "$(test_selection_required_command)"
    if [ -n "$TEST_SELECTION_MATCHES" ]; then
        printf 'Matches:\n'
        printf '%s\n' "$TEST_SELECTION_MATCHES" | while IFS=$'\t' read -r input pattern suite mode reason; do
            printf '  %s -> %s (%s, %s, %s)\n' "$input" "$pattern" "$suite" "$mode" "$reason"
        done
    fi
}
