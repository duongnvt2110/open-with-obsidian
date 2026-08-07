#!/usr/bin/env bash
# Provider-neutral, Bash 3.2-compatible context budgeting.
# Context files are generated projections. Task, lifecycle, source files, and
# verification evidence remain authoritative.

context_run_root() { printf '%s/context\n' "$(run_dir "$1")"; }
context_current_dir() { printf '%s/current\n' "$(context_run_root "$1")"; }
context_previous_dir() { printf '%s/previous\n' "$(context_run_root "$1")"; }
context_selections_file() { printf '%s/selections.tsv\n' "$(context_run_root "$1")"; }
context_working_memory_file() { printf '%s/working-memory.md\n' "$(context_run_root "$1")"; }
context_last_build_file() { printf '%s/last-build.conf\n' "$(context_run_root "$1")"; }

context_policy_number() {
    local key value
    key=$1
    value=$(control_get "$key" 2>/dev/null || printf '')
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    [ "$value" -gt 0 ] || return 1
    printf '%s\n' "$value"
}

context_publication_marker() { printf '%s/publication.conf\n' "$(context_run_root "$1")"; }

context_resolve_source() {
    local relative candidate parent physical_parent physical_root resolved
    relative=$(safe_relative_path "$1" 0) || return 1
    candidate=$HARNESS_REPO_ROOT/$relative
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    parent=$(dirname "$candidate")
    physical_parent=$(CDPATH= cd -- "$parent" 2>/dev/null && pwd -P) || return 1
    physical_root=$(CDPATH= cd -- "$HARNESS_REPO_ROOT" 2>/dev/null && pwd -P) || return 1
    case "$physical_parent" in
        "$physical_root"|"$physical_root"/*) ;;
        *) return 1 ;;
    esac
    resolved=$physical_parent/$(basename "$candidate")
    [ -f "$resolved" ] && [ ! -L "$resolved" ] || return 1
    printf '%s\n' "$resolved"
}

context_range_bytes() {
    local file start end
    file=$1; start=$2; end=$3
    if [ "$start" -eq 0 ] && [ "$end" -eq 0 ]; then
        file_size "$file"
    else
        LC_ALL=C awk -v first="$start" -v last="$end" 'NR >= first && NR <= last {total += length($0) + 1} END {print total+0}' "$file"
    fi
}

context_fence_for_range() {
    local file start end
    file=$1; start=$2; end=$3
    LC_ALL=C awk -v first="$start" -v last="$end" '
        function inspect(line, i, run) {
            run=0
            for (i=1; i<=length(line); i++) {
                if (substr(line,i,1) == "`") {run++; if (run > maximum) maximum=run}
                else run=0
            }
        }
        (first == 0 && last == 0) || (NR >= first && NR <= last) {inspect($0)}
        END {
            count=maximum+1
            if (count < 3) count=3
            for (i=0; i<count; i++) printf "`"
            printf "\n"
        }
    ' "$file"
}

context_calculate_generation_digest() {
    local directory listing sorted path
    directory=$1
    listing=$(mktemp "${TMPDIR:-/tmp}/context-digest.XXXXXX") || return 1
    sorted=$listing.sorted
    : >"$listing"
    for path in "$directory"/base.md "$directory"/task-details.md "$directory"/failure-summary.md "$directory"/index.tsv "$directory"/warnings.tsv "$directory"/status.conf "$directory"/bundle-*.md; do
        [ -f "$path" ] || continue
        printf '%s\t%s\n' "$(basename "$path")" "$(sha256_file "$path")" >>"$listing" || { rm -f "$listing" "$sorted"; return 1; }
    done
    LC_ALL=C sort "$listing" >"$sorted" || { rm -f "$listing" "$sorted"; return 1; }
    sha256_file "$sorted"
    status=$?
    rm -f "$listing" "$sorted"
    return "$status"
}

context_validate_generation_digest() {
    local directory expected actual extra
    directory=$1
    [ -f "$directory/context.sha256" ] || return 1
    IFS= read -r expected extra <"$directory/context.sha256" || return 1
    [ -n "$expected" ] && [ -z "$extra" ] || return 1
    actual=$(context_calculate_generation_digest "$directory") || return 1
    [ "$actual" = "$expected" ]
}

context_recover_publication() {
    local run_id marker current previous
    run_id=$1; marker=$(context_publication_marker "$run_id"); current=$(context_current_dir "$run_id"); previous=$(context_previous_dir "$run_id")
    [ -f "$marker" ] || return 0
    if [ ! -d "$current" ] && [ -d "$previous" ]; then mv "$previous" "$current" || return 1; fi
    [ -d "$current" ] || return 1
    rm -f "$marker"
}

context_effective_current_dir() {
    local run_id current previous marker
    run_id=$1; current=$(context_current_dir "$run_id"); previous=$(context_previous_dir "$run_id"); marker=$(context_publication_marker "$run_id")
    if [ -d "$current" ]; then printf '%s\n' "$current"; return 0; fi
    if [ -f "$marker" ] && [ -d "$previous" ]; then printf '%s\n' "$previous"; return 0; fi
    return 1
}

context_path_allowed() {
    local task_id path file pattern matched
    task_id=$1
    path=$(safe_relative_path "$2" 0) || return 1
    path_is_harness_control "$path" && return 1
    path_is_harness_data "$path" && return 1
    context_resolve_source "$path" >/dev/null || return 1
    matched=0
    for file in "$(task_dir "$task_id")/scopes.txt" "$(task_dir "$task_id")/read-context.txt"; do
        [ -f "$file" ] || continue
        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            if path_matches "$path" "$pattern"; then matched=1; break; fi
        done <"$file"
        [ "$matched" -eq 0 ] || break
    done
    if [ "$matched" -eq 0 ] && [ -f "$(task_dir "$task_id")/understanding-evidence.tsv" ]; then
        awk -F '\t' -v wanted="$path" '$3 == wanted {found=1} END {exit found ? 0 : 1}' "$(task_dir "$task_id")/understanding-evidence.tsv" && matched=1
    fi
    [ "$matched" -eq 1 ]
}


context_write_default_selections() {
    local task_id output evidence temporary claim_id claim_type claim_path claim_symbol claim_rationale extra reason
    task_id=$1
    output=$2
    evidence=$(task_dir "$task_id")/understanding-evidence.tsv
    temporary=$(mktemp "${TMPDIR:-/tmp}/context-selections.XXXXXX") || return 1
    : >"$temporary"
    if [ -f "$evidence" ]; then
        while IFS=$'\t' read -r claim_id claim_type claim_path claim_symbol claim_rationale extra; do
            [ -n "$claim_path" ] || continue
            reason=$claim_type
            [ -z "$claim_symbol" ] || reason="$reason: $claim_symbol"
            [ -z "$claim_rationale" ] || reason="$reason - $claim_rationale"
            printf '%s\t0\t0\t%s\n' "$claim_path" "$(printf '%s' "$reason" | tr '\t\r\n' '   ')" >>"$temporary"
        done <"$evidence"
    fi
    awk -F '\t' '!seen[$1]++' "$temporary" | atomic_write "$output"
    status=$?
    rm -f "$temporary"
    return "$status"
}

context_ensure_working_memory() {
    local file
    file=$1
    [ -f "$file" ] && return 0
    cat <<'EOF_MEMORY' | atomic_write "$file"
# Working Memory

## Current Objective

## Locked Decisions

## Important Constraints

## Files Changed

## Current Failure

## Rejected Approaches and Reasons

## Unresolved Questions

## Next Action

## Evidence References
EOF_MEMORY
}

context_validate_range() {
    local file start end total
    file=$1; start=$2; end=$3
    case "$start:$end" in
        0:0) return 0 ;;
        *[!0-9:]*|:*|*:) return 1 ;;
    esac
    [ "$start" -gt 0 ] && [ "$end" -ge "$start" ] || return 1
    total=$(awk 'END {print NR+0}' "$file") || return 1
    [ "$end" -le "$total" ]
}

context_extract_range() {
    local file start end
    file=$1; start=$2; end=$3
    if [ "$start" -eq 0 ] && [ "$end" -eq 0 ]; then
        cat "$file"
    else
        awk -v first="$start" -v last="$end" 'NR >= first && NR <= last {print}' "$file"
    fi
}

context_append_warning() {
    local file code detail
    file=$1; code=$2; detail=$3
    printf '%s\t%s\n' "$code" "$(printf '%s' "$detail" | tr '\t\r\n' '   ')" >>"$file"
}

context_render_failure_summary() {
    local run_id output maximum remediation check_id exit_code log stderr digest temporary bounded state
    run_id=$1; output=$2
    state=$(state_get "$run_id" STATE 2>/dev/null || printf UNKNOWN)
    case "$state" in FAILED|REMEDIATING) ;; *) : >"$output"; return 0 ;; esac
    remediation=$(run_dir "$run_id")/remediation.conf
    [ -f "$remediation" ] || { : >"$output"; return 0; }
    maximum=$(context_policy_number CONTEXT_CHECK_SUMMARY_MAXIMUM_BYTES) || return 1
    check_id=$(conf_get "$remediation" FAILED_CHECK 2>/dev/null || printf '')
    exit_code=$(conf_get "$remediation" EXIT_CODE 2>/dev/null || printf '')
    log=$(run_dir "$run_id")/artifacts/checks/$check_id.log
    stderr=$(run_dir "$run_id")/artifacts/checks/$check_id.stderr.log
    temporary=$(mktemp "${TMPDIR:-/tmp}/context-failure.XXXXXX") || return 1
    {
        printf '# Current Verification Failure\n\n'
        printf -- '- Check: `%s`\n' "$check_id"
        printf -- '- Exit code: `%s`\n' "$exit_code"
        if [ -f "$log" ]; then
            digest=$(sha256_file "$log") || { rm -f "$temporary"; return 1; }
            printf -- '- Full log: `%s`\n' "${log#$HARNESS_REPO_ROOT/}"
            printf -- '- Full log SHA-256: `%s`\n\n' "$digest"
            printf '## Important Diagnostics\n\n```text\n'
            awk 'BEGIN {count=0} {lower=tolower($0); if (lower ~ /fail|error|panic|fatal|exception/) {if (count < 20) print NR ": " $0; count++}}' "$log"
            printf '```\n\n## Last Output Lines\n\n```text\n'
            tail -n 30 "$log"
            printf '```\n'
        else
            printf -- '- Full log is not available.\n'
        fi
        if [ -f "$stderr" ]; then
            printf -- '\n- Standard-error log: `%s`\n' "${stderr#$HARNESS_REPO_ROOT/}"
        fi
    } >"$temporary" || { rm -f "$temporary"; return 1; }
    if [ "$(file_size "$temporary")" -le "$maximum" ]; then
        cat "$temporary" | atomic_write "$output"
        status=$?
        rm -f "$temporary"
        return "$status"
    fi
    bounded=$(mktemp "${TMPDIR:-/tmp}/context-failure-bounded.XXXXXX") || { rm -f "$temporary"; return 1; }
    awk -v maximum="$maximum" '
        {bytes=length($0)+1; if (used+bytes > maximum-160) exit; print; used+=bytes}
        END {print ""; print "[Summary truncated. The full log remains authoritative.]"}
    ' "$temporary" >"$bounded"
    cat "$bounded" | atomic_write "$output"
    status=$?
    rm -f "$temporary" "$bounded"
    return "$status"
}

context_render_full_base() {
    local run_id task_id output directory spec understanding state key label id description assumption_id statement assumption_status extra memory memory_max memory_size memory_digest failure
    run_id=$1; task_id=$2; output=$3
    directory=$(task_dir "$task_id")
    spec=$directory/spec.conf
    understanding=$directory/understanding.conf
    state=$(state_get "$run_id" STATE 2>/dev/null || printf UNKNOWN)
    memory=$(context_working_memory_file "$run_id")
    failure=$(dirname "$output")/failure-summary.md
    {
        printf '# Compact Context Base\n\n'
        printf -- '- Task: `%s`\n' "$task_id"
        printf -- '- Run: `%s`\n' "$run_id"
        printf -- '- State: `%s`\n' "$state"
        printf -- '- Title: %s\n' "$(conf_get "$spec" TITLE 2>/dev/null || printf '')"
        printf '\n## Goal\n\n%s\n' "$(conf_get "$spec" GOAL 2>/dev/null || printf '')"
        printf '\n## Active Acceptance Criteria\n\n'
        while IFS=$'\t' read -r id description extra; do
            [ -n "$id" ] || continue
            printf -- '- `%s`: %s\n' "$id" "$description"
        done <"$directory/criteria.tsv"
        printf '\n## Important Constraints\n\n'
        for key in COMPATIBILITY_RISK INTERFACE_IMPACT DEPENDENCIES SECURITY_IMPACT DATA_IMPACT OPERATIONAL_IMPACT NFR_IMPACT ROLLBACK_PLAN; do
            case "$key" in
                COMPATIBILITY_RISK) label='Compatibility risk' ;;
                INTERFACE_IMPACT) label='Interface impact' ;;
                DEPENDENCIES) label='Dependencies' ;;
                SECURITY_IMPACT) label='Security impact' ;;
                DATA_IMPACT) label='Data impact' ;;
                OPERATIONAL_IMPACT) label='Operational impact' ;;
                NFR_IMPACT) label='NFR impact' ;;
                ROLLBACK_PLAN) label='Rollback plan' ;;
            esac
            printf -- '- **%s:** %s\n' "$label" "$(conf_get "$understanding" "$key" 2>/dev/null || printf '')"
        done
        printf '\n## Writable Scope\n\n'
        while IFS= read -r id; do [ -n "$id" ] && printf -- '- `%s`\n' "$id"; done <"$directory/scopes.txt"
        printf '\n## Recommended Read Context\n\n'
        while IFS= read -r id; do [ -n "$id" ] && printf -- '- `%s`\n' "$id"; done <"$directory/read-context.txt"
        printf '\n## Locked Decisions and Assumptions\n\n'
        if [ -s "$directory/assumptions.tsv" ]; then
            while IFS=$'\t' read -r assumption_id statement assumption_status extra; do
                [ -n "$assumption_id" ] || continue
                printf -- '- `%s` [%s]: %s\n' "$assumption_id" "$assumption_status" "$statement"
            done <"$directory/assumptions.tsv"
        else
            printf -- '- None recorded.\n'
        fi
        printf '\n## Working Memory\n\n'
        memory_max=$(context_policy_number CONTEXT_WORKING_MEMORY_MAXIMUM_BYTES) || return 1
        if [ -f "$memory" ]; then
            memory_size=$(file_size "$memory") || return 1
            if [ "$memory_size" -le "$memory_max" ]; then
                cat "$memory"
            else
                memory_digest=$(sha256_file "$memory") || return 1
                printf 'Working memory was not embedded because it is %s bytes; maximum is %s.\n\n' "$memory_size" "$memory_max"
                printf -- '- Path: `%s`\n- SHA-256: `%s`\n' "${memory#$HARNESS_REPO_ROOT/}" "$memory_digest"
            fi
        else
            printf 'No working memory has been recorded.\n'
        fi
        if [ -s "$failure" ]; then printf '\n'; cat "$failure"; fi
        printf '\n## Source Bundle Index\n\nSee `index.tsv` in this context generation. Load only the bundle needed for the current step.\n'
    } >"$output"
}


context_render_compact_base() {
    local run_id task_id output details directory spec state id description extra failure memory memory_size memory_digest
    run_id=$1; task_id=$2; output=$3; details=$4
    directory=$(task_dir "$task_id"); spec=$directory/spec.conf; state=$(state_get "$run_id" STATE 2>/dev/null || printf UNKNOWN); failure=$(dirname "$output")/failure-summary.md
    memory=$(context_working_memory_file "$run_id")
    {
        printf '# Compact Context Base\n\n'
        printf -- '- Task: `%s`\n- Run: `%s`\n- State: `%s`\n' "$task_id" "$run_id" "$state"
        printf '\n## Goal\n\n%s\n' "$(conf_get "$spec" GOAL 2>/dev/null || printf '')"
        printf '\n## Acceptance Criteria\n\n'
        while IFS=$'\t' read -r id description extra; do [ -n "$id" ] && printf -- '- `%s`: %s\n' "$id" "$description"; done <"$directory/criteria.tsv"
        printf '\n## Writable Scope\n\n'
        while IFS= read -r id; do [ -n "$id" ] && printf -- '- `%s`\n' "$id"; done <"$directory/scopes.txt"
        if [ -s "$failure" ]; then printf '\n'; cat "$failure"; fi
        printf '\n## Additional Task Details\n\nFull constraints and assumptions are retained in `%s`.\n' "$(basename "$details")"
        if [ -f "$memory" ]; then
            memory_size=$(file_size "$memory") || return 1
            memory_digest=$(sha256_file "$memory") || return 1
            printf '\n## Working Memory Reference\n\n- Path: `%s`\n- Bytes: `%s`\n- SHA-256: `%s`\n' "${memory#$HARNESS_REPO_ROOT/}" "$memory_size" "$memory_digest"
        fi
        printf '\n## Source Bundle Index\n\nSee `index.tsv`; load only the bundle needed for the current step.\n'
    } >"$output"
}


context_bundle_header() {
    local output number run_id task_id
    output=$1; number=$2; run_id=$3; task_id=$4
    {
        printf '# Source Context Bundle %s\n\n' "$number"
        printf -- '- Task: `%s`\n- Run: `%s`\n\n' "$task_id" "$run_id"
    } >"$output"
}

context_generate_digest() {
    local directory digest
    directory=$1
    digest=$(context_calculate_generation_digest "$directory") || return 1
    printf '%s\n' "$digest" >"$directory/context.sha256"
}


context_publish_generation() {
    local run_id temporary root current previous marker
    run_id=$1; temporary=$2
    root=$(context_run_root "$run_id"); current=$(context_current_dir "$run_id"); previous=$(context_previous_dir "$run_id"); marker=$(context_publication_marker "$run_id")
    mkdir -p "$root" || return 1
    context_recover_publication "$run_id" || return 1
    {
        conf_write_pair STATUS PREPARING
        conf_write_pair CURRENT "$current"
        conf_write_pair PREVIOUS "$previous"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$marker" || return 1
    rm -rf "$previous" || return 1
    if [ -d "$current" ]; then mv "$current" "$previous" || return 1; fi
    {
        conf_write_pair STATUS SWITCHING
        conf_write_pair CURRENT "$current"
        conf_write_pair PREVIOUS "$previous"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$marker" || return 1
    if ! mv "$temporary" "$current"; then
        [ ! -d "$previous" ] || mv "$previous" "$current" 2>/dev/null || true
        rm -f "$marker"
        return 1
    fi
    rm -f "$marker"
}


context_record_last_build() {
    local run_id result detail
    run_id=$1; result=$2; detail=$3
    {
        conf_write_pair RESULT "$result"
        conf_write_pair DETAIL "$(printf '%s' "$detail" | tr '\t\r\n' '   ')"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$(context_last_build_file "$run_id")"
}

context_build_for_run() {
    local run_id task_id root selections memory temporary warnings invalid_count reference_count embedded_count bundle_count bundle_number bundle_file bundle_size bundle_max base_max full_base base_compacted result path start end reason extra source section section_size source_bytes digest range_label broad_bytes broad_max memory_max memory_size memory_digest memory_oversized max_bundles max_selections selection_count omitted_count duplicate_count seen key fence estimated_size approval_hash
    run_id=$1; task_id=$2
    root=$(context_run_root "$run_id")
    mkdir -p "$root" || return 1
    context_recover_publication "$run_id" || return 1
    if ! approval_consistency "$task_id" "$run_id"; then
        context_record_last_build "$run_id" RECOVERY "approved task or harness bindings changed; previous context was preserved" >/dev/null 2>&1 || true
        harness_warn "approved task or harness bindings changed; previous context was preserved and the lifecycle remains active"
        return 0
    fi
    approval_hash=$(conf_get "$(task_dir "$task_id")/approval.conf" CONTRACT_HASH) || return 1
    selections=$(context_selections_file "$run_id")
    memory=$(context_working_memory_file "$run_id")
    [ -f "$selections" ] || context_write_default_selections "$task_id" "$selections" || return 1
    context_ensure_working_memory "$memory" || return 1
    temporary=$(mktemp -d "$root/.build.XXXXXX") || return 1
    warnings=$temporary/warnings.tsv; : >"$warnings"
    context_render_failure_summary "$run_id" "$temporary/failure-summary.md" || { rm -rf "$temporary"; return 1; }
    base_max=$(context_policy_number CONTEXT_BASE_MAXIMUM_BYTES) || { rm -rf "$temporary"; return 1; }
    bundle_max=$(context_policy_number CONTEXT_BUNDLE_MAXIMUM_BYTES) || { rm -rf "$temporary"; return 1; }
    max_bundles=$(context_policy_number CONTEXT_MAXIMUM_BUNDLES) || { rm -rf "$temporary"; return 1; }
    max_selections=$(context_policy_number CONTEXT_MAXIMUM_SELECTIONS) || { rm -rf "$temporary"; return 1; }
    memory_max=$(context_policy_number CONTEXT_WORKING_MEMORY_MAXIMUM_BYTES) || { rm -rf "$temporary"; return 1; }
    memory_size=$(file_size "$memory") || { rm -rf "$temporary"; return 1; }
    memory_digest=$(sha256_file "$memory") || { rm -rf "$temporary"; return 1; }
    memory_oversized=0
    if [ "$memory_size" -gt "$memory_max" ]; then
        memory_oversized=1
        context_append_warning "$warnings" WORKING_MEMORY_OVERSIZED "working-memory.md is $memory_size bytes; it was referenced rather than embedded because the maximum is $memory_max."
    fi
    full_base=$temporary/base-full.md
    context_render_full_base "$run_id" "$task_id" "$full_base" || { rm -rf "$temporary"; return 1; }
    base_compacted=0
    if [ "$(file_size "$full_base")" -le "$base_max" ]; then
        mv "$full_base" "$temporary/base.md" || { rm -rf "$temporary"; return 1; }
    else
        mv "$full_base" "$temporary/task-details.md" || { rm -rf "$temporary"; return 1; }
        context_render_compact_base "$run_id" "$task_id" "$temporary/base.md" "$temporary/task-details.md" || { rm -rf "$temporary"; return 1; }
        if [ "$(file_size "$temporary/base.md")" -gt "$base_max" ]; then
            {
                printf '# Compact Context Base\n\n'
                printf -- '- Task: `%s`\n- Run: `%s`\n- State: `%s`\n' "$task_id" "$run_id" "$(state_get "$run_id" STATE 2>/dev/null || printf UNKNOWN)"
                printf -- '- Approved contract SHA-256: `%s`\n' "$approval_hash"
                printf '\n## Authoritative References\n\n- Task contract directory: `%s`\n- Full generated details: `task-details.md`\n- Source selections: `index.tsv`\n' "${HARNESS_TASKS_DIR#$HARNESS_REPO_ROOT/}/$task_id"
                printf '\n## Working Memory Reference\n\n- Path: `%s`\n- Bytes: `%s`\n- SHA-256: `%s`\n' "${memory#$HARNESS_REPO_ROOT/}" "$memory_size" "$memory_digest"
            } >"$temporary/base.md" || { rm -rf "$temporary"; return 1; }
            context_append_warning "$warnings" BASE_REFERENCE_ONLY "Even the compact base exceeded $base_max bytes; authoritative details remain available by reference."
        fi
        if [ "$(file_size "$temporary/base.md")" -gt "$base_max" ]; then
            rm -rf "$temporary"
            context_record_last_build "$run_id" RECOVERY "mandatory base could not fit its configured hard limit" >/dev/null 2>&1 || true
            harness_warn "mandatory context base could not fit its hard limit; previous context was preserved"
            return 0
        fi
        base_compacted=1
        context_append_warning "$warnings" BASE_COMPACTED "Full task details exceeded $base_max bytes and were moved to task-details.md."
    fi
    printf 'bundle\tpath\tstart_line\tend_line\tembedded\tfile_sha256\treason\n' >"$temporary/index.tsv"
    invalid_count=0; reference_count=0; embedded_count=0; bundle_count=0; bundle_number=0; bundle_file=""; bundle_size=0
    selection_count=0; omitted_count=0; duplicate_count=0
    seen=$(mktemp "${TMPDIR:-/tmp}/context-seen.XXXXXX") || { rm -rf "$temporary"; return 1; }
    : >"$seen"
    while IFS=$'\t' read -r path start end reason extra; do
        [ -n "$path$start$end$reason$extra" ] || continue
        if [ -n "$extra" ]; then
            invalid_count=$((invalid_count + 1)); context_append_warning "$warnings" INVALID_SELECTION "selection row has unsupported extra fields."; continue
        fi
        key=$(printf '%s\t%s\t%s' "$path" "$start" "$end")
        if grep -F -x "$key" "$seen" >/dev/null 2>&1; then
            duplicate_count=$((duplicate_count + 1)); context_append_warning "$warnings" DUPLICATE_SELECTION "$path:$start-$end was selected more than once; the first row was retained."; continue
        fi
        printf '%s\n' "$key" >>"$seen"
        selection_count=$((selection_count + 1))
        if [ "$selection_count" -gt "$max_selections" ]; then
            omitted_count=$((omitted_count + 1)); context_append_warning "$warnings" SELECTION_LIMIT "$path:$start-$end was omitted because the maximum selection count is $max_selections."; continue
        fi
        if [ "$(printf '%s' "$reason" | wc -c | tr -d ' ')" -gt 1024 ] || ! context_path_allowed "$task_id" "$path"; then
            invalid_count=$((invalid_count + 1)); context_append_warning "$warnings" INVALID_SELECTION "$path is unavailable, outside approved context, or has an oversized reason."; continue
        fi
        source=$(context_resolve_source "$path") || { invalid_count=$((invalid_count + 1)); context_append_warning "$warnings" INVALID_SELECTION "$path could not be resolved safely."; continue; }
        if ! context_validate_range "$source" "$start" "$end"; then
            invalid_count=$((invalid_count + 1)); context_append_warning "$warnings" INVALID_RANGE "$path:$start-$end is not a valid source range."; continue
        fi
        digest=$(sha256_file "$source") || { rm -f "$seen"; rm -rf "$temporary"; return 1; }
        if [ "$start" -eq 0 ] && [ "$end" -eq 0 ]; then range_label=whole-file; else range_label=$start-$end; fi
        source_bytes=$(context_range_bytes "$source" "$start" "$end") || { rm -f "$seen"; rm -rf "$temporary"; return 1; }
        estimated_size=$((source_bytes + ${#path} + ${#reason} + 512))
        if [ "$estimated_size" -gt "$bundle_max" ]; then
            printf 'REFERENCE\t%s\t%s\t%s\tNO\t%s\t%s\n' "$path" "$start" "$end" "$digest" "$reason" >>"$temporary/index.tsv"
            reference_count=$((reference_count + 1)); context_append_warning "$warnings" OVERSIZED_SELECTION "$path:$range_label is referenced, not embedded, because it exceeds $bundle_max bytes."; continue
        fi
        section=$(mktemp "${TMPDIR:-/tmp}/context-section.XXXXXX") || { rm -f "$seen"; rm -rf "$temporary"; return 1; }
        fence=$(context_fence_for_range "$source" "$start" "$end") || { rm -f "$section" "$seen"; rm -rf "$temporary"; return 1; }
        {
            printf '## `%s` (%s)\n\n' "$path" "$range_label"
            printf 'Reason: %s\n\n%s text\n' "$reason" "$fence"
            context_extract_range "$source" "$start" "$end"
            printf '\n%s\n\n' "$fence"
        } >"$section" || { rm -f "$section" "$seen"; rm -rf "$temporary"; return 1; }
        section_size=$(file_size "$section") || { rm -f "$section" "$seen"; rm -rf "$temporary"; return 1; }
        if [ "$section_size" -gt "$bundle_max" ]; then
            printf 'REFERENCE\t%s\t%s\t%s\tNO\t%s\t%s\n' "$path" "$start" "$end" "$digest" "$reason" >>"$temporary/index.tsv"
            reference_count=$((reference_count + 1)); context_append_warning "$warnings" OVERSIZED_SELECTION "$path:$range_label is referenced, not embedded, because it exceeds $bundle_max bytes."; rm -f "$section"; continue
        fi
        if [ -z "$bundle_file" ] || [ $((bundle_size + section_size)) -gt "$bundle_max" ]; then
            if [ "$bundle_number" -ge "$max_bundles" ]; then
                printf 'LIMIT_REFERENCE\t%s\t%s\t%s\tNO\t%s\t%s\n' "$path" "$start" "$end" "$digest" "$reason" >>"$temporary/index.tsv"
                omitted_count=$((omitted_count + 1)); context_append_warning "$warnings" BUNDLE_LIMIT "$path:$range_label was referenced because the maximum bundle count is $max_bundles."; rm -f "$section"; continue
            fi
            bundle_number=$((bundle_number + 1)); bundle_count=$bundle_number
            bundle_file=$temporary/bundle-$(printf '%03d' "$bundle_number").md
            context_bundle_header "$bundle_file" "$(printf '%03d' "$bundle_number")" "$run_id" "$task_id" || { rm -f "$section" "$seen"; rm -rf "$temporary"; return 1; }
            bundle_size=$(file_size "$bundle_file") || { rm -f "$section" "$seen"; rm -rf "$temporary"; return 1; }
            if [ $((bundle_size + section_size)) -gt "$bundle_max" ]; then
                rm -f "$bundle_file"
                bundle_number=$((bundle_number - 1)); bundle_count=$bundle_number; bundle_file=""; bundle_size=0
                printf 'REFERENCE\t%s\t%s\t%s\tNO\t%s\t%s\n' "$path" "$start" "$end" "$digest" "$reason" >>"$temporary/index.tsv"
                reference_count=$((reference_count + 1)); context_append_warning "$warnings" OVERSIZED_SELECTION "$path:$range_label is referenced, not embedded, because its exact rendered section exceeds $bundle_max bytes."; rm -f "$section"; continue
            fi
        fi
        cat "$section" >>"$bundle_file" || { rm -f "$section" "$seen"; rm -rf "$temporary"; return 1; }
        bundle_size=$((bundle_size + section_size)); embedded_count=$((embedded_count + 1))
        printf 'bundle-%03d.md\t%s\t%s\t%s\tYES\t%s\t%s\n' "$bundle_number" "$path" "$start" "$end" "$digest" "$reason" >>"$temporary/index.tsv"
        rm -f "$section"
    done <"$selections"
    rm -f "$seen"
    broad_bytes=$(conf_get "$(task_dir "$task_id")/approval.conf" CONTEXT_BYTES 2>/dev/null || printf 0)
    case "$broad_bytes" in ''|*[!0-9]*) broad_bytes=0 ;; esac
    broad_max=$(control_get CONTEXT_MAXIMUM_BYTES)
    result=NORMAL
    if [ "$invalid_count" -gt 0 ] || [ "$omitted_count" -gt 0 ]; then result=INCOMPLETE
    elif [ "$reference_count" -gt 0 ] || [ "$bundle_count" -gt 1 ] || [ "$base_compacted" -eq 1 ] || [ "$memory_oversized" -eq 1 ] || [ "$broad_bytes" -gt "$broad_max" ]; then result=CHUNKED
    fi
    {
        conf_write_pair RESULT "$result"
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair RUN_ID "$run_id"
        conf_write_pair CONTRACT_HASH "$approval_hash"
        conf_write_pair BASE_BYTES "$(file_size "$temporary/base.md")"
        conf_write_pair BUNDLE_COUNT "$bundle_count"
        conf_write_pair EMBEDDED_SELECTIONS "$embedded_count"
        conf_write_pair REFERENCED_SELECTIONS "$reference_count"
        conf_write_pair INVALID_SELECTIONS "$invalid_count"
        conf_write_pair OMITTED_SELECTIONS "$omitted_count"
        conf_write_pair DUPLICATE_SELECTIONS "$duplicate_count"
        conf_write_pair WORKING_MEMORY_BYTES "$memory_size"
        conf_write_pair WORKING_MEMORY_MAXIMUM_BYTES "$memory_max"
        conf_write_pair WORKING_MEMORY_EMBEDDED "$([ "$memory_oversized" -eq 0 ] && printf 1 || printf 0)"
        conf_write_pair WORKING_MEMORY_SHA256 "$memory_digest"
        conf_write_pair BROAD_CONTEXT_BYTES "$broad_bytes"
        conf_write_pair WARNING_COUNT "$(wc -l <"$warnings" | tr -d ' ')"
    } | atomic_write "$temporary/status.conf" || { rm -rf "$temporary"; return 1; }
    context_generate_digest "$temporary" || { rm -rf "$temporary"; return 1; }
    context_publish_generation "$run_id" "$temporary" || { rm -rf "$temporary"; return 1; }
    context_record_last_build "$run_id" "$result" "context generation published" || return 1
    if [ "$result" != NORMAL ]; then harness_warn "context generation result is $result; the harness lifecycle remains active"; fi
    return 0
}


context_build_active() {
    local run_id task_id status
    acquire_lock "$HARNESS_GLOBAL_LOCK" context-build || return 2
    trap cleanup_common EXIT INT TERM
    run_id=$(active_run_id) || { release_lock; trap - EXIT INT TERM; return 3; }
    task_id=$(state_get "$run_id" TASK_ID) || { release_lock; trap - EXIT INT TERM; return 3; }
    context_build_for_run "$run_id" "$task_id"
    status=$?
    release_lock; trap - EXIT INT TERM
    return "$status"
}


context_build_best_effort() {
    local run_id task_id
    run_id=$1; task_id=$2
    if ! context_build_for_run "$run_id" "$task_id"; then
        context_record_last_build "$run_id" RECOVERY "context rebuild failed; previous generation was preserved" >/dev/null 2>&1 || true
        harness_warn "context rebuild failed; previous context was preserved and the lifecycle continues"
        return 0
    fi
}

context_current_sources_valid() {
    local run_id current index bundle path start end embedded expected reason source actual status memory expected_memory actual_memory
    run_id=$1
    current=$(context_effective_current_dir "$run_id") || return 1
    index=$current/index.tsv
    status=$current/status.conf
    [ -f "$index" ] && [ -f "$status" ] || return 1
    while IFS=$'\t' read -r bundle path start end embedded expected reason; do
        [ "$bundle" = bundle ] && continue
        [ -n "$path" ] || continue
        source=$(context_resolve_source "$path") || return 1
        actual=$(sha256_file "$source") || return 1
        [ "$actual" = "$expected" ] || return 1
    done <"$index"
    expected_memory=$(conf_get "$status" WORKING_MEMORY_SHA256 2>/dev/null || printf NONE)
    if [ "$expected_memory" != NONE ]; then
        memory=$(context_working_memory_file "$run_id")
        [ -f "$memory" ] || return 1
        actual_memory=$(sha256_file "$memory") || return 1
        [ "$actual_memory" = "$expected_memory" ] || return 1
    fi
}


context_show_active() {
    local run_id task_id current source_stale contract_stale
    run_id=$(active_run_id) || return 3
    task_id=$(state_get "$run_id" TASK_ID) || return 3
    current=$(context_effective_current_dir "$run_id") || return 3
    [ -f "$current/status.conf" ] && [ -f "$current/base.md" ] || return 3
    context_validate_generation_digest "$current" || return 4
    source_stale=0; contract_stale=0
    context_current_sources_valid "$run_id" || source_stale=1
    approval_consistency "$task_id" "$run_id" || contract_stale=1
    [ "$(conf_get "$current/status.conf" CONTRACT_HASH 2>/dev/null || printf '')" = "$(conf_get "$(task_dir "$task_id")/approval.conf" CONTRACT_HASH 2>/dev/null || printf NONE)" ] || contract_stale=1
    printf '# Context Status\n\n```conf\n'
    cat "$current/status.conf"
    if [ "$source_stale" -eq 1 ]; then printf 'SOURCE_STATUS=STALE\n'; else printf 'SOURCE_STATUS=CURRENT\n'; fi
    if [ "$contract_stale" -eq 1 ]; then printf 'CONTRACT_STATUS=STALE\n'; else printf 'CONTRACT_STATUS=CURRENT\n'; fi
    printf 'GENERATION_INTEGRITY=VALID\n'
    printf '```\n\n'
    if [ "$contract_stale" -eq 1 ]; then
        printf '> WARNING: The approved task or harness bindings changed after this context generation. The displayed generation is preserved evidence; rebuild only after the approval is restored or amended.\n\n'
    fi
    if [ "$source_stale" -eq 1 ]; then
        printf '> WARNING: One or more selected source files or working memory changed after this context generation. Run `context build` before using source bundles.\n\n'
    fi
    cat "$current/base.md"
    printf '\n## Available Source Bundles\n\n```tsv\n'
    cat "$current/index.tsv"
    printf '```\n'
    if [ -s "$current/warnings.tsv" ]; then
        printf '\n## Context Warnings\n\n```tsv\n'
        cat "$current/warnings.tsv"
        printf '```\n'
    fi
}

