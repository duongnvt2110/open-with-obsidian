#!/usr/bin/env bash

conventions_inspection_schema_validate() {
    local file category description confidence matches total examples method limitations extra example old_ifs
    file=$1
    while IFS=$'\t' read -r category description confidence matches total examples method limitations extra; do
        [ -n "$category$description$confidence$matches$total$examples$method$limitations$extra" ] || continue
        [ -z "$extra" ] || return 1
        conventions_category_exists "$category" || return 1
        case "$confidence" in LOW|MEDIUM|HIGH) ;; *) return 1 ;; esac
        case "$matches:$total" in *[!0-9:]*|:*) return 1 ;; esac
        [ "$matches" -le "$total" ] || return 1
        [ -n "$(trim_space "$description")" ] && [ -n "$(trim_space "$method")" ] && [ -n "$(trim_space "$limitations")" ] || return 1
        old_ifs=$IFS; IFS=,
        for example in $examples; do
            [ -n "$example" ] || continue
            [ "$example" = "-" ] && continue
            safe_relative_path "$example" 0 >/dev/null || { IFS=$old_ifs; return 1; }
        done
        IFS=$old_ifs
    done <"$file"
}

conventions_inspect_repository() {
    local output report metadata temporary observation inventory workspace inspector_artifacts checks_file toolchain_bindings empty_bindings empty_exceptions file id purpose result_line result category description confidence matches total examples method limitations extra generated context_total wrap_total constructor_total tree_hash check_workspace
    acquire_lock "$HARNESS_GLOBAL_LOCK" inspect || return 2
    trap cleanup_common EXIT INT TERM
    output=$HARNESS_RUNTIME_DIR/convention-observations.tsv
    report=$HARNESS_RUNTIME_DIR/convention-inspection-report.md
    metadata=$HARNESS_RUNTIME_DIR/inspection.conf
    temporary=$(mktemp "${TMPDIR:-/tmp}/convention-observations.XXXXXX") || return 1
    inventory=$(mktemp "${TMPDIR:-/tmp}/inspection-inventory.XXXXXX") || return 1
    : >"$temporary"; observation=0
    inventory_write "$HARNESS_REPO_ROOT" "$inventory" || return 1
    tree_hash=$(inventory_hash "$inventory") || return 1
    inspect_add() {
        observation=$((observation + 1))
        printf 'OBS-%03d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$observation" "$1" "$(conventions_sanitize_field "$2")" "$3" "$4" "$5" "$(conventions_sanitize_field "$6")" "$(conventions_sanitize_field "$7")" "$(conventions_sanitize_field "$8")" >>"$temporary"
    }
    [ -f "$HARNESS_REPO_ROOT/go.mod" ] && inspect_add repository "Go module detected" HIGH 1 1 go.mod "file presence" "Architecture still requires human review"
    [ -f "$HARNESS_REPO_ROOT/package.json" ] && inspect_add repository "Node package detected" HIGH 1 1 package.json "file presence" "Workspace packages may use different conventions"
    [ -f "$HARNESS_REPO_ROOT/Gemfile" ] && inspect_add repository "Ruby bundle detected" HIGH 1 1 Gemfile "file presence" "Framework conventions still require human review"
    [ -f "$HARNESS_REPO_ROOT/pyproject.toml" ] && inspect_add repository "Python project detected" HIGH 1 1 pyproject.toml "file presence" "Multiple Python tools may share this file"
    [ -f "$HARNESS_REPO_ROOT/Makefile" ] && inspect_add build "Makefile build entry point detected" HIGH 1 1 Makefile "file presence" "Targets are evidence, not automatically authoritative"
    [ -f "$HARNESS_REPO_ROOT/AGENTS.md" ] && inspect_add documentation "Repository instructions detected" HIGH 1 1 AGENTS.md "authoritative document presence" "Human must confirm current applicability"
    file=$(find "$HARNESS_REPO_ROOT" -maxdepth 4 -type f \( -iname '*adr*' -o -path '*/adr/*' -o -iname 'architecture.md' \) -print 2>/dev/null | sed -n '1p')
    [ -n "$file" ] && inspect_add decisions "Architecture decision documentation detected" HIGH 1 1 "${file#"$HARNESS_REPO_ROOT/"}" "document discovery" "Documents may be historical or superseded"
    file=$(find "$HARNESS_REPO_ROOT/.github/workflows" -type f 2>/dev/null | sed -n '1p')
    [ -n "$file" ] && inspect_add build "CI workflow detected" HIGH 1 1 "${file#"$HARNESS_REPO_ROOT/"}" "workflow discovery" "CI commands require human selection as checks"
    for file in .golangci.yml .golangci.yaml .rubocop.yml .eslintrc .eslintrc.json eslint.config.js pyproject.toml; do
        [ -f "$HARNESS_REPO_ROOT/$file" ] && inspect_add naming "Lint or formatting configuration detected" HIGH 1 1 "$file" "configuration presence" "A configuration file may contain disabled or legacy rules"
    done
    for file in openapi.yaml openapi.yml swagger.yaml swagger.yml; do
        [ -f "$HARNESS_REPO_ROOT/$file" ] && inspect_add compatibility "API specification detected" HIGH 1 1 "$file" "contract presence" "Compatibility policy still requires human approval"
    done
    [ -d "$HARNESS_REPO_ROOT/db/migrations" ] && inspect_add migrations "Database migration directory detected" HIGH 1 1 db/migrations "directory presence" "Migration safety rules require human approval"
    [ -d "$HARNESS_REPO_ROOT/internal/repository" ] && inspect_add persistence "Repository implementation directory detected" MEDIUM 1 1 internal/repository "directory presence" "Placement does not prove interface or transaction conventions"
    [ -d "$HARNESS_REPO_ROOT/tests" ] && inspect_add testing "Top-level tests directory detected" MEDIUM 1 1 tests "directory presence" "Other test locations may also exist"
    [ -d "$HARNESS_REPO_ROOT/vendor" ] && inspect_add repository "Vendored content detected" HIGH 1 1 vendor "directory presence" "Vendored files should normally be excluded from convention inference"
    [ -d "$HARNESS_REPO_ROOT/node_modules" ] && inspect_add repository "Dependency installation directory detected" HIGH 1 1 node_modules "directory presence" "Consider an approved inventory exclusion"
    generated=$(find "$HARNESS_REPO_ROOT" -type f \( -name '*.generated.*' -o -name '*_generated.go' -o -name '*.gen.go' \) 2>/dev/null | awk 'NR <= 5' | sed "s#^$HARNESS_REPO_ROOT/##" | awk 'BEGIN{first=1} {if(!first) printf ","; printf "%s", $0; first=0} END{if(!first) printf "\n"}')
    [ -n "$generated" ] && inspect_add generation "Generated source files detected" MEDIUM 1 1 "$generated" "filename-pattern scan" "Filename patterns are heuristic"
    if [ -f "$HARNESS_REPO_ROOT/go.mod" ]; then
        context_total=$(grep -R --include='*.go' -l 'context\.Context' "$HARNESS_REPO_ROOT" 2>/dev/null | grep -v '/vendor/' | wc -l | tr -d ' ')
        [ "$context_total" -gt 0 ] && inspect_add functions "context.Context usage detected in Go source" MEDIUM "$context_total" "$context_total" "-" "text-pattern scan" "Does not parse signatures"
        wrap_total=$(grep -R --include='*.go' -l 'fmt\.Errorf.*%w' "$HARNESS_REPO_ROOT" 2>/dev/null | grep -v '/vendor/' | wc -l | tr -d ' ')
        [ "$wrap_total" -gt 0 ] && inspect_add errors "Go error wrapping with %w detected" MEDIUM "$wrap_total" "$wrap_total" "-" "text-pattern scan" "Does not prove consistent boundary ownership"
        constructor_total=$(grep -R --include='*.go' -h '^func New[A-Z]' "$HARNESS_REPO_ROOT" 2>/dev/null | wc -l | tr -d ' ')
        [ "$constructor_total" -gt 0 ] && inspect_add constructors "New<Type> constructor pattern detected" MEDIUM "$constructor_total" "$constructor_total" "-" "text-pattern scan" "Does not distinguish factories from constructors"
    fi
    # Custom inspectors run independently against the same immutable repository snapshot.
    checks_file=$(mktemp "${TMPDIR:-/tmp}/inspection-checks.XXXXXX") || return 1
    : >"$checks_file"
    for file in "$HARNESS_COMMAND_DIR"/*.conf; do
        [ -f "$file" ] || continue
        id=$(basename "$file" .conf)
        purpose=$(command_get "$id" PURPOSE 2>/dev/null || printf VERIFICATION)
        [ "$purpose" = INSPECTION ] && printf '%s\n' "$id" >>"$checks_file"
    done
    if [ -s "$checks_file" ]; then
        workspace=$(make_temp_dir harness-inspection-base) || return 1
        copy_repository_workspace "$workspace" "$inventory" || return 1
        inspector_artifacts=$HARNESS_RUNTIME_DIR/inspection-checks; mkdir -p "$inspector_artifacts"
        toolchain_bindings=$(mktemp "${TMPDIR:-/tmp}/inspection-toolchain.XXXXXX") || return 1
        empty_bindings=$(mktemp "${TMPDIR:-/tmp}/inspection-bindings.XXXXXX") || return 1
        empty_exceptions=$(mktemp "${TMPDIR:-/tmp}/inspection-exceptions.XXXXXX") || return 1
        : >"$empty_bindings"; : >"$empty_exceptions"
        write_toolchain_bindings "$checks_file" "$toolchain_bindings" || return 1
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            check_workspace=$(make_temp_dir "harness-inspector-$id") || return 1
            result_line=$(run_check "$id" "$workspace" "$inspector_artifacts" "$empty_bindings" "$toolchain_bindings" "$empty_exceptions" "$check_workspace"); result=$?
            rm -rf "$check_workspace"
            if [ "$result" -eq 0 ]; then
                conventions_inspection_schema_validate "$inspector_artifacts/$id.log" || return 1
                while IFS=$'\t' read -r category description confidence matches total examples method limitations extra; do
                    [ -n "$category$description" ] || continue
                    inspect_add "$category" "$description" "$confidence" "$matches" "$total" "$examples" "custom:$id:$method" "$limitations"
                done <"$inspector_artifacts/$id.log"
            else
                inspect_add repository "Custom inspector $id failed" LOW 0 1 "$id" "registered inspector" "Review the inspector log before relying on repository understanding"
            fi
        done <"$checks_file"
        rm -rf "$workspace"; rm -f "$toolchain_bindings" "$empty_bindings" "$empty_exceptions"
    fi
    rm -f "$checks_file" "$inventory"
    conventions_inspection_schema_validate <(awk -F '\t' 'BEGIN{OFS="\t"} {print $2,$3,$4,$5,$6,$7,$8,$9}' "$temporary") 2>/dev/null || return 1
    LC_ALL=C sort "$temporary" | atomic_write "$output" || return 1
    {
        printf '# Brownfield repository inspection\n\nGenerated: `%s`\n\n' "$(harness_now)"
        printf 'Observations are evidence only. Human review and promotion are required before they become authoritative conventions.\n\n'
        if [ -s "$output" ]; then
            printf '| ID | Category | Observation | Confidence | Matches | Total | Examples | Method | Limitations |\n|---|---|---|---|---:|---:|---|---|---|\n'
            while IFS=$'\t' read -r id category description confidence matches total examples method limitations; do
                printf '| %s | %s | %s | %s | %s | %s | `%s` | %s | %s |\n' "$id" "$category" "$description" "$confidence" "$matches" "$total" "$examples" "$method" "$limitations"
            done <"$output"
        else
            printf 'No structural observations were detected. Register project-specific inspection commands for deeper analysis.\n'
        fi
    } | atomic_write "$report" || return 1
    {
        conf_write_pair INSPECTION_HASH "$(sha256_file "$output")"
        conf_write_pair REPORT_HASH "$(sha256_file "$report")"
        conf_write_pair INSPECTED_TREE_HASH "$tree_hash"
        conf_write_pair GENERATED_AT "$(harness_now)"
    } | atomic_write "$metadata" || return 1
    release_lock; trap - EXIT INT TERM
    printf '%s\n' "$report"
}

