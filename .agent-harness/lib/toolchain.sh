#!/usr/bin/env bash

command_tools() {
    local id file
    id=$1; file=$(command_file "$id")
    awk -F '=' '
        /^TOOL_[0-9]+=/ { number=substr($1,6)+0; values[number]=substr($0,index($0,"=")+1); if(number>maximum)maximum=number }
        END { for(i=1;i<=maximum;i++) if(i in values) print values[i] }' "$file"
}

command_outputs() {
    local id file
    id=$1; file=$(command_file "$id")
    awk -F '=' '
        /^OUTPUT_[0-9]+=/ { number=substr($1,8)+0; values[number]=substr($0,index($0,"=")+1); if(number>maximum)maximum=number }
        END { for(i=1;i<=maximum;i++) if(i in values) print values[i] }' "$file"
}

resolve_path_executable() {
    local name old_ifs directory candidate
    name=$1
    case "$name" in
        */*) [ -f "$name" ] && [ -x "$name" ] || return 1; absolute_path "$name" ;;
        *)
            old_ifs=$IFS; IFS=:
            for directory in $PATH; do
                [ -n "$directory" ] || directory=.
                candidate=$directory/$name
                if [ -f "$candidate" ] && [ -x "$candidate" ]; then IFS=$old_ifs; absolute_path "$candidate"; return; fi
            done
            IFS=$old_ifs
            return 1
            ;;
    esac
}

command_interpreter_tool() {
    local id executable first interpreter
    id=$1
    executable=$(command_get "$id" EXECUTABLE 2>/dev/null || printf '')
    case "$executable" in */*) ;; *) return 0 ;; esac
    [ -f "$HARNESS_REPO_ROOT/$executable" ] || return 0
    first=$(sed -n '1p' "$HARNESS_REPO_ROOT/$executable" 2>/dev/null || printf '')
    case "$first" in
        '#!/usr/bin/env '*)
            printf '/usr/bin/env\n'
            interpreter=${first#'#!/usr/bin/env '}; interpreter=${interpreter%% *}
            [ -n "$interpreter" ] && printf '%s\n' "$interpreter"
            ;;
        '#!'*)
            interpreter=${first#'#!'}; interpreter=${interpreter%% *}
            [ -n "$interpreter" ] && printf '%s\n' "$interpreter"
            ;;
    esac
}

write_toolchain_bindings() {
    local checks_file output temporary check_id tool resolved digest mode
    checks_file=$1; output=$2
    temporary=$(mktemp "${TMPDIR:-/tmp}/toolchain-bindings.XXXXXX") || return 1
    : >"$temporary"
    while IFS= read -r check_id; do
        [ -n "$check_id" ] || continue
        mode=$(command_get "$check_id" TOOLCHAIN_MODE 2>/dev/null || printf '')
        mode=${mode:-STRICT}
        [ "$mode" = "STRICT" ] || continue
        {
            command_tools "$check_id"
            command_interpreter_tool "$check_id"
            if [ "$(command_get "$check_id" GIT_MODE 2>/dev/null || printf NONE)" = READ_ONLY_SNAPSHOT ]; then printf 'git\n'; fi
            :
        } | LC_ALL=C sort -u | while IFS= read -r tool; do
            [ -n "$tool" ] || continue
            resolved=$(resolve_path_executable "$tool") || exit 9
            digest=$(sha256_file "$resolved") || exit 9
            printf '%s\t%s\t%s\t%s\n' "$check_id" "$tool" "$resolved" "$digest" >>"$temporary"
        done || { rm -f "$temporary"; return 2; }
    done <"$checks_file"
    LC_ALL=C sort -u "$temporary" | atomic_write "$output"
    local result=$?
    rm -f "$temporary"
    return "$result"
}

toolchain_bindings_current() {
    local file check_id tool path digest extra
    file=$1
    [ -f "$file" ] || return 1
    while IFS=$'\t' read -r check_id tool path digest extra; do
        [ -n "$check_id" ] && [ -n "$tool" ] && [ -z "$extra" ] || return 1
        [ -f "$path" ] && [ -x "$path" ] || return 1
        [ "$(sha256_file "$path")" = "$digest" ] || return 1
    done <"$file"
}

toolchain_path_for_check() {
    local check_id executable bindings bin_directory mode binding_check tool path digest alias existing
    check_id=$1; executable=$2; bindings=$3; bin_directory=${4:-}
    mode=$(command_get "$check_id" TOOLCHAIN_MODE 2>/dev/null || printf '')
    mode=${mode:-STRICT}
    if [ "$mode" = "LEGACY" ]; then printf '%s\n' "$PATH"; return; fi
    [ -n "$bin_directory" ] || return 1
    rm -rf "$bin_directory"
    mkdir -p "$bin_directory" || return 1
    chmod 700 "$bin_directory" 2>/dev/null || true
    while IFS=$'\t' read -r binding_check tool path digest; do
        [ "$binding_check" = "$check_id" ] || continue
        alias=$(basename "$tool")
        printf '%s\n' "$alias" | LC_ALL=C grep -E '^[A-Za-z0-9][A-Za-z0-9._+@-]*$' >/dev/null 2>&1 || return 1
        if [ -e "$bin_directory/$alias" ] || [ -L "$bin_directory/$alias" ]; then
            existing=$(readlink "$bin_directory/$alias" 2>/dev/null || printf '')
            [ "$existing" = "$path" ] || return 1
        else
            ln -s "$path" "$bin_directory/$alias" || return 1
        fi
    done <"$bindings"
    printf '%s\n' "$bin_directory"
}
