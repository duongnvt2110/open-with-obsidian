#!/usr/bin/env bash

project_contract_file() { printf '%s/project.conf\n' "$HARNESS_PROJECT_DIR"; }
project_architecture_file() { printf '%s/architecture.tsv\n' "$HARNESS_PROJECT_DIR"; }
project_nfrs_file() { printf '%s/nfrs.tsv\n' "$HARNESS_PROJECT_DIR"; }
project_decisions_file() { printf '%s/decisions.tsv\n' "$HARNESS_PROJECT_DIR"; }
project_interfaces_file() { printf '%s/interfaces.tsv\n' "$HARNESS_PROJECT_DIR"; }
project_history_file() { printf '%s/project-history.tsv\n' "$HARNESS_PROJECT_DIR"; }

project_contract_hash() {
    local payload name file digest
    payload=""
    for name in project.conf architecture.tsv nfrs.tsv decisions.tsv interfaces.tsv; do
        file=$HARNESS_PROJECT_DIR/$name
        [ -f "$file" ] || return 1
        digest=$(sha256_file "$file") || return 1
        payload=$payload$name:$digest';'
    done
    sha256_text "$payload"
}

project_contract_validate() {
    local file key id a b c d e extra
    file=$(project_contract_file)
    [ -f "$file" ] || return 1
    [ "$(conf_get "$file" STATUS 2>/dev/null || printf '')" = "ACTIVE" ] || return 1
    for key in PROJECT_NAME BUSINESS_GOAL SUCCESS_CRITERIA ARCHITECTURE_SUMMARY TECHNOLOGY_CONSTRAINTS DATA_MODEL_SUMMARY API_STRATEGY SECURITY_BOUNDARY RELIABILITY_STRATEGY DEPLOYMENT_TOPOLOGY MIGRATION_STRATEGY OWNER; do
        [ -n "$(trim_space "$(conf_get "$file" "$key" 2>/dev/null || printf '')")" ] || return 1
    done
    [ -s "$(project_architecture_file)" ] && [ -s "$(project_nfrs_file)" ] && [ -s "$(project_decisions_file)" ] && [ -s "$(project_interfaces_file)" ] || return 1
    while IFS=$'\t' read -r id a b c d extra; do
        identifier_validate "$id" && [ -n "$(trim_space "$a")" ] && [ -n "$(trim_space "$b")" ] && [ -n "$(trim_space "$c")" ] && [ -n "$(trim_space "$d")" ] && [ -z "$extra" ] || return 1
    done <"$(project_architecture_file)"
    while IFS=$'\t' read -r id a b c d extra; do
        identifier_validate "$id" && [ -n "$(trim_space "$a")" ] && [ -n "$(trim_space "$b")" ] && [ -n "$(trim_space "$c")" ] && [ -n "$(trim_space "$d")" ] && [ -z "$extra" ] || return 1
    done <"$(project_nfrs_file)"
    while IFS=$'\t' read -r id a b c d extra; do
        identifier_validate "$id" && [ -n "$(trim_space "$a")" ] && [ -n "$(trim_space "$b")" ] && [ -n "$(trim_space "$c")" ] && [ -n "$(trim_space "$d")" ] && [ -z "$extra" ] || return 1
        case "$d" in PROPOSED|ACCEPTED|SUPERSEDED|REJECTED) ;; *) return 1 ;; esac
    done <"$(project_decisions_file)"
    while IFS=$'\t' read -r id a b c d e extra; do
        identifier_validate "$id" && [ -n "$(trim_space "$a")" ] && [ -n "$(trim_space "$b")" ] && [ -n "$(trim_space "$c")" ] && [ -n "$(trim_space "$d")" ] && [ -n "$(trim_space "$e")" ] && [ -z "$extra" ] || return 1
    done <"$(project_interfaces_file)"
    for file in "$(project_architecture_file)" "$(project_nfrs_file)" "$(project_decisions_file)" "$(project_interfaces_file)"; do
        awk -F '\t' 'NF { if (seen[$1]++) exit 1 }' "$file" || return 1
    done
}

project_mutation_allowed() { active_pointer_absent; }

project_define() {
    local name goal success architecture technology data_model api_strategy security reliability deployment migration owner approved_by file previous next
    name=$1; goal=$2; success=$3; architecture=$4; technology=$5; data_model=$6; api_strategy=$7; security=$8; reliability=$9; shift 9
    deployment=$1; migration=$2; owner=$3; approved_by=$4
    acquire_lock "$HARNESS_GLOBAL_LOCK" project-define || return 2
    trap cleanup_common EXIT INT TERM
    project_mutation_allowed || return 3
    for value in "$name" "$goal" "$success" "$architecture" "$technology" "$data_model" "$api_strategy" "$security" "$reliability" "$deployment" "$migration" "$owner" "$approved_by"; do
        [ -n "$(trim_space "$value")" ] || return 3
    done
    file=$(project_contract_file)
    previous=$(project_contract_hash 2>/dev/null || printf NONE)
    {
        conf_write_pair STATUS ACTIVE
        conf_write_pair PROJECT_NAME "$(printf '%s' "$name" | tr '	
' '   ')"
        conf_write_pair BUSINESS_GOAL "$(printf '%s' "$goal" | tr '	
' '   ')"
        conf_write_pair SUCCESS_CRITERIA "$(printf '%s' "$success" | tr '	
' '   ')"
        conf_write_pair ARCHITECTURE_SUMMARY "$(printf '%s' "$architecture" | tr '	
' '   ')"
        conf_write_pair TECHNOLOGY_CONSTRAINTS "$(printf '%s' "$technology" | tr '	
' '   ')"
        conf_write_pair DATA_MODEL_SUMMARY "$(printf '%s' "$data_model" | tr '	
' '   ')"
        conf_write_pair API_STRATEGY "$(printf '%s' "$api_strategy" | tr '	
' '   ')"
        conf_write_pair SECURITY_BOUNDARY "$(printf '%s' "$security" | tr '	
' '   ')"
        conf_write_pair RELIABILITY_STRATEGY "$(printf '%s' "$reliability" | tr '	
' '   ')"
        conf_write_pair DEPLOYMENT_TOPOLOGY "$(printf '%s' "$deployment" | tr '	
' '   ')"
        conf_write_pair MIGRATION_STRATEGY "$(printf '%s' "$migration" | tr '	
' '   ')"
        conf_write_pair OWNER "$(printf '%s' "$owner" | tr '	
' '   ')"
        conf_write_pair UPDATED_BY "$(printf '%s' "$approved_by" | tr '	
' '   ')"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$file" || return 1
    next=$(project_contract_hash) || return 1
    printf '%s	DEFINE	%s	%s	%s	%s
' "$(new_id PROJCHG)" "$previous" "$next" "$(printf '%s' "$approved_by" | tr '	
' '   ')" "$(harness_now)" >>"$(project_history_file)"
    release_lock
    trap - EXIT INT TERM
}

project_add_record() {
    local kind id a b c d e approved_by file columns previous next
    kind=$1; id=$2; a=$3; b=$4; c=$5; d=$6; e=$7; approved_by=$8
    identifier_validate "$id" || return 3
    for value in "$a" "$b" "$c" "$d" "$approved_by"; do [ -n "$(trim_space "$value")" ] || return 3; done
    [ "$kind" != interface ] || [ -n "$(trim_space "$e")" ] || return 3
    [ "$kind" != decision ] || { case "$d" in PROPOSED|ACCEPTED|SUPERSEDED|REJECTED) ;; *) return 3 ;; esac; }
    acquire_lock "$HARNESS_GLOBAL_LOCK" project-record || return 2
    trap cleanup_common EXIT INT TERM
    project_mutation_allowed || return 3
    case "$kind" in
        architecture) file=$(project_architecture_file); columns=4 ;;
        nfr) file=$(project_nfrs_file); columns=4 ;;
        decision) file=$(project_decisions_file); columns=4 ;;
        interface) file=$(project_interfaces_file); columns=5 ;;
        *) return 3 ;;
    esac
    awk -F '\t' -v wanted="$id" '$1 == wanted {found=1} END {exit found ? 0 : 1}' "$file" && return 3
    previous=$(project_contract_hash 2>/dev/null || printf NONE)
    if [ "$columns" -eq 4 ]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$(printf '%s' "$a" | tr '\t\r\n' '   ')" "$(printf '%s' "$b" | tr '\t\r\n' '   ')" "$(printf '%s' "$c" | tr '\t\r\n' '   ')" "$(printf '%s' "$d" | tr '\t\r\n' '   ')" >>"$file"
    else
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(printf '%s' "$a" | tr '\t\r\n' '   ')" "$(printf '%s' "$b" | tr '\t\r\n' '   ')" "$(printf '%s' "$c" | tr '\t\r\n' '   ')" "$(printf '%s' "$d" | tr '\t\r\n' '   ')" "$(printf '%s' "$e" | tr '\t\r\n' '   ')" >>"$file"
    fi
    next=$(project_contract_hash) || return 1
    printf '%s\tADD_%s\t%s\t%s\t%s\t%s\n' "$(new_id PROJCHG)" "$(printf '%s' "$kind" | tr '[:lower:]' '[:upper:]')" "$previous" "$next" "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')" "$(harness_now)" >>"$(project_history_file)"
    release_lock
    trap - EXIT INT TERM
}
