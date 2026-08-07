#!/usr/bin/env bash

convention_categories_file() { printf '%s/convention-categories.tsv\n' "$HARNESS_POLICY_DIR"; }
convention_modules_file() { printf '%s/modules.tsv\n' "$HARNESS_PROJECT_DIR"; }
convention_rules_file() { printf '%s/rules.tsv\n' "$HARNESS_CONVENTIONS_DIR"; }
convention_exceptions_file() { printf '%s/exceptions.tsv\n' "$HARNESS_CONVENTIONS_DIR"; }
convention_history_file() { printf '%s/history.tsv\n' "$HARNESS_CONVENTIONS_DIR"; }
convention_applicability_file() { printf '%s/applicability.tsv\n' "$HARNESS_CONVENTIONS_DIR"; }
convention_replacements_file() { printf '%s/replacements.tsv\n' "$HARNESS_CONVENTIONS_DIR"; }
convention_candidate_origins_file() { printf '%s/candidate-origins.tsv\n' "$HARNESS_CONVENTIONS_DIR"; }
convention_update_journal() { printf '%s/convention-update.conf\n' "$HARNESS_RUNTIME_DIR"; }

conventions_sanitize_field() {
    local value
    printf '%s' "$1" | tr '\t\r\n' '   '
}

conventions_category_exists() {
    local category
    category=$1
    awk -F '\t' -v wanted="$category" '$1 == wanted {found=1} END {exit found ? 0 : 1}' "$(convention_categories_file)"
}

conventions_module_exists() {
    local module_id
    module_id=$1
    [ -z "$module_id" ] || [ "$module_id" = "*" ] && return 0
    awk -F '\t' -v wanted="$module_id" '$1 == wanted {found=1} END {exit found ? 0 : 1}' "$(convention_modules_file)"
}

conventions_rule_line() {
    local rule_id
    rule_id=$1
    awk -F '\t' -v wanted="$rule_id" '$1 == wanted {print; exit}' "$(convention_rules_file)"
}

conventions_rule_exists() {
    local rule_id
    [ -n "$(conventions_rule_line "$1")" ]
}

conventions_contract_hash() {
    local temporary file name normalized digest result status
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-contract.XXXXXX") || return 1
    : >"$temporary"
    for file in "$(convention_modules_file)" "$(convention_rules_file)" "$(convention_applicability_file)" "$(convention_exceptions_file)" "$(convention_replacements_file)" "$(convention_candidate_origins_file)"; do
        [ -f "$file" ] || { rm -f "$temporary"; return 1; }
        name=$(basename "$file")
        normalized=$(awk 'NF && $0 !~ /^[[:space:]]*#/' "$file" | LC_ALL=C sort)
        digest=$(sha256_text "$normalized") || { rm -f "$temporary"; return 1; }
        printf '%s:%s\n' "$name" "$digest" >>"$temporary"
    done
    result=$(sha256_file "$temporary")
    status=$?
    rm -f "$temporary"
    [ "$status" -eq 0 ] || return "$status"
    printf '%s\n' "$result"
}

conventions_validate_modules() {
    local file seen module_id root_path language framework owner extra root_prefix
    file=$(convention_modules_file)
    [ -f "$file" ] || return 1
    seen=$(mktemp "${TMPDIR:-/tmp}/convention-modules.XXXXXX") || return 1
    : >"$seen"
    while IFS=$'\t' read -r module_id root_path language framework owner extra; do
        [ -n "$module_id$root_path$language$framework$owner$extra" ] || continue
        [ -z "$extra" ] || { rm -f "$seen"; return 1; }
        identifier_validate "$module_id" || { rm -f "$seen"; return 1; }
        grep -Fx "$module_id" "$seen" >/dev/null 2>&1 && { rm -f "$seen"; return 1; }
        printf '%s\n' "$module_id" >>"$seen"
        [ -n "$root_path" ] || { rm -f "$seen"; return 1; }
        glob_validate "$root_path" || { rm -f "$seen"; return 1; }
        case "${root_path%%/*}" in *'*'*|*'?'*) rm -f "$seen"; return 1 ;; esac
        root_prefix=$(conventions_static_prefix "$root_path")
        if [ -n "$root_prefix" ] && path_is_harness_control "$root_prefix"; then rm -f "$seen"; return 1; fi
        [ -n "$(trim_space "$owner")" ] || { rm -f "$seen"; return 1; }
    done <"$file"
    rm -f "$seen"
}

conventions_validate_rules() {
    local file seen rule_id category level status source module_id path_pattern trigger enforcement check_id example_path rule_text extra path_prefix purpose
    file=$(convention_rules_file)
    [ -f "$file" ] || return 1
    seen=$(mktemp "${TMPDIR:-/tmp}/convention-rules.XXXXXX") || return 1
    : >"$seen"
    while IFS=$'\t' read -r rule_id category level status source module_id path_pattern trigger enforcement check_id example_path rule_text extra; do
        [ -n "$rule_id$category$level$status$source$module_id$path_pattern$trigger$enforcement$check_id$example_path$rule_text$extra" ] || continue
        [ -z "$extra" ] || { rm -f "$seen"; return 1; }
        [ -n "$check_id" ] && [ -n "$example_path" ] || { rm -f "$seen"; return 1; }
        identifier_validate "$rule_id" || { rm -f "$seen"; return 1; }
        grep -Fx "$rule_id" "$seen" >/dev/null 2>&1 && { rm -f "$seen"; return 1; }
        printf '%s\n' "$rule_id" >>"$seen"
        conventions_category_exists "$category" || { rm -f "$seen"; return 1; }
        case "$level" in MUST|SHOULD|MAY) ;; *) rm -f "$seen"; return 1 ;; esac
        case "$status" in CANDIDATE|ACTIVE|DEPRECATED|REPLACED) ;; *) rm -f "$seen"; return 1 ;; esac
        case "$source" in DECLARED|OBSERVED|INFERRED|EXTERNAL) ;; *) rm -f "$seen"; return 1 ;; esac
        if [ "$status" = "ACTIVE" ]; then
            case "$source" in
                DECLARED|EXTERNAL) ;;
                OBSERVED|INFERRED)
                    awk -F '\t' -v wanted="$rule_id" '$3 == "PROMOTE" && $4 == wanted {found=1} END {exit found ? 0 : 1}' "$(convention_history_file)" || { rm -f "$seen"; return 1; }
                    ;;
                *) rm -f "$seen"; return 1 ;;
            esac
        fi
        conventions_module_exists "$module_id" || { rm -f "$seen"; return 1; }
        glob_validate "$path_pattern" || { rm -f "$seen"; return 1; }
        path_prefix=$(conventions_static_prefix "$path_pattern")
        if [ -n "$path_prefix" ] && path_is_harness_control "$path_prefix"; then rm -f "$seen"; return 1; fi
        case "$trigger" in ANY|NEW|MODIFIED|DELETED|NEW_OR_MODIFIED|CUSTOM_CHECK) ;; *) rm -f "$seen"; return 1 ;; esac
        case "$enforcement" in
            AUTOMATED|MIXED)
                [ "$check_id" != "-" ] && command_validate "$check_id" || { rm -f "$seen"; return 1; }
                purpose=$(command_get "$check_id" PURPOSE 2>/dev/null || printf '')
                [ "${purpose:-VERIFICATION}" = "VERIFICATION" ] || { rm -f "$seen"; return 1; }
                ;;
            MANUAL|INFORMATIONAL)
                [ "$check_id" = "-" ] || { rm -f "$seen"; return 1; }
                ;;
            *) rm -f "$seen"; return 1 ;;
        esac
        if [ "$example_path" != "-" ]; then
            safe_relative_path "$example_path" 0 >/dev/null || { rm -f "$seen"; return 1; }
            path_is_harness_control "$example_path" && { rm -f "$seen"; return 1; }
            [ -f "$HARNESS_REPO_ROOT/$example_path" ] || { rm -f "$seen"; return 1; }
        fi
        [ -n "$(trim_space "$rule_text")" ] || { rm -f "$seen"; return 1; }
    done <"$file"
    rm -f "$seen"
}

conventions_csv_valid() {
    local value
    value=$1
    [ -n "$value" ] || return 1
    [ "$value" = "*" ] && return 0
    csv_identifiers_validate "$value"
}

conventions_validate_applicability() {
    local file seen rule_id languages file_types profiles risks phase order extra
    file=$(convention_applicability_file); [ -f "$file" ] || return 1
    seen=$(mktemp "${TMPDIR:-/tmp}/convention-applicability.XXXXXX") || return 1
    : >"$seen"
    while IFS=$'\t' read -r rule_id languages file_types profiles risks phase order extra; do
        [ -n "$rule_id$languages$file_types$profiles$risks$phase$order$extra" ] || continue
        [ -z "$extra" ] || { rm -f "$seen"; return 1; }
        conventions_rule_exists "$rule_id" || { rm -f "$seen"; return 1; }
        grep -Fx "$rule_id" "$seen" >/dev/null 2>&1 && { rm -f "$seen"; return 1; }
        printf '%s\n' "$rule_id" >>"$seen"
        conventions_csv_valid "$languages" && conventions_csv_valid "$file_types" && conventions_csv_valid "$profiles" && conventions_csv_valid "$risks" || { rm -f "$seen"; return 1; }
        case "$phase" in PREPARE|STATIC|BUILD|TEST|INTEGRATION|MIGRATION) ;; *) rm -f "$seen"; return 1 ;; esac
        case "$order" in ''|*[!0-9]*) rm -f "$seen"; return 1 ;; esac
        [ "$order" -ge 0 ] && [ "$order" -le 9999 ] || { rm -f "$seen"; return 1; }
    done <"$file"
    while IFS=$'\t' read -r rule_id _; do
        [ -n "$rule_id" ] || continue
        grep -Fx "$rule_id" "$seen" >/dev/null 2>&1 || { rm -f "$seen"; return 1; }
    done <"$(convention_rules_file)"
    rm -f "$seen"
}

conventions_validate_replacements() {
    local old new trigger removal_date approved_by reason extra
    [ -f "$(convention_replacements_file)" ] || return 1
    while IFS=$'\t' read -r old new trigger removal_date approved_by reason extra; do
        [ -n "$old$new$trigger$removal_date$approved_by$reason$extra" ] || continue
        [ -z "$extra" ] || return 1
        conventions_rule_exists "$old" && conventions_rule_exists "$new" || return 1
        [ "$old" != "$new" ] || return 1
        case "$trigger" in NEW|MODIFIED|NEW_OR_MODIFIED|CUSTOM_CHECK) ;; *) return 1 ;; esac
        [ "$removal_date" = "UNSCHEDULED" ] || case "$removal_date" in ????-??-??) ;; *) return 1 ;; esac
        [ -n "$(trim_space "$approved_by")" ] && [ -n "$(trim_space "$reason")" ] || return 1
    done <"$(convention_replacements_file)"
}

conventions_triggers_overlap() {
    local a b
    a=$1; b=$2
    [ "$a" = ANY ] || [ "$b" = ANY ] || [ "$a" = "$b" ] && return 0
    case "$a:$b" in
        NEW_OR_MODIFIED:NEW|NEW_OR_MODIFIED:MODIFIED|NEW:NEW_OR_MODIFIED|MODIFIED:NEW_OR_MODIFIED) return 0 ;;
    esac
    return 1
}

conventions_modules_overlap() {
    local a b a_root b_root
    a=$1; b=$2
    [ "$a" = "*" ] || [ "$b" = "*" ] || [ "$a" = "$b" ] && return 0
    a_root=$(conventions_module_root "$a" 2>/dev/null || printf '')
    b_root=$(conventions_module_root "$b" 2>/dev/null || printf '')
    [ -n "$a_root$b_root" ] || return 1
    conventions_patterns_overlap "$a_root" "$b_root"
}

conventions_rule_specificity() {
    local module_id path_pattern prefix module_score
    module_id=$1; path_pattern=$2
    [ "$module_id" = "*" ] && module_score=0 || module_score=1
    prefix=$(conventions_static_prefix "$path_pattern")
    printf '%s:%04d\n' "$module_score" "${#prefix}"
}

conventions_detect_conflicts() {
    local output first second old_ifs a_id a_cat a_level a_status a_source a_module a_path a_trigger a_enforcement a_check a_example a_text b_id b_cat b_level b_status b_source b_module b_path b_trigger b_enforcement b_check b_example b_text a_spec b_spec
    output=$1
    : >"$output"
    while IFS= read -r first; do
        [ -n "$first" ] || continue
        old_ifs=$IFS; IFS=$'\t' read -r a_id a_cat a_level a_status a_source a_module a_path a_trigger a_enforcement a_check a_example a_text <<EOF_A
$first
EOF_A
        IFS=$old_ifs
        [ "$a_status" = ACTIVE ] && [ "$a_level" = MUST ] || continue
        while IFS= read -r second; do
            [ -n "$second" ] || continue
            old_ifs=$IFS; IFS=$'\t' read -r b_id b_cat b_level b_status b_source b_module b_path b_trigger b_enforcement b_check b_example b_text <<EOF_B
$second
EOF_B
            IFS=$old_ifs
            [ "$b_id" \> "$a_id" ] || continue
            [ "$b_status" = ACTIVE ] && [ "$b_level" = MUST ] || continue
            [ "$a_cat" = "$b_cat" ] || continue
            conventions_modules_overlap "$a_module" "$b_module" || continue
            conventions_patterns_overlap "$a_path" "$b_path" || continue
            conventions_triggers_overlap "$a_trigger" "$b_trigger" || continue
            [ "$a_text" != "$b_text" ] || continue
            a_spec=$(conventions_rule_specificity "$a_module" "$a_path")
            b_spec=$(conventions_rule_specificity "$b_module" "$b_path")
            [ "$a_spec" = "$b_spec" ] || continue
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$a_id" "$b_id" "$a_cat" "$a_module" "$a_path" "$b_module" "$b_path" >>"$output"
        done <"$(convention_rules_file)"
    done <"$(convention_rules_file)"
}

conventions_validate_conflicts() {
    local temporary
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-conflicts.XXXXXX") || return 1
    conventions_detect_conflicts "$temporary" || { rm -f "$temporary"; return 1; }
    if [ -s "$temporary" ]; then
        cat "$temporary" | atomic_write "$HARNESS_RUNTIME_DIR/convention-conflicts.tsv" >/dev/null 2>&1 || true
        rm -f "$temporary"
        return 1
    fi
    : | atomic_write "$HARNESS_RUNTIME_DIR/convention-conflicts.tsv" >/dev/null 2>&1 || true
    rm -f "$temporary"
}

conventions_validate_candidate_origins() {
    local rule_id observation_id evidence_hash approved_by extra rule_line status source observation_line
    [ -f "$(convention_candidate_origins_file)" ] || return 1
    while IFS=$'\t' read -r rule_id observation_id evidence_hash approved_by extra; do
        [ -n "$rule_id$observation_id$evidence_hash$approved_by$extra" ] || continue
        [ -z "$extra" ] || return 1
        rule_line=$(conventions_rule_line "$rule_id"); [ -n "$rule_line" ] || return 1
        status=$(printf '%s' "$rule_line" | awk -F '\t' '{print $4}')
        source=$(printf '%s' "$rule_line" | awk -F '\t' '{print $5}')
        case "$source" in OBSERVED|INFERRED) ;; *) return 1 ;; esac
        case "$observation_id" in OBS-[0-9][0-9][0-9]) ;; *) return 1 ;; esac
        case "$evidence_hash" in [0-9a-f][0-9a-f]*) [ "${#evidence_hash}" -eq 64 ] || return 1 ;; *) return 1 ;; esac
        [ -n "$(trim_space "$approved_by")" ] || return 1
    done <"$(convention_candidate_origins_file)"
    while IFS=$'\t' read -r rule_id _ _ status source _; do
        [ -n "$rule_id" ] || continue
        case "$source" in OBSERVED|INFERRED)
            awk -F '\t' -v wanted="$rule_id" '$1 == wanted {found=1} END {exit found ? 0 : 1}' "$(convention_candidate_origins_file)" || return 1
            ;;
        esac
    done <"$(convention_rules_file)"
}

conventions_validate_exceptions() {
    local file seen exception_id rule_id path_pattern task_id expires_at approved_by reason status extra rule_line rule_category rule_level
    file=$(convention_exceptions_file)
    [ -f "$file" ] || return 1
    seen=$(mktemp "${TMPDIR:-/tmp}/convention-exceptions.XXXXXX") || return 1
    : >"$seen"
    while IFS=$'\t' read -r exception_id rule_id path_pattern task_id expires_at approved_by reason status extra; do
        [ -n "$exception_id$rule_id$path_pattern$task_id$expires_at$approved_by$reason$status$extra" ] || continue
        [ -z "$extra" ] || { rm -f "$seen"; return 1; }
        identifier_validate "$exception_id" || { rm -f "$seen"; return 1; }
        grep -Fx "$exception_id" "$seen" >/dev/null 2>&1 && { rm -f "$seen"; return 1; }
        printf '%s\n' "$exception_id" >>"$seen"
        conventions_rule_exists "$rule_id" || { rm -f "$seen"; return 1; }
        glob_validate "$path_pattern" || { rm -f "$seen"; return 1; }
        [ "$path_pattern" != "**" ] || { rm -f "$seen"; return 1; }
        case "$task_id" in '') rm -f "$seen"; return 1 ;; esac
        [ "$task_id" = "*" ] || [ -d "$(task_dir "$task_id")" ] || { rm -f "$seen"; return 1; }
        [ -n "$(trim_space "$approved_by")" ] && [ -n "$(trim_space "$reason")" ] || { rm -f "$seen"; return 1; }
        case "$status" in ACTIVE|EXPIRED|REVOKED) ;; *) rm -f "$seen"; return 1 ;; esac
        if [ "$expires_at" != "NEVER" ]; then
            case "$expires_at" in ????-??-??T??:??:??Z) ;; *) rm -f "$seen"; return 1 ;; esac
        fi
        rule_line=$(conventions_rule_line "$rule_id")
        rule_category=$(printf '%s' "$rule_line" | awk -F '\t' '{print $2}')
        rule_level=$(printf '%s' "$rule_line" | awk -F '\t' '{print $3}')
        if [ "$rule_level" = "MUST" ]; then
            case "$rule_category" in security|compliance|secrets|authorization|authentication) rm -f "$seen"; return 1 ;; esac
        fi
    done <"$file"
    rm -f "$seen"
}

conventions_validate_history() {
    local file expected_seq previous_event last_contract seq timestamp action object_id actor previous_contract new_contract reason recorded_previous event_hash extra payload
    file=$(convention_history_file)
    [ -s "$file" ] || return 1
    expected_seq=1
    previous_event="GENESIS"
    last_contract=""
    while IFS=$'\t' read -r seq timestamp action object_id actor previous_contract new_contract reason recorded_previous event_hash extra; do
        [ -z "$extra" ] || return 1
        [ "$seq" = "$expected_seq" ] || return 1
        [ "$recorded_previous" = "$previous_event" ] || return 1
        payload=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$seq" "$timestamp" "$action" "$object_id" "$actor" "$previous_contract" "$new_contract" "$reason" "$recorded_previous")
        [ "$(sha256_text "$payload")" = "$event_hash" ] || return 1
        previous_event=$event_hash
        last_contract=$new_contract
        expected_seq=$((expected_seq + 1))
    done <"$file"
    [ "$last_contract" = "$(conventions_contract_hash)" ]
}

conventions_validate() {
    [ -s "$(convention_categories_file)" ] || return 1
    conventions_validate_modules || return 1
    conventions_validate_rules || return 1
    conventions_validate_applicability || return 1
    conventions_validate_exceptions || return 1
    conventions_validate_replacements || return 1
    conventions_validate_candidate_origins || return 1
    conventions_validate_history || return 1
    conventions_validate_conflicts || return 1
}

conventions_append_history() {
    local action object_id actor previous_contract new_contract reason file seq previous_event last old_ifs old_seq old_hash timestamp payload event_hash temporary status
    action=$1
    object_id=$2
    actor=$3
    previous_contract=$4
    new_contract=$5
    reason=$(conventions_sanitize_field "$6")
    file=$(convention_history_file)
    seq=1
    previous_event=GENESIS
    if [ -s "$file" ]; then
        last=$(tail -n 1 "$file")
        old_ifs=$IFS; IFS=$'\t' read -r old_seq _ _ _ _ _ _ _ _ old_hash <<EOF_LAST
$last
EOF_LAST
        IFS=$old_ifs
        seq=$((old_seq + 1))
        previous_event=$old_hash
    fi
    timestamp=$(harness_now)
    payload=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$seq" "$timestamp" "$action" "$object_id" "$(conventions_sanitize_field "$actor")" "$previous_contract" "$new_contract" "$reason" "$previous_event")
    event_hash=$(sha256_text "$payload") || return 1
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-history.XXXXXX") || return 1
    cat "$file" >"$temporary" 2>/dev/null || :
    printf '%s\t%s\n' "$payload" "$event_hash" >>"$temporary"
    cat "$temporary" | atomic_write "$file"
    status=$?
    rm -f "$temporary"
    return "$status"
}

conventions_ensure_history() {
    local file current
    file=$(convention_history_file)
    [ -s "$file" ] && return 0
    current=$(conventions_contract_hash) || return 1
    conventions_append_history BOOTSTRAP conventions system NONE "$current" "initial convention contract"
}

conventions_last_history_contract() {
    local file
    file=$(convention_history_file)
    [ -s "$file" ] || return 1
    tail -n 1 "$file" | awk -F '	' '{print $7}'
}

conventions_begin_update() {
    local action object_id actor previous_contract reason journal
    action=$1; object_id=$2; actor=$3; previous_contract=$4; reason=$5
    journal=$(convention_update_journal)
    {
        conf_write_pair STATUS PREPARED
        conf_write_pair ACTION "$action"
        conf_write_pair OBJECT_ID "$object_id"
        conf_write_pair ACTOR "$(conventions_sanitize_field "$actor")"
        conf_write_pair PREVIOUS_CONTRACT_HASH "$previous_contract"
        conf_write_pair REASON "$(conventions_sanitize_field "$reason")"
        conf_write_pair STARTED_AT "$(harness_now)"
    } | atomic_write "$journal"
}

conventions_clear_update() {
    rm -f "$(convention_update_journal)"
}

conventions_recover_update() {
    local journal status action object_id actor previous_contract reason current_contract history_contract
    journal=$(convention_update_journal)
    [ -f "$journal" ] || return 0
    status=$(conf_get "$journal" STATUS 2>/dev/null || printf '')
    [ "$status" = "PREPARED" ] || return 1
    action=$(conf_get "$journal" ACTION 2>/dev/null || printf '')
    object_id=$(conf_get "$journal" OBJECT_ID 2>/dev/null || printf '')
    actor=$(conf_get "$journal" ACTOR 2>/dev/null || printf '')
    previous_contract=$(conf_get "$journal" PREVIOUS_CONTRACT_HASH 2>/dev/null || printf '')
    reason=$(conf_get "$journal" REASON 2>/dev/null || printf '')
    [ -n "$action" ] && [ -n "$object_id" ] && [ -n "$previous_contract" ] || return 1
    current_contract=$(conventions_contract_hash) || return 1
    history_contract=$(conventions_last_history_contract) || return 1
    if [ "$history_contract" = "$current_contract" ]; then
        conventions_clear_update
        return 0
    fi
    [ "$history_contract" = "$previous_contract" ] || return 1
    if [ "$current_contract" = "$previous_contract" ]; then
        conventions_clear_update
        return 0
    fi
    conventions_validate_modules || return 1
    conventions_validate_rules || return 1
    conventions_validate_applicability || return 1
    conventions_validate_exceptions || return 1
    conventions_validate_replacements || return 1
    conventions_validate_candidate_origins || return 1
    conventions_validate_conflicts || return 1
    conventions_append_history "$action" "$object_id" "recovery:$actor" "$previous_contract" "$current_contract" "$reason" || return 1
    conventions_clear_update
}

