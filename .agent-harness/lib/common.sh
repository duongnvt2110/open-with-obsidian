#!/usr/bin/env bash
# Bash 3.2-compatible shared helpers.

HARNESS_JSON_MODE=${HARNESS_JSON_MODE:-0}
HARNESS_LOCK_PATH=""

harness_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

harness_epoch_seconds() {
    date '+%s'
}

harness_die() {
    local code message
    code=$1
    shift
    message=$*
    if [ "$HARNESS_JSON_MODE" = "1" ]; then
        printf '{"error":"HarnessError","message":"%s","exit_code":%s}\n' "$(json_escape "$message")" "$code"
    else
        printf 'ERROR: %s\n' "$message" >&2
    fi
    exit "$code"
}

harness_warn() {
    printf 'WARN: %s\n' "$*" >&2
}

json_escape() {
    # POSIX awk keeps this independent of jq and Python.
    printf '%s' "$1" | awk 'BEGIN { ORS="" }
        {
            if (NR > 1) printf "\\n"
            gsub(/\\/, "\\\\")
            gsub(/\"/, "\\\"")
            gsub(/\t/, "\\t")
            gsub(/\r/, "\\r")
            printf "%s", $0
        }'
}

sha256_file() {
    local file
    file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        return 127
    fi
}

sha256_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    else
        return 127
    fi
}

file_mode() {
    local file
    file=$1
    if stat -c '%a' "$file" >/dev/null 2>&1; then
        stat -c '%a' "$file"
    else
        stat -f '%Lp' "$file"
    fi
}

file_nlink() {
    local file
    file=$1
    if stat -c '%h' "$file" >/dev/null 2>&1; then
        stat -c '%h' "$file"
    else
        stat -f '%l' "$file"
    fi
}

file_size() {
    local file
    file=$1
    if stat -c '%s' "$file" >/dev/null 2>&1; then
        stat -c '%s' "$file"
    else
        stat -f '%z' "$file"
    fi
}

atomic_write() {
    local destination directory temporary
    destination=$1
    directory=$(dirname "$destination")
    mkdir -p "$directory" || return 1
    temporary=$(mktemp "$directory/.harness-tmp.XXXXXX") || return 1
    if ! cat >"$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    chmod 600 "$temporary" 2>/dev/null || true
    if ! mv "$temporary" "$destination"; then
        rm -f "$temporary"
        return 1
    fi
}

conf_get() {
    local file key
    file=$1
    key=$2
    [ -f "$file" ] || return 1
    awk -v wanted="$key" '
        index($0, "=") > 0 {
            current = substr($0, 1, index($0, "=") - 1)
            if (current == wanted) {
                print substr($0, index($0, "=") + 1)
                exit
            }
        }' "$file"
}

conf_has() {
    local file key
    file=$1
    key=$2
    conf_get "$file" "$key" >/dev/null 2>&1
}

conf_validate_schema() {
    # Usage: conf_validate_schema FILE "SCALAR KEY ..." "INDEXED_PREFIX_ ..."
    # Blank lines and comments are allowed. Every key must be known and unique.
    # Indexed keys must start at 1 and remain contiguous for each prefix.
    local file scalar_keys indexed_prefixes
    file=$1
    scalar_keys=$2
    indexed_prefixes=$3
    [ -f "$file" ] || return 1
    awk -v scalars="$scalar_keys" -v prefixes="$indexed_prefixes" '
        BEGIN {
            split(scalars, scalar_list, /[[:space:]]+/)
            for (i in scalar_list) if (scalar_list[i] != "") scalar[scalar_list[i]] = 1
            split(prefixes, prefix_list, /[[:space:]]+/)
            for (i in prefix_list) if (prefix_list[i] != "") indexed[prefix_list[i]] = 1
        }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        index($0, "=") == 0 { bad = 1; next }
        {
            key = substr($0, 1, index($0, "=") - 1)
            if (key !~ /^[A-Z][A-Z0-9_]*$/) { bad = 1; next }
            if (++seen[key] > 1) { bad = 1; next }
            if (key in scalar) next
            matched = 0
            for (prefix in indexed) {
                if (index(key, prefix) == 1) {
                    suffix = substr(key, length(prefix) + 1)
                    if (suffix !~ /^[1-9][0-9]*$/) { bad = 1; matched = 1; break }
                    number = suffix + 0
                    indexes[prefix, number] = 1
                    if (number > maximum[prefix]) maximum[prefix] = number
                    matched = 1
                    break
                }
            }
            if (!matched) bad = 1
        }
        END {
            for (prefix in maximum) {
                for (i = 1; i <= maximum[prefix]; i++) {
                    if (!indexes[prefix, i]) bad = 1
                }
            }
            exit bad ? 1 : 0
        }
    ' "$file"
}

conf_write_pair() {
    local key value
    key=$1
    value=$2
    case "$key$value" in
        *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    esac
    printf '%s=%s\n' "$key" "$value"
}

trim_space() {
    printf '%s' "$1" | awk '{$1=$1; print}'
}

lower_text() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

safe_relative_path() {
    local path allow_glob old_ifs segment restore_glob
    path=$1
    allow_glob=${2:-0}
    [ -n "$path" ] || return 1
    case "$path" in
        /*|~*|*\\*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    esac
    while [ "${path#./}" != "$path" ]; do path=${path#./}; done
    [ -n "$path" ] || return 1
    old_ifs=$IFS
    case $- in *f*) restore_glob=0 ;; *) restore_glob=1; set -f ;; esac
    IFS='/'
    set -- $path
    IFS=$old_ifs
    [ "$restore_glob" -eq 0 ] || set +f
    for segment in "$@"; do
        [ -n "$segment" ] || return 1
        [ "$segment" != "." ] || return 1
        [ "$segment" != ".." ] || return 1
    done
    if [ "$allow_glob" != "1" ]; then
        case "$path" in *'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*) return 1 ;; esac
    fi
    printf '%s\n' "$path"
}

glob_validate() {
    local pattern
    pattern=$1
    safe_relative_path "$pattern" 1 >/dev/null || return 1
    # Deliberately support only *, **, and ?. Character classes are rejected.
    case "$pattern" in *'['*|*']'*|*'{'*|*'}'*) return 1 ;; esac
    return 0
}

glob_to_regex() {
    local pattern result i length char next_index
    pattern=$1
    result='^'
    i=0
    length=${#pattern}
    while [ "$i" -lt "$length" ]; do
        char=${pattern:$i:1}
        if [ "$char" = '*' ]; then
            next_index=$((i + 1))
            if [ "$next_index" -lt "$length" ] && [ "${pattern:$next_index:1}" = '*' ]; then
                result=$result'.*'
                i=$((i + 2))
                continue
            fi
            result=$result'[^/]*'
        elif [ "$char" = '?' ]; then
            result=$result'[^/]'
        else
            case "$char" in
                '.'|'+'|'('|')'|'|'|'^'|'$'|'\\') result="${result}\\${char}" ;;
                *) result=$result$char ;;
            esac
        fi
        i=$((i + 1))
    done
    printf '%s$\n' "$result"
}

path_matches() {
    local path pattern regex
    path=$1
    pattern=$2
    glob_validate "$pattern" || return 2
    regex=$(glob_to_regex "$pattern") || return 2
    printf '%s\n' "$path" | grep -E "$regex" >/dev/null 2>&1
}

path_has_vcs_segment() {
    local path old_ifs segment restore_glob
    path=$(lower_text "$1")
    old_ifs=$IFS
    case $- in *f*) restore_glob=0 ;; *) restore_glob=1; set -f ;; esac
    IFS='/'
    set -- $path
    IFS=$old_ifs
    [ "$restore_glob" -eq 0 ] || set +f
    for segment in "$@"; do
        case "$segment" in .git|.hg|.svn) return 0 ;; esac
    done
    return 1
}

path_is_harness_control() {
    local path
    path=$(lower_text "$1")
    case "$path" in
        .agent-harness|.agent-harness/*|agents.md|workflow.md|context.md) return 0 ;;
    esac
    return 1
}

path_is_harness_data() {
    local path
    path=$(lower_text "$1")
    case "$path" in
        .agent-harness/runtime|.agent-harness/runtime/*|.agent-harness/tasks|.agent-harness/tasks/*|.agent-harness/runs|.agent-harness/runs/*) return 0 ;;
    esac
    return 1
}

make_temp_dir() {
    local prefix
    prefix=${1:-agent-harness}
    mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

absolute_path() {
    local target directory filename
    target=$1
    if [ -d "$target" ]; then
        (cd "$target" 2>/dev/null && pwd -P)
    else
        directory=$(dirname "$target")
        filename=$(basename "$target")
        (cd "$directory" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$filename")
    fi
}

acquire_lock() {
    local lock_dir operation
    lock_dir=$1
    operation=$2
    if mkdir "$lock_dir" 2>/dev/null; then
        {
            conf_write_pair PID "$$"
            conf_write_pair HOST "$(hostname 2>/dev/null || printf unknown)"
            conf_write_pair OPERATION "$operation"
            conf_write_pair STARTED_AT "$(harness_now)"
        } | atomic_write "$lock_dir/owner.conf" || return 1
        HARNESS_LOCK_PATH=$lock_dir
        return 0
    fi
    return 1
}

release_lock() {
    local lock_dir
    lock_dir=${1:-$HARNESS_LOCK_PATH}
    [ -n "$lock_dir" ] || return 0
    rm -rf "$lock_dir"
    if [ "$HARNESS_LOCK_PATH" = "$lock_dir" ]; then HARNESS_LOCK_PATH=""; fi
}

lock_is_stale() {
    local lock_dir owner lock_host lock_pid current_host
    lock_dir=$1
    owner=$lock_dir/owner.conf
    [ -f "$owner" ] || return 0
    lock_host=$(conf_get "$owner" HOST 2>/dev/null || printf '')
    lock_pid=$(conf_get "$owner" PID 2>/dev/null || printf '')
    current_host=$(hostname 2>/dev/null || printf unknown)
    [ "$lock_host" = "$current_host" ] || return 1
    case "$lock_pid" in ''|*[!0-9]*) return 0 ;; esac
    kill -0 "$lock_pid" 2>/dev/null && return 1
    return 0
}

process_tree_pids() {
    local root frontier next pid ppid item found
    root=$1
    frontier=$root
    printf '%s
' "$root"
    while [ -n "$frontier" ]; do
        next=''
        while read -r pid ppid; do
            [ -n "$pid" ] && [ -n "$ppid" ] || continue
            found=0
            for item in $frontier; do [ "$ppid" = "$item" ] && found=1; done
            if [ "$found" -eq 1 ]; then
                printf '%s
' "$pid"
                next="$next $pid"
            fi
        done <<EOF_PS
$(ps -eo pid=,ppid= 2>/dev/null)
EOF_PS
        frontier=$(trim_space "$next")
    done
}

kill_process_tree_signal() {
    local root signal pids pid
    root=$1; signal=$2
    pids=$(process_tree_pids "$root" | awk 'NF {values[NR]=$1} END {for (i=NR; i>=1; i--) print values[i]}')
    for pid in $pids; do kill "-$signal" "$pid" 2>/dev/null || true; done
}

kill_process_tree() {
    kill_process_tree_signal "$1" TERM
}

run_with_timeout_capture() {
    # Run every check behind a small worker that owns a unique lifetime marker.
    # The watchdog acts only while that marker exists, preventing a completed
    # command PID from being mistaken for a later reused PID. When setsid is
    # available, the worker reports its real process group because setsid may
    # fork and make $! differ from the group leader.
    local timeout_seconds output_file error_file command_pid watchdog_pid timeout_flag active_flag group_file result group_mode tree_pids later_pids tree_pid command_group group_wait
    timeout_seconds=$1; output_file=$2; error_file=$3; shift 3
    timeout_flag=$(mktemp "${TMPDIR:-/tmp}/harness-timeout.XXXXXX") || return 1
    active_flag=$(mktemp "${TMPDIR:-/tmp}/harness-active.XXXXXX") || { rm -f "$timeout_flag"; return 1; }
    group_file=$(mktemp "${TMPDIR:-/tmp}/harness-group.XXXXXX") || { rm -f "$timeout_flag" "$active_flag"; return 1; }
    rm -f "$timeout_flag"
    : >"$group_file"
    group_mode=0
    if command -v setsid >/dev/null 2>&1; then group_mode=1; fi
    if [ "$error_file" = COMBINED ]; then
        if [ "$group_mode" -eq 1 ]; then
            setsid bash -c 'marker=$1; group_file=$2; shift 2; group=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d " "); printf "%s\n" "$group" >"$group_file"; trap '\''rm -f "$marker"'\'' EXIT; "$@"' harness-timeout-worker "$active_flag" "$group_file" "$@" >"$output_file" 2>&1 &
        else
            bash -c 'marker=$1; shift; trap '\''rm -f "$marker"'\'' EXIT; "$@"' harness-timeout-worker "$active_flag" "$@" >"$output_file" 2>&1 &
        fi
    else
        if [ "$group_mode" -eq 1 ]; then
            setsid bash -c 'marker=$1; group_file=$2; shift 2; group=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d " "); printf "%s\n" "$group" >"$group_file"; trap '\''rm -f "$marker"'\'' EXIT; "$@"' harness-timeout-worker "$active_flag" "$group_file" "$@" >"$output_file" 2>"$error_file" &
        else
            bash -c 'marker=$1; shift; trap '\''rm -f "$marker"'\'' EXIT; "$@"' harness-timeout-worker "$active_flag" "$@" >"$output_file" 2>"$error_file" &
        fi
    fi
    command_pid=$!
    command_group=''
    if [ "$group_mode" -eq 1 ]; then
        group_wait=0
        while [ ! -s "$group_file" ] && [ "$group_wait" -lt 100 ]; do
            kill -0 "$command_pid" 2>/dev/null || break
            sleep 0.01
            group_wait=$((group_wait + 1))
        done
        if [ -s "$group_file" ]; then
            command_group=$(sed -n '1{s/[^0-9]//g;p;}' "$group_file")
        fi
    fi
    (
        timer_pid=''
        watchdog_cleanup() {
            if [ -n "$timer_pid" ]; then
                kill -TERM "$timer_pid" 2>/dev/null || true
                wait "$timer_pid" 2>/dev/null || true
            fi
            exit 0
        }
        trap watchdog_cleanup TERM INT
        sleep "$timeout_seconds" &
        timer_pid=$!
        wait "$timer_pid" 2>/dev/null || exit 0
        timer_pid=''
        [ -f "$active_flag" ] || exit 0
        : >"$timeout_flag"
        tree_pids=$(process_tree_pids "$command_pid" | awk 'NF {values[NR]=$1} END {for (i=NR; i>=1; i--) print values[i]}')
        if [ "$group_mode" -eq 1 ] && [ -n "$command_group" ]; then
            kill -TERM "-$command_group" 2>/dev/null || true
        fi
        for tree_pid in $tree_pids; do kill -TERM "$tree_pid" 2>/dev/null || true; done
        sleep 1
        # Re-snapshot before KILL so descendants created during TERM handling are
        # included. Retain the first snapshot to cover children that reparented.
        later_pids=$(process_tree_pids "$command_pid" 2>/dev/null | awk 'NF {values[NR]=$1} END {for (i=NR; i>=1; i--) print values[i]}')
        if [ "$group_mode" -eq 1 ] && [ -n "$command_group" ]; then
            kill -KILL "-$command_group" 2>/dev/null || true
        fi
        for tree_pid in $tree_pids $later_pids; do kill -KILL "$tree_pid" 2>/dev/null || true; done
    ) </dev/null >/dev/null 2>&1 &
    watchdog_pid=$!
    wait "$command_pid" 2>/dev/null
    result=$?
    rm -f "$active_flag"
    if [ -f "$timeout_flag" ]; then
        # Timeout handling has started. Do not cancel the watchdog merely
        # because the process-group leader exited after TERM; it still owns
        # the KILL escalation for TERM-resistant or reparented descendants.
        wait "$watchdog_pid" 2>/dev/null || true
        rm -f "$group_file" "$timeout_flag"
        return 124
    fi
    kill_process_tree_signal "$watchdog_pid" TERM
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    rm -f "$group_file" "$timeout_flag"
    return "$result"
}

run_with_timeout() {
    local timeout_seconds output_file
    timeout_seconds=$1
    output_file=$2
    shift 2
    run_with_timeout_capture "$timeout_seconds" "$output_file" COMBINED "$@"
}

run_with_timeout_split() {
    local timeout_seconds output_file error_file
    timeout_seconds=$1
    output_file=$2
    error_file=$3
    shift 3
    run_with_timeout_capture "$timeout_seconds" "$output_file" "$error_file" "$@"
}

require_command() {
    command -v "$1" >/dev/null 2>&1
}

cleanup_common() {
    release_lock
}

identifier_validate() {
    local value
    value=$1
    [ ${#value} -le 64 ] || return 1
    printf '%s\n' "$value" | LC_ALL=C grep -E '^[A-Za-z0-9][A-Za-z0-9._-]*$' >/dev/null 2>&1
}

csv_identifiers_validate() {
    local value old_ifs item
    value=$1
    [ -n "$value" ] || return 0
    [ "$value" = "*" ] && return 0
    old_ifs=$IFS
    IFS=','
    set -- $value
    IFS=$old_ifs
    for item in "$@"; do identifier_validate "$item" || return 1; done
}

path_text_supported() {
    local value
    value=$1
    [ -n "$value" ] || return 1
    case "$value" in -*) return 1 ;; esac
    if printf '%s' "$value" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; then return 1; fi
    return 0
}

csv_contains_value() {
    local csv wanted old_ifs item
    csv=$1
    wanted=$2
    [ "$csv" = "*" ] && return 0
    old_ifs=$IFS
    IFS=','
    set -- $csv
    IFS=$old_ifs
    for item in "$@"; do [ "$item" = "$wanted" ] && return 0; done
    return 1
}

select_supported_locale() {
    local candidate available matched
    for candidate in "${LC_ALL:-}" "${LANG:-}"; do
        [ -n "$candidate" ] || continue
        case "$candidate" in *$'\t'*|*$'\r'*|*$'\n'*|*=*) continue ;; esac
        if command -v locale >/dev/null 2>&1; then
            available=$(locale -a 2>/dev/null || printf '')
            matched=$(printf '%s\n' "$available" | awk -v wanted="$candidate" '
                function norm(value) {
                    value=tolower(value)
                    gsub(/[-_.]/, "", value)
                    return value
                }
                norm($0) == norm(wanted) { print; exit }
            ')
            [ -n "$matched" ] || continue
            printf '%s\n' "$matched"
            return 0
        elif [ "$candidate" = C ] || [ "$candidate" = POSIX ]; then
            printf 'C\n'
            return 0
        fi
    done
    # C is required by POSIX and is the deterministic fallback when the host
    # advertises an unavailable locale.
    printf 'C\n'
}

harness_normalize_locale() {
    local selected
    selected=$(select_supported_locale) || selected=C
    LANG=$selected
    LC_ALL=$selected
    export LANG LC_ALL
}
