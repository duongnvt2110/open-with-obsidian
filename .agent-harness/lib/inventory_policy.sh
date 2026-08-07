#!/usr/bin/env bash

inventory_policy_file() { printf '%s/inventory-policy.tsv\n' "$HARNESS_PROJECT_DIR"; }

inventory_policy_hash() {
    local normalized
    normalized=$(awk 'NF && $0 !~ /^[[:space:]]*#/' "$(inventory_policy_file)" | LC_ALL=C sort)
    sha256_text "$normalized"
}

inventory_policy_validate() {
    local file seen type pattern reason approved_by approved_at extra prefix first key
    file=$(inventory_policy_file)
    [ -f "$file" ] || return 1
    seen=$(mktemp "${TMPDIR:-/tmp}/inventory-policy.XXXXXX") || return 1
    : >"$seen"
    while IFS=$'\t' read -r type pattern reason approved_by approved_at extra; do
        [ -n "$type$pattern$reason$approved_by$approved_at$extra" ] || continue
        [ -z "$extra" ] || { rm -f "$seen"; return 1; }
        case "$type" in EXCLUDE|ALLOW_SYMLINK|ALLOW_HARDLINK|ALLOW_SUBMODULE) ;; *) rm -f "$seen"; return 1 ;; esac
        glob_validate "$pattern" || { rm -f "$seen"; return 1; }
        first=${pattern%%/*}
        case "$first" in *'*'*|*'?'*) rm -f "$seen"; return 1 ;; esac
        prefix=$(conventions_static_prefix "$pattern" 2>/dev/null || printf '%s' "$first")
        if [ -n "$prefix" ] && path_is_harness_control "$prefix"; then rm -f "$seen"; return 1; fi
        [ -n "$(trim_space "$reason")" ] && [ -n "$(trim_space "$approved_by")" ] || { rm -f "$seen"; return 1; }
        case "$approved_at" in ????-??-??T??:??:??Z) ;; *) rm -f "$seen"; return 1 ;; esac
        key=$type:$pattern
        grep -Fx "$key" "$seen" >/dev/null 2>&1 && { rm -f "$seen"; return 1; }
        printf '%s\n' "$key" >>"$seen"
    done <"$file"
    rm -f "$seen"
}

inventory_policy_match() {
    local wanted path type pattern reason approved_by approved_at
    wanted=$1; path=$2
    while IFS=$'\t' read -r type pattern reason approved_by approved_at; do
        [ "$type" = "$wanted" ] || continue
        path_matches "$path" "$pattern" && return 0
    done <"$(inventory_policy_file)"
    return 1
}

inventory_policy_excluded() { inventory_policy_match EXCLUDE "$1"; }
inventory_policy_allows_symlink() { inventory_policy_match ALLOW_SYMLINK "$1"; }
inventory_policy_allows_hardlink() { inventory_policy_match ALLOW_HARDLINK "$1"; }
inventory_policy_allows_submodule() { inventory_policy_match ALLOW_SUBMODULE "$1"; }

inventory_policy_exact_allows_symlink() {
    local path type pattern reason approved_by approved_at
    path=$1
    while IFS=$'\t' read -r type pattern reason approved_by approved_at; do
        [ "$type" = ALLOW_SYMLINK ] || continue
        [ "$pattern" = "$path" ] && return 0
    done <"$(inventory_policy_file)"
    return 1
}

inventory_policy_mutation_allowed() { active_pointer_absent; }

inventory_policy_add() {
    local type pattern reason approved_by file temporary
    type=$1; pattern=$2; reason=$3; approved_by=$4
    acquire_lock "$HARNESS_GLOBAL_LOCK" inventory-policy-add || return 2
    trap cleanup_common EXIT INT TERM
    inventory_policy_mutation_allowed || return 3
    file=$(inventory_policy_file)
    temporary=$(mktemp "${TMPDIR:-/tmp}/inventory-policy.XXXXXX") || return 1
    cat "$file" >"$temporary"
    printf '%s\t%s\t%s\t%s\t%s\n' "$type" "$pattern" "$(printf '%s' "$reason" | tr '\t\r\n' '   ')" "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')" "$(harness_now)" >>"$temporary"
    LC_ALL=C sort -t $'\t' -k1,2 "$temporary" | atomic_write "$file" || { rm -f "$temporary"; return 1; }
    rm -f "$temporary"
    inventory_policy_validate || return 4
    release_lock
    trap - EXIT INT TERM
}


inventory_policy_remove() {
    local type pattern reason approved_by file temporary found current_type current_pattern current_reason current_by current_at extra
    type=$1; pattern=$2; reason=$3; approved_by=$4
    acquire_lock "$HARNESS_GLOBAL_LOCK" inventory-policy-remove || return 2
    trap cleanup_common EXIT INT TERM
    inventory_policy_mutation_allowed || return 3
    file=$(inventory_policy_file)
    temporary=$(mktemp "${TMPDIR:-/tmp}/inventory-policy.XXXXXX") || return 1
    found=0
    while IFS=$'\t' read -r current_type current_pattern current_reason current_by current_at extra; do
        [ -n "$current_type$current_pattern$current_reason$current_by$current_at$extra" ] || continue
        if [ "$current_type" = "$type" ] && [ "$current_pattern" = "$pattern" ]; then
            found=1
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$current_type" "$current_pattern" "$current_reason" "$current_by" "$current_at" >>"$temporary"
    done <"$file"
    [ "$found" -eq 1 ] || { rm -f "$temporary"; return 3; }
    cat "$temporary" | atomic_write "$file" || { rm -f "$temporary"; return 1; }
    rm -f "$temporary"
    inventory_policy_validate || return 4
    printf '%s\t%s\t%s\t%s\t%s\n' REMOVE "$type:$pattern" "$(printf '%s' "$reason" | tr '\t\r\n' '   ')" "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')" "$(harness_now)" >>"$HARNESS_RUNTIME_DIR/inventory-policy-history.tsv"
    release_lock
    trap - EXIT INT TERM
}

inventory_policy_conflicts_with_verification() {
    local task_id effective_checks type excluded rule_id level enforcement check_id example phase order pattern check trusted executable trusted_file
    task_id=$1; effective_checks=$2
    while IFS=$'\t' read -r type excluded _; do
        [ "$type" = "EXCLUDE" ] || continue
        while IFS=$'\t' read -r rule_id level enforcement check_id example phase order; do
            [ -n "$rule_id" ] || continue
            if [ "$example" != "-" ] && conventions_patterns_overlap "$excluded" "$example"; then return 0; fi
        done <"$(task_dir "$task_id")/applicable-conventions.tsv"
        while IFS= read -r check; do
            [ -n "$check" ] || continue
            trusted_file=$(mktemp "${TMPDIR:-/tmp}/harness-trusted-inputs.XXXXXX") || return 1
            command_trusted_inputs "$check" >"$trusted_file" || { rm -f "$trusted_file"; return 1; }
            while IFS= read -r trusted; do
                [ -n "$trusted" ] || continue
                if conventions_patterns_overlap "$excluded" "$trusted"; then rm -f "$trusted_file"; return 0; fi
            done <"$trusted_file"
            rm -f "$trusted_file"
            executable=$(command_get "$check" EXECUTABLE 2>/dev/null || printf '')
            case "$executable" in */*) conventions_patterns_overlap "$excluded" "$executable" && return 0 ;; esac
        done <"$effective_checks"
    done <"$(inventory_policy_file)"
    return 1
}

inventory_policy_conflicts_with_task() {
    local task_id scopes reads patterns type pattern task_pattern
    task_id=$1
    scopes=$(task_dir "$task_id")/scopes.txt
    reads=$(task_dir "$task_id")/read-context.txt
    while IFS=$'	' read -r type pattern _; do
        case "$type" in
            EXCLUDE)
                for patterns in "$scopes" "$reads"; do
                    while IFS= read -r task_pattern; do
                        [ -n "$task_pattern" ] || continue
                        conventions_patterns_overlap "$pattern" "$task_pattern" && return 0
                    done <"$patterns"
                done
                ;;
            ALLOW_SUBMODULE)
                while IFS= read -r task_pattern; do
                    [ -n "$task_pattern" ] || continue
                    conventions_patterns_overlap "$pattern" "$task_pattern" && return 0
                done <"$scopes"
                ;;
        esac
    done <"$(inventory_policy_file)"
    return 1
}

inventory_policy_vcs_allowed() {
    local path lower prefix
    path=$1
    lower=$(lower_text "$path")
    case "$lower" in
        */.git|*/.git/*|*/.hg|*/.hg/*|*/.svn|*/.svn/*)
            prefix=${path%%/.git*}; prefix=${prefix%%/.hg*}; prefix=${prefix%%/.svn*}
            inventory_policy_allows_submodule "$prefix" || inventory_policy_allows_submodule "$prefix/**"
            ;;
        *) return 1 ;;
    esac
}

inventory_pattern_within_scope() {
    local pattern scope base prefix
    pattern=$1; scope=$2
    [ "$pattern" = "$scope" ] && return 0
    case "$scope" in
        */'**')
            base=${scope%/'**'}; base=${base%/}
            prefix=$(conventions_static_prefix "$pattern" 2>/dev/null || printf '')
            [ -n "$prefix" ] || return 1
            case "$prefix" in "$base"|"$base"/*) return 0 ;; esac
            ;;
    esac
    case "$pattern" in *'*'*|*'?'*) return 1 ;; esac
    path_matches "$pattern" "$scope"
}

inventory_outputs_conflict_with_task() {
    local task_id effective_checks check output scope allowed type excluded other_check trusted
    task_id=$1; effective_checks=$2
    while IFS= read -r check; do
        [ -n "$check" ] || continue
        while IFS= read -r output; do
            [ -n "$output" ] || continue
            allowed=0
            while IFS= read -r scope; do
                [ -n "$scope" ] || continue
                inventory_pattern_within_scope "$output" "$scope" && { allowed=1; break; }
            done <"$(task_dir "$task_id")/scopes.txt"
            [ "$allowed" -eq 1 ] || return 0
            while IFS=$'\t' read -r type excluded _; do
                [ "$type" = EXCLUDE ] || continue
                conventions_patterns_overlap "$output" "$excluded" && return 0
            done <"$(inventory_policy_file)"
            while IFS= read -r other_check; do
                [ -n "$other_check" ] || continue
                while IFS= read -r trusted; do
                    [ -n "$trusted" ] || continue
                    conventions_patterns_overlap "$output" "$trusted" && return 0
                done <<EOF_TRUSTED
$(command_trusted_inputs "$other_check")
EOF_TRUSTED
            done <"$effective_checks"
        done <<EOF_OUTPUTS
$(command_outputs "$check")
EOF_OUTPUTS
    done <"$effective_checks"
    return 1
}
