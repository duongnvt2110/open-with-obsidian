#!/usr/bin/env bash

workflow_file() { printf '%s/workflow.conf\n' "$HARNESS_POLICY_DIR"; }
controls_file() { printf '%s/controls.conf\n' "$HARNESS_POLICY_DIR"; }

workflow_targets() {
    local state
    state=$1
    conf_get "$(workflow_file)" "TRANSITION_$state"
}

workflow_owner() {
    local state
    state=$1
    conf_get "$(workflow_file)" "OWNER_$state"
}

workflow_initial_state() {
    conf_get "$(workflow_file)" INITIAL_STATE
}

workflow_is_terminal() {
    local state terminals old_ifs item
    state=$1
    terminals=$(conf_get "$(workflow_file)" TERMINAL_STATES)
    old_ifs=$IFS
    IFS=','
    set -- $terminals
    IFS=$old_ifs
    for item in "$@"; do [ "$item" = "$state" ] && return 0; done
    return 1
}

workflow_transition_allowed() {
    local from to targets old_ifs target
    from=$1
    to=$2
    targets=$(workflow_targets "$from" 2>/dev/null || printf '')
    old_ifs=$IFS
    IFS=','
    set -- $targets
    IFS=$old_ifs
    for target in "$@"; do [ "$target" = "$to" ] && return 0; done
    return 1
}

control_get() {
    conf_get "$(controls_file)" "$1"
}

policy_list_values() {
    local file prefix
    file=$1
    prefix=$2
    awk -v prefix="$prefix" '
        index($0, "=") > 0 {
            key = substr($0, 1, index($0, "=") - 1)
            if (index(key, prefix) == 1) print substr($0, index($0, "=") + 1)
        }' "$file"
}

command_file() {
    identifier_validate "$1" || return 1
    printf '%s/%s.conf\n' "$HARNESS_COMMAND_DIR" "$1"
}

command_exists() {
    [ -f "$(command_file "$1")" ]
}

command_get() {
    local id key
    id=$1
    key=$2
    conf_get "$(command_file "$id")" "$key"
}

command_args() {
    local id file
    id=$1
    file=$(command_file "$id")
    awk -F '=' '
        /^ARG_[0-9]+=/ {
            number = substr($1, 5) + 0
            values[number] = substr($0, index($0, "=") + 1)
            if (number > maximum) maximum = number
        }
        END { for (i = 1; i <= maximum; i++) if (i in values) print values[i] }' "$file"
}

command_trusted_inputs() {
    local id file
    id=$1
    file=$(command_file "$id")
    awk -F '=' '
        /^TRUSTED_INPUT_[0-9]+=/ {
            number = substr($1, 15) + 0
            values[number] = substr($0, index($0, "=") + 1)
            if (number > maximum) maximum = number
        }
        END { for (i = 1; i <= maximum; i++) if (i in values) print values[i] }' "$file"
}

command_environment_keys() {
    local id file
    id=$1
    file=$(command_file "$id")
    awk -F '=' '
        /^ENV_ALLOW_[0-9]+=/ {
            number = substr($1, 11) + 0
            values[number] = substr($0, index($0, "=") + 1)
            if (number > maximum) maximum = number
        }
        END { for (i = 1; i <= maximum; i++) if (i in values) print values[i] }' "$file"
}

command_resolve_executable() {
    local id executable safe candidate old_ifs directory
    id=$1
    executable=$(command_get "$id" EXECUTABLE)
    case "$executable" in
        */*)
            safe=$(safe_relative_path "$executable" 0) || return 1
            candidate=$HARNESS_REPO_ROOT/$safe
            [ -f "$candidate" ] && [ -x "$candidate" ] || return 1
            absolute_path "$candidate"
            ;;
        *)
            old_ifs=$IFS; IFS=:
            for directory in $PATH; do
                [ -n "$directory" ] || directory=.
                candidate=$directory/$executable
                if [ -f "$candidate" ] && [ -x "$candidate" ]; then
                    IFS=$old_ifs
                    absolute_path "$candidate"
                    return
                fi
            done
            IFS=$old_ifs
            return 1
            ;;
    esac
}

command_is_raw_shell() {
    local executable base
    executable=$1
    base=$(basename "$executable" | tr '[:upper:]' '[:lower:]')
    case "$base" in sh|bash|zsh|dash|fish|cmd|cmd.exe|powershell|powershell.exe|pwsh|pwsh.exe|env|busybox) return 0 ;; esac
    return 1
}

command_validate() {
    local id file recorded_id executable cwd timeout evidence phase order purpose environment_key pattern base first_arg trusted output tool git_mode toolchain_mode output_schema output_disposition
    id=$1
    identifier_validate "$id" || return 1
    file=$(command_file "$id")
    [ -f "$file" ] || return 1
    conf_validate_schema "$file"         "ID EXECUTABLE CWD TIMEOUT_SECONDS EVIDENCE_TYPE PHASE ORDER PURPOSE GIT_MODE TOOLCHAIN_MODE OUTPUT_SCHEMA OUTPUT_DISPOSITION"         "ARG_ TRUSTED_INPUT_ ENV_ALLOW_ TOOL_ OUTPUT_" || return 1
    recorded_id=$(conf_get "$file" ID 2>/dev/null || printf '')
    [ "$recorded_id" = "$id" ] || return 1
    executable=$(conf_get "$file" EXECUTABLE 2>/dev/null || printf '')
    [ -n "$executable" ] || return 1
    command_is_raw_shell "$executable" && return 1
    cwd=$(conf_get "$file" CWD 2>/dev/null || printf '')
    cwd=${cwd:-.}
    [ "$cwd" = "." ] || safe_relative_path "$cwd" 0 >/dev/null || return 1
    timeout=$(conf_get "$file" TIMEOUT_SECONDS 2>/dev/null || printf '')
    [ -n "$timeout" ] || timeout=$(control_get DEFAULT_TIMEOUT_SECONDS)
    case "$timeout" in ''|*[!0-9]*) return 1 ;; esac
    [ "$timeout" -gt 0 ] || return 1
    evidence=$(conf_get "$file" EVIDENCE_TYPE 2>/dev/null || printf '')
    case "$evidence" in automated_test|integration_test|static_check|benchmark|migration_dry_run|manual_review) ;; *) return 1 ;; esac
    phase=$(conf_get "$file" PHASE 2>/dev/null || printf '')
    phase=${phase:-TEST}
    case "$phase" in PREPARE|STATIC|BUILD|TEST|INTEGRATION|MIGRATION) ;; *) return 1 ;; esac
    order=$(conf_get "$file" ORDER 2>/dev/null || printf '')
    order=${order:-100}
    case "$order" in ''|*[!0-9]*) return 1 ;; esac
    [ "$order" -le 9999 ] || return 1
    purpose=$(conf_get "$file" PURPOSE 2>/dev/null || printf '')
    purpose=${purpose:-VERIFICATION}
    case "$purpose" in VERIFICATION|INSPECTION) ;; *) return 1 ;; esac
    while IFS= read -r environment_key; do
        [ -n "$environment_key" ] || continue
        case "$environment_key" in *[!A-Z0-9_]*|'') return 1 ;; esac
    done <<EOF_ENV_KEYS
$(command_environment_keys "$id")
EOF_ENV_KEYS
    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        glob_validate "$pattern" || return 1
    done <<EOF_TRUST
$(command_trusted_inputs "$id")
EOF_TRUST
    # Repository-local interpreter scripts must be bound as trusted inputs.
    base=$(basename "$executable" | tr '[:upper:]' '[:lower:]')
    case "$base" in python|python2|python3|ruby|node|perl)
        first_arg=$(command_args "$id" | sed -n '1p')
        if [ -n "$first_arg" ] && [ "${first_arg#-}" = "$first_arg" ] && safe_relative_path "$first_arg" 0 >/dev/null 2>&1; then
            trusted=0
            while IFS= read -r pattern; do
                [ -n "$pattern" ] || continue
                if path_matches "$first_arg" "$pattern"; then trusted=1; break; fi
            done <<EOF_INPUTS
$(command_trusted_inputs "$id")
EOF_INPUTS
            [ "$trusted" -eq 1 ] || return 1
        fi
        ;;
    esac
    git_mode=$(conf_get "$file" GIT_MODE 2>/dev/null || printf '')
    git_mode=${git_mode:-NONE}
    case "$git_mode" in NONE) ;; READ_ONLY_SNAPSHOT) command -v git >/dev/null 2>&1 || return 1 ;; *) return 1 ;; esac
    toolchain_mode=$(conf_get "$file" TOOLCHAIN_MODE 2>/dev/null || printf '')
    toolchain_mode=${toolchain_mode:-STRICT}
    case "$toolchain_mode" in STRICT|LEGACY) ;; *) return 1 ;; esac
    while IFS= read -r tool; do
        [ -n "$tool" ] || continue
        case "$tool" in *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
        resolve_path_executable "$tool" >/dev/null 2>&1 || return 1
    done <<EOF_TOOLS
$(command_tools "$id")
EOF_TOOLS
    output=0
    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        output=1
        glob_validate "$pattern" || return 1
        path_is_harness_control "${pattern%%[*?]*}" && return 1
    done <<EOF_OUTPUTS
$(command_outputs "$id")
EOF_OUTPUTS
    [ "$output" -eq 0 ] || [ "$phase" = "PREPARE" ] || return 1
    output_disposition=$(conf_get "$file" OUTPUT_DISPOSITION 2>/dev/null || printf '')
    output_disposition=${output_disposition:-EPHEMERAL}
    case "$output_disposition" in EPHEMERAL|REQUIRED_IN_REPOSITORY) ;; *) return 1 ;; esac
    [ "$output" -ne 0 ] || [ "$output_disposition" = "EPHEMERAL" ] || return 1
    if [ "$purpose" = "INSPECTION" ]; then
        output_schema=$(conf_get "$file" OUTPUT_SCHEMA 2>/dev/null || printf '')
        [ "$output_schema" = "observations-v1" ] || return 1
        [ "$output" -eq 0 ] || return 1
    fi
    return 0
}

policy_validate() {
    local workflow controls file id numeric
    workflow=$(workflow_file)
    controls=$(controls_file)
    [ -f "$workflow" ] && [ -f "$controls" ] || return 1
    conf_validate_schema "$controls"         "ENFORCEMENT_MODE DEFAULT_TIMEOUT_SECONDS MAXIMUM_COMMAND_OUTPUT_BYTES PUBLIC_RESULT_MAXIMUM_BYTES WORKFLOW_PACKET_MAXIMUM_BYTES DEFAULT_ATTEMPT_BUDGET SAME_FAILURE_RETHINK_THRESHOLD CONTEXT_WARNING_BYTES CONTEXT_MAXIMUM_BYTES CONTEXT_BASE_MAXIMUM_BYTES CONTEXT_BUNDLE_MAXIMUM_BYTES CONTEXT_MAXIMUM_BUNDLES CONTEXT_MAXIMUM_SELECTIONS CONTEXT_WORKING_MEMORY_MAXIMUM_BYTES CONTEXT_CHECK_SUMMARY_MAXIMUM_BYTES REQUIRE_INDEPENDENT_FINAL_REVIEW_FOR_HIGH_RISK"         "ASSURANCE_" || return 1
    conf_validate_schema "$workflow"         "INITIAL_STATE TERMINAL_STATES TRANSITION_INTAKE TRANSITION_CLARIFICATION_REQUIRED TRANSITION_IMPLEMENTING TRANSITION_VERIFYING TRANSITION_FAILED TRANSITION_REMEDIATING TRANSITION_PASSED TRANSITION_FINALIZED TRANSITION_CANCELLED OWNER_IMPLEMENTING OWNER_VERIFYING OWNER_FAILED OWNER_REMEDIATING OWNER_PASSED OWNER_FINALIZED"         "" || return 1
    [ "$(conf_get "$controls" ENFORCEMENT_MODE)" = "AUDIT_ONLY" ] || return 1
    for numeric in DEFAULT_TIMEOUT_SECONDS MAXIMUM_COMMAND_OUTPUT_BYTES PUBLIC_RESULT_MAXIMUM_BYTES WORKFLOW_PACKET_MAXIMUM_BYTES DEFAULT_ATTEMPT_BUDGET SAME_FAILURE_RETHINK_THRESHOLD CONTEXT_WARNING_BYTES CONTEXT_MAXIMUM_BYTES CONTEXT_BASE_MAXIMUM_BYTES CONTEXT_BUNDLE_MAXIMUM_BYTES CONTEXT_MAXIMUM_BUNDLES CONTEXT_MAXIMUM_SELECTIONS CONTEXT_WORKING_MEMORY_MAXIMUM_BYTES CONTEXT_CHECK_SUMMARY_MAXIMUM_BYTES; do
        case "$(conf_get "$controls" "$numeric" 2>/dev/null || printf '')" in ''|*[!0-9]*) return 1 ;; esac
        [ "$(conf_get "$controls" "$numeric")" -gt 0 ] || return 1
    done
    [ "$(conf_get "$controls" SAME_FAILURE_RETHINK_THRESHOLD)" -le "$(conf_get "$controls" DEFAULT_ATTEMPT_BUDGET)" ] || return 1
    [ "$(conf_get "$controls" CONTEXT_WARNING_BYTES)" -lt "$(conf_get "$controls" CONTEXT_MAXIMUM_BYTES)" ] || return 1
    [ "$(conf_get "$controls" CONTEXT_BASE_MAXIMUM_BYTES)" -lt "$(conf_get "$controls" CONTEXT_BUNDLE_MAXIMUM_BYTES)" ] || return 1
    [ "$(conf_get "$controls" CONTEXT_BUNDLE_MAXIMUM_BYTES)" -le "$(conf_get "$controls" CONTEXT_MAXIMUM_BYTES)" ] || return 1
    case "$(conf_get "$controls" REQUIRE_INDEPENDENT_FINAL_REVIEW_FOR_HIGH_RISK 2>/dev/null || printf '')" in 0|1) ;; *) return 1 ;; esac
    [ "$(workflow_initial_state)" = "INTAKE" ] || return 1
    [ "$(workflow_owner IMPLEMENTING)" = "approval" ] || return 1
    [ "$(workflow_owner VERIFYING)" = "verification" ] || return 1
    [ "$(workflow_owner FAILED)" = "verification" ] || return 1
    [ "$(workflow_owner REMEDIATING)" = "verification" ] || return 1
    [ "$(workflow_owner PASSED)" = "verification" ] || return 1
    [ "$(workflow_owner FINALIZED)" = "finalization" ] || return 1
    [ "$(workflow_targets FINALIZED)" = "" ] || return 1
    [ "$(workflow_targets CANCELLED)" = "" ] || return 1
    [ -s "$HARNESS_POLICY_DIR/transient-paths.txt" ] || return 1
    [ -s "$(convention_categories_file)" ] || return 1
    conventions_validate || return 1
    inventory_policy_validate || return 1
    identity_policy_validate || return 1
    if [ -s "$(project_contract_file)" ]; then project_contract_validate || return 1; fi
    for file in "$HARNESS_COMMAND_DIR"/*.conf; do
        [ -f "$file" ] || continue
        id=$(basename "$file" .conf)
        command_validate "$id" || return 1
    done
    return 0
}
