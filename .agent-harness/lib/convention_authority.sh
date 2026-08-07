#!/usr/bin/env bash

conventions_mutation_allowed() {
    active_pointer_absent
}

conventions_add_module() {
    local module_id root_path language framework owner approved_by previous modules backup temporary new
    module_id=$1; root_path=$2; language=$3; framework=$4; owner=$5; approved_by=$6
    [ -n "$(trim_space "$approved_by")" ] || return 3
    acquire_lock "$HARNESS_GLOBAL_LOCK" convention-module-add || return 2
    trap cleanup_common EXIT INT TERM
    conventions_mutation_allowed || return 3
    conventions_validate || return 4
    conventions_module_exists "$module_id" && return 3
    previous=$(conventions_contract_hash) || return 1
    conventions_begin_update MODULE_ADD "$module_id" "$approved_by" "$previous" "module root $root_path" || return 1
    modules=$(convention_modules_file)
    backup=$(mktemp "${TMPDIR:-/tmp}/convention-modules-backup.XXXXXX") || { conventions_clear_update; return 1; }
    cp "$modules" "$backup" || { conventions_clear_update; rm -f "$backup"; return 1; }
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-modules.XXXXXX") || { conventions_clear_update; rm -f "$backup"; return 1; }
    cat "$modules" >"$temporary"
    printf '%s\t%s\t%s\t%s\t%s\n' "$module_id" "$root_path" "${language:--}" "${framework:--}" "$(conventions_sanitize_field "$owner")" >>"$temporary"
    LC_ALL=C sort -t $'	' -k1,1 "$temporary" | atomic_write "$modules" || { cp "$backup" "$modules"; rm -f "$backup" "$temporary"; return 1; }
    rm -f "$temporary"
    if ! conventions_validate_modules; then cp "$backup" "$modules"; conventions_clear_update; rm -f "$backup"; return 4; fi
    new=$(conventions_contract_hash) || { cp "$backup" "$modules"; conventions_clear_update; rm -f "$backup"; return 1; }
    if ! conventions_append_history MODULE_ADD "$module_id" "$approved_by" "$previous" "$new" "module root $root_path"; then cp "$backup" "$modules"; conventions_clear_update; rm -f "$backup"; return 1; fi
    conventions_clear_update
    rm -f "$backup"
    release_lock
    trap - EXIT INT TERM
}

conventions_add_rule_record() {
    local rule_id category level source module_id path_pattern trigger enforcement check_id example_path rule_text approved_by status languages file_types profiles risks phase order origin_id observation_line observation_hash action previous rules applicability origins rules_backup applicability_backup origins_backup temporary app_temporary origins_temporary new stored_check stored_example
    rule_id=$1; category=$2; level=$3; source=$4; module_id=$5; path_pattern=$6; trigger=$7; enforcement=$8; check_id=$9
    shift 9
    example_path=$1; rule_text=$2; approved_by=$3; status=$4; languages=$5; file_types=$6; profiles=$7; risks=$8; phase=$9
    shift 9
    order=$1; origin_id=${2:--}
    [ -n "$(trim_space "$approved_by")" ] || return 3
    if [ "$status" = "CANDIDATE" ]; then
        case "$origin_id" in OBS-[0-9][0-9][0-9]) ;; *) return 3 ;; esac
        observation_line=$(awk -F '\t' -v wanted="$origin_id" '$1 == wanted {print; exit}' "$HARNESS_RUNTIME_DIR/convention-observations.tsv" 2>/dev/null)
        [ -n "$observation_line" ] || return 3
        observation_hash=$(sha256_text "$observation_line") || return 1
    fi
    case "$status:$source" in
        ACTIVE:DECLARED|ACTIVE:EXTERNAL|CANDIDATE:OBSERVED|CANDIDATE:INFERRED) ;;
        *) return 3 ;;
    esac
    acquire_lock "$HARNESS_GLOBAL_LOCK" convention-add || return 2
    trap cleanup_common EXIT INT TERM
    conventions_mutation_allowed || return 3
    conventions_validate || return 4
    conventions_rule_exists "$rule_id" && return 3
    previous=$(conventions_contract_hash) || return 1
    action=ADD; [ "$status" = "CANDIDATE" ] && action=CANDIDATE_ADD
    conventions_begin_update "$action" "$rule_id" "$approved_by" "$previous" "$rule_text" || return 1
    rules=$(convention_rules_file); applicability=$(convention_applicability_file); origins=$(convention_candidate_origins_file)
    rules_backup=$(mktemp "${TMPDIR:-/tmp}/convention-rules-backup.XXXXXX") || { conventions_clear_update; return 1; }
    applicability_backup=$(mktemp "${TMPDIR:-/tmp}/convention-app-backup.XXXXXX") || { conventions_clear_update; rm -f "$rules_backup"; return 1; }
    origins_backup=$(mktemp "${TMPDIR:-/tmp}/convention-origin-backup.XXXXXX") || { conventions_clear_update; rm -f "$rules_backup" "$applicability_backup"; return 1; }
    cp "$rules" "$rules_backup" && cp "$applicability" "$applicability_backup" && cp "$origins" "$origins_backup" || { conventions_clear_update; rm -f "$rules_backup" "$applicability_backup" "$origins_backup"; return 1; }
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-rules.XXXXXX") || return 1
    app_temporary=$(mktemp "${TMPDIR:-/tmp}/convention-app.XXXXXX") || { rm -f "$temporary"; return 1; }
    origins_temporary=$(mktemp "${TMPDIR:-/tmp}/convention-origins.XXXXXX") || { rm -f "$temporary" "$app_temporary"; return 1; }
    cat "$rules" >"$temporary"; cat "$applicability" >"$app_temporary"; cat "$origins" >"$origins_temporary"
    stored_check=${check_id:--}; stored_example=${example_path:--}
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$rule_id" "$category" "$level" "$status" "$source" "${module_id:-*}" "$path_pattern" "$trigger" "$enforcement" "$stored_check" "$stored_example" "$(conventions_sanitize_field "$rule_text")" >>"$temporary"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rule_id" "${languages:-*}" "${file_types:-*}" "${profiles:-*}" "${risks:-*}" "${phase:-TEST}" "${order:-100}" >>"$app_temporary"
    if [ "$status" = "CANDIDATE" ]; then
        printf '%s\t%s\t%s\t%s\n' "$rule_id" "$origin_id" "$observation_hash" "$(conventions_sanitize_field "$approved_by")" >>"$origins_temporary"
    fi
    LC_ALL=C sort -t $'\t' -k1,1 "$temporary" | atomic_write "$rules" || { cp "$rules_backup" "$rules"; rm -f "$temporary" "$app_temporary" "$origins_temporary"; return 1; }
    LC_ALL=C sort -t $'\t' -k1,1 "$app_temporary" | atomic_write "$applicability" || { cp "$rules_backup" "$rules"; cp "$applicability_backup" "$applicability"; rm -f "$temporary" "$app_temporary" "$origins_temporary"; return 1; }
    LC_ALL=C sort -t $'\t' -k1,1 "$origins_temporary" | atomic_write "$origins" || { cp "$rules_backup" "$rules"; cp "$applicability_backup" "$applicability"; cp "$origins_backup" "$origins"; rm -f "$temporary" "$app_temporary" "$origins_temporary"; return 1; }
    rm -f "$temporary" "$app_temporary" "$origins_temporary"
    if ! conventions_validate_rules || ! conventions_validate_applicability || ! conventions_validate_candidate_origins || ! conventions_validate_conflicts; then
        cp "$rules_backup" "$rules"; cp "$applicability_backup" "$applicability"; cp "$origins_backup" "$origins"; conventions_clear_update; rm -f "$rules_backup" "$applicability_backup" "$origins_backup"; return 4
    fi
    new=$(conventions_contract_hash) || { cp "$rules_backup" "$rules"; cp "$applicability_backup" "$applicability"; cp "$origins_backup" "$origins"; conventions_clear_update; rm -f "$rules_backup" "$applicability_backup" "$origins_backup"; return 1; }
    if ! conventions_append_history "$action" "$rule_id" "$approved_by" "$previous" "$new" "$rule_text"; then
        cp "$rules_backup" "$rules"; cp "$applicability_backup" "$applicability"; cp "$origins_backup" "$origins"; conventions_clear_update; rm -f "$rules_backup" "$applicability_backup" "$origins_backup"; return 1
    fi
    conventions_clear_update
    rm -f "$rules_backup" "$applicability_backup" "$origins_backup"
    release_lock
    trap - EXIT INT TERM
}

conventions_add_rule() {
    local rule_id category level source module_id path_pattern trigger enforcement check_id example_path rule_text approved_by languages file_types profiles risks phase order
    rule_id=$1; category=$2; level=$3; source=$4; module_id=$5; path_pattern=$6; trigger=$7; enforcement=$8; check_id=$9
    shift 9
    example_path=$1; rule_text=$2; approved_by=$3; languages=${4:-*}; file_types=${5:-*}; profiles=${6:-*}; risks=${7:-*}; phase=${8:-TEST}; order=${9:-100}
    conventions_add_rule_record "$rule_id" "$category" "$level" "$source" "$module_id" "$path_pattern" "$trigger" "$enforcement" "$check_id" "$example_path" "$rule_text" "$approved_by" ACTIVE "$languages" "$file_types" "$profiles" "$risks" "$phase" "$order" "-"
}

conventions_add_candidate() {
    local rule_id category level source module_id path_pattern trigger enforcement check_id example_path rule_text approved_by languages file_types profiles risks phase order origin_id
    rule_id=$1; category=$2; level=$3; source=$4; module_id=$5; path_pattern=$6; trigger=$7; enforcement=$8; check_id=$9
    shift 9
    example_path=$1; rule_text=$2; approved_by=$3; languages=${4:-*}; file_types=${5:-*}; profiles=${6:-*}; risks=${7:-*}; phase=${8:-TEST}; order=${9:-100}; origin_id=${10:-}
    conventions_add_rule_record "$rule_id" "$category" "$level" "$source" "$module_id" "$path_pattern" "$trigger" "$enforcement" "$check_id" "$example_path" "$rule_text" "$approved_by" CANDIDATE "$languages" "$file_types" "$profiles" "$risks" "$phase" "$order" "$origin_id"
}

conventions_promote_rule() {
    local rule_id approved_by previous rules backup temporary new source status line
    rule_id=$1; approved_by=$2
    acquire_lock "$HARNESS_GLOBAL_LOCK" convention-promote || return 2
    trap cleanup_common EXIT INT TERM
    conventions_mutation_allowed || return 3
    conventions_validate || return 4
    line=$(conventions_rule_line "$rule_id"); [ -n "$line" ] || return 3
    source=$(printf '%s' "$line" | awk -F '\t' '{print $5}')
    status=$(printf '%s' "$line" | awk -F '\t' '{print $4}')
    [ "$status" = "CANDIDATE" ] || return 3
    case "$source" in OBSERVED|INFERRED) ;; *) return 3 ;; esac
    previous=$(conventions_contract_hash) || return 1
    conventions_begin_update PROMOTE "$rule_id" "$approved_by" "$previous" "candidate promoted" || return 1
    rules=$(convention_rules_file); backup=$(mktemp "${TMPDIR:-/tmp}/convention-rules-backup.XXXXXX") || return 1
    cp "$rules" "$backup" || return 1
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-rules.XXXXXX") || return 1
    awk -F '\t' -v OFS='\t' -v wanted="$rule_id" '$1 == wanted {$4="ACTIVE"} {print}' "$rules" >"$temporary"
    cat "$temporary" | atomic_write "$rules" || { cp "$backup" "$rules"; rm -f "$temporary" "$backup"; return 1; }
    rm -f "$temporary"
    new=$(conventions_contract_hash) || { cp "$backup" "$rules"; return 1; }
    conventions_append_history PROMOTE "$rule_id" "$approved_by" "$previous" "$new" "candidate promoted" || { cp "$backup" "$rules"; return 1; }
    conventions_clear_update
    rm -f "$backup"
    conventions_validate || return 4
    release_lock
    trap - EXIT INT TERM
}

conventions_deprecate_rule() {
    local rule_id approved_by reason previous rules backup temporary new
    rule_id=$1; approved_by=$2; reason=$3
    acquire_lock "$HARNESS_GLOBAL_LOCK" convention-deprecate || return 2
    trap cleanup_common EXIT INT TERM
    conventions_mutation_allowed || return 3
    conventions_validate || return 4
    conventions_rule_exists "$rule_id" || return 3
    previous=$(conventions_contract_hash) || return 1
    conventions_begin_update DEPRECATE "$rule_id" "$approved_by" "$previous" "$reason" || return 1
    rules=$(convention_rules_file)
    backup=$(mktemp "${TMPDIR:-/tmp}/convention-rules-backup.XXXXXX") || { conventions_clear_update; return 1; }
    cp "$rules" "$backup" || { conventions_clear_update; rm -f "$backup"; return 1; }
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-rules.XXXXXX") || { conventions_clear_update; rm -f "$backup"; return 1; }
    awk -F '\t' -v OFS='\t' -v wanted="$rule_id" '$1 == wanted {$4="DEPRECATED"} {print}' "$rules" >"$temporary"
    cat "$temporary" | atomic_write "$rules" || { cp "$backup" "$rules"; rm -f "$backup" "$temporary"; return 1; }
    rm -f "$temporary"
    conventions_validate_rules || { cp "$backup" "$rules"; conventions_clear_update; rm -f "$backup"; return 4; }
    new=$(conventions_contract_hash) || { cp "$backup" "$rules"; conventions_clear_update; rm -f "$backup"; return 1; }
    conventions_append_history DEPRECATE "$rule_id" "$approved_by" "$previous" "$new" "$reason" || { cp "$backup" "$rules"; conventions_clear_update; rm -f "$backup"; return 1; }
    conventions_clear_update
    rm -f "$backup"
    release_lock
    trap - EXIT INT TERM
}

conventions_add_exception() {
    local exception_id rule_id path_pattern task_id expires_at reason approved_by previous file backup temporary new
    exception_id=$1; rule_id=$2; path_pattern=$3; task_id=$4; expires_at=$5; reason=$6; approved_by=$7
    acquire_lock "$HARNESS_GLOBAL_LOCK" convention-exception-add || return 2
    trap cleanup_common EXIT INT TERM
    conventions_mutation_allowed || return 3
    conventions_validate || return 4
    conventions_rule_exists "$rule_id" || return 3
    previous=$(conventions_contract_hash) || return 1
    conventions_begin_update EXCEPTION_ADD "$exception_id" "$approved_by" "$previous" "$reason" || return 1
    file=$(convention_exceptions_file); backup=$(mktemp "${TMPDIR:-/tmp}/exception-backup.XXXXXX") || return 1
    cp "$file" "$backup" || return 1
    temporary=$(mktemp "${TMPDIR:-/tmp}/exceptions.XXXXXX") || return 1
    cat "$file" >"$temporary"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tACTIVE\n' "$exception_id" "$rule_id" "$path_pattern" "${task_id:-*}" "${expires_at:-NEVER}" "$(conventions_sanitize_field "$approved_by")" "$(conventions_sanitize_field "$reason")" >>"$temporary"
    LC_ALL=C sort -t $'\t' -k1,1 "$temporary" | atomic_write "$file" || { cp "$backup" "$file"; rm -f "$temporary" "$backup"; return 1; }
    rm -f "$temporary"
    conventions_validate_exceptions || { cp "$backup" "$file"; conventions_clear_update; rm -f "$backup"; return 4; }
    new=$(conventions_contract_hash) || { cp "$backup" "$file"; return 1; }
    conventions_append_history EXCEPTION_ADD "$exception_id" "$approved_by" "$previous" "$new" "$reason" || { cp "$backup" "$file"; return 1; }
    conventions_clear_update
    rm -f "$backup"
    release_lock
    trap - EXIT INT TERM
}

conventions_revoke_exception() {
    local exception_id reason approved_by previous file backup temporary new
    exception_id=$1; reason=$2; approved_by=$3
    acquire_lock "$HARNESS_GLOBAL_LOCK" convention-exception-revoke || return 2
    trap cleanup_common EXIT INT TERM
    conventions_mutation_allowed || return 3
    conventions_validate || return 4
    awk -F '\t' -v wanted="$exception_id" '$1 == wanted && $8 == "ACTIVE" {found=1} END {exit found ? 0 : 1}' "$(convention_exceptions_file)" || return 3
    previous=$(conventions_contract_hash) || return 1
    conventions_begin_update EXCEPTION_REVOKE "$exception_id" "$approved_by" "$previous" "$reason" || return 1
    file=$(convention_exceptions_file); backup=$(mktemp "${TMPDIR:-/tmp}/exception-backup.XXXXXX") || return 1
    cp "$file" "$backup" || return 1
    temporary=$(mktemp "${TMPDIR:-/tmp}/exceptions.XXXXXX") || return 1
    awk -F '\t' -v OFS='\t' -v wanted="$exception_id" '$1 == wanted {$8="REVOKED"} {print}' "$file" >"$temporary"
    cat "$temporary" | atomic_write "$file" || { cp "$backup" "$file"; rm -f "$temporary" "$backup"; return 1; }
    rm -f "$temporary"
    new=$(conventions_contract_hash) || { cp "$backup" "$file"; return 1; }
    conventions_append_history EXCEPTION_REVOKE "$exception_id" "$approved_by" "$previous" "$new" "$reason" || { cp "$backup" "$file"; return 1; }
    conventions_clear_update
    rm -f "$backup"
    release_lock
    trap - EXIT INT TERM
}

conventions_replace_rule() {
    local old_id new_id reason approved_by migration_trigger removal_date previous rules replacements rules_backup replacements_backup temporary repl_tmp new_contract
    old_id=$1; new_id=$2; reason=$3; approved_by=$4; migration_trigger=${5:-NEW_OR_MODIFIED}; removal_date=${6:-UNSCHEDULED}
    acquire_lock "$HARNESS_GLOBAL_LOCK" convention-replace || return 2
    trap cleanup_common EXIT INT TERM
    conventions_mutation_allowed || return 3
    conventions_validate || return 4
    conventions_rule_exists "$old_id" && conventions_rule_exists "$new_id" || return 3
    [ "$(conventions_rule_line "$new_id" | awk -F '\t' '{print $4}')" = "ACTIVE" ] || return 3
    previous=$(conventions_contract_hash) || return 1
    conventions_begin_update REPLACE "$old_id" "$approved_by" "$previous" "$reason" || return 1
    rules=$(convention_rules_file); replacements=$(convention_replacements_file)
    rules_backup=$(mktemp "${TMPDIR:-/tmp}/rules-backup.XXXXXX") || return 1
    replacements_backup=$(mktemp "${TMPDIR:-/tmp}/replacements-backup.XXXXXX") || return 1
    cp "$rules" "$rules_backup"; cp "$replacements" "$replacements_backup"
    temporary=$(mktemp "${TMPDIR:-/tmp}/rules.XXXXXX") || return 1
    repl_tmp=$(mktemp "${TMPDIR:-/tmp}/replacements.XXXXXX") || return 1
    awk -F '\t' -v OFS='\t' -v wanted="$old_id" '$1 == wanted {$4="REPLACED"} {print}' "$rules" >"$temporary"
    cat "$replacements" >"$repl_tmp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$old_id" "$new_id" "$migration_trigger" "$removal_date" "$(conventions_sanitize_field "$approved_by")" "$(conventions_sanitize_field "$reason")" >>"$repl_tmp"
    cat "$temporary" | atomic_write "$rules" || return 1
    LC_ALL=C sort -t $'\t' -k1,1 "$repl_tmp" | atomic_write "$replacements" || return 1
    rm -f "$temporary" "$repl_tmp"
    conventions_validate_rules && conventions_validate_replacements || { cp "$rules_backup" "$rules"; cp "$replacements_backup" "$replacements"; return 4; }
    new_contract=$(conventions_contract_hash) || return 1
    conventions_append_history REPLACE "$old_id" "$approved_by" "$previous" "$new_contract" "$reason" || { cp "$rules_backup" "$rules"; cp "$replacements_backup" "$replacements"; return 1; }
    conventions_clear_update
    rm -f "$rules_backup" "$replacements_backup"
    release_lock
    trap - EXIT INT TERM
}

