#!/usr/bin/env bash

conventions_list() {
    local first rule_id category level status source module_id path_pattern trigger enforcement check_id example_path rule_text
    if [ "$HARNESS_JSON_MODE" = "1" ]; then
        printf '{"contract_hash":"%s","rules":[' "$(conventions_contract_hash)"
        first=1
        while IFS=$'\t' read -r rule_id category level status source module_id path_pattern trigger enforcement check_id example_path rule_text; do
            [ -n "$rule_id" ] || continue
            [ "$first" -eq 1 ] || printf ','
            printf '{"id":"%s","category":"%s","level":"%s","status":"%s","path":"%s","enforcement":"%s"}' \
                "$(json_escape "$rule_id")" "$(json_escape "$category")" "$(json_escape "$level")" "$(json_escape "$status")" "$(json_escape "$path_pattern")" "$(json_escape "$enforcement")"
            first=0
        done <"$(convention_rules_file)"
        printf ']}\n'
    else
        printf 'Convention contract: %s\n' "$(conventions_contract_hash)"
        if [ ! -s "$(convention_rules_file)" ]; then printf 'No repository conventions defined.\n'; return 0; fi
        printf 'ID\tCATEGORY\tLEVEL\tSTATUS\tPATH\tENFORCEMENT\n'
        awk -F '\t' 'BEGIN{OFS="\t"} {print $1,$2,$3,$4,$7,$9}' "$(convention_rules_file)"
    fi
}

conventions_static_prefix() {
    local pattern
    pattern=$1
    printf '%s' "$pattern" | sed 's/[?*].*$//' | sed 's#/*$##'
}

conventions_patterns_overlap() {
    local first second first_prefix second_prefix
    first=$1; second=$2
    first_prefix=$(conventions_static_prefix "$first")
    second_prefix=$(conventions_static_prefix "$second")
    [ -z "$first_prefix" ] || [ -z "$second_prefix" ] && return 0
    case "$first_prefix/" in "$second_prefix/"*) return 0 ;; esac
    case "$second_prefix/" in "$first_prefix/"*) return 0 ;; esac
    path_matches "$first" "$second" && return 0
    path_matches "$second" "$first" && return 0
    return 1
}

conventions_module_root() {
    local module_id
    module_id=$1
    [ -n "$module_id" ] && [ "$module_id" != "*" ] || { printf '**\n'; return 0; }
    awk -F '\t' -v wanted="$module_id" '$1 == wanted {print $2; exit}' "$(convention_modules_file)"
}

conventions_applicability_line() {
    awk -F '\t' -v wanted="$1" '$1 == wanted {print; exit}' "$(convention_applicability_file)"
}

conventions_csv_contains() {
    local values wanted old_ifs item
    values=$1; wanted=$2
    [ "$values" = "*" ] && return 0
    old_ifs=$IFS; IFS=','
    set -- $values
    IFS=$old_ifs
    for item in "$@"; do [ "$item" = "$wanted" ] && return 0; done
    return 1
}

conventions_module_language() {
    local module_id
    module_id=$1
    [ "$module_id" != "*" ] || { printf '*\n'; return 0; }
    awk -F '\t' -v wanted="$module_id" '$1 == wanted {print $3; exit}' "$(convention_modules_file)"
}

conventions_path_file_type() {
    local path base
    path=$1; base=$(basename "$path")
    case "$base" in
        *.*) printf '%s\n' "${base##*.}" | tr '[:upper:]' '[:lower:]' ;;
        *) printf 'none\n' ;;
    esac
}

conventions_path_language() {
    local type
    type=$(conventions_path_file_type "$1")
    case "$type" in
        go) printf 'go\n' ;; rb) printf 'ruby\n' ;; py) printf 'python\n' ;;
        js|jsx|mjs|cjs) printf 'javascript\n' ;; ts|tsx) printf 'typescript\n' ;;
        java) printf 'java\n' ;; kt|kts) printf 'kotlin\n' ;; rs) printf 'rust\n' ;;
        cs) printf 'csharp\n' ;; php) printf 'php\n' ;; sh|bash) printf 'shell\n' ;;
        sql) printf 'sql\n' ;; yaml|yml) printf 'yaml\n' ;; json) printf 'json\n' ;;
        *) printf '%s\n' "$type" ;;
    esac
}

conventions_rule_dimensions_match() {
    local rule_id task_id path actual line old_ifs languages file_types profiles risks phase order profile risk module_id module_language path_type path_language
    rule_id=$1; task_id=$2; path=$3; actual=${4:-0}
    line=$(conventions_applicability_line "$rule_id"); [ -n "$line" ] || return 1
    old_ifs=$IFS; IFS=$'\t' read -r _ languages file_types profiles risks phase order <<EOF_APP
$line
EOF_APP
    IFS=$old_ifs
    profile=$(conf_get "$(task_dir "$task_id")/plan.conf" PROFILE)
    risk=$(conf_get "$(task_dir "$task_id")/plan.conf" RISK)
    conventions_csv_contains "$profiles" "$profile" || return 1
    conventions_csv_contains "$risks" "$risk" || return 1
    module_id=$(conventions_rule_line "$rule_id" | awk -F '\t' '{print $6}')
    module_language=$(conventions_module_language "$module_id")
    if [ "$languages" != "*" ]; then
        if [ "$module_language" != "*" ] && [ "$module_language" != "-" ]; then
            conventions_csv_contains "$languages" "$module_language" || return 1
        elif [ "$actual" = "1" ]; then
            path_language=$(conventions_path_language "$path")
            conventions_csv_contains "$languages" "$path_language" || return 1
        fi
    fi
    if [ "$file_types" != "*" ] && [ "$actual" = "1" ]; then
        path_type=$(conventions_path_file_type "$path")
        conventions_csv_contains "$file_types" "$path_type" || return 1
    fi
    return 0
}

conventions_rule_matches_scope() {
    local rule_id module_id path_pattern scope task_id module_root
    rule_id=$1; module_id=$2; path_pattern=$3; scope=$4; task_id=$5
    conventions_patterns_overlap "$path_pattern" "$scope" || return 1
    module_root=$(conventions_module_root "$module_id") || return 1
    [ "$module_root" = "**" ] || conventions_patterns_overlap "$module_root" "$scope" || return 1
    conventions_rule_dimensions_match "$rule_id" "$task_id" "$scope" 0
}

conventions_rule_matches_path() {
    local rule_id module_id path_pattern path task_id module_root
    rule_id=$1; module_id=$2; path_pattern=$3; path=$4; task_id=$5
    path_matches "$path" "$path_pattern" || return 1
    module_root=$(conventions_module_root "$module_id") || return 1
    [ "$module_root" = "**" ] || path_matches "$path" "$module_root" || return 1
    conventions_rule_dimensions_match "$rule_id" "$task_id" "$path" 1
}

conventions_exception_active() {
    local expires now
    expires=$1
    [ "$expires" = "NEVER" ] && return 0
    now=$(harness_now)
    [ "$now" \< "$expires" ]
}

conventions_exception_for_scope() {
    local rule_id scope task_id exception_id exception_rule path_pattern exception_task expires approved_by reason status
    rule_id=$1; scope=$2; task_id=$3
    while IFS=$'\t' read -r exception_id exception_rule path_pattern exception_task expires approved_by reason status; do
        [ "$status" = "ACTIVE" ] && [ "$exception_rule" = "$rule_id" ] || continue
        [ "$exception_task" = "*" ] || [ "$exception_task" = "$task_id" ] || continue
        conventions_exception_active "$expires" || continue
        [ "$path_pattern" = "$scope" ] || continue
        printf '%s\n' "$exception_id"; return 0
    done <"$(convention_exceptions_file)"
    return 1
}

conventions_select_for_task() {
    local task_id output exceptions_output scopes temporary exceptions_tmp rule_id category level status source module_id path_pattern trigger enforcement check_id example_path rule_text selected unexcepted scope exception_id app_line old_ifs languages file_types profiles risks phase order
    task_id=$1; output=$2; exceptions_output=${3:-$(task_dir "$task_id")/applicable-exceptions.tsv}
    scopes=$(task_dir "$task_id")/scopes.txt
    temporary=$(mktemp "${TMPDIR:-/tmp}/applicable-conventions.XXXXXX") || return 1
    exceptions_tmp=$(mktemp "${TMPDIR:-/tmp}/applicable-exceptions.XXXXXX") || { rm -f "$temporary"; return 1; }
    : >"$temporary"; : >"$exceptions_tmp"
    while IFS=$'\t' read -r rule_id category level status source module_id path_pattern trigger enforcement check_id example_path rule_text; do
        [ "$status" = "ACTIVE" ] || continue
        selected=0; unexcepted=0
        while IFS= read -r scope; do
            [ -n "$scope" ] || continue
            conventions_rule_matches_scope "$rule_id" "$module_id" "$path_pattern" "$scope" "$task_id" || continue
            selected=1
            exception_id=$(conventions_exception_for_scope "$rule_id" "$scope" "$task_id" 2>/dev/null || printf '')
            if [ -n "$exception_id" ]; then
                printf '%s\t%s\t%s\n' "$exception_id" "$rule_id" "$scope" >>"$exceptions_tmp"
            else
                unexcepted=1
            fi
        done <"$scopes"
        [ "$selected" -eq 1 ] && [ "$unexcepted" -eq 1 ] || continue
        app_line=$(conventions_applicability_line "$rule_id")
        old_ifs=$IFS; IFS=$'\t' read -r _ languages file_types profiles risks phase order <<EOF_APP
$app_line
EOF_APP
        IFS=$old_ifs
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rule_id" "$level" "$enforcement" "$check_id" "$example_path" "$phase" "$order" >>"$temporary"
    done <"$(convention_rules_file)"
    LC_ALL=C sort -t $'\t' -k1,1 "$temporary" | atomic_write "$output" || { rm -f "$temporary" "$exceptions_tmp"; return 1; }
    LC_ALL=C sort -u "$exceptions_tmp" | atomic_write "$exceptions_output"
    status=$?
    rm -f "$temporary" "$exceptions_tmp"
    return "$status"
}

conventions_merge_examples_into_read_context() {
    local task_id directory temporary rule_id level enforcement check_id example_path phase order extra status
    task_id=$1
    directory=$(task_dir "$task_id")
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-read-context.XXXXXX") || return 1
    cat "$directory/read-context.txt" >"$temporary"
    while IFS=$'\t' read -r rule_id level enforcement check_id example_path phase order extra; do
        [ -z "$extra" ] || { rm -f "$temporary"; return 1; }
        [ "$example_path" != "-" ] || continue
        printf '%s\n' "$example_path" >>"$temporary"
    done <"$directory/applicable-conventions.tsv"
    awk 'NF && !seen[$0]++' "$temporary" | atomic_write "$directory/read-context.txt"
    status=$?
    rm -f "$temporary"
    return "$status"
}

conventions_refresh_task_contract() {
    local task_id output exceptions
    task_id=$1
    output=$(task_dir "$task_id")/applicable-conventions.tsv
    exceptions=$(task_dir "$task_id")/applicable-exceptions.tsv
    conventions_select_for_task "$task_id" "$output" "$exceptions" || return 1
    conventions_merge_examples_into_read_context "$task_id" || return 1
}

conventions_validate_task_file() {
    local task_id file seen rule_id level enforcement check_id example_path phase order extra line old_ifs expected_level status expected_enforcement expected_check expected_example app_line expected_phase expected_order
    task_id=$1
    file=$(task_dir "$task_id")/applicable-conventions.tsv
    [ -f "$file" ] && [ -f "$(task_dir "$task_id")/applicable-exceptions.tsv" ] || return 1
    seen=$(mktemp "${TMPDIR:-/tmp}/task-conventions.XXXXXX") || return 1
    : >"$seen"
    while IFS=$'\t' read -r rule_id level enforcement check_id example_path phase order extra; do
        [ -n "$rule_id$level$enforcement$check_id$example_path$phase$order$extra" ] || continue
        [ -z "$extra" ] || { rm -f "$seen"; return 1; }
        grep -Fx "$rule_id" "$seen" >/dev/null 2>&1 && { rm -f "$seen"; return 1; }
        printf '%s\n' "$rule_id" >>"$seen"
        line=$(conventions_rule_line "$rule_id"); [ -n "$line" ] || { rm -f "$seen"; return 1; }
        old_ifs=$IFS; IFS=$'\t' read -r _ _ expected_level status _ _ _ _ expected_enforcement expected_check expected_example _ <<EOF_RULE
$line
EOF_RULE
        IFS=$old_ifs
        app_line=$(conventions_applicability_line "$rule_id")
        expected_phase=$(printf '%s' "$app_line" | awk -F '\t' '{print $6}')
        expected_order=$(printf '%s' "$app_line" | awk -F '\t' '{print $7}')
        [ "$status" = "ACTIVE" ] || { rm -f "$seen"; return 1; }
        [ "$level" = "$expected_level" ] && [ "$enforcement" = "$expected_enforcement" ] && [ "$check_id" = "$expected_check" ] && [ "$example_path" = "$expected_example" ] && [ "$phase" = "$expected_phase" ] && [ "$order" = "$expected_order" ] || { rm -f "$seen"; return 1; }
    done <"$file"
    rm -f "$seen"
}

conventions_write_effective_checks_for_file() {
    local task_id conventions_file output metadata temporary check_id rule_id level enforcement example_path phase order source status
    task_id=$1; conventions_file=$2; output=$3; metadata=$4
    temporary=$(mktemp "${TMPDIR:-/tmp}/effective-checks.XXXXXX") || return 1
    : >"$temporary"
    while IFS= read -r check_id; do
        [ -n "$check_id" ] || continue
        phase=$(command_get "$check_id" PHASE 2>/dev/null || printf '')
        order=$(command_get "$check_id" ORDER 2>/dev/null || printf '')
        phase=${phase:-TEST}; order=${order:-100}
        printf '%s\tMUST\t%s\t%s\tTASK\n' "$check_id" "$phase" "$order" >>"$temporary"
    done <"$(task_dir "$task_id")/checks.txt"
    while IFS=$'\t' read -r rule_id level enforcement check_id example_path phase order; do
        case "$enforcement" in
            AUTOMATED|MIXED)
                [ "$check_id" != "-" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$check_id" "$level" "$phase" "$order" "$rule_id" >>"$temporary"
                ;;
        esac
    done <"$conventions_file"
    awk -F '\t' '
        function lr(v){return v=="MUST"?3:(v=="SHOULD"?2:1)}
        function pr(v){return v=="PREPARE"?1:(v=="STATIC"?2:(v=="BUILD"?3:(v=="TEST"?4:(v=="INTEGRATION"?5:6))))}
        {
            id=$1
            if (!(id in sources)) sources[id]=$5; else if (index("," sources[id] ",", "," $5 ",")==0) sources[id]=sources[id] "," $5
            if (!(id in seen) || lr($2)>lr(level[id]) || (lr($2)==lr(level[id]) && (pr($3)<pr(phase[id]) || (pr($3)==pr(phase[id]) && $4+0<order[id]+0)))) {
                seen[id]=1; level[id]=$2; phase[id]=$3; order[id]=$4+0
            }
        }
        END {
            for (id in seen) printf "%02d\t%04d\t%s\t%s\t%s\t%d\t%s\n",pr(phase[id]),order[id],id,level[id],phase[id],order[id],sources[id]
        }' "$temporary" | LC_ALL=C sort | cut -f3- | atomic_write "$metadata" || { rm -f "$temporary"; return 1; }
    awk -F '\t' '{print $1}' "$metadata" | atomic_write "$output"
    status=$?
    rm -f "$temporary"
    return "$status"
}

conventions_write_effective_checks() {
    local task_id output metadata
    task_id=$1; output=$2; metadata=${3:-${output%.txt}-metadata.tsv}
    conventions_write_effective_checks_for_file "$task_id" "$(task_dir "$task_id")/applicable-conventions.tsv" "$output" "$metadata"
}

conventions_required_manual_rules() {
    local task_id
    task_id=$1
    awk -F '\t' '($3 == "MANUAL" || $3 == "MIXED") && ($2 == "MUST" || $2 == "SHOULD") {print $1"\t"$2}' "$(task_dir "$task_id")/applicable-conventions.tsv"
}

conventions_has_manual_rules() {
    [ -n "$(conventions_required_manual_rules "$1")" ]
}

conventions_has_review_obligations() {
    local task_id
    task_id=$1
    awk -F '\t' '$2 == "SHOULD" || (($3 == "MANUAL" || $3 == "MIXED") && $2 == "MUST") {found=1} END {exit found ? 0 : 1}' "$(task_dir "$task_id")/applicable-conventions.tsv"
}

conventions_change_type() {
    local path baseline current before after
    path=$1; baseline=$2; current=$3
    before=$(awk -F '\t' -v wanted="$path" '$1 == wanted {print; exit}' "$baseline")
    after=$(awk -F '\t' -v wanted="$path" '$1 == wanted {print; exit}' "$current")
    if [ -z "$before" ] && [ -n "$after" ]; then printf 'NEW\n'
    elif [ -n "$before" ] && [ -z "$after" ]; then printf 'DELETED\n'
    elif [ "$before" != "$after" ]; then printf 'MODIFIED\n'
    else printf 'UNCHANGED\n'; fi
}

conventions_trigger_matches() {
    local trigger change_type
    trigger=$1; change_type=$2
    case "$trigger" in
        ANY|CUSTOM_CHECK) [ "$change_type" != "UNCHANGED" ] ;;
        NEW_OR_MODIFIED) [ "$change_type" = "NEW" ] || [ "$change_type" = "MODIFIED" ] ;;
        *) [ "$trigger" = "$change_type" ] ;;
    esac
}

conventions_exception_for_path() {
    local rule_id path task_id exception_id exception_rule path_pattern exception_task expires_at approved_by reason status
    rule_id=$1; path=$2; task_id=$3
    while IFS=$'\t' read -r exception_id exception_rule path_pattern exception_task expires_at approved_by reason status; do
        [ "$status" = "ACTIVE" ] || continue
        [ "$exception_rule" = "$rule_id" ] || continue
        [ "$exception_task" = "*" ] || [ "$exception_task" = "$task_id" ] || continue
        conventions_exception_active "$expires_at" || continue
        path_matches "$path" "$path_pattern" || continue
        printf '%s\n' "$exception_id"
        return 0
    done <"$(convention_exceptions_file)"
    return 1
}

conventions_actual_for_changes() {
    local task_id baseline current changed output exceptions_output temporary exceptions_tmp path change_type rule_id category level status source module_id path_pattern trigger enforcement check_id example_path rule_text exception_id app_line phase order
    task_id=$1; baseline=$2; current=$3; changed=$4; output=$5; exceptions_output=${6:-$(run_dir "$(active_run_id)")/artifacts/actual-exceptions.tsv}
    temporary=$(mktemp "${TMPDIR:-/tmp}/actual-conventions.XXXXXX") || return 1
    exceptions_tmp=$(mktemp "${TMPDIR:-/tmp}/actual-exceptions.XXXXXX") || { rm -f "$temporary"; return 1; }
    : >"$temporary"; : >"$exceptions_tmp"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        change_type=$(conventions_change_type "$path" "$baseline" "$current")
        while IFS=$'\t' read -r rule_id category level status source module_id path_pattern trigger enforcement check_id example_path rule_text; do
            [ "$status" = "ACTIVE" ] || continue
            conventions_rule_matches_path "$rule_id" "$module_id" "$path_pattern" "$path" "$task_id" || continue
            conventions_trigger_matches "$trigger" "$change_type" || continue
            exception_id=$(conventions_exception_for_path "$rule_id" "$path" "$task_id" 2>/dev/null || printf '')
            if [ -n "$exception_id" ]; then
                printf '%s\t%s\t%s\n' "$exception_id" "$rule_id" "$path" >>"$exceptions_tmp"
                continue
            fi
            app_line=$(conventions_applicability_line "$rule_id")
            phase=$(printf '%s' "$app_line" | awk -F '\t' '{print $6}')
            order=$(printf '%s' "$app_line" | awk -F '\t' '{print $7}')
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rule_id" "$level" "$enforcement" "$check_id" "$example_path" "$phase" "$order" >>"$temporary"
        done <"$(convention_rules_file)"
    done <"$changed"
    LC_ALL=C sort -u -t $'\t' -k1,1 "$temporary" | atomic_write "$output" || { rm -f "$temporary" "$exceptions_tmp"; return 1; }
    LC_ALL=C sort -u "$exceptions_tmp" | atomic_write "$exceptions_output"
    status=$?
    rm -f "$temporary" "$exceptions_tmp"
    return "$status"
}

conventions_actual_requires_reapproval() {
    local approved actual rule_id level enforcement check_id example_path phase order
    approved=$1; actual=$2
    while IFS=$'	' read -r rule_id level enforcement check_id example_path phase order; do
        if ! awk -F '	' -v wanted="$rule_id" '$1 == wanted {found=1} END {exit found ? 0 : 1}' "$approved"; then
            case "$level:$enforcement" in
                MUST:*|SHOULD:*|MAY:AUTOMATED|MAY:MIXED) return 0 ;;
            esac
        fi
    done <"$actual"
    return 1
}
