#!/usr/bin/env bash

identity_policy_file() { printf '%s/identity-policy.conf\n' "$HARNESS_PROJECT_DIR"; }

identity_policy_validate() {
    local file mode key verifier verifier_hash issuer
    file=$(identity_policy_file)
    [ -f "$file" ] || return 1
    conf_validate_schema "$file" \
        "MODE ENV_KEY VERIFIER_PATH VERIFIER_HASH TRUSTED_ISSUER UPDATED_BY UPDATED_AT" "" || return 1
    mode=$(conf_get "$file" MODE 2>/dev/null || printf '')
    key=$(conf_get "$file" ENV_KEY 2>/dev/null || printf '-')
    verifier=$(conf_get "$file" VERIFIER_PATH 2>/dev/null || printf '-')
    verifier_hash=$(conf_get "$file" VERIFIER_HASH 2>/dev/null || printf '-')
    issuer=$(conf_get "$file" TRUSTED_ISSUER 2>/dev/null || printf '-')
    case "$mode" in
        DECLARATIVE|OS_USER|EXTERNAL_FILE|EXTERNAL)
            [ "$key" = "-" ] || return 1
            [ "$verifier" = "-" ] && [ "$verifier_hash" = "-" ] && [ "$issuer" = "-" ] || return 1
            ;;
        ENVIRONMENT)
            case "$key" in ''|'-'|*[!A-Z0-9_]*) return 1 ;; esac
            [ "$verifier" = "-" ] && [ "$verifier_hash" = "-" ] && [ "$issuer" = "-" ] || return 1
            ;;
        EXTERNAL_VERIFIED)
            [ "$key" = "-" ] || return 1
            case "$verifier" in /*) ;; *) return 1 ;; esac
            case "$verifier" in "$HARNESS_REPO_ROOT"|"$HARNESS_REPO_ROOT"/*) return 1 ;; esac
            [ -f "$verifier" ] && [ -x "$verifier" ] || return 1
            [ "$(sha256_file "$verifier")" = "$verifier_hash" ] || return 1
            [ -n "$issuer" ] && [ "$issuer" != "-" ] || return 1
            ;;
        *) return 1 ;;
    esac
}

identity_set_policy() {
    local mode env_key approved_by verifier issuer verifier_hash
    mode=$1; env_key=$2; approved_by=$3; verifier=${4:--}; issuer=${5:--}
    acquire_lock "$HARNESS_GLOBAL_LOCK" identity-policy || return 2
    trap cleanup_common EXIT INT TERM
    active_pointer_absent || return 3
    verifier_hash=-
    case "$mode" in
        DECLARATIVE|OS_USER|EXTERNAL_FILE|EXTERNAL)
            env_key=-; verifier=-; issuer=-
            ;;
        ENVIRONMENT)
            case "$env_key" in ''|'-'|*[!A-Z0-9_]*) return 3 ;; esac
            verifier=-; issuer=-
            ;;
        EXTERNAL_VERIFIED)
            env_key=-
            case "$verifier" in /*) ;; *) return 3 ;; esac
            case "$verifier" in "$HARNESS_REPO_ROOT"|"$HARNESS_REPO_ROOT"/*) return 3 ;; esac
            [ -f "$verifier" ] && [ -x "$verifier" ] || return 3
            [ -n "$issuer" ] && [ "$issuer" != "-" ] || return 3
            verifier_hash=$(sha256_file "$verifier") || return 1
            ;;
        *) return 3 ;;
    esac
    {
        conf_write_pair MODE "$mode"
        conf_write_pair ENV_KEY "$env_key"
        conf_write_pair VERIFIER_PATH "$verifier"
        conf_write_pair VERIFIER_HASH "$verifier_hash"
        conf_write_pair TRUSTED_ISSUER "$issuer"
        conf_write_pair UPDATED_BY "$(printf '%s' "$approved_by" | tr '\t\r\n' '   ')"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$(identity_policy_file)" || return 1
    release_lock
    trap - EXIT INT TERM
}

identity_external_evidence_validate() {
    local evidence require_issuer
    evidence=$1; require_issuer=$2
    conf_validate_schema "$evidence" \
        "PRINCIPAL DECISION SUBJECT_HASH ISSUER SIGNATURE SIGNATURE_FORMAT SIGNED_AT" "" || return 1
    [ -n "$(conf_get "$evidence" PRINCIPAL 2>/dev/null || printf '')" ] || return 1
    [ "$(conf_get "$evidence" DECISION 2>/dev/null || printf '')" = APPROVE ] || return 1
    [ -n "$(conf_get "$evidence" SUBJECT_HASH 2>/dev/null || printf '')" ] || return 1
    if [ "$require_issuer" = 1 ]; then
        [ -n "$(conf_get "$evidence" ISSUER 2>/dev/null || printf '')" ] || return 1
        [ -n "$(conf_get "$evidence" SIGNATURE 2>/dev/null || printf '')" ] || return 1
    fi
}

identity_capture() {
    local claimed evidence subject_hash action output mode key actual principal evidence_hash decision evidence_subject verifier verifier_hash issuer evidence_issuer verified_at
    claimed=$1; evidence=${2:-}; subject_hash=$3; action=$4; output=$5
    [ -n "$(trim_space "$claimed")" ] || return 1
    identity_policy_validate || return 1
    mode=$(conf_get "$(identity_policy_file)" MODE)
    key=$(conf_get "$(identity_policy_file)" ENV_KEY 2>/dev/null || printf '-')
    principal=$claimed
    evidence_hash=NONE
    verifier_hash=NONE
    issuer=NONE
    verified_at=NONE
    case "$mode" in
        DECLARATIVE) ;;
        OS_USER)
            actual=$(id -un 2>/dev/null || printf '')
            [ -n "$actual" ] && [ "$actual" = "$claimed" ] || return 1
            principal=$actual
            ;;
        ENVIRONMENT)
            actual=$(printenv "$key" 2>/dev/null || printf '')
            [ -n "$actual" ] && [ "$actual" = "$claimed" ] || return 1
            principal=$actual
            ;;
        EXTERNAL|EXTERNAL_FILE)
            [ -n "$evidence" ] && [ -f "$evidence" ] || return 1
            identity_external_evidence_validate "$evidence" 0 || return 1
            principal=$(conf_get "$evidence" PRINCIPAL)
            decision=$(conf_get "$evidence" DECISION)
            evidence_subject=$(conf_get "$evidence" SUBJECT_HASH)
            [ "$principal" = "$claimed" ] && [ "$decision" = "APPROVE" ] && [ "$evidence_subject" = "$subject_hash" ] || return 1
            evidence_hash=$(sha256_file "$evidence") || return 1
            ;;
        EXTERNAL_VERIFIED)
            [ -n "$evidence" ] && [ -f "$evidence" ] || return 1
            identity_external_evidence_validate "$evidence" 1 || return 1
            principal=$(conf_get "$evidence" PRINCIPAL)
            decision=$(conf_get "$evidence" DECISION)
            evidence_subject=$(conf_get "$evidence" SUBJECT_HASH)
            evidence_issuer=$(conf_get "$evidence" ISSUER)
            issuer=$(conf_get "$(identity_policy_file)" TRUSTED_ISSUER)
            verifier=$(conf_get "$(identity_policy_file)" VERIFIER_PATH)
            verifier_hash=$(conf_get "$(identity_policy_file)" VERIFIER_HASH)
            [ "$principal" = "$claimed" ] && [ "$decision" = "APPROVE" ] && [ "$evidence_subject" = "$subject_hash" ] && [ "$evidence_issuer" = "$issuer" ] || return 1
            [ "$(sha256_file "$verifier")" = "$verifier_hash" ] || return 1
            env -i \
                "PATH=/usr/bin:/bin" \
                "HARNESS_IDENTITY_EVIDENCE=$evidence" \
                "HARNESS_IDENTITY_CLAIMED=$claimed" \
                "HARNESS_IDENTITY_SUBJECT_HASH=$subject_hash" \
                "HARNESS_IDENTITY_ACTION=$action" \
                "HARNESS_IDENTITY_ISSUER=$issuer" \
                "$verifier" || return 1
            evidence_hash=$(sha256_file "$evidence") || return 1
            verified_at=$(harness_now)
            ;;
    esac
    {
        conf_write_pair ACTION "$action"
        conf_write_pair SUBJECT_HASH "$subject_hash"
        conf_write_pair CLAIMED_IDENTITY "$(printf '%s' "$claimed" | tr '\t\r\n' '   ')"
        conf_write_pair PRINCIPAL "$(printf '%s' "$principal" | tr '\t\r\n' '   ')"
        conf_write_pair ASSURANCE_MODE "$mode"
        conf_write_pair EVIDENCE_HASH "$evidence_hash"
        conf_write_pair VERIFIER_HASH "$verifier_hash"
        conf_write_pair TRUSTED_ISSUER "$issuer"
        conf_write_pair VERIFIED_AT "$verified_at"
        conf_write_pair CAPTURED_AT "$(harness_now)"
    } | atomic_write "$output"
}
