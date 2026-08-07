#!/usr/bin/env bash
# Distribution package validation, copying, installation, upgrade, and recovery.
# Bash 3.2 compatible. This library does not introduce workflow authority.

package_safe_relative_path() {
    local path segment old_ifs
    path=$1
    [ -n "$path" ] || return 1
    case "$path" in /*|./*|../*|*/../*|*/..|*\\*|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
    old_ifs=$IFS; IFS='/'; set -- $path; IFS=$old_ifs
    for segment in "$@"; do [ -n "$segment" ] && [ "$segment" != . ] && [ "$segment" != .. ] || return 1; done
    return 0
}

package_absolute_path() {
    local target parent base
    target=$1
    if [ -d "$target" ]; then (cd "$target" 2>/dev/null && pwd -P); return; fi
    parent=$(dirname "$target"); base=$(basename "$target")
    (cd "$parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base")
}

package_path_is_within() {
    local root candidate
    root=$(package_absolute_path "$1") || return 1
    candidate=$(package_absolute_path "$2") || return 1
    case "$candidate" in "$root"|"$root"/*) return 0 ;; esac
    return 1
}

package_release_list() { printf '%s/.agent-harness/release-files.txt\n' "$1"; }
package_manifest() { printf '%s/.agent-harness/manifest.tsv\n' "$1"; }

package_manifest_entries_validate() {
    local root scope manifest path expected mode extra file actual actual_mode previous
    root=$1; scope=${2:-full}; manifest=$(package_manifest "$root")
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
    previous=''
    while IFS=$'\t' read -r path expected mode extra; do
        [ -n "$path" ] || continue
        [ -z "$extra" ] || return 1
        package_safe_relative_path "$path" || return 1
        [ "$path" != .agent-harness/manifest.tsv ] || return 1
        [ -z "$previous" ] || [ "$previous" \< "$path" ] || return 1
        previous=$path
        case "$expected" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ "${#expected}" -eq 64 ] || return 1 ;; *) return 1 ;; esac
        case "$mode" in 644|755) ;; *) return 1 ;; esac
        if [ "$scope" = installed ]; then case "$path" in .agent-harness/*) ;; *) continue ;; esac; fi
        file=$root/$path
        [ -f "$file" ] && [ ! -L "$file" ] || return 1
        [ "$(file_nlink "$file")" = 1 ] || return 1
        actual=$(sha256_file "$file") || return 1
        [ "$actual" = "$expected" ] || return 1
        actual_mode=$(file_mode "$file") || return 1
        [ "$actual_mode" = "$mode" ] || return 1
    done <"$manifest"
}

package_release_list_validate() {
    local root list manifest_paths release_paths path previous
    root=$1; list=$(package_release_list "$root")
    [ -f "$list" ] && [ ! -L "$list" ] || return 1
    manifest_paths=$(mktemp "${TMPDIR:-/tmp}/harness-manifest-paths.XXXXXX") || return 1
    release_paths=$(mktemp "${TMPDIR:-/tmp}/harness-release-paths.XXXXXX") || { rm -f "$manifest_paths"; return 1; }
    previous=''; : >"$release_paths"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        package_safe_relative_path "$path" || { rm -f "$manifest_paths" "$release_paths"; return 1; }
        [ "$path" != .agent-harness/manifest.tsv ] || { rm -f "$manifest_paths" "$release_paths"; return 1; }
        [ -z "$previous" ] || [ "$previous" \< "$path" ] || { rm -f "$manifest_paths" "$release_paths"; return 1; }
        previous=$path
        printf '%s\n' "$path" >>"$release_paths"
    done <"$list"
    awk -F '\t' 'NF {print $1}' "$(package_manifest "$root")" >"$manifest_paths"
    cmp -s "$manifest_paths" "$release_paths"
    result=$?
    rm -f "$manifest_paths" "$release_paths"
    return "$result"
}

package_special_entries_rejected() {
    local root path
    root=$1
    while IFS= read -r path; do
        [ -d "$path" ] || [ -f "$path" ] || return 1
        [ ! -L "$path" ] || return 1
        if [ -f "$path" ]; then [ "$(file_nlink "$path")" = 1 ] || return 1; fi
    done <<EOF_ENTRIES
$(find "$root" -mindepth 1 -print 2>/dev/null)
EOF_ENTRIES
}

package_exact_closure_validate() {
    local root expected actual path
    root=$1
    expected=$(mktemp "${TMPDIR:-/tmp}/harness-expected.XXXXXX") || return 1
    actual=$(mktemp "${TMPDIR:-/tmp}/harness-actual.XXXXXX") || { rm -f "$expected"; return 1; }
    cat "$(package_release_list "$root")" >"$expected"
    printf '%s\n' .agent-harness/manifest.tsv >>"$expected"
    LC_ALL=C sort -u "$expected" -o "$expected"
    (
        cd "$root" || exit 1
        find . -type f -print | sed 's#^\./##' | LC_ALL=C sort
    ) >"$actual" || { rm -f "$expected" "$actual"; return 1; }
    cmp -s "$expected" "$actual"
    result=$?
    rm -f "$expected" "$actual"
    return "$result"
}

package_contract_validate() {
    local root strict scope external_expected
    root=$1; strict=${2:-0}; scope=${3:-full}
    [ -d "$root/.agent-harness" ] || return 1
    package_manifest_entries_validate "$root" "$scope" || return 1
    package_release_list_validate "$root" || return 1
    external_expected=${HARNESS_EXPECTED_MANIFEST_HASH:-}
    [ -z "$external_expected" ] || [ "$external_expected" = "$(sha256_file "$(package_manifest "$root")")" ] || return 1
    if [ "$strict" = 1 ]; then
        package_special_entries_rejected "$root" || return 1
        [ "$scope" = installed ] || package_exact_closure_validate "$root" || return 1
    fi
    return 0
}

package_tree_digest() {
    local root scope manifest path expected mode aggregate manifest_hash digest result
    root=$1; scope=${2:-full}; manifest=$(package_manifest "$root")
    package_manifest_entries_validate "$root" "$scope" || return 1
    aggregate=$(mktemp "${TMPDIR:-/tmp}/harness-tree.XXXXXX") || return 1
    : >"$aggregate"
    while IFS=$'\t' read -r path expected mode; do
        [ -n "$path" ] || continue
        printf 'file\t%s\t%s\t%s\n' "$path" "$mode" "$expected" >>"$aggregate"
    done <"$manifest"
    manifest_hash=$(sha256_file "$manifest") || { rm -f "$aggregate"; return 1; }
    printf 'manifest\t.agent-harness/manifest.tsv\t644\t%s\n' "$manifest_hash" >>"$aggregate"
    digest=$(sha256_file "$aggregate")
    result=$?
    rm -f "$aggregate"
    [ "$result" -eq 0 ] && printf '%s\n' "$digest"
    return "$result"
}

package_copy_release() {
    local source output parent stage path mode old_umask
    source=$1; output=$2
    package_contract_validate "$source" 0 full || return 1
    [ ! -L "$output" ] || return 1
    if [ -e "$output" ]; then
        [ -d "$output" ] || return 1
        find "$output" -mindepth 1 -print | grep . >/dev/null 2>&1 && return 1
    fi
    parent=$(dirname "$output"); [ -d "$parent" ] || return 1
    source=$(package_absolute_path "$source") || return 1
    output=$(package_absolute_path "$output") || return 1
    case "$output" in "$source"|"$source"/*) return 1 ;; esac
    old_umask=$(umask); umask 077
    stage=$(mktemp -d "$parent/.harness-export.XXXXXX") || { umask "$old_umask"; return 1; }
    umask "$old_umask"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        mkdir -p "$stage/$(dirname "$path")" || { rm -rf "$stage"; return 1; }
        cp "$source/$path" "$stage/$path" || { rm -rf "$stage"; return 1; }
        mode=$(file_mode "$source/$path") || { rm -rf "$stage"; return 1; }
        chmod "$mode" "$stage/$path" || { rm -rf "$stage"; return 1; }
    done <"$(package_release_list "$source")"
    mkdir -p "$stage/.agent-harness" || { rm -rf "$stage"; return 1; }
    cp "$(package_manifest "$source")" "$stage/.agent-harness/manifest.tsv" || { rm -rf "$stage"; return 1; }
    chmod 644 "$stage/.agent-harness/manifest.tsv" || { rm -rf "$stage"; return 1; }
    package_contract_validate "$stage" 1 full || { rm -rf "$stage"; return 1; }
    [ ! -d "$output" ] || rmdir "$output" || { rm -rf "$stage"; return 1; }
    mv "$stage" "$output" || { rm -rf "$stage"; return 1; }
}

package_mutable_paths() {
    cat <<'EOF_PATHS'
runtime
tasks
runs
project
config/commands
EOF_PATHS
}

package_preserve_state() {
    local old save rel
    old=$1; save=$2
    mkdir -p "$save" || return 1
    while IFS= read -r rel; do
        [ -e "$old/$rel" ] || continue
        mkdir -p "$save/$(dirname "$rel")" || return 1
        cp -Rp "$old/$rel" "$save/$rel" || return 1
    done <<EOF_STATE
$(package_mutable_paths)
EOF_STATE
}

package_restore_state() {
    local save target rel
    save=$1; target=$2
    [ -d "$save" ] || return 0
    while IFS= read -r rel; do
        [ -e "$save/$rel" ] || continue
        rm -rf "$target/$rel"
        mkdir -p "$target/$(dirname "$rel")" || return 1
        cp -Rp "$save/$rel" "$target/$rel" || return 1
    done <<EOF_STATE
$(package_mutable_paths)
EOF_STATE
}

package_operation_root() { printf '%s/.harness-operations\n' "$1"; }

package_operation_create() {
    local repository kind root operation
    repository=$1; kind=$2; root=$(package_operation_root "$repository")
    [ ! -L "$root" ] || return 1
    mkdir -p "$root" || return 1
    package_path_is_within "$repository" "$root" || return 1
    operation=$root/$kind-$(date -u '+%Y%m%d%H%M%S')-$$
    mkdir "$operation" || return 1
    package_path_is_within "$root" "$operation" || { rm -rf "$operation"; return 1; }
    printf '%s\n' "$operation"
}

package_journal_write() {
    local journal phase kind repository old_digest new_digest
    journal=$1; phase=$2; kind=$3; repository=$4; old_digest=$5; new_digest=$6
    {
        conf_write_pair SCHEMA_VERSION 1
        conf_write_pair KIND "$kind"
        conf_write_pair PHASE "$phase"
        conf_write_pair REPOSITORY "$repository"
        conf_write_pair OLD_PACKAGE_DIGEST "$old_digest"
        conf_write_pair NEW_PACKAGE_DIGEST "$new_digest"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$journal"
}

package_install() {
    local source repository operation stage journal digest
    source=$1; repository=$2
    [ -d "$repository" ] && [ ! -L "$repository" ] || return 2
    [ ! -e "$repository/.agent-harness" ] || return 3
    package_contract_validate "$source" 1 full || return 4
    digest=$(package_tree_digest "$source" installed) || return 4
    operation=$(package_operation_create "$repository" install) || return 4
    stage=$operation/stage-root; journal=$operation/journal.conf
    package_journal_write "$journal" PREPARED INSTALL "$repository" NONE "$digest" || return 4
    package_copy_release "$source" "$stage" || return 4
    package_journal_write "$journal" STAGED INSTALL "$repository" NONE "$digest" || return 4
    mv "$stage/.agent-harness" "$repository/.agent-harness" || return 4
    rm -rf "$stage"
    package_journal_write "$journal" PUBLISHED INSTALL "$repository" NONE "$digest" || return 4
    HARNESS_REPOSITORY_ROOT="$repository" "$repository/.agent-harness/harness" doctor >/dev/null 2>&1 || {
        rm -rf "$repository/.agent-harness"
        package_journal_write "$journal" ROLLED_BACK INSTALL "$repository" NONE "$digest" || true
        return 4
    }
    package_journal_write "$journal" COMPLETED INSTALL "$repository" NONE "$digest" || return 4
    return 0
}

package_active_task_blocks_upgrade() {
    local installation
    installation=$1
    [ -e "$installation/runtime/active-run.conf" ]
}

package_upgrade() {
    local source repository target operation backup stage state_save journal old_digest new_digest
    source=$1; repository=$2; target=$repository/.agent-harness
    [ -d "$target" ] && [ ! -L "$target" ] || return 2
    package_active_task_blocks_upgrade "$target" && return 3
    package_contract_validate "$source" 1 full || return 4
    package_contract_validate "$repository" 0 installed || return 4
    old_digest=$(package_tree_digest "$repository" installed) || return 4
    new_digest=$(package_tree_digest "$source" installed) || return 4
    operation=$(package_operation_create "$repository" upgrade) || return 4
    backup=$operation/backup-root; stage=$operation/stage-root; state_save=$operation/state; journal=$operation/journal.conf
    package_journal_write "$journal" PREPARED UPGRADE "$repository" "$old_digest" "$new_digest" || return 4
    mkdir -p "$backup" || return 4
    cp -Rp "$target" "$backup/.agent-harness" || return 4
    package_contract_validate "$backup" 0 installed || return 4
    [ "$(package_tree_digest "$backup" installed)" = "$old_digest" ] || return 4
    package_preserve_state "$target" "$state_save" || return 4
    package_copy_release "$source" "$stage" || return 4
    package_restore_state "$state_save" "$stage/.agent-harness" || return 4
    package_journal_write "$journal" STAGED UPGRADE "$repository" "$old_digest" "$new_digest" || return 4
    mv "$target" "$operation/old-agent-harness" || return 4
    if ! mv "$stage/.agent-harness" "$target"; then
        mv "$operation/old-agent-harness" "$target" 2>/dev/null || true
        return 4
    fi
    rm -rf "$stage"
    package_journal_write "$journal" PUBLISHED UPGRADE "$repository" "$old_digest" "$new_digest" || return 4
    if HARNESS_REPOSITORY_ROOT="$repository" "$target/harness" doctor >/dev/null 2>&1; then
        package_journal_write "$journal" COMPLETED UPGRADE "$repository" "$old_digest" "$new_digest" || return 4
        rm -rf "$operation/old-agent-harness" "$backup" "$state_save"
        return 0
    fi
    rm -rf "$target"
    package_contract_validate "$backup" 0 installed && [ "$(package_tree_digest "$backup" installed)" = "$old_digest" ] || return 4
    mv "$operation/old-agent-harness" "$target" || return 4
    package_journal_write "$journal" ROLLED_BACK UPGRADE "$repository" "$old_digest" "$new_digest" || true
    return 4
}

package_journal_validate() {
    local journal repository kind phase schema journal_repository old_digest new_digest
    journal=$1; repository=$2
    [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
    awk -F= '
        BEGIN { required["SCHEMA_VERSION"]=1; required["KIND"]=1; required["PHASE"]=1; required["REPOSITORY"]=1; required["OLD_PACKAGE_DIGEST"]=1; required["NEW_PACKAGE_DIGEST"]=1; required["UPDATED_AT"]=1 }
        NF != 2 || !($1 in required) || $2 == "" { bad=1; next }
        { count[$1]++ }
        END { for (key in required) if (count[key] != 1) bad=1; exit bad ? 1 : 0 }
    ' "$journal" || return 1
    schema=$(conf_get "$journal" SCHEMA_VERSION 2>/dev/null || printf '')
    kind=$(conf_get "$journal" KIND 2>/dev/null || printf '')
    phase=$(conf_get "$journal" PHASE 2>/dev/null || printf '')
    journal_repository=$(conf_get "$journal" REPOSITORY 2>/dev/null || printf '')
    old_digest=$(conf_get "$journal" OLD_PACKAGE_DIGEST 2>/dev/null || printf '')
    new_digest=$(conf_get "$journal" NEW_PACKAGE_DIGEST 2>/dev/null || printf '')
    [ "$schema" = 1 ] || return 1
    [ "$(package_absolute_path "$journal_repository")" = "$(package_absolute_path "$repository")" ] || return 1
    case "$kind" in INSTALL|UPGRADE) ;; *) return 1 ;; esac
    case "$phase" in PREPARED|STAGED|PUBLISHED|COMPLETED|ROLLED_BACK) ;; *) return 1 ;; esac
    case "$new_digest" in [0-9a-f][0-9a-f]*) [ "${#new_digest}" -eq 64 ] || return 1 ;; *) return 1 ;; esac
    if [ "$kind" = INSTALL ]; then [ "$old_digest" = NONE ] || return 1
    else case "$old_digest" in [0-9a-f][0-9a-f]*) [ "${#old_digest}" -eq 64 ] || return 1 ;; *) return 1 ;; esac; fi
    return 0
}

package_latest_journal() {
    local repository root
    repository=$1; root=$(package_operation_root "$repository")
    [ -d "$root" ] || return 1
    find "$root" -mindepth 2 -maxdepth 2 -name journal.conf -type f -print 2>/dev/null | LC_ALL=C sort | tail -n 1
}

package_recover() {
    local repository journal operation kind phase old_digest new_digest backup target
    repository=$1
    [ ! -L "$(package_operation_root "$repository")" ] || return 4
    package_path_is_within "$repository" "$(package_operation_root "$repository")" || return 4
    journal=$(package_latest_journal "$repository" 2>/dev/null || printf '')
    [ -n "$journal" ] || return 0
    package_journal_validate "$journal" "$repository" || return 4
    operation=$(dirname "$journal")
    package_path_is_within "$(package_operation_root "$repository")" "$operation" || return 4
    kind=$(conf_get "$journal" KIND 2>/dev/null || printf CORRUPT)
    phase=$(conf_get "$journal" PHASE 2>/dev/null || printf CORRUPT)
    old_digest=$(conf_get "$journal" OLD_PACKAGE_DIGEST 2>/dev/null || printf '')
    new_digest=$(conf_get "$journal" NEW_PACKAGE_DIGEST 2>/dev/null || printf '')
    target=$repository/.agent-harness
    case "$phase" in COMPLETED|ROLLED_BACK) return 0 ;; esac
    case "$kind" in
        INSTALL)
            if [ -d "$target" ] && package_contract_validate "$repository" 0 installed && [ "$(package_tree_digest "$repository" installed)" = "$new_digest" ]; then
                package_journal_write "$journal" COMPLETED INSTALL "$repository" NONE "$new_digest"
                return 0
            fi
            rm -rf "$target" "$operation/stage-root"
            package_journal_write "$journal" ROLLED_BACK INSTALL "$repository" NONE "$new_digest"
            ;;
        UPGRADE)
            if [ -d "$target" ] && package_contract_validate "$repository" 0 installed && [ "$(package_tree_digest "$repository" installed)" = "$new_digest" ]; then
                package_journal_write "$journal" COMPLETED UPGRADE "$repository" "$old_digest" "$new_digest"
                rm -rf "$operation/old-agent-harness" "$operation/backup-root" "$operation/state" "$operation/stage-root"
                return 0
            fi
            backup=$operation/backup-root
            [ -d "$backup/.agent-harness" ] || return 4
            package_contract_validate "$backup" 0 installed || return 4
            [ "$(package_tree_digest "$backup" installed)" = "$old_digest" ] || return 4
            rm -rf "$target"
            if [ -d "$operation/old-agent-harness" ]; then
                mv "$operation/old-agent-harness" "$target" || return 4
            else
                cp -Rp "$backup/.agent-harness" "$target" || return 4
            fi
            package_journal_write "$journal" ROLLED_BACK UPGRADE "$repository" "$old_digest" "$new_digest"
            ;;
        *) return 4 ;;
    esac
}
