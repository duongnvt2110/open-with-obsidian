#!/usr/bin/env bash

conventions_review_obligations() {
    local task_id run_id output temporary rule_id level check_id source sources item old_ifs warnings status
    task_id=$1; run_id=$2; output=$3
    temporary=$(mktemp "${TMPDIR:-/tmp}/review-obligations.XXXXXX") || return 1
    : >"$temporary"
    while IFS=$'	' read -r rule_id level; do
        [ -n "$rule_id" ] || continue
        printf '%s	%s	MANUAL
' "$rule_id" "$level" >>"$temporary"
    done <<EOF_MANUAL
$(conventions_required_manual_rules "$task_id")
EOF_MANUAL
    warnings=$(run_dir "$run_id")/artifacts/convention-warnings.tsv
    if [ -f "$warnings" ]; then
        while IFS=$'	' read -r check_id level sources; do
            [ "$level" = SHOULD ] || continue
            old_ifs=$IFS; IFS=,
            for item in $sources; do
                [ -n "$item" ] && [ "$item" != TASK ] || continue
                printf '%s	SHOULD	AUTOMATED_WARNING
' "$item" >>"$temporary"
            done
            IFS=$old_ifs
        done <"$warnings"
    fi
    LC_ALL=C sort -u "$temporary" | atomic_write "$output"
    status=$?
    rm -f "$temporary"
    return "$status"
}

conventions_validate_manual_review_input() {
    local task_id run_id input required provided rule_id level source decision reviewed_paths rationale extra expected_level status
    task_id=$1; run_id=$2; input=$3
    required=$(mktemp "${TMPDIR:-/tmp}/required-manual.XXXXXX") || return 1
    conventions_review_obligations "$task_id" "$run_id" "$required" || { rm -f "$required"; return 1; }
    provided=$(mktemp "${TMPDIR:-/tmp}/provided-manual.XXXXXX") || { rm -f "$required"; return 1; }
    : >"$provided"
    while IFS=$'\t' read -r rule_id decision reviewed_paths rationale extra; do
        [ -n "$rule_id$decision$reviewed_paths$rationale$extra" ] || continue
        [ -z "$extra" ] || { rm -f "$required" "$provided"; return 1; }
        expected_level=$(awk -F '\t' -v wanted="$rule_id" '$1 == wanted {print $2; exit}' "$required")
        [ -n "$expected_level" ] || { rm -f "$required" "$provided"; return 1; }
        case "$expected_level:$decision" in MUST:PASS|SHOULD:PASS|SHOULD:WAIVE) ;; *) rm -f "$required" "$provided"; return 1 ;; esac
        [ -n "$(trim_space "$reviewed_paths")" ] && [ -n "$(trim_space "$rationale")" ] || { rm -f "$required" "$provided"; return 1; }
        grep -Fx "$rule_id" "$provided" >/dev/null 2>&1 && { rm -f "$required" "$provided"; return 1; }
        printf '%s\n' "$rule_id" >>"$provided"
    done <"$input"
    LC_ALL=C sort -u "$provided" -o "$provided"
    awk -F '\t' '{print $1}' "$required" | LC_ALL=C sort -u >"$required.ids"
    cmp -s "$required.ids" "$provided"
    status=$?
    rm -f "$required" "$required.ids" "$provided"
    return "$status"
}

conventions_write_manual_review() {
    local task_id run_id approved_by input verification verified_tree output temporary rule_id decision reviewed_paths rationale status
    task_id=$1; run_id=$2; approved_by=$3; input=$4
    verification=$(run_dir "$run_id")/verification.conf
    verified_tree=$(conf_get "$verification" VERIFIED_TREE_HASH)
    output=$(task_dir "$task_id")/convention-review.tsv
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-review.XXXXXX") || return 1
    : >"$temporary"
    while IFS=$'\t' read -r rule_id decision reviewed_paths rationale; do
        [ -n "$rule_id" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rule_id" "$decision" "$(conventions_sanitize_field "$reviewed_paths")" "$(conventions_sanitize_field "$rationale")" "$(conventions_sanitize_field "$approved_by")" "$(harness_now)" "$verified_tree" >>"$temporary"
    done <"$input"
    cat "$temporary" | atomic_write "$output"
    status=$?
    rm -f "$temporary"
    return "$status"
}

