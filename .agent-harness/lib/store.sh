#!/usr/bin/env bash

repository_worktree_id() {
    local root git_dir base
    root=$1
    if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null || printf '')
        case "$git_dir" in
            .git|*/.git) printf 'main\n' ;;
            *) base=$(basename "$git_dir"); identifier_validate "$base" && printf '%s\n' "$base" || printf '%s\n' "$(sha256_text "$git_dir" | cut -c1-16)" ;;
        esac
    else
        printf 'standalone\n'
    fi
}

repository_paths_supported() {
    local root path
    root=$1
    (
        cd "$root" || exit 1
        find . \
            \( -path './.git' -o -path './.agent-harness/runtime' -o -path './.agent-harness/tasks' -o -path './.agent-harness/runs' \) -prune -o \
            \( -type f -o -type l \) -print0 |
        while IFS= read -r -d '' path; do
            path=${path#./}
            path_text_supported "$path" || exit 4
        done
    )
}


harness_init_paths() {
    HARNESS_REPO_ROOT=$1
    HARNESS_DIR=$HARNESS_REPO_ROOT/.agent-harness
    HARNESS_POLICY_DIR=$HARNESS_DIR/policy
    HARNESS_COMMAND_DIR=$HARNESS_DIR/config/commands
    HARNESS_PROJECT_DIR=$HARNESS_DIR/project
    HARNESS_CONVENTIONS_DIR=$HARNESS_PROJECT_DIR/conventions
    HARNESS_RUNTIME_DIR=$HARNESS_DIR/runtime
    HARNESS_TASKS_DIR=$HARNESS_DIR/tasks
    HARNESS_RUNS_DIR=$HARNESS_DIR/runs
    HARNESS_ACTIVE_POINTER=$HARNESS_RUNTIME_DIR/active-run.conf
    HARNESS_GLOBAL_LOCK=$HARNESS_RUNTIME_DIR/.lock
    HARNESS_MANIFEST=$HARNESS_DIR/manifest.tsv
    HARNESS_WORKTREE_ID=$(repository_worktree_id "$HARNESS_REPO_ROOT")
    export HARNESS_REPO_ROOT HARNESS_DIR HARNESS_POLICY_DIR HARNESS_COMMAND_DIR HARNESS_PROJECT_DIR HARNESS_CONVENTIONS_DIR
    export HARNESS_RUNTIME_DIR HARNESS_TASKS_DIR HARNESS_RUNS_DIR HARNESS_ACTIVE_POINTER HARNESS_GLOBAL_LOCK HARNESS_MANIFEST HARNESS_WORKTREE_ID
}

legacy_runtime_migration_journal_write() {
    local status source_hash journal
    status=$1
    source_hash=$2
    journal=$HARNESS_RUNTIME_DIR/migration.conf
    {
        conf_write_pair MIGRATION legacy_workflow_metadata
        conf_write_pair STATUS "$status"
        conf_write_pair SOURCE_HASH "$source_hash"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$journal"
}

migrate_known_legacy_runtime() {
    local source journal history expected_hash source_hash status journal_hash
    source=$HARNESS_RUNTIME_DIR/v3-workflow.json
    journal=$HARNESS_RUNTIME_DIR/migration.conf
    history=$HARNESS_RUNTIME_DIR/migration-history.tsv
    expected_hash=720448e879e65b57d9345f1bacdfd49ec6c7fe85fded6023e5df4275ec42e5c0

    if [ ! -e "$source" ]; then
        if [ -f "$journal" ] && [ "$(conf_get "$journal" MIGRATION 2>/dev/null || printf '')" = legacy_workflow_metadata ]; then
            status=$(conf_get "$journal" STATUS 2>/dev/null || printf '')
            journal_hash=$(conf_get "$journal" SOURCE_HASH 2>/dev/null || printf '')
            if [ "$status" = PREPARED ] && grep -F "legacy_workflow_metadata"$'\t'"COMPLETED"$'\t'"$journal_hash"$'\t' "$history" >/dev/null 2>&1; then
                legacy_runtime_migration_journal_write COMPLETED "$journal_hash" || return 1
            fi
        fi
        return 0
    fi
    [ -f "$source" ] && [ ! -L "$source" ] || return 3
    source_hash=$(sha256_file "$source") || return 1
    [ "$source_hash" = "$expected_hash" ] || return 3
    if [ -f "$journal" ]; then
        [ "$(conf_get "$journal" MIGRATION 2>/dev/null || printf '')" = legacy_workflow_metadata ] || return 3
        journal_hash=$(conf_get "$journal" SOURCE_HASH 2>/dev/null || printf '')
        [ "$journal_hash" = "$source_hash" ] || return 3
    else
        legacy_runtime_migration_journal_write PREPARED "$source_hash" || return 1
    fi
    if ! grep -F "legacy_workflow_metadata"$'\t'"COMPLETED"$'\t'"$source_hash"$'\t' "$history" >/dev/null 2>&1; then
        printf '%s\t%s\t%s\t%s\n' legacy_workflow_metadata COMPLETED "$source_hash" "$(harness_now)" >>"$history" || return 1
    fi
    rm -f "$source" || return 1
    legacy_runtime_migration_journal_write COMPLETED "$source_hash"
}

harness_ensure_layout() {
    mkdir -p "$HARNESS_RUNTIME_DIR" "$HARNESS_TASKS_DIR" "$HARNESS_RUNS_DIR" "$HARNESS_COMMAND_DIR" "$HARNESS_CONVENTIONS_DIR"
    [ -f "$HARNESS_TASKS_DIR/index.tsv" ] || : >"$HARNESS_TASKS_DIR/index.tsv"
    [ -f "$HARNESS_PROJECT_DIR/modules.tsv" ] || : >"$HARNESS_PROJECT_DIR/modules.tsv"
    [ -f "$HARNESS_PROJECT_DIR/inventory-policy.tsv" ] || : >"$HARNESS_PROJECT_DIR/inventory-policy.tsv"
    [ -f "$HARNESS_CONVENTIONS_DIR/rules.tsv" ] || : >"$HARNESS_CONVENTIONS_DIR/rules.tsv"
    [ -f "$HARNESS_CONVENTIONS_DIR/exceptions.tsv" ] || : >"$HARNESS_CONVENTIONS_DIR/exceptions.tsv"
    [ -f "$HARNESS_CONVENTIONS_DIR/history.tsv" ] || : >"$HARNESS_CONVENTIONS_DIR/history.tsv"
    [ -f "$HARNESS_CONVENTIONS_DIR/applicability.tsv" ] || : >"$HARNESS_CONVENTIONS_DIR/applicability.tsv"
    [ -f "$HARNESS_CONVENTIONS_DIR/replacements.tsv" ] || : >"$HARNESS_CONVENTIONS_DIR/replacements.tsv"
    [ -f "$HARNESS_CONVENTIONS_DIR/candidate-origins.tsv" ] || : >"$HARNESS_CONVENTIONS_DIR/candidate-origins.tsv"
    [ -f "$HARNESS_PROJECT_DIR/project.conf" ] || : >"$HARNESS_PROJECT_DIR/project.conf"
    [ -f "$HARNESS_PROJECT_DIR/architecture.tsv" ] || : >"$HARNESS_PROJECT_DIR/architecture.tsv"
    [ -f "$HARNESS_PROJECT_DIR/nfrs.tsv" ] || : >"$HARNESS_PROJECT_DIR/nfrs.tsv"
    [ -f "$HARNESS_PROJECT_DIR/decisions.tsv" ] || : >"$HARNESS_PROJECT_DIR/decisions.tsv"
    [ -f "$HARNESS_PROJECT_DIR/interfaces.tsv" ] || : >"$HARNESS_PROJECT_DIR/interfaces.tsv"
    [ -f "$HARNESS_PROJECT_DIR/project-history.tsv" ] || : >"$HARNESS_PROJECT_DIR/project-history.tsv"
    [ -f "$HARNESS_PROJECT_DIR/identity-policy.conf" ] || {
        {
            conf_write_pair MODE DECLARATIVE
            conf_write_pair ENV_KEY '-'
            conf_write_pair VERIFIER_PATH '-'
            conf_write_pair VERIFIER_HASH '-'
            conf_write_pair TRUSTED_ISSUER '-'
            conf_write_pair UPDATED_BY system
            conf_write_pair UPDATED_AT "$(harness_now)"
        } | atomic_write "$HARNESS_PROJECT_DIR/identity-policy.conf" || return 1
    }
    [ -f "$HARNESS_PROJECT_DIR/external-anchor.conf" ] || : >"$HARNESS_PROJECT_DIR/external-anchor.conf"
    migrate_known_legacy_runtime || true
    if command -v conventions_ensure_history >/dev/null 2>&1; then
        conventions_ensure_history || return 1
    fi
}

inventory_find_paths() {
    local root
    root=$1
    repository_paths_supported "$root" || return $?
    (
        cd "$root" || exit 1
        find . \
            \( -path './.git' -o -path './.agent-harness/runtime' -o -path './.agent-harness/tasks' -o -path './.agent-harness/runs' \) -prune -o \
            \( -type f -o -type l \) -print
    ) | sed 's#^\./##' | LC_ALL=C sort
}

inventory_linked_task_paths() {
    local mount output task_id source pattern temporary result
    mount=$1
    output=$2
    temporary=$(mktemp "${TMPDIR:-/tmp}/harness-linked-paths.XXXXXX") || return 1
    : >"$temporary"
    task_id=$(active_task_id 2>/dev/null || printf '')
    if [ -n "$task_id" ] && [ -d "$(task_dir "$task_id")" ]; then
        for source in "$(task_dir "$task_id")/scopes.txt" "$(task_dir "$task_id")/read-context.txt"; do
            [ -f "$source" ] || continue
            while IFS= read -r pattern; do
                [ -n "$pattern" ] || continue
                case "$pattern" in
                    "$mount") rm -f "$temporary"; return 3 ;;
                    "$mount"/*)
                        safe_relative_path "$pattern" 0 >/dev/null || { rm -f "$temporary"; return 3; }
                        path_has_vcs_segment "$pattern" && { rm -f "$temporary"; return 3; }
                        printf '%s\n' "$pattern" >>"$temporary"
                        ;;
                esac
            done <"$source"
        done
    fi
    LC_ALL=C sort -u "$temporary" | atomic_write "$output"
    result=$?
    rm -f "$temporary"
    return "$result"
}

inventory_linked_file_write() {
    local mount resolved path output relative candidate current old_ifs segment restore_glob mode digest links kind
    mount=$1
    resolved=$2
    path=$3
    output=$4
    relative=${path#"$mount"/}
    [ -n "$relative" ] || return 3
    safe_relative_path "$relative" 0 >/dev/null || return 3
    path_has_vcs_segment "$relative" && return 3
    current=$resolved
    old_ifs=$IFS
    case $- in *f*) restore_glob=0 ;; *) restore_glob=1; set -f ;; esac
    IFS='/'
    set -- $relative
    IFS=$old_ifs
    [ "$restore_glob" -eq 0 ] || set +f
    for segment in "$@"; do
        current=$current/$segment
        [ ! -L "$current" ] || return 3
    done
    candidate=$(absolute_path "$resolved/$relative") || return 3
    case "$candidate" in "$resolved"/*) ;; *) return 3 ;; esac
    if [ -f "$candidate" ]; then
        links=$(file_nlink "$candidate") || return 1
        kind=F
        if [ "$links" -gt 1 ]; then
            inventory_policy_allows_hardlink "$path" || return 3
            kind=H
        fi
        mode=$(file_mode "$candidate") || return 1
        digest=$(sha256_file "$candidate") || return 1
        printf '%s\t%s\t%s\t%s\n' "$path" "$kind" "$mode" "$digest" >>"$output"
    elif [ ! -e "$candidate" ]; then
        [ -d "$(dirname "$candidate")" ] || return 3
        printf '%s\tM\t0\t%s\n' "$path" "$(sha256_text missing)" >>"$output"
    else
        return 3
    fi
}

inventory_write() {
    local root output temporary path absolute target resolved digest links mode result kind linked_paths linked_path
    root=$1
    output=$2
    temporary=$(mktemp "${TMPDIR:-/tmp}/harness-inventory.XXXXXX") || return 1
    : >"$temporary"
    inventory_find_paths "$root" | while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in *$'\n'*|*$'\r'*|*$'\t'*) rm -f "$temporary"; return 1 ;; esac
        if command -v inventory_policy_excluded >/dev/null 2>&1 && inventory_policy_excluded "$path"; then
            continue
        fi
        absolute=$root/$path
        if [ -L "$absolute" ]; then
            command -v inventory_policy_allows_symlink >/dev/null 2>&1 && inventory_policy_allows_symlink "$path" || { rm -f "$temporary"; return 3; }
            target=$(readlink "$absolute") || { rm -f "$temporary"; return 1; }
            case "$target" in /*) resolved=$(absolute_path "$target") ;; *) resolved=$(absolute_path "$(dirname "$absolute")/$target") ;; esac
            [ -e "$resolved" ] || { rm -f "$temporary"; return 3; }
            digest=$(sha256_text "$target|$resolved") || { rm -f "$temporary"; return 1; }
            printf '%s\tL\t0\t%s\n' "$path" "$digest" >>"$temporary"
            case "$resolved" in
                "$root"/*) ;;
                *)
                    command -v inventory_policy_exact_allows_symlink >/dev/null 2>&1 && inventory_policy_exact_allows_symlink "$path" || { rm -f "$temporary"; return 3; }
                    [ -d "$resolved" ] || { rm -f "$temporary"; return 3; }
                    path_has_vcs_segment "$path" && { rm -f "$temporary"; return 3; }
                    linked_paths=$(mktemp "${TMPDIR:-/tmp}/harness-linked-task-paths.XXXXXX") || { rm -f "$temporary"; return 1; }
                    inventory_linked_task_paths "$path" "$linked_paths" || { result=$?; rm -f "$temporary" "$linked_paths"; return "$result"; }
                    while IFS= read -r linked_path; do
                        [ -n "$linked_path" ] || continue
                        inventory_linked_file_write "$path" "$resolved" "$linked_path" "$temporary" || { result=$?; rm -f "$temporary" "$linked_paths"; return "$result"; }
                    done <"$linked_paths"
                    rm -f "$linked_paths"
                    ;;
            esac
        elif [ -f "$absolute" ]; then
            links=$(file_nlink "$absolute") || { rm -f "$temporary"; return 1; }
            kind=F
            if [ "$links" -gt 1 ]; then
                command -v inventory_policy_allows_hardlink >/dev/null 2>&1 && inventory_policy_allows_hardlink "$path" || { rm -f "$temporary"; return 3; }
                kind=H
            fi
            mode=$(file_mode "$absolute") || { rm -f "$temporary"; return 1; }
            digest=$(sha256_file "$absolute") || { rm -f "$temporary"; return 1; }
            printf '%s\t%s\t%s\t%s\n' "$path" "$kind" "$mode" "$digest" >>"$temporary"
        else
            rm -f "$temporary"
            return 1
        fi
    done
    result=$?
    if [ "$result" -ne 0 ]; then
        rm -f "$temporary"
        return "$result"
    fi
    LC_ALL=C sort "$temporary" | atomic_write "$output"
    result=$?
    rm -f "$temporary"
    return "$result"
}

inventory_hash() {
    local file
    file=$1
    sha256_file "$file"
}

inventory_changed_paths() {
    local before after output
    before=$1
    after=$2
    output=$3
    awk -F '\t' '
        NR == FNR { old[$1] = $0; next }
        { now[$1] = $0; if (!($1 in old) || old[$1] != $0) changed[$1] = 1 }
        END {
            for (path in old) if (!(path in now)) changed[path] = 1
            for (path in changed) print path
        }' "$before" "$after" | LC_ALL=C sort | atomic_write "$output"
}

inventory_lookup_hash() {
    local inventory path
    inventory=$1
    path=$2
    awk -F '\t' -v wanted="$path" '$1 == wanted {print $4; exit}' "$inventory"
}

inventory_filter_transient() {
    local input output path kind mode digest transient pattern
    input=$1
    output=$2
    while IFS=$'\t' read -r path kind mode digest; do
        transient=0
        while IFS= read -r pattern; do
            [ -n "$pattern" ] || continue
            if path_matches "$path" "$pattern"; then transient=1; break; fi
        done <"$HARNESS_POLICY_DIR/transient-paths.txt"
        [ "$transient" -eq 1 ] || printf '%s\t%s\t%s\t%s\n' "$path" "$kind" "$mode" "$digest"
    done <"$input" | atomic_write "$output"
}

copy_repository_workspace() {
    local destination inventory list external_mounts path kind mode digest mount source resolved is_external expected actual
    destination=$1
    inventory=${2:-}
    mkdir -p "$destination"
    if [ -n "$inventory" ] && [ -f "$inventory" ]; then
        list=$(mktemp "${TMPDIR:-/tmp}/harness-copy-list.XXXXXX") || return 1
        external_mounts=$(mktemp "${TMPDIR:-/tmp}/harness-copy-linked.XXXXXX") || { rm -f "$list"; return 1; }
        : >"$list"; : >"$external_mounts"
        while IFS=$'\t' read -r path kind mode digest; do
            [ "$kind" = L ] || continue
            source=$HARNESS_REPO_ROOT/$path
            [ -L "$source" ] || continue
            resolved=$(absolute_path "$source") || { rm -f "$list" "$external_mounts"; return 1; }
            case "$resolved" in "$HARNESS_REPO_ROOT"/*) ;; *) printf '%s\n' "$path" >>"$external_mounts" ;; esac
        done <"$inventory"
        while IFS=$'\t' read -r path kind mode digest; do
            [ "$kind" != M ] || continue
            is_external=0
            while IFS= read -r mount; do
                case "$path" in "$mount"|"$mount"/*) is_external=1; break ;; esac
            done <"$external_mounts"
            [ "$is_external" -eq 1 ] || printf '%s\n' "$path" >>"$list"
        done <"$inventory"
        if [ -s "$list" ]; then
            (
                cd "$HARNESS_REPO_ROOT" || exit 1
                tar -cf - -T "$list"
            ) | (
                cd "$destination" || exit 1
                tar -xf -
            ) || { rm -f "$list" "$external_mounts"; return 1; }
        fi
        while IFS=$'\t' read -r path kind mode digest; do
            case "$kind" in F|H) ;; *) continue ;; esac
            is_external=0
            while IFS= read -r mount; do
                case "$path" in "$mount"/*) is_external=1; break ;; esac
            done <"$external_mounts"
            [ "$is_external" -eq 1 ] || continue
            source=$HARNESS_REPO_ROOT/$path
            [ -f "$source" ] && [ ! -L "$source" ] || { rm -f "$list" "$external_mounts"; return 1; }
            mkdir -p "$destination/$(dirname "$path")" || { rm -f "$list" "$external_mounts"; return 1; }
            cp -p "$source" "$destination/$path" || { rm -f "$list" "$external_mounts"; return 1; }
            expected=$digest; actual=$(sha256_file "$destination/$path") || { rm -f "$list" "$external_mounts"; return 1; }
            [ "$actual" = "$expected" ] || { rm -f "$list" "$external_mounts"; return 3; }
        done <"$inventory"
        rm -f "$list" "$external_mounts"
    else
        (
            cd "$HARNESS_REPO_ROOT" || exit 1
            tar -cf - .
        ) | (
            cd "$destination" || exit 1
            tar -xf -
        ) || return 1
    fi
    rm -rf "$destination/.git" "$destination/.agent-harness/runtime" "$destination/.agent-harness/tasks" "$destination/.agent-harness/runs"
    mkdir -p "$destination/.agent-harness/runtime" "$destination/.agent-harness/tasks" "$destination/.agent-harness/runs"
}

copy_workspace_tree() {
    local source destination
    source=$1
    destination=$2
    rm -rf "$destination"
    mkdir -p "$destination" || return 1
    (cd "$source" && tar -cf - .) | (cd "$destination" && tar -xf -) || return 1
}

workspace_git_snapshot() {
    local workspace mode
    workspace=$1
    mode=$2
    rm -rf "$workspace/.git"
    [ "$mode" = "READ_ONLY_SNAPSHOT" ] || return 0
    command -v git >/dev/null 2>&1 || return 1
    (
        cd "$workspace" || exit 1
        git init -q || exit 1
        git config user.name 'Harness Snapshot' || exit 1
        git config user.email 'harness@invalid.local' || exit 1
        git add -A || exit 1
        git commit -qm 'verified snapshot' --no-gpg-sign || exit 1
        git tag harness-snapshot >/dev/null 2>&1 || true
        chmod -R a-w .git 2>/dev/null || true
    )
}

cleanup_workspace_transients() {
    local root pattern
    root=$1
    while IFS= read -r pattern; do
        [ -n "$pattern" ] || continue
        # Only predefined transient patterns are accepted. Use find by basename for portability.
        case "$pattern" in
            '**/__pycache__/**') find "$root" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true ;;
            '**/*.pyc') find "$root" -type f -name '*.pyc' -delete 2>/dev/null || true ;;
            '**/.pytest_cache/**') find "$root" -type d -name '.pytest_cache' -prune -exec rm -rf {} + 2>/dev/null || true ;;
            '**/.coverage') find "$root" -type f -name '.coverage' -delete 2>/dev/null || true ;;
            '**/coverage.out') find "$root" -type f -name 'coverage.out' -delete 2>/dev/null || true ;;
        esac
    done <"$HARNESS_POLICY_DIR/transient-paths.txt"
}

active_pointer_validate() {
    local task_id run_id worktree state_file
    [ -e "$HARNESS_ACTIVE_POINTER" ] || return 1
    [ -f "$HARNESS_ACTIVE_POINTER" ] && [ ! -L "$HARNESS_ACTIVE_POINTER" ] || return 2
    awk -F= '
        BEGIN { required["TASK_ID"]=1; required["RUN_ID"]=1; required["WORKTREE_ID"]=1; required["UPDATED_AT"]=1 }
        NF != 2 || !($1 in required) || $2 == "" { bad=1; next }
        { count[$1]++ }
        END {
            for (key in required) if (count[key] != 1) bad=1
            exit bad ? 1 : 0
        }
    ' "$HARNESS_ACTIVE_POINTER" || return 2
    task_id=$(conf_get "$HARNESS_ACTIVE_POINTER" TASK_ID 2>/dev/null || printf '')
    run_id=$(conf_get "$HARNESS_ACTIVE_POINTER" RUN_ID 2>/dev/null || printf '')
    worktree=$(conf_get "$HARNESS_ACTIVE_POINTER" WORKTREE_ID 2>/dev/null || printf '')
    identifier_validate "$task_id" && identifier_validate "$run_id" || return 2
    [ "$worktree" = "$HARNESS_WORKTREE_ID" ] || return 2
    [ -d "$(task_dir "$task_id")" ] && [ -d "$(run_dir "$run_id")" ] || return 2
    state_file=$(run_state_file "$run_id")
    [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 2
    [ "$(conf_get "$state_file" RUN_ID 2>/dev/null || printf '')" = "$run_id" ] || return 2
    [ "$(conf_get "$state_file" TASK_ID 2>/dev/null || printf '')" = "$task_id" ] || return 2
    [ "$(conf_get "$state_file" WORKTREE_ID 2>/dev/null || printf '')" = "$HARNESS_WORKTREE_ID" ] || return 2
    return 0
}

active_pointer_absent() { [ ! -e "$HARNESS_ACTIVE_POINTER" ]; }

active_run_id() {
    active_pointer_validate || return $?
    conf_get "$HARNESS_ACTIVE_POINTER" RUN_ID
}

active_task_id() {
    active_pointer_validate || return $?
    conf_get "$HARNESS_ACTIVE_POINTER" TASK_ID
}

write_active_pointer() {
    local task_id run_id
    task_id=$1
    run_id=$2
    {
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair RUN_ID "$run_id"
        conf_write_pair WORKTREE_ID "$HARNESS_WORKTREE_ID"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$HARNESS_ACTIVE_POINTER"
}

deactivate_run() {
    rm -f "$HARNESS_ACTIVE_POINTER"
}

run_dir() { printf '%s/%s\n' "$HARNESS_RUNS_DIR" "$1"; }
task_dir() { printf '%s/%s\n' "$HARNESS_TASKS_DIR" "$1"; }

run_state_file() { printf '%s/state.conf\n' "$(run_dir "$1")"; }
run_events_file() { printf '%s/events.tsv\n' "$(run_dir "$1")"; }

state_get() {
    local run_id key
    run_id=$1
    key=$2
    conf_get "$(run_state_file "$run_id")" "$key"
}

write_state() {
    local run_id task_id state failure_count hold predecessor
    run_id=$1
    task_id=$2
    state=$3
    failure_count=$4
    hold=${5:-}
    predecessor=${6:-}
    {
        conf_write_pair RUN_ID "$run_id"
        conf_write_pair TASK_ID "$task_id"
        conf_write_pair STATE "$state"
        conf_write_pair FAILURE_COUNT "$failure_count"
        conf_write_pair HOLD "$hold"
        conf_write_pair PREDECESSOR_RUN_ID "$predecessor"
        conf_write_pair WORKTREE_ID "$HARNESS_WORKTREE_ID"
        conf_write_pair UPDATED_AT "$(harness_now)"
    } | atomic_write "$(run_state_file "$run_id")"
}

write_projection() {
    local run_id state_file task_id state failures hold
    run_id=$1
    state_file=$(run_state_file "$run_id")
    task_id=$(conf_get "$state_file" TASK_ID)
    state=$(conf_get "$state_file" STATE)
    failures=$(conf_get "$state_file" FAILURE_COUNT)
    hold=$(conf_get "$state_file" HOLD 2>/dev/null || printf '')
    {
        printf '# Harness Run\n\n'
        printf -- '- Task: `%s`\n' "$task_id"
        printf -- '- Run: `%s`\n' "$run_id"
        printf -- '- State: `%s`\n' "$state"
        printf -- '- Failures: `%s`\n' "$failures"
        if [ -n "$hold" ]; then printf -- '- Hold: `%s`\n' "$hold"; fi
    } | atomic_write "$(run_dir "$run_id")/current.md"
}

append_event() {
    local run_id from to owner reason events sequence previous timestamp payload event_hash
    run_id=$1
    from=$2
    to=$3
    owner=$4
    reason=$5
    events=$(run_events_file "$run_id")
    mkdir -p "$(dirname "$events")"
    [ -f "$events" ] || : >"$events"
    sequence=$(( $(wc -l <"$events" | tr -d ' ') + 1 ))
    previous=$(tail -n 1 "$events" 2>/dev/null | awk -F '\t' '{print $8}')
    [ -n "$previous" ] || previous=GENESIS
    reason=$(printf '%s' "$reason" | tr '\t\r\n' '   ')
    timestamp=$(harness_now)
    payload=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$sequence" "$timestamp" "$from" "$to" "$owner" "$reason" "$previous")
    event_hash=$(sha256_text "$payload") || return 1
    printf '%s\t%s\n' "$payload" "$event_hash" >>"$events"
}

validate_event_log() {
    local run_id events expected_sequence previous last_to sequence timestamp from to owner reason recorded_previous event_hash extra payload calculated required_owner initial
    run_id=$1
    events=$(run_events_file "$run_id")
    [ -f "$events" ] || return 1
    expected_sequence=1
    previous=GENESIS
    last_to=""
    initial=$(workflow_initial_state)
    while IFS=$'\t' read -r sequence timestamp from to owner reason recorded_previous event_hash extra; do
        [ -z "$extra" ] || return 1
        [ -n "$reason" ] || return 1
        [ "$sequence" = "$expected_sequence" ] || return 1
        [ "$recorded_previous" = "$previous" ] || return 1
        payload=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$sequence" "$timestamp" "$from" "$to" "$owner" "$reason" "$recorded_previous")
        calculated=$(sha256_text "$payload") || return 1
        [ "$calculated" = "$event_hash" ] || return 1
        if [ "$expected_sequence" -eq 1 ]; then
            [ "$from" = "NO_TASK" ] && [ "$to" = "$initial" ] && [ "$owner" = "system" ] || return 1
        else
            [ "$from" = "$last_to" ] || return 1
            workflow_transition_allowed "$from" "$to" || return 1
            required_owner=$(workflow_owner "$to" 2>/dev/null || printf '')
            if [ -n "$required_owner" ]; then [ "$owner" = "$required_owner" ] || return 1; fi
        fi
        last_to=$to
        previous=$event_hash
        expected_sequence=$((expected_sequence + 1))
    done <"$events"
    [ "$expected_sequence" -gt 1 ] || return 1
    printf '%s\n' "$last_to"
}

validate_event_chain() {
    local run_id last_state state
    run_id=$1
    last_state=$(validate_event_log "$run_id") || return 1
    state=$(state_get "$run_id" STATE)
    [ "$last_state" = "$state" ]
}

repair_state_from_events() {
    local run_id last_state state_file task_id failures hold predecessor
    run_id=$1
    last_state=$(validate_event_log "$run_id") || return 1
    state_file=$(run_state_file "$run_id")
    task_id=$(conf_get "$state_file" TASK_ID 2>/dev/null || active_task_id 2>/dev/null || printf '')
    [ -n "$task_id" ] || return 1
    failures=$(conf_get "$state_file" FAILURE_COUNT 2>/dev/null || printf 0)
    hold=$(conf_get "$state_file" HOLD 2>/dev/null || printf '')
    predecessor=$(conf_get "$state_file" PREDECESSOR_RUN_ID 2>/dev/null || printf '')
    write_state "$run_id" "$task_id" "$last_state" "$failures" "$hold" "$predecessor" || return 1
    write_projection "$run_id"
}

new_id() {
    local prefix
    prefix=$1
    printf '%s-%s-%05d\n' "$prefix" "$(date -u '+%Y%m%d%H%M%S')" "$RANDOM"
}

package_integrity_check() {
    local actual declared
    package_contract_validate "$HARNESS_REPO_ROOT" 0 installed || return 1
    actual=$(package_tree_digest "$HARNESS_REPO_ROOT" installed) || return 1
    declared=${HARNESS_DECLARED_PACKAGE_DIGEST:-}
    [ -z "$declared" ] || [ "$declared" = "$actual" ] || return 1
    if [ -n "${HARNESS_EXECUTED_PACKAGE_DIGEST:-}" ]; then
        [ "$HARNESS_EXECUTED_PACKAGE_DIGEST" = "$actual" ] || return 1
    fi
    return 0
}

render_task_index() {
    local output temporary run_map directory task_id spec title status latest_run run run_task
    output=$1
    temporary=$(mktemp "${TMPDIR:-/tmp}/harness-index.XXXXXX") || return 1
    run_map=$(mktemp "${TMPDIR:-/tmp}/harness-run-map.XXXXXX") || { rm -f "$temporary"; return 1; }
    : >"$temporary"; : >"$run_map"
    for run in "$HARNESS_RUNS_DIR"/*; do
        [ -d "$run" ] || continue
        run_task=$(conf_get "$run/state.conf" TASK_ID 2>/dev/null || printf '')
        [ -n "$run_task" ] && printf '%s	%s
' "$run_task" "$(basename "$run")" >>"$run_map"
    done
    for directory in "$HARNESS_TASKS_DIR"/*; do
        [ -d "$directory" ] || continue
        task_id=$(basename "$directory")
        spec=$directory/spec.conf
        [ -f "$spec" ] || continue
        title=$(conf_get "$spec" TITLE 2>/dev/null || printf '')
        status=$(conf_get "$spec" STATUS 2>/dev/null || printf '')
        latest_run=$(awk -F '	' -v wanted="$task_id" '$1 == wanted {value=$2} END {print value}' "$run_map")
        printf '%s	%s	%s	%s
' "$task_id" "$status" "$latest_run" "$title" >>"$temporary"
    done
    LC_ALL=C sort "$temporary" >"$output"
    result=$?
    rm -f "$temporary" "$run_map"
    return "$result"
}

rebuild_task_index() {
    local temporary result
    temporary=$(mktemp "${TMPDIR:-/tmp}/harness-index-rendered.XXXXXX") || return 1
    render_task_index "$temporary" || { rm -f "$temporary"; return 1; }
    cat "$temporary" | atomic_write "$HARNESS_TASKS_DIR/index.tsv"
    result=$?
    rm -f "$temporary"
    return "$result"
}

# Build an ephemeral authority view for read-only commands on a clean package.
# This prevents audit, doctor, status, and next from materializing repository
# state merely by inspecting an uninitialized installation.
harness_readonly_view_begin() {
    local empty_data
    HARNESS_READONLY_VIEW=''
    empty_data=1
    for candidate in "$HARNESS_RUNTIME_DIR" "$HARNESS_TASKS_DIR" "$HARNESS_RUNS_DIR" "$HARNESS_PROJECT_DIR"; do
        [ ! -e "$candidate" ] || empty_data=0
    done
    [ "$empty_data" -eq 1 ] || return 0
    HARNESS_READONLY_VIEW=$(mktemp -d "${TMPDIR:-/tmp}/harness-readonly.XXXXXX") || return 1
    HARNESS_ORIGINAL_RUNTIME_DIR=$HARNESS_RUNTIME_DIR
    HARNESS_ORIGINAL_TASKS_DIR=$HARNESS_TASKS_DIR
    HARNESS_ORIGINAL_RUNS_DIR=$HARNESS_RUNS_DIR
    HARNESS_ORIGINAL_PROJECT_DIR=$HARNESS_PROJECT_DIR
    HARNESS_ORIGINAL_CONVENTIONS_DIR=$HARNESS_CONVENTIONS_DIR
    HARNESS_ORIGINAL_COMMAND_DIR=$HARNESS_COMMAND_DIR
    HARNESS_ORIGINAL_ACTIVE_POINTER=$HARNESS_ACTIVE_POINTER
    HARNESS_ORIGINAL_GLOBAL_LOCK=$HARNESS_GLOBAL_LOCK
    HARNESS_RUNTIME_DIR=$HARNESS_READONLY_VIEW/runtime
    HARNESS_TASKS_DIR=$HARNESS_READONLY_VIEW/tasks
    HARNESS_RUNS_DIR=$HARNESS_READONLY_VIEW/runs
    HARNESS_PROJECT_DIR=$HARNESS_READONLY_VIEW/project
    HARNESS_CONVENTIONS_DIR=$HARNESS_PROJECT_DIR/conventions
    HARNESS_COMMAND_DIR=$HARNESS_READONLY_VIEW/config/commands
    HARNESS_ACTIVE_POINTER=$HARNESS_RUNTIME_DIR/active-run.conf
    HARNESS_GLOBAL_LOCK=$HARNESS_RUNTIME_DIR/.lock
    mkdir -p "$HARNESS_RUNTIME_DIR" "$HARNESS_TASKS_DIR" "$HARNESS_RUNS_DIR" "$HARNESS_CONVENTIONS_DIR" "$HARNESS_COMMAND_DIR" || return 1
    if [ -d "$HARNESS_ORIGINAL_COMMAND_DIR" ]; then
        cp -Rp "$HARNESS_ORIGINAL_COMMAND_DIR/." "$HARNESS_COMMAND_DIR/" || return 1
    fi
    : >"$HARNESS_TASKS_DIR/index.tsv"
    : >"$HARNESS_PROJECT_DIR/modules.tsv"
    : >"$HARNESS_PROJECT_DIR/inventory-policy.tsv"
    : >"$HARNESS_CONVENTIONS_DIR/rules.tsv"
    : >"$HARNESS_CONVENTIONS_DIR/exceptions.tsv"
    : >"$HARNESS_CONVENTIONS_DIR/history.tsv"
    : >"$HARNESS_CONVENTIONS_DIR/applicability.tsv"
    : >"$HARNESS_CONVENTIONS_DIR/replacements.tsv"
    : >"$HARNESS_CONVENTIONS_DIR/candidate-origins.tsv"
    : >"$HARNESS_PROJECT_DIR/project.conf"
    : >"$HARNESS_PROJECT_DIR/architecture.tsv"
    : >"$HARNESS_PROJECT_DIR/nfrs.tsv"
    : >"$HARNESS_PROJECT_DIR/decisions.tsv"
    : >"$HARNESS_PROJECT_DIR/interfaces.tsv"
    : >"$HARNESS_PROJECT_DIR/project-history.tsv"
    : >"$HARNESS_PROJECT_DIR/external-anchor.conf"
    {
        conf_write_pair MODE DECLARATIVE
        conf_write_pair ENV_KEY '-'
        conf_write_pair VERIFIER_PATH '-'
        conf_write_pair VERIFIER_HASH '-'
        conf_write_pair TRUSTED_ISSUER '-'
        conf_write_pair UPDATED_BY system
        conf_write_pair UPDATED_AT '1970-01-01T00:00:00Z'
    } >"$HARNESS_PROJECT_DIR/identity-policy.conf"
    if command -v conventions_ensure_history >/dev/null 2>&1; then conventions_ensure_history || return 1; fi
    export HARNESS_RUNTIME_DIR HARNESS_TASKS_DIR HARNESS_RUNS_DIR HARNESS_PROJECT_DIR HARNESS_CONVENTIONS_DIR HARNESS_COMMAND_DIR HARNESS_ACTIVE_POINTER HARNESS_GLOBAL_LOCK
}

harness_readonly_view_end() {
    [ -n "${HARNESS_READONLY_VIEW:-}" ] || return 0
    HARNESS_RUNTIME_DIR=$HARNESS_ORIGINAL_RUNTIME_DIR
    HARNESS_TASKS_DIR=$HARNESS_ORIGINAL_TASKS_DIR
    HARNESS_RUNS_DIR=$HARNESS_ORIGINAL_RUNS_DIR
    HARNESS_PROJECT_DIR=$HARNESS_ORIGINAL_PROJECT_DIR
    HARNESS_CONVENTIONS_DIR=$HARNESS_ORIGINAL_CONVENTIONS_DIR
    HARNESS_COMMAND_DIR=$HARNESS_ORIGINAL_COMMAND_DIR
    HARNESS_ACTIVE_POINTER=$HARNESS_ORIGINAL_ACTIVE_POINTER
    HARNESS_GLOBAL_LOCK=$HARNESS_ORIGINAL_GLOBAL_LOCK
    rm -rf "$HARNESS_READONLY_VIEW"
    HARNESS_READONLY_VIEW=''
    export HARNESS_RUNTIME_DIR HARNESS_TASKS_DIR HARNESS_RUNS_DIR HARNESS_PROJECT_DIR HARNESS_CONVENTIONS_DIR HARNESS_COMMAND_DIR HARNESS_ACTIVE_POINTER HARNESS_GLOBAL_LOCK
}
