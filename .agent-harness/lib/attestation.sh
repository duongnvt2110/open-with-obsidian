#!/usr/bin/env bash

external_anchor_file() { printf '%s/external-anchor.conf\n' "$HARNESS_PROJECT_DIR"; }

external_anchor_validate() {
    local config mode anchor adapter adapter_hash
    config=$(external_anchor_file)
    [ -f "$config" ] || return 1
    [ -s "$config" ] || return 0
    conf_validate_schema "$config" \
        "MODE ANCHOR_FILE ADAPTER_PATH ADAPTER_HASH UPDATED_BY UPDATED_AT" "" || return 1
    mode=$(conf_get "$config" MODE 2>/dev/null || printf '')
    anchor=$(conf_get "$config" ANCHOR_FILE 2>/dev/null || printf '-')
    adapter=$(conf_get "$config" ADAPTER_PATH 2>/dev/null || printf '-')
    adapter_hash=$(conf_get "$config" ADAPTER_HASH 2>/dev/null || printf '-')
    case "$mode" in
        LOCAL_FILE)
            case "$anchor" in /*) ;; *) return 1 ;; esac
            case "$anchor" in "$HARNESS_REPO_ROOT"|"$HARNESS_REPO_ROOT"/*) return 1 ;; esac
            [ "$adapter" = "-" ] && [ "$adapter_hash" = "-" ] || return 1
            ;;
        ADAPTER)
            [ "$anchor" = "-" ] || return 1
            case "$adapter" in /*) ;; *) return 1 ;; esac
            case "$adapter" in "$HARNESS_REPO_ROOT"|"$HARNESS_REPO_ROOT"/*) return 1 ;; esac
            [ -f "$adapter" ] && [ -x "$adapter" ] || return 1
            [ "$(sha256_file "$adapter")" = "$adapter_hash" ] || return 1
            ;;
        *) return 1 ;;
    esac
}

external_anchor_configure() {
    external_anchor_configure_local "$@"
}

external_anchor_configure_local() {
    local path approved_by absolute
    path=$1; approved_by=$2
    acquire_lock "$HARNESS_GLOBAL_LOCK" anchor-configure || return 2
    trap cleanup_common EXIT INT TERM
    active_pointer_absent || return 3
    case "$path" in /*) absolute=$path ;; *) return 3 ;; esac
    case "$absolute" in "$HARNESS_REPO_ROOT"|"$HARNESS_REPO_ROOT"/*) return 3 ;; esac
    {
        conf_write_pair MODE LOCAL_FILE
        conf_write_pair ANCHOR_FILE "$absolute"
        conf_write_pair ADAPTER_PATH '-'
        conf_write_pair ADAPTER_HASH '-'
        conf_write_pair UPDATED_BY "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$(external_anchor_file)" || return 1
    release_lock
    trap - EXIT INT TERM
}

external_anchor_configure_adapter() {
    local path approved_by absolute digest
    path=$1; approved_by=$2
    acquire_lock "$HARNESS_GLOBAL_LOCK" anchor-adapter-configure || return 2
    trap cleanup_common EXIT INT TERM
    active_pointer_absent || return 3
    case "$path" in /*) absolute=$path ;; *) return 3 ;; esac
    case "$absolute" in "$HARNESS_REPO_ROOT"|"$HARNESS_REPO_ROOT"/*) return 3 ;; esac
    [ -f "$absolute" ] && [ -x "$absolute" ] || return 3
    digest=$(sha256_file "$absolute") || return 1
    {
        conf_write_pair MODE ADAPTER
        conf_write_pair ANCHOR_FILE '-'
        conf_write_pair ADAPTER_PATH "$absolute"
        conf_write_pair ADAPTER_HASH "$digest"
        conf_write_pair UPDATED_BY "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$(external_anchor_file)" || return 1
    release_lock
    trap - EXIT INT TERM
}

run_event_head() {
    local run_id
    run_id=$1
    tail -n 1 "$(run_events_file "$run_id")" 2>/dev/null | awk -F '\t' '{print $8}'
}

attestation_generate() {
    local run_id output task_id verification finalization payload hash
    run_id=$1; output=$2
    task_id=$(state_get "$run_id" TASK_ID)
    verification=$(run_dir "$run_id")/verification.conf
    finalization=$(run_dir "$run_id")/finalization.conf
    if [ -f "$output" ] && attestation_verify "$output"; then
        [ "$(conf_get "$output" TASK_ID 2>/dev/null || printf '')" = "$task_id" ] || return 1
        [ "$(conf_get "$output" RUN_ID 2>/dev/null || printf '')" = "$run_id" ] || return 1
        [ "$(conf_get "$output" PACKAGE_HASH 2>/dev/null || printf '')" = "$(sha256_file "$HARNESS_MANIFEST")" ] || return 1
        [ "$(conf_get "$output" EVENT_HEAD 2>/dev/null || printf '')" = "$(run_event_head "$run_id")" ] || return 1
        [ "$(conf_get "$output" VERIFICATION_HASH 2>/dev/null || printf '')" = "$(sha256_file "$verification")" ] || return 1
        [ "$(conf_get "$output" FINALIZATION_HASH 2>/dev/null || printf '')" = "$(sha256_file "$finalization")" ] || return 1
        return 0
    fi
    payload=$(cat <<EOF_PAYLOAD
TASK_ID=$task_id
RUN_ID=$run_id
PACKAGE_HASH=$(sha256_file "$HARNESS_MANIFEST")
PROJECT_CONTRACT_HASH=$(project_contract_hash 2>/dev/null || printf NONE)
CONVENTION_CONTRACT_HASH=$(conventions_contract_hash)
INVENTORY_POLICY_HASH=$(inventory_policy_hash)
EVENT_HEAD=$(run_event_head "$run_id")
VERIFICATION_HASH=$(sha256_file "$verification" 2>/dev/null || printf NONE)
FINALIZATION_HASH=$(sha256_file "$finalization" 2>/dev/null || printf NONE)
GENERATED_AT=$(harness_now)
EOF_PAYLOAD
)
    hash=$(sha256_text "$payload") || return 1
    { printf '%s\n' "$payload"; conf_write_pair ATTESTATION_HASH "$hash"; } | atomic_write "$output"
}

attestation_verify() {
    local file recorded payload
    file=$1
    [ -f "$file" ] || return 1
    recorded=$(conf_get "$file" ATTESTATION_HASH 2>/dev/null || printf '')
    payload=$(awk '!/^ATTESTATION_HASH=/' "$file")
    [ -n "$recorded" ] && [ "$(sha256_text "$payload")" = "$recorded" ]
}

external_anchor_local_lock() {
    local anchor lock attempts
    anchor=$1; lock=$anchor.lock; attempts=0
    while ! mkdir "$lock" 2>/dev/null; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 10 ] || return 1
        sleep 1
    done
    {
        conf_write_pair PID "$$"
        conf_write_pair HOST "$(hostname 2>/dev/null || printf unknown)"
        conf_write_pair STARTED_AT "$(harness_now)"
    } | atomic_write "$lock/owner.conf" || { rm -rf "$lock"; return 1; }
    EXTERNAL_ANCHOR_LOCK=$lock
}

external_anchor_local_unlock() {
    [ -n "${EXTERNAL_ANCHOR_LOCK:-}" ] || return 0
    rm -rf "$EXTERNAL_ANCHOR_LOCK"
    EXTERNAL_ANCHOR_LOCK=
}

external_anchor_local_validate_chain() {
    local anchor timestamp worktree attestation_hash previous entry_hash extra expected previous_expected
    anchor=$1
    [ -f "$anchor" ] || return 1
    previous_expected=GENESIS
    while IFS=$'\t' read -r timestamp worktree attestation_hash previous entry_hash extra; do
        [ -n "$timestamp$worktree$attestation_hash$previous$entry_hash" ] && [ -z "$extra" ] || return 1
        [ "$previous" = "$previous_expected" ] || return 1
        expected=$(sha256_text "$timestamp|$worktree|$attestation_hash|$previous") || return 1
        [ "$expected" = "$entry_hash" ] || return 1
        previous_expected=$entry_hash
    done <"$anchor"
}

external_anchor_adapter_call() {
    local action attestation config adapter adapter_hash hash
    action=$1; attestation=$2; config=$(external_anchor_file)
    adapter=$(conf_get "$config" ADAPTER_PATH) || return 1
    adapter_hash=$(conf_get "$config" ADAPTER_HASH) || return 1
    [ "$(sha256_file "$adapter")" = "$adapter_hash" ] || return 1
    hash=$(conf_get "$attestation" ATTESTATION_HASH) || return 1
    env -i \
        "PATH=/usr/bin:/bin" \
        "HARNESS_ANCHOR_ACTION=$action" \
        "HARNESS_ATTESTATION_FILE=$attestation" \
        "HARNESS_ATTESTATION_HASH=$hash" \
        "HARNESS_WORKTREE_ID=$HARNESS_WORKTREE_ID" \
        "$adapter"
}

external_anchor_append() {
    local attestation config mode anchor hash timestamp previous entry_hash
    attestation=$1; config=$(external_anchor_file)
    [ -s "$config" ] || return 0
    external_anchor_validate || return 1
    mode=$(conf_get "$config" MODE)
    if [ "$mode" = ADAPTER ]; then
        external_anchor_adapter_call APPEND "$attestation"
        return
    fi
    anchor=$(conf_get "$config" ANCHOR_FILE)
    hash=$(conf_get "$attestation" ATTESTATION_HASH) || return 1
    mkdir -p "$(dirname "$anchor")" || return 1
    external_anchor_local_lock "$anchor" || return 1
    if [ -f "$anchor" ]; then
        external_anchor_local_validate_chain "$anchor" || { external_anchor_local_unlock; return 1; }
        if awk -F '\t' -v wanted="$hash" '$3 == wanted {found=1} END {exit found ? 0 : 1}' "$anchor"; then
            external_anchor_local_unlock
            return 0
        fi
        previous=$(tail -n 1 "$anchor" | awk -F '\t' '{print $5}')
    else
        previous=GENESIS
    fi
    timestamp=$(harness_now)
    entry_hash=$(sha256_text "$timestamp|$HARNESS_WORKTREE_ID|$hash|$previous") || { external_anchor_local_unlock; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$timestamp" "$HARNESS_WORKTREE_ID" "$hash" "$previous" "$entry_hash" >>"$anchor" || { external_anchor_local_unlock; return 1; }
    sync 2>/dev/null || true
    external_anchor_local_unlock
}

external_anchor_contains() {
    local attestation config mode anchor hash
    attestation=$1; config=$(external_anchor_file)
    [ -s "$config" ] || return 0
    external_anchor_validate || return 1
    mode=$(conf_get "$config" MODE)
    if [ "$mode" = ADAPTER ]; then
        external_anchor_adapter_call CONTAINS "$attestation"
        return
    fi
    anchor=$(conf_get "$config" ANCHOR_FILE)
    [ -f "$anchor" ] || return 1
    external_anchor_local_validate_chain "$anchor" || return 1
    hash=$(conf_get "$attestation" ATTESTATION_HASH 2>/dev/null || printf '')
    [ -n "$hash" ] || return 1
    awk -F '\t' -v wanted="$hash" '$3 == wanted {found=1} END {exit found ? 0 : 1}' "$anchor"
}
