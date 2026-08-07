#!/usr/bin/env bash
# Public package and core-command wrapper. Bash 3.2 compatible.
set -u
set -o pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SOURCE_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
. "$SCRIPT_DIR/lib/common.sh"
harness_normalize_locale
. "$SCRIPT_DIR/lib/package.sh"

wrapper_usage() {
    cat <<'USAGE'
Usage:
  .agent-harness/harness.sh <core-command> [arguments]
  .agent-harness/harness.sh validate-package [--json] [--strict]
  .agent-harness/harness.sh export --output DIRECTORY
  .agent-harness/harness.sh install --repository DIRECTORY
  .agent-harness/harness.sh upgrade [--source PACKAGE] --repository DIRECTORY
  .agent-harness/harness.sh recover-package --repository DIRECTORY

Package commands validate exact declared files, reject unsafe file types and
hard links, preserve repository-owned files, and journal install/upgrade work.
Core commands are delegated to .agent-harness/harness.
USAGE
}

validate_package_cli() {
    local json strict digest
    json=0; strict=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=1; shift ;;
            --strict) strict=1; shift ;;
            *) wrapper_usage >&2; return 2 ;;
        esac
    done
    if package_contract_validate "$SOURCE_ROOT" "$strict"; then
        digest=$(package_tree_digest "$SOURCE_ROOT") || return 4
        if [ "$json" = 1 ]; then
            printf '{"result":"PASS","strict":%s,"package_tree_sha256":"%s","version":"%s"}\n' \
                "$strict" "$digest" "$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || printf unknown)"
        else
            printf 'Package validation: PASS\nPackage tree SHA-256: %s\n' "$digest"
        fi
        return 0
    fi
    [ "$json" = 0 ] || printf '{"result":"FAIL","strict":%s}\n' "$strict"
    return 4
}

export_cli() {
    local output digest output_parent output_absolute
    output=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --output) [ "$#" -ge 2 ] || return 2; output=$2; shift 2 ;;
            *) wrapper_usage >&2; return 2 ;;
        esac
    done
    [ -n "$output" ] || { wrapper_usage >&2; return 2; }
    [ ! -L "$output" ] || return 2
    if [ -e "$output" ]; then
        [ -d "$output" ] || return 2
        find "$output" -mindepth 1 -print | grep . >/dev/null 2>&1 && return 2
    fi
    output_parent=$(dirname "$output"); [ -d "$output_parent" ] || return 2
    output_absolute=$(package_absolute_path "$output") || return 2
    case "$output_absolute" in "$SOURCE_ROOT"|"$SOURCE_ROOT"/*) return 2 ;; esac
    package_copy_release "$SOURCE_ROOT" "$output" || return 4
    digest=$(package_tree_digest "$output") || return 4
    printf 'Exported clean harness package: %s\nPackage tree SHA-256: %s\n' "$output" "$digest"
}

install_cli() {
    local repository
    repository=''
    while [ "$#" -gt 0 ]; do
        case "$1" in --repository) [ "$#" -ge 2 ] || return 2; repository=$2; shift 2 ;; *) wrapper_usage >&2; return 2 ;; esac
    done
    [ -n "$repository" ] || return 2
    package_install "$SOURCE_ROOT" "$repository" || return $?
    printf 'Installed harness into: %s\n' "$repository"
}

upgrade_cli() {
    local source repository
    source=$SOURCE_ROOT; repository=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source) [ "$#" -ge 2 ] || return 2; source=$2; shift 2 ;;
            --repository) [ "$#" -ge 2 ] || return 2; repository=$2; shift 2 ;;
            *) wrapper_usage >&2; return 2 ;;
        esac
    done
    [ -n "$repository" ] || return 2
    package_upgrade "$source" "$repository" || return $?
    printf 'Upgraded harness in: %s\n' "$repository"
}

recover_package_cli() {
    local repository
    [ "${1:-}" = --repository ] && [ -n "${2:-}" ] && [ "$#" -eq 2 ] || return 2
    repository=$2
    package_recover "$repository" || return $?
    printf 'Package recovery: PASS\n'
}

command_name=${1:-help}
[ "$#" -eq 0 ] || shift
case "$command_name" in
    validate-package) validate_package_cli "$@" ;;
    export) export_cli "$@" ;;
    install) install_cli "$@" ;;
    upgrade) upgrade_cli "$@" ;;
    recover-package) recover_package_cli "$@" ;;
    help|-h|--help) wrapper_usage ;;
    *)
        package_contract_validate "$SOURCE_ROOT" 0 || { printf 'ERROR: source package integrity validation failed\n' >&2; exit 6; }
        HARNESS_DECLARED_PACKAGE_DIGEST=$(package_tree_digest "$SOURCE_ROOT") || exit 6
        export HARNESS_DECLARED_PACKAGE_DIGEST
        exec "$SCRIPT_DIR/harness" "$command_name" "$@"
        ;;
esac
