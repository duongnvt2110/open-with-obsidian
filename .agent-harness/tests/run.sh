#!/usr/bin/env bash
set -e
. "$(dirname "$0")/support.sh"
. "$SOURCE_ROOT/.agent-harness/lib/common.sh"
harness_normalize_locale
. "$SOURCE_ROOT/.agent-harness/lib/package.sh"
HARNESS_REPO_ROOT=$SOURCE_ROOT
HARNESS_POLICY_DIR=$SOURCE_ROOT/.agent-harness/policy
. "$SOURCE_ROOT/.agent-harness/lib/test_selection.sh"

PASSED=0
SKIPPED=0
TOTAL=0
TEST_JSON=${HARNESS_TEST_JSON:-0}
TEST_GATE=${HARNESS_TEST_GATE:-}
TEST_MODE=${HARNESS_TEST_MODE:-}
TEST_FILTER=${HARNESS_TEST_FILTER:-}
TEST_SUITE=${HARNESS_TEST_SUITE:-}
TEST_SINCE=${HARNESS_TEST_SINCE:-HEAD}
TEST_EXPLAIN=${HARNESS_TEST_EXPLAIN:-0}
TEST_GATE_SEEN=0
TEST_FULL_SEEN=0
TEST_MODE_SEEN=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --full)
            [ "$TEST_GATE_SEEN" -eq 0 ] || [ "$TEST_GATE" = release ] || { printf 'ERROR: --full conflicts with --gate %s\n' "$TEST_GATE" >&2; exit 2; }
            [ "$TEST_MODE_SEEN" -eq 0 ] || [ "$TEST_MODE" = full ] || { printf 'ERROR: --full conflicts with --mode %s\n' "$TEST_MODE" >&2; exit 2; }
            TEST_GATE=release; TEST_MODE=full; TEST_FULL_SEEN=1; shift
            ;;
        --gate)
            [ "$#" -ge 2 ] || { printf 'ERROR: --gate requires a value\n' >&2; exit 2; }
            case "$2" in fast|lifecycle|adversarial|release) ;; *) printf 'ERROR: invalid test gate: %s\n' "$2" >&2; exit 2 ;; esac
            [ "$TEST_MODE_SEEN" -eq 0 ] || { printf 'ERROR: --gate conflicts with --mode\n' >&2; exit 2; }
            [ "$TEST_FULL_SEEN" -eq 0 ] || [ "$2" = release ] || { printf 'ERROR: --gate %s conflicts with --full\n' "$2" >&2; exit 2; }
            [ "$TEST_GATE_SEEN" -eq 0 ] || [ "$TEST_GATE" = "$2" ] || { printf 'ERROR: multiple test gates conflict\n' >&2; exit 2; }
            TEST_GATE=$2; TEST_GATE_SEEN=1; shift 2
            ;;
        --mode)
            [ "$#" -ge 2 ] || { printf 'ERROR: --mode requires focused, standard, full, or auto\n' >&2; exit 2; }
            test_mode_valid "$2" || { printf 'ERROR: invalid test mode: %s\n' "$2" >&2; exit 2; }
            [ "$TEST_GATE_SEEN" -eq 0 ] || { printf 'ERROR: --mode conflicts with --gate\n' >&2; exit 2; }
            [ "$TEST_MODE_SEEN" -eq 0 ] || [ "$TEST_MODE" = "$2" ] || { printf 'ERROR: multiple test modes conflict\n' >&2; exit 2; }
            TEST_MODE=$2; TEST_MODE_SEEN=1; shift 2
            ;;
        --suite) [ "$#" -ge 2 ] || { printf 'ERROR: --suite requires a value\n' >&2; exit 2; }; TEST_SUITE=$2; shift 2 ;;
        --since) [ "$#" -ge 2 ] || { printf 'ERROR: --since requires a Git reference\n' >&2; exit 2; }; TEST_SINCE=$2; shift 2 ;;
        --explain) TEST_EXPLAIN=1; shift ;;
        --json) TEST_JSON=1; shift ;;
        --filter) [ "$#" -ge 2 ] || { printf 'ERROR: --filter requires a comma-separated case list\n' >&2; exit 2; }; TEST_FILTER=$2; shift 2 ;;
        *) printf 'ERROR: unknown test option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -n "$TEST_MODE" ] || {
    if [ -n "$TEST_GATE" ]; then TEST_MODE='';
    elif [ "${HARNESS_TEST_MODE:-fast}" = full ]; then TEST_GATE=release;
    else TEST_GATE=fast;
    fi
}

if [ -n "$TEST_MODE" ]; then
    case "$TEST_MODE" in
        focused)
            if [ -n "$TEST_SUITE" ]; then
                test_selection_resolve_suite "$TEST_SUITE" || { printf 'ERROR: unknown focused suite: %s\n' "$TEST_SUITE" >&2; exit 2; }
                [ -n "$TEST_FILTER" ] || TEST_FILTER=$TEST_SELECTION_CASES
            fi
            [ -n "$TEST_FILTER" ] || { printf 'ERROR: focused mode requires --filter or --suite\n' >&2; exit 2; }
            TEST_GATE=release
            ;;
        standard) TEST_GATE=standard ;;
        full) TEST_GATE=release ;;
        auto)
            changed=$(mktemp "${TMPDIR:-/tmp}/test-selection-changed.XXXXXX") || exit 2
            test_selection_changed_paths_since "$TEST_SINCE" "$changed" || { rm -f "$changed"; printf 'ERROR: cannot calculate changed paths since %s\n' "$TEST_SINCE" >&2; exit 2; }
            test_selection_resolve_file "$changed" path || { rm -f "$changed"; printf 'ERROR: test impact policy is invalid\n' >&2; exit 2; }
            rm -f "$changed"
            TEST_MODE=$TEST_SELECTION_MODE
            case "$TEST_MODE" in
                focused) TEST_GATE=release; [ -n "$TEST_FILTER" ] || TEST_FILTER=$TEST_SELECTION_CASES ;;
                standard) TEST_GATE=standard ;;
                full) TEST_GATE=release ;;
            esac
            ;;
    esac
fi

case "$TEST_GATE" in fast|lifecycle|adversarial|release|standard) ;; *) printf 'ERROR: invalid test gate: %s\n' "$TEST_GATE" >&2; exit 2 ;; esac

if [ "$TEST_EXPLAIN" = 1 ]; then
    if [ -z "$TEST_SELECTION_SOURCE" ]; then
        test_selection_reset
        TEST_SELECTION_MODE=${TEST_MODE:-$TEST_GATE}
        case "$TEST_SELECTION_MODE" in fast|lifecycle|adversarial|release) TEST_SELECTION_MODE=focused ;; esac
        TEST_SELECTION_CASES=${TEST_FILTER:-all-cases-in-selected-mode}
        TEST_SELECTION_SUITES=${TEST_SUITE:-none}
        TEST_SELECTION_REASONS=EXPLICIT_SELECTION
    fi
    if [ "$TEST_JSON" = 1 ]; then
        printf '{"result":"EXPLAIN","mode":"%s","gate":"%s","selection":' "$(json_escape "${TEST_MODE:-legacy-gate}")" "$(json_escape "$TEST_GATE")"
        test_selection_json true
        printf '}\n'
    else
        printf 'Test mode: %s\nGate: %s\n' "${TEST_MODE:-legacy-gate}" "$TEST_GATE"
        test_selection_explain_text
    fi
    exit 0
fi

unset HARNESS_TEST_JSON HARNESS_TEST_GATE HARNESS_TEST_MODE HARNESS_TEST_FILTER HARNESS_TEST_SUITE HARNESS_TEST_SINCE HARNESS_TEST_EXPLAIN

gate_selects_case() {
    local gates
    gates=$1
    [ "$TEST_GATE" = release ] && return 0
    if [ "$TEST_GATE" = standard ]; then
        case ",$gates," in *,fast,*|*,lifecycle,*|*,adversarial,*) return 0 ;; esac
        return 1
    fi
    case ",$gates," in *",$TEST_GATE,"*) return 0 ;; esac
    return 1
}

HARNESS_TEST_PARENT_TMPDIR=${TMPDIR:-/tmp}
HARNESS_TEST_SUITE_TMP=$(mktemp -d "$HARNESS_TEST_PARENT_TMPDIR/harness-suite.XXXXXX") || { printf 'ERROR: cannot create suite temporary root\n' >&2; exit 2; }
export TMPDIR=$HARNESS_TEST_SUITE_TMP
cleanup_suite() {
    chmod -R u+w "$HARNESS_TEST_SUITE_TMP" 2>/dev/null || true
    rm -rf "$HARNESS_TEST_SUITE_TMP" 2>/dev/null || true
}
trap cleanup_suite EXIT INT TERM

run_case() {
    local name implementation gates started finished duration status
    name=$1
    implementation=$2
    gates=$3
    shift 3
    gate_selects_case "$gates" || return 0
    if [ -n "$TEST_FILTER" ]; then
        case ",$TEST_FILTER," in *",$name,"*) ;; *) return 0 ;; esac
    fi
    TOTAL=$((TOTAL + 1))
    started=$(date +%s)
    if (
        FIXTURE=""
        HARNESS_LAST_OUTPUT=""
        cleanup_case() {
            if [ -n "${FIXTURE:-}" ]; then
                chmod -R u+w "$FIXTURE" 2>/dev/null || true
                rm -rf "$FIXTURE" 2>/dev/null || true
            fi
            [ -z "${HARNESS_LAST_OUTPUT:-}" ] || rm -f "$HARNESS_LAST_OUTPUT" 2>/dev/null || true
        }
        trap cleanup_case EXIT INT TERM
        "$implementation" "$@"
    ); then
        PASSED=$((PASSED + 1))
        finished=$(date +%s); duration=$((finished - started))
        [ "$TEST_JSON" = "1" ] || printf 'PASS: %s (%ss)
' "$name" "$duration"
    else
        status=$?
        finished=$(date +%s); duration=$((finished - started))
        if [ "$status" -eq 77 ]; then
            SKIPPED=$((SKIPPED + 1))
            [ "$TEST_JSON" = "1" ] || printf 'SKIP: %s (%ss)\n' "$name" "$duration"
            return 0
        fi
        printf 'FAIL: %s (%ss)
' "$name" "$duration" >&2
        exit 1
    fi
}

case_bash32() {
    for file in "$SOURCE_ROOT/.agent-harness/harness" "$SOURCE_ROOT/.agent-harness/harness.sh" "$SOURCE_ROOT/.agent-harness/lib"/*.sh; do bash -n "$file"; done
    if grep -R -E 'declare[[:space:]]+-A|mapfile|readarray|local[[:space:]]+-n|\$\{[^}]+,,\}|coproc' "$SOURCE_ROOT/.agent-harness/harness" "$SOURCE_ROOT/.agent-harness/lib" >/dev/null 2>&1; then fail 'Bash 4+ construct detected'; fi
}

case_bootstrap() {
    new_fixture
    assert_contains "$(cd "$FIXTURE" && ./.agent-harness/harness status)" NO_TASK
    (cd "$FIXTURE" && ./.agent-harness/harness doctor) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness audit) >/dev/null
}

case_export_clean_package() {
    local output
    output=$(mktemp -d "${TMPDIR:-/tmp}/harness-export-test.XXXXXX") || fail 'cannot create export destination'
    rm -rf "$output"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$output") >/dev/null || fail 'public export command failed'
    [ -x "$output/.agent-harness/harness" ] || fail 'exported harness is missing or not executable'
    [ -x "$output/.agent-harness/harness.sh" ] || fail 'exported harness wrapper is missing or not executable'
    [ -f "$output/.agent-harness/manifest.tsv" ] || fail 'exported manifest is missing'
    [ ! -e "$output/manifest.json" ] || fail 'obsolete root manifest metadata leaked into export'
    [ ! -e "$output/.agent-harness/runtime" ] || fail 'runtime state leaked into export'
    (cd "$output" && ./.agent-harness/harness doctor) >/dev/null || fail 'exported package doctor failed'
    rm -rf "$output"
}

case_export_rejects_unsafe_destinations() {
    local output
    assert_status 2 bash -c "cd '$SOURCE_ROOT' && ./.agent-harness/harness.sh export"
    assert_status 2 bash -c "cd '$SOURCE_ROOT' && ./.agent-harness/harness.sh export --output '$SOURCE_ROOT/.agent-harness'"
    output=$(mktemp -d "${TMPDIR:-/tmp}/harness-export-nonempty.XXXXXX") || fail 'cannot create non-empty export destination'
    printf 'preserve\n' >"$output/canary.txt"
    assert_status 2 bash -c "cd '$SOURCE_ROOT' && ./.agent-harness/harness.sh export --output '$output'"
    grep -Fx preserve "$output/canary.txt" >/dev/null || fail 'unsafe export changed the destination'
    rm -rf "$output"
}

case_export_is_clean_deterministic_copy_only() {
    local first second before after first_digest second_digest
    first=$(mktemp -d "${TMPDIR:-/tmp}/harness-export-first.XXXXXX") || fail 'cannot create first export destination'
    second=$(mktemp -d "${TMPDIR:-/tmp}/harness-export-second.XXXXXX") || fail 'cannot create second export destination'
    rm -rf "$first" "$second"
    before=$(test_tree_digest "$SOURCE_ROOT") || fail 'cannot digest source before export'
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$first") >/dev/null || fail 'first export failed'
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$second") >/dev/null || fail 'second export failed'
    after=$(test_tree_digest "$SOURCE_ROOT") || fail 'cannot digest source after export'
    assert_eq "$after" "$before"
    first_digest=$(package_tree_digest "$first") || fail 'cannot digest first export'
    second_digest=$(package_tree_digest "$second") || fail 'cannot digest second export'
    assert_eq "$first_digest" "$second_digest"
    diff -r "$first" "$second" >/dev/null || fail 'repeated exports differ'
    for path in runtime tasks runs project config; do
        [ ! -e "$first/.agent-harness/$path" ] || fail "generated $path state leaked into export"
    done
    [ ! -e "$first/my_docs" ] || fail 'linked my_docs leaked into export'
    [ "$(file_mode "$first/.agent-harness/harness")" = "$(file_mode "$second/.agent-harness/harness")" ] || fail 'exported executable modes differ'
    rm -rf "$first" "$second"
}

case_success() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf 'old\n' >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf 'good\n' >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null; assert_eq "$(active_state)" PASSED
    (cd "$FIXTURE" && ./.agent-harness/harness finalize) >/dev/null; assert_eq "$(active_state)" NO_TASK; (cd "$FIXTURE" && ./.agent-harness/harness audit) >/dev/null
}

case_scope_violation() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/other"; printf 'old\n' >"$FIXTURE/app/value.txt"; printf safe >"$FIXTURE/other/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf good >"$FIXTURE/app/value.txt"; printf changed >"$FIXTURE/other/value.txt"; assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"; assert_eq "$(active_state)" IMPLEMENTING
}

case_failure_remediation() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf bad >"$FIXTURE/app/value.txt"; assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"; assert_eq "$(active_state)" REMEDIATING
}

case_trusted_drift() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_script_check; create_basic_task script-check integration_test; approve_basic_task
    printf good >"$FIXTURE/app/value.txt"; printf '#!/usr/bin/env bash\nexit 0\n' >"$FIXTURE/checks/verify.sh"; chmod +x "$FIXTURE/checks/verify.sh"
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"; assert_eq "$(active_state)" IMPLEMENTING
}

case_control_scope() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    assert_status 2 bash -c "cd '$FIXTURE' && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope '.agent-harness/**' --check check-app --coverage 'AC-001|check-app|automated_test|Validates done'"
}

case_nested_vcs() {
    new_fixture; mkdir -p "$FIXTURE/vendor/repo/.Git" "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; printf x >"$FIXTURE/vendor/repo/.Git/config"; register_grep_check good; create_basic_task
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_invalid_glob() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    assert_status 2 bash -c "cd '$FIXTURE' && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope '[z-a]' --check check-app --coverage 'AC-001|check-app|automated_test|Validates done'"
}

case_package_tamper() {
    new_fixture; printf '\n# tampered\n' >>"$FIXTURE/.agent-harness/lib/common.sh"; assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"; assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness doctor"
}

case_scoped_manifest_self_update() {
    local digest manifest
    new_fixture
    mkdir -p "$FIXTURE/.agent-harness/config/commands"
    cat >"$FIXTURE/.agent-harness/config/commands/self-update-check.conf" <<'EOF_CHECK'
ID=self-update-check
EXECUTABLE=test
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
ARG_1=-s
ARG_2=.agent-harness/lib/verify.sh
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create \
      --title 'Scoped self update' --goal 'Update one managed harness file safely' --stakeholders maintainers \
      --profile feature --risk medium \
      --criterion 'AC-001|Managed file remains valid' \
      --scope '.agent-harness/lib/verify.sh' --scope '.agent-harness/manifest.tsv' \
      --check self-update-check \
      --coverage 'AC-001|self-update-check|static_check|Checks the approved managed file') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task understand \
      --by reviewer --current-behavior 'Managed files are manifest bound.' \
      --entry-points '.agent-harness/lib/verify.sh' --data-flow 'task -> manifest -> verification' \
      --dependencies none --interface-impact none --compatibility-risk low \
      --scope-rationale 'Only one managed file and its manifest change.' \
      --check-rationale 'The registered check validates the managed file.' \
      --rollback-plan 'Restore both approved files.' --security-impact reviewed \
      --data-impact none --operational-impact none --nfr-impact integrity \
      --module 'repository|Harness self-update fixture.' \
      --evidence 'OTHER|README.md|-|Repository evidence.' \
      --inspection-skip-reason 'Synthetic self-update fixture.' --step 'Update managed file and manifest') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by reviewer) >/dev/null
    printf '\n' >>"$FIXTURE/.agent-harness/lib/verify.sh"
    digest=$(sha256_file "$FIXTURE/.agent-harness/lib/verify.sh")
    manifest="$FIXTURE/.agent-harness/manifest.tsv"
    awk -F '\t' -v OFS='\t' -v wanted='.agent-harness/lib/verify.sh' -v digest="$digest" '$1 == wanted {$2=digest} {print}' "$manifest" >"$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    assert_eq "$(active_state)" PASSED
}

case_low_risk_manifest_self_update_denied() {
    local digest manifest
    new_fixture
    mkdir -p "$FIXTURE/.agent-harness/config/commands"
    cat >"$FIXTURE/.agent-harness/config/commands/self-update-check.conf" <<'EOF_CHECK'
ID=self-update-check
EXECUTABLE=test
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
ARG_1=-s
ARG_2=.agent-harness/lib/verify.sh
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create \
      --title 'Low risk self update' --goal 'Prove low risk cannot update harness policy' --stakeholders maintainers \
      --profile feature --risk low \
      --criterion 'AC-001|Managed file remains valid' \
      --scope '.agent-harness/lib/verify.sh' --scope '.agent-harness/manifest.tsv' \
      --check self-update-check \
      --coverage 'AC-001|self-update-check|static_check|Checks the approved managed file') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task understand \
      --by reviewer --current-behavior 'Managed files are manifest bound.' \
      --entry-points '.agent-harness/lib/verify.sh' --data-flow 'task -> manifest -> verification' \
      --dependencies none --interface-impact none --compatibility-risk low \
      --scope-rationale 'Only one managed file and its manifest change.' \
      --check-rationale 'The registered check validates the managed file.' \
      --rollback-plan 'Restore both approved files.' --security-impact reviewed \
      --data-impact none --operational-impact none --nfr-impact integrity \
      --module 'repository|Harness self-update fixture.' \
      --evidence 'OTHER|README.md|-|Repository evidence.' \
      --inspection-skip-reason 'Synthetic self-update fixture.' --step 'Update managed file and manifest') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by reviewer) >/dev/null
    printf '\n' >>"$FIXTURE/.agent-harness/lib/verify.sh"
    digest=$(sha256_file "$FIXTURE/.agent-harness/lib/verify.sh")
    manifest="$FIXTURE/.agent-harness/manifest.tsv"
    awk -F '\t' -v OFS='\t' -v wanted='.agent-harness/lib/verify.sh' -v digest="$digest" '$1 == wanted {$2=digest} {print}' "$manifest" >"$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    assert_eq "$(active_state)" IMPLEMENTING
}

case_clarification() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task
    question=$(cd "$FIXTURE" && ./.agent-harness/harness task clarify --question 'Which value?'); id=$(printf '%s' "$question" | awk '{print $3}'); assert_eq "$(active_state)" CLARIFICATION_REQUIRED
    (cd "$FIXTURE" && ./.agent-harness/harness task answer --id "$id" --answer good) >/dev/null; assert_eq "$(active_state)" INTAKE; approve_basic_task
}

case_final_review() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Migration --goal 'Set good' --stakeholders users --profile migration --criterion 'AC-001|Value is good' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Checks value') >/dev/null
    understand_active_task
    approve_basic_task; printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null; assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness finalize"
    assert_contains "$(cd "$FIXTURE" && ./.agent-harness/harness next)" 'harness approve --final --by <name>'
    (cd "$FIXTURE" && ./.agent-harness/harness approve --final --by reviewer) >/dev/null
    assert_contains "$(cd "$FIXTURE" && ./.agent-harness/harness next)" 'harness finalize'
    (cd "$FIXTURE" && ./.agent-harness/harness finalize) >/dev/null
}

case_finalize_drift() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null; printf changed >"$FIXTURE/app/value.txt"; assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness finalize"; assert_eq "$(active_state)" REMEDIATING
}

case_recover_verifying() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    (cd "$FIXTURE"; . .agent-harness/lib/common.sh; . .agent-harness/lib/store.sh; . .agent-harness/lib/policy.sh; . .agent-harness/lib/workflow.sh; harness_init_paths "$FIXTURE"; run_id=$(active_run_id); transition_run "$run_id" VERIFYING verification interrupted)
    (cd "$FIXTURE" && ./.agent-harness/harness recover) >/dev/null; assert_eq "$(active_state)" REMEDIATING
}

case_event_recovery() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    (cd "$FIXTURE"; . .agent-harness/lib/common.sh; . .agent-harness/lib/store.sh; . .agent-harness/lib/policy.sh; harness_init_paths "$FIXTURE"; run_id=$(active_run_id); append_event "$run_id" IMPLEMENTING VERIFYING verification 'event ahead')
    (cd "$FIXTURE" && ./.agent-harness/harness recover) >/dev/null; assert_eq "$(active_state)" REMEDIATING
}

case_event_owner() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf"); events="$FIXTURE/.agent-harness/runs/$run_id/events.tsv"
    (cd "$FIXTURE"; . .agent-harness/lib/common.sh; line=$(sed -n '2p' "$events"); old_ifs=$IFS; IFS=$'\t' read -r seq ts from to owner reason previous hash <<EOF_LINE
$line
EOF_LINE
    IFS=$old_ifs; payload=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$seq" "$ts" "$from" "$to" verification "$reason" "$previous"); new_hash=$(sha256_text "$payload"); sed -n '1p' "$events" >"$events.tmp"; printf '%s\t%s\n' "$payload" "$new_hash" >>"$events.tmp"; mv "$events.tmp" "$events")
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"
}

case_json() {
    new_fixture; assert_contains "$(cd "$FIXTURE" && ./.agent-harness/harness status --json)" '"state":"NO_TASK"'; assert_contains "$(cd "$FIXTURE" && ./.agent-harness/harness audit --json)" '"result":"PASS"'
    assert_status 2 bash -c "cd '$FIXTURE' && ./.agent-harness/harness unknown --json"; assert_contains "$(cat "$HARNESS_LAST_OUTPUT")" '"exit_code":2'
}

case_relocation() {
    new_fixture; moved=$(mktemp -d "${TMPDIR:-/tmp}/harness-moved.XXXXXX"); rm -rf "$moved"; mv "$FIXTURE" "$moved"; FIXTURE=$moved; (cd "$FIXTURE" && ./.agent-harness/harness doctor) >/dev/null; (cd "$FIXTURE" && ./.agent-harness/harness audit) >/dev/null
}

case_raw_shell() {
    # Clean exports intentionally omit project command state.
    new_fixture; mkdir -p "$FIXTURE/.agent-harness/config/commands"; cat >"$FIXTURE/.agent-harness/config/commands/bad.conf" <<'EOF_CHECK'
ID=bad
EXECUTABLE=/bin/bash
CWD=.
TIMEOUT_SECONDS=10
EVIDENCE_TYPE=static_check
ARG_1=-c
ARG_2=true
EOF_CHECK
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness doctor"
}

case_check_mutation() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks"; printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/checks/mutate.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
printf created > app/created-by-check.txt
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/mutate.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/mutate.conf" <<'EOF_CHECK'
ID=mutate
EXECUTABLE=checks/mutate.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=automated_test
TRUSTED_INPUT_1=checks/mutate.sh
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check mutate --coverage 'AC-001|mutate|automated_test|Runs mutation check') >/dev/null; understand_active_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"; assert_eq "$(active_state)" REMEDIATING
}

case_symlink() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; ln -s value.txt "$FIXTURE/app/link.txt"; register_grep_check good; create_basic_task; assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_hardlink() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; ln "$FIXTURE/app/value.txt" "$FIXTURE/app/copy.txt"; register_grep_check good; create_basic_task; assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_timeout() {
    output=$(mktemp "${TMPDIR:-/tmp}/harness-timeout-test.XXXXXX")
    started=$(date +%s)
    set +e
    run_with_timeout 1 "$output" sleep 10
    result=$?
    set -e
    elapsed=$(( $(date +%s) - started ))
    rm -f "$output"
    [ "$result" -eq 124 ] || fail "expected timeout exit 124, got $result"
    [ "$elapsed" -lt 8 ] || fail "timeout handling took too long: $elapsed seconds"
}

case_hash_fallback() {
    new_fixture
    bin=$(mktemp -d "${TMPDIR:-/tmp}/harness-bin.XXXXXX")
    ln -s "$(command -v shasum)" "$bin/shasum"
    ln -s "$(command -v awk)" "$bin/awk"
    ln -s "$(command -v bash)" "$bin/bash"
    expected=$(sha256sum "$FIXTURE/README.md" | awk '{print $1}')
    actual=$(PATH="$bin" "$bin/bash" -c '. "'$FIXTURE'/.agent-harness/lib/common.sh"; sha256_file "'$FIXTURE'/README.md"')
    rm -rf "$bin"
    assert_eq "$actual" "$expected"
}

case_unmanaged_core() {
    new_fixture; printf '# unexpected
' >"$FIXTURE/.agent-harness/lib/unmanaged.sh"
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"
}


case_convention_deduplicated_check() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; add_automated_convention; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    effective="$FIXTURE/.agent-harness/runs/$run_id/artifacts/effective-checks.txt"
    assert_eq "$(grep -c '^check-app$' "$effective")" 1
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    assert_contains "$(cat "$FIXTURE/.agent-harness/tasks/$task_id/applicable-conventions.tsv")" 'REPO-001'
    printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
}

case_inspection_runtime_only() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    (cd "$FIXTURE" && ./.agent-harness/harness inspect) >/dev/null
    [ -f "$FIXTURE/.agent-harness/runtime/convention-observations.tsv" ] || fail "inspection observations missing"
    printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
}

case_convention_contract_drift() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; add_automated_convention; create_basic_task; approve_basic_task
    printf '
' >>"$FIXTURE/.agent-harness/project/conventions/rules.tsv"
    printf 'TAMPER	errors	MUST	ACTIVE	DECLARED	*	app/**	ANY	MANUAL			Tampered rule
' >>"$FIXTURE/.agent-harness/project/conventions/rules.tsv"
    printf good >"$FIXTURE/app/value.txt"
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"
}

case_manual_convention_review() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; add_manual_convention; create_basic_task; approve_basic_task
    printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --final --by reviewer"
    (cd "$FIXTURE" && ./.agent-harness/harness approve --final --by reviewer --rule 'ARCH-001|PASS|app/value.txt|Application boundary remains intact') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness finalize) >/dev/null
}

case_convention_mutation_blocked_during_task() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness conventions add --id ERR-001 --category errors --level MUST --source DECLARED --path 'app/**' --trigger ANY --enforcement MANUAL --rule 'Use canonical errors.' --by reviewer"
}


case_convention_module_registration() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness conventions module add --id application --root 'app/**' --language text --framework none --owner backend --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id APP-001 --category architecture --level MUST --source DECLARED --module application --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement AUTOMATED --check check-app --example app/value.txt --rule 'Application module changes must pass the application check.' --by reviewer) >/dev/null
    create_basic_task; approve_basic_task
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    assert_contains "$(cat "$FIXTURE/.agent-harness/tasks/$task_id/applicable-conventions.tsv")" 'APP-001'
    printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
}

case_convention_example_read_context() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; add_manual_convention; create_basic_task; approve_basic_task
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    grep -Fx 'app/value.txt' "$FIXTURE/.agent-harness/tasks/$task_id/read-context.txt" >/dev/null 2>&1 || fail "canonical example missing from read context"
    if grep -Fx 'app/value.txt' "$FIXTURE/.agent-harness/tasks/$task_id/scopes.txt" >/dev/null 2>&1; then fail "canonical example was incorrectly added as an extra write scope"; fi
    return 0
}

case_convention_update_recovery() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"
    (
        cd "$FIXTURE" || exit 1
        . .agent-harness/lib/common.sh
        . .agent-harness/lib/store.sh
        . .agent-harness/lib/policy.sh
        . .agent-harness/lib/conventions.sh
        harness_init_paths "$FIXTURE"
        harness_ensure_layout
        previous=$(conventions_contract_hash)
        conventions_begin_update ADD RECOVER-001 reviewer "$previous" 'simulated interrupted convention update'
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          RECOVER-001 errors MUST ACTIVE DECLARED '*' 'app/**' NEW_OR_MODIFIED MANUAL - app/value.txt 'Recovered application error convention.' \
          >>"$(convention_rules_file)"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' RECOVER-001 '*' '*' '*' '*' TEST 100 >>"$(convention_applicability_file)"
    )
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"
    (cd "$FIXTURE" && ./.agent-harness/harness recover) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions validate) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness audit) >/dev/null
    [ ! -f "$FIXTURE/.agent-harness/runtime/convention-update.conf" ] || fail "convention update journal was not cleared"
    last_contract=$(tail -n 1 "$FIXTURE/.agent-harness/project/conventions/history.tsv" | awk -F '\t' '{print $7}')
    current_contract=$(
        cd "$FIXTURE" || exit 1
        . .agent-harness/lib/common.sh
        . .agent-harness/lib/store.sh
        . .agent-harness/lib/policy.sh
        . .agent-harness/lib/conventions.sh
        harness_init_paths "$FIXTURE"
        conventions_contract_hash
    )
    assert_eq "$last_contract" "$current_contract"
}


case_understanding_required() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct check') >/dev/null
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
    understand_active_task; approve_basic_task
}

case_open_assumption_blocked() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct check') >/dev/null
    assert_status 3 record_understanding_with_assumption OPEN
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_candidate_promotion() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness inspect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions candidate add --id DOC-001 --category documentation --level SHOULD --source OBSERVED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement MANUAL --example app/value.txt --observation OBS-001 --rule 'Changes should preserve repository documentation conventions.' --by reviewer) >/dev/null
    grep -F $'DOC-001	documentation	SHOULD	CANDIDATE' "$FIXTURE/.agent-harness/project/conventions/rules.tsv" >/dev/null || fail 'candidate not recorded'
    (cd "$FIXTURE" && ./.agent-harness/harness conventions promote --id DOC-001 --by lead) >/dev/null
    grep -F $'DOC-001	documentation	SHOULD	ACTIVE	OBSERVED' "$FIXTURE/.agent-harness/project/conventions/rules.tsv" >/dev/null || fail 'candidate not promoted'
    (cd "$FIXTURE" && ./.agent-harness/harness conventions validate) >/dev/null
}

case_exception_applied() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; register_failing_check convention-fail
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id REPO-EX --category persistence --level MUST --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement AUTOMATED --check convention-fail --example app/value.txt --rule 'Normally requires the failing fixture check.' --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions exception add --id EX-001 --rule REPO-EX --path 'app/**' --reason 'Approved fixture exception.' --by lead) >/dev/null
    create_basic_task; approve_basic_task
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    grep -F EX-001 "$FIXTURE/.agent-harness/tasks/$task_id/applicable-exceptions.tsv" >/dev/null || fail 'exception not bound'
    ! grep -F REPO-EX "$FIXTURE/.agent-harness/tasks/$task_id/applicable-conventions.tsv" >/dev/null || fail 'excepted rule remained active'
    printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
}

case_should_warning() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; register_failing_check advisory
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id QUAL-001 --category testing --level SHOULD --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement AUTOMATED --check advisory --example app/value.txt --rule 'The advisory quality check should pass.' --by reviewer) >/dev/null
    create_basic_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    grep -F $'advisory	SHOULD	QUAL-001' "$FIXTURE/.agent-harness/runs/$run_id/artifacts/convention-warnings.tsv" >/dev/null || fail 'SHOULD warning missing'
    (cd "$FIXTURE" && ./.agent-harness/harness approve --final --by reviewer --rule 'QUAL-001|WAIVE|app/value.txt|Accepted advisory deviation') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness finalize) >/dev/null
}

case_may_warning_nonblocking() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; register_failing_check optional-check
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id OPT-001 --category performance --level MAY --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement AUTOMATED --check optional-check --example app/value.txt --rule 'The optional optimization check may pass.' --by reviewer) >/dev/null
    create_basic_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness finalize) >/dev/null
}

case_conflicting_rules_blocked() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id ARCH-A --category architecture --level MUST --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement MANUAL --example app/value.txt --rule 'Use architecture A.' --by reviewer) >/dev/null
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness conventions add --id ARCH-B --category architecture --level MUST --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement MANUAL --example app/value.txt --rule 'Use architecture B.' --by reviewer"
    ! grep -F ARCH-B "$FIXTURE/.agent-harness/project/conventions/rules.tsv" >/dev/null || fail 'conflicting rule was retained'
}

case_inventory_exclusion() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/vendor"; printf old >"$FIXTURE/app/value.txt"; dd if=/dev/zero of="$FIXTURE/vendor/large.bin" bs=1024 count=256 2>/dev/null; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness inventory policy add --type EXCLUDE --path 'vendor/**' --reason 'Approved third-party content.' --by reviewer) >/dev/null
    create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    ! grep -F vendor/ "$FIXTURE/.agent-harness/runs/$run_id/artifacts/baseline-inventory.tsv" >/dev/null || fail 'excluded path remained in inventory'
    assert_contains "$(cd "$FIXTURE" && ./.agent-harness/harness audit --json)" 'inventory_exclusion_active:vendor/**'
}

case_inventory_trusted_conflict() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/vendor"; printf old >"$FIXTURE/app/value.txt"; printf fixture >"$FIXTURE/vendor/check.txt"; register_grep_check good
    printf 'TRUSTED_INPUT_1=vendor/check.txt
' >>"$FIXTURE/.agent-harness/config/commands/check-app.conf"
    (cd "$FIXTURE" && ./.agent-harness/harness inventory policy add --type EXCLUDE --path 'vendor/**' --reason 'Third-party content.' --by reviewer) >/dev/null
    create_basic_task
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_allowed_symlink() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; ln -s value.txt "$FIXTURE/app/link.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness inventory policy add --type ALLOW_SYMLINK --path app/link.txt --reason 'Approved in-repository alias.' --by reviewer) >/dev/null
    create_basic_task; approve_basic_task
}

case_allowed_external_linked_doc() {
    local external run_id
    new_fixture
    external=$(mktemp -d "${TMPDIR:-/tmp}/harness-linked-docs.XXXXXX") || fail 'cannot create linked-doc target'
    printf 'approved input\n' >"$external/approved.md"
    printf 'human-owned input\n' >"$external/unscoped.md"
    ln -s "$external" "$FIXTURE/my_docs"
    (cd "$FIXTURE" && ./.agent-harness/harness inventory policy add --type ALLOW_SYMLINK --path my_docs --reason 'Approved project documentation mount.' --by reviewer) >/dev/null
    cat >"$FIXTURE/.agent-harness/config/commands/linked-doc-check.conf" <<'EOF_LINKED_DOC_CHECK'
ID=linked-doc-check
EXECUTABLE=true
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
PURPOSE=VERIFICATION
EOF_LINKED_DOC_CHECK
    (
      cd "$FIXTURE" || exit 1
      ./.agent-harness/harness task create --title 'Linked doc' --goal 'Update one approved linked document' --stakeholders users \
        --criterion 'AC-001|Approved linked document is governed' --scope my_docs/approved.md \
        --check linked-doc-check --coverage 'AC-001|linked-doc-check|static_check|Exercises linked-document inventory enforcement'
      ./.agent-harness/harness task understand --by reviewer --current-behavior 'One human-owned document is linked into the repository.' \
        --entry-points my_docs/approved.md --data-flow 'The harness inventories the exact approved logical path.' \
        --dependencies 'An explicitly approved external documentation mount.' --interface-impact 'No public interface change.' \
        --compatibility-risk 'The linked mount must remain fail closed.' --scope-rationale 'Only my_docs/approved.md is writable.' \
        --check-rationale 'Approval and verification exercise linked-document inventory.' --rollback-plan 'Restore the approved baseline content.' \
        --security-impact 'External traversal is limited to one exact logical file.' --data-impact 'One human-owned document may change.' \
        --operational-impact 'No runtime service impact.' --nfr-impact 'Inventory remains deterministic.' \
        --module 'repository|Repository-level linked documentation.' --evidence 'OTHER|README.md|-|Stable repository evidence.' \
        --inspection-skip-reason 'Synthetic linked-document fixture.' --step 'Modify the exact approved linked document.' \
        --step 'Run linked-document verification.'
      ./.agent-harness/harness approve --by reviewer
    ) >/dev/null || fail 'approved external linked document was rejected'
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    grep -F $'my_docs/approved.md\tF\t' "$FIXTURE/.agent-harness/runs/$run_id/artifacts/baseline-inventory.tsv" >/dev/null || fail 'approved linked document missing from inventory'
    ! grep -F 'my_docs/unscoped.md' "$FIXTURE/.agent-harness/runs/$run_id/artifacts/baseline-inventory.tsv" >/dev/null || fail 'unscoped linked document leaked into inventory'
    printf 'approved update\n' >"$external/approved.md"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null || fail 'approved linked-document change did not verify'
    grep -Fx my_docs/approved.md "$FIXTURE/.agent-harness/runs/$run_id/artifacts/changed-paths.txt" >/dev/null || fail 'linked-document modification was not detected'
    rm -rf "$external"
}

case_known_stale_runtime_migrated() {
    local history before after
    new_fixture
    mkdir -p "$FIXTURE/.agent-harness/runtime"
    cat >"$FIXTURE/.agent-harness/runtime/v3-workflow.json" <<'EOF_STALE_RUNTIME'
{
  "workflow_version": "v3",
  "implementation_version": "v3-core",
  "enforcement_mode": "AUDIT_ONLY",
  "assurance_limitations": ["repository-local governance; OS-level isolation is outside scope"],
  "state_path": "runtime/state.json",
  "mixed_artifacts": false,
  "migration_required": false
}
EOF_STALE_RUNTIME
    (cd "$FIXTURE" && ./.agent-harness/harness status) >/dev/null || fail 'read-only status failed before migration'
    [ -e "$FIXTURE/.agent-harness/runtime/v3-workflow.json" ] || fail 'read-only status unexpectedly migrated runtime state'
    (cd "$FIXTURE" && ./.agent-harness/harness recover) >/dev/null || fail 'known stale runtime migration failed'
    [ ! -e "$FIXTURE/.agent-harness/runtime/v3-workflow.json" ] || fail 'known stale runtime file was not removed'
    history="$FIXTURE/.agent-harness/runtime/migration-history.tsv"
    [ -s "$history" ] || fail 'runtime migration history was not recorded'
    grep -F $'legacy_workflow_metadata\tCOMPLETED\t' "$history" >/dev/null || fail 'runtime migration completion missing'
    before=$(wc -l <"$history" | tr -d ' ')
    (cd "$FIXTURE" && ./.agent-harness/harness recover) >/dev/null || fail 'second runtime migration pass failed'
    after=$(wc -l <"$history" | tr -d ' ')
    assert_eq "$after" "$before"
}

case_unknown_stale_runtime_preserved() {
    new_fixture
    mkdir -p "$FIXTURE/.agent-harness/runtime"
    printf '{"unknown":true}\n' >"$FIXTURE/.agent-harness/runtime/v9-unknown.json"
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"
    [ -f "$FIXTURE/.agent-harness/runtime/v9-unknown.json" ] || fail 'unknown runtime file was deleted'
    assert_contains "$(cat "$HARNESS_LAST_OUTPUT")" 'unknown_versioned_runtime:.agent-harness/runtime/v9-unknown.json'
}

case_worker_packet_json() {
    local packet repeated text_packet run_id events
    new_fixture
    packet=$(cd "$FIXTURE" && ./.agent-harness/harness next --json)
    assert_contains "$packet" '"schema_version":"1"'
    assert_contains "$packet" '"state":"NO_TASK"'
    assert_contains "$packet" '"next_action":{"command":"harness task create"'
    mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    packet=$(cd "$FIXTURE" && HARNESS_PACKET_SECRET='must-not-leak' ./.agent-harness/harness next --json)
    repeated=$(cd "$FIXTURE" && HARNESS_PACKET_SECRET='different-secret' ./.agent-harness/harness next --json)
    assert_eq "$packet" "$repeated"
    assert_contains "$packet" '"state":"IMPLEMENTING"'
    assert_contains "$packet" '"goal":"Set the value to good"'
    assert_contains "$packet" '"acceptance_criteria":[{"id":"AC-001"'
    assert_contains "$packet" '"writable_scopes":["app/**"]'
    assert_contains "$packet" '"required_checks":[{"id":"check-app","evidence_type":"automated_test"'
    assert_contains "$packet" '"next_action":{"command":"harness verify"'
    assert_contains "$packet" '"task_contract_hash":"'
    printf '%s' "$packet" | grep -F 'must-not-leak' >/dev/null 2>&1 && fail 'worker packet leaked an environment value'
    text_packet=$(cd "$FIXTURE" && ./.agent-harness/harness next)
    assert_eq "$text_packet" 'Implement only within the approved scope, then run: harness verify'
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    events="$FIXTURE/.agent-harness/runs/$run_id/events.tsv"
    printf 'tamper\n' >>"$events"
    assert_status 4 bash -c "cd '$FIXTURE' && ./.agent-harness/harness next --json"
}

case_append_only_remediation_attempts() {
    local run_id attempts packet first_attempt
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    attempts="$FIXTURE/.agent-harness/runs/$run_id/artifacts/attempts.tsv"
    [ -s "$attempts" ] || fail 'first remediation attempt index missing'
    grep -F $'001\tREMEDIATING\t' "$attempts" >/dev/null || fail 'attempt 001 was not retained'
    printf bad >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    grep -F $'001\tREMEDIATING\t' "$attempts" >/dev/null || fail 'attempt 001 was overwritten'
    grep -F $'002\tREMEDIATING\t' "$attempts" >/dev/null || fail 'attempt 002 was not appended'
    packet=$(cd "$FIXTURE" && ./.agent-harness/harness next --json)
    assert_contains "$packet" '"attempt_id":"002"'
    assert_contains "$packet" '"attempt_count":2'
    printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify >/dev/null && ./.agent-harness/harness finalize >/dev/null) || fail 'repaired verification did not finalize'
    grep -F $'003\tPASSED\t' "$attempts" >/dev/null || fail 'passing attempt was not retained'
    assert_eq "$(wc -l <"$attempts" | tr -d ' ')" 3
    [ -s "$FIXTURE/.agent-harness/runs/$run_id/artifacts/attempts/001/blocking-failures.tsv" ] || fail 'attempt 001 failure evidence missing'
    [ -s "$FIXTURE/.agent-harness/runs/$run_id/artifacts/attempts/002/blocking-failures.tsv" ] || fail 'attempt 002 failure evidence missing'
    first_attempt="$FIXTURE/.agent-harness/runs/$run_id/artifacts/attempts/001/attempt.conf"
    printf 'TAMPERED=yes\n' >>"$first_attempt"
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"
    assert_contains "$(cat "$HARNESS_LAST_OUTPUT")" "attempt_history_invalid:$run_id"
}

run_synthetic_business_scenario() {
    local business unrelated_hash run_id packet attempts
    business=$(mktemp -d "${TMPDIR:-/tmp}/harness-business.XXXXXX") || fail 'cannot create synthetic business repository'
    chmod 700 "$business"
    mkdir -p "$business/services/orders" "$business/docs" "$business/unrelated"
    printf 'legacy_key=timestamp\n' >"$business/services/orders/idempotency.conf"
    printf 'Human request: retries for one order ID must be idempotent.\n' >"$business/docs/request.md"
    printf 'preserve this dirty business note\n' >"$business/unrelated/owner-note.txt"
    unrelated_hash=$(sha256_file "$business/unrelated/owner-note.txt")
    install_clean_harness "$business"
    mkdir -p "$business/.agent-harness/config/commands" || fail 'cannot create business command directory'
    (cd "$business" && ./.agent-harness/harness status >/dev/null) || fail 'business harness bootstrap failed'
    for path in ADR.md adrs context policies my_docs; do [ ! -e "$business/$path" ] || fail "bootstrap created forbidden root path: $path"; done
    (cd "$business" && ./.agent-harness/harness doctor >/dev/null && ./.agent-harness/harness audit >/dev/null) || fail 'installed business harness health check failed'
    cat >"$business/.agent-harness/config/commands/order-idempotency.conf" <<'EOF_ORDER_CHECK'
ID=order-idempotency
EXECUTABLE=grep
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=integration_test
PURPOSE=VERIFICATION
ARG_1=-qx
ARG_2=idempotency_key=order_id
ARG_3=services/orders/idempotency.conf
EOF_ORDER_CHECK
    (
      cd "$business" || exit 1
      ./.agent-harness/harness task create --title 'Order retry idempotency' --goal 'Use the stable order ID as the idempotency key' \
        --stakeholders 'order operations and customers' --profile feature --risk high \
        --criterion 'AC-001|Order retries use the order ID idempotency key' --scope services/orders/idempotency.conf \
        --read docs/request.md --check order-idempotency \
        --coverage 'AC-001|order-idempotency|integration_test|The local check validates the exact business rule'
    ) >/dev/null || fail 'business task creation failed'
    packet=$(cd "$business" && ./.agent-harness/harness next --json)
    assert_contains "$packet" '"state":"INTAKE"'
    assert_contains "$packet" '"next_action":{"command":"harness approve --by <name>"'
    (
      cd "$business" || exit 1
      ./.agent-harness/harness task understand --by business-reviewer \
        --current-behavior 'Retries derive a legacy timestamp key and can duplicate one logical order.' \
        --entry-points services/orders/idempotency.conf --data-flow 'The order service reads one configured key for retry deduplication.' \
        --dependencies 'Existing order persistence only.' --interface-impact 'No external API shape changes.' \
        --compatibility-risk 'High because retry identity affects duplicate order processing.' \
        --scope-rationale 'Only the order idempotency configuration is writable.' \
        --check-rationale 'The registered local check enforces the exact stable key.' \
        --rollback-plan 'Restore the approved baseline configuration.' --security-impact 'No credential handling.' \
        --data-impact 'Future retry identity changes; no fixture migration.' --operational-impact 'Prevents duplicate retry processing.' \
        --nfr-impact 'Retry behavior becomes deterministic.' --module 'repository|Synthetic brownfield business module.' \
        --evidence 'OTHER|docs/request.md|-|The fixture request defines the business outcome.' \
        --inspection-skip-reason 'Deterministic synthetic business fixture.' --step 'Change only the idempotency configuration.' \
        --step 'Run the local integration check and remediate any failure.'
      ./.agent-harness/harness approve --by business-reviewer --second-by risk-reviewer
    ) >/dev/null || fail 'business task approval failed'
    printf 'changed outside scope\n' >"$business/unrelated/owner-note.txt"
    assert_status 3 bash -c "cd '$business' && ./.agent-harness/harness verify"
    printf 'preserve this dirty business note\n' >"$business/unrelated/owner-note.txt"
    printf 'idempotency_key=timestamp\n' >"$business/services/orders/idempotency.conf"
    assert_status 5 bash -c "cd '$business' && ./.agent-harness/harness verify"
    packet=$(cd "$business" && ./.agent-harness/harness next --json)
    assert_contains "$packet" '"state":"REMEDIATING"'
    assert_contains "$packet" '"attempt_id":"001"'
    assert_contains "$packet" '"check_id":"order-idempotency"'
    printf 'idempotency_key=order_id\n' >"$business/services/orders/idempotency.conf"
    (cd "$business" && ./.agent-harness/harness verify >/dev/null) || fail 'business repair did not pass verification'
    assert_status 3 bash -c "cd '$business' && ./.agent-harness/harness finalize"
    (cd "$business" && ./.agent-harness/harness approve --final --by release-reviewer >/dev/null && ./.agent-harness/harness finalize >/dev/null) || fail 'business final review/finalization failed'
    (cd "$business" && ./.agent-harness/harness audit >/dev/null) || fail 'finalized business audit failed'
    [ "$(sha256_file "$business/unrelated/owner-note.txt")" = "$unrelated_hash" ] || fail 'unrelated business file changed'
    run_id=$(awk -F '\t' 'NF {value=$3} END {print value}' "$business/.agent-harness/tasks/index.tsv")
    attempts="$business/.agent-harness/runs/$run_id/artifacts/attempts.tsv"
    grep -F $'001\tREMEDIATING\t' "$attempts" >/dev/null || fail 'business failed attempt missing'
    grep -F $'002\tPASSED\t' "$attempts" >/dev/null || fail 'business repaired attempt missing'
    assert_contains "$(cd "$business" && ./.agent-harness/harness next)" 'Create a task with:'
    rm -rf "$business"
}

case_synthetic_business_e2e() {
    run_synthetic_business_scenario
    run_synthetic_business_scenario
}

case_real_business_repo_smoke() {
    local source snapshot source_head source_status final_head final_status
    source=${HARNESS_E2E_BUSINESS_REPO:-}
    if [ -z "$source" ]; then return 77; fi
    [ -d "$source" ] || fail 'HARNESS_E2E_BUSINESS_REPO is not a directory'
    git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail 'HARNESS_E2E_BUSINESS_REPO is not a Git worktree'
    source_head=$(git -C "$source" rev-parse HEAD) || fail 'cannot read real repository HEAD'
    source_status=$(git -C "$source" status --porcelain=v1 -z | sha256_text)
    snapshot=$(mktemp -d "${TMPDIR:-/tmp}/harness-real-business.XXXXXX") || fail 'cannot create real repository snapshot'
    chmod 700 "$snapshot"
    git -C "$source" archive HEAD | (cd "$snapshot" && tar -xf -) || fail 'cannot create committed-tree snapshot'
    [ ! -e "$snapshot/.git" ] || fail 'real snapshot copied Git metadata'
    install_clean_harness "$snapshot"
    mkdir -p "$snapshot/harness-smoke"
    printf bad >"$snapshot/harness-smoke/value.txt"
    cat >"$snapshot/.agent-harness/config/commands/real-smoke-check.conf" <<'EOF_REAL_CHECK'
ID=real-smoke-check
EXECUTABLE=grep
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=integration_test
PURPOSE=VERIFICATION
ARG_1=-qx
ARG_2=good
ARG_3=harness-smoke/value.txt
EOF_REAL_CHECK
    (
      cd "$snapshot" || exit 1
      ./.agent-harness/harness doctor >/dev/null && ./.agent-harness/harness audit >/dev/null
      ./.agent-harness/harness task create --title 'Real repository smoke' --goal 'Exercise a snapshot-only sentinel' --stakeholders maintainers \
        --criterion 'AC-001|Sentinel passes' --scope harness-smoke/value.txt --check real-smoke-check \
        --coverage 'AC-001|real-smoke-check|integration_test|Snapshot-only sentinel check'
      ./.agent-harness/harness task understand --by smoke-reviewer --current-behavior 'Snapshot sentinel is bad.' \
        --entry-points harness-smoke/value.txt --data-flow 'Local check reads the snapshot sentinel.' --dependencies none \
        --interface-impact none --compatibility-risk low --scope-rationale 'Only snapshot sentinel is writable.' \
        --check-rationale 'Local exact-value check.' --rollback-plan 'Delete snapshot.' --security-impact none --data-impact none \
        --operational-impact none --nfr-impact 'Source repository remains unchanged.' --module 'repository|Committed-tree snapshot.' \
        --evidence 'OTHER|harness-smoke/value.txt|-|Disposable snapshot sentinel.' --inspection-skip-reason 'Opt-in smoke overlay.' \
        --step 'Fail then repair sentinel verification.'
      ./.agent-harness/harness approve --by smoke-reviewer
      printf still-bad >harness-smoke/value.txt
      set +e; ./.agent-harness/harness verify >/dev/null 2>&1; result=$?; set -e; [ "$result" -eq 5 ]
      printf good >harness-smoke/value.txt
      ./.agent-harness/harness verify >/dev/null && ./.agent-harness/harness finalize >/dev/null && ./.agent-harness/harness audit >/dev/null
    ) || fail 'real repository snapshot lifecycle failed'
    final_head=$(git -C "$source" rev-parse HEAD)
    final_status=$(git -C "$source" status --porcelain=v1 -z | sha256_text)
    [ "$source_head" = "$final_head" ] && [ "$source_status" = "$final_status" ] || fail 'real repository source changed during smoke'
    if [ "${HARNESS_E2E_KEEP_DEBUG:-0}" = 1 ]; then printf 'Retained redacted real-smoke snapshot: %s\n' "$snapshot"; else rm -rf "$snapshot"; fi
}

case_finalized_approval_survives_package_evolution() {
    local readme_hash temporary
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify >/dev/null && ./.agent-harness/harness finalize >/dev/null) || fail 'fixture finalization failed'
    printf '\nLater template documentation update.\n' >>"$FIXTURE/README.md"
    readme_hash=$(sha256_file "$FIXTURE/README.md")
    temporary=$(mktemp "${TMPDIR:-/tmp}/manifest-evolution.XXXXXX") || fail 'cannot create manifest update'
    awk -F '\t' -v OFS='\t' -v hash="$readme_hash" '$1 == "README.md" {$2=hash} {print}' "$FIXTURE/.agent-harness/manifest.tsv" >"$temporary"
    mv "$temporary" "$FIXTURE/.agent-harness/manifest.tsv"
    (cd "$FIXTURE" && ./.agent-harness/harness audit >/dev/null) || fail 'later package evolution invalidated finalized approval'
}

case_environment_allowlist() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks"; printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/checks/env-check.sh" <<'EOF_ENV_SCRIPT'
#!/usr/bin/env bash
[ "${HARNESS_TEST_ALLOWED:-}" = "yes" ] && grep -q good app/value.txt
EOF_ENV_SCRIPT
    chmod +x "$FIXTURE/checks/env-check.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/env-check.conf" <<'EOF_ENV_CHECK'
ID=env-check
EXECUTABLE=checks/env-check.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=automated_test
ENV_ALLOW_1=HARNESS_TEST_ALLOWED
TOOL_1=grep
TRUSTED_INPUT_1=checks/env-check.sh
EOF_ENV_CHECK
    create_basic_task env-check automated_test; approve_basic_task; printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && HARNESS_TEST_ALLOWED=yes ./.agent-harness/harness verify) >/dev/null
}

case_ordered_failure_collection() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_failing_check fail-a STATIC 10; register_failing_check fail-b STATIC 20; register_failing_check later TEST 10
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Checks run' --scope 'app/**' --check fail-a --check fail-b --check later --coverage 'AC-001|fail-a|static_check|Static prerequisite') >/dev/null
    understand_active_task; approve_basic_task; printf changed >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    assert_eq "$(wc -l <"$FIXTURE/.agent-harness/runs/$run_id/artifacts/blocking-failures.tsv" | tr -d ' ')" 2
    grep -F $'later	TEST	blocked_by_STATIC' "$FIXTURE/.agent-harness/runs/$run_id/artifacts/skipped-checks.tsv" >/dev/null || fail 'later phase was not skipped'
}

case_critical_two_person_approval() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Critical --goal Goal --stakeholders users --risk critical --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct check') >/dev/null
    understand_active_task
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by reviewer --second-by second-reviewer) >/dev/null
}

case_context_budget() {
    local task_id run_id result
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/docs"; printf old >"$FIXTURE/app/value.txt"; dd if=/dev/zero of="$FIXTURE/docs/large.txt" bs=1024 count=210 2>/dev/null; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --read docs/large.txt --check check-app --coverage 'AC-001|check-app|automated_test|Direct check') >/dev/null
    understand_active_task
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by reviewer) >/dev/null || fail 'broad context overflow blocked approval'
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    assert_eq "$(conf_get "$FIXTURE/.agent-harness/tasks/$task_id/approval.conf" CONTEXT_OVERFLOW)" 1
    result=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" RESULT)
    assert_eq "$result" CHUNKED
    assert_eq "$(active_state)" IMPLEMENTING
}

case_compact_context_generated() {
    local run_id output
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    [ -f "$FIXTURE/.agent-harness/runs/$run_id/context/current/base.md" ] || fail 'compact base was not generated'
    [ -f "$FIXTURE/.agent-harness/runs/$run_id/context/current/index.tsv" ] || fail 'context index was not generated'
    grep -F 'app/value.txt' "$FIXTURE/.agent-harness/runs/$run_id/context/current/index.tsv" >/dev/null || fail 'understanding evidence was not selected'
    output=$(cd "$FIXTURE" && ./.agent-harness/harness context show)
    assert_contains "$output" 'Compact Context Base'
}

case_context_build_deterministic() {
    local run_id first second
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    first=$(cat "$FIXTURE/.agent-harness/runs/$run_id/context/current/context.sha256")
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null
    second=$(cat "$FIXTURE/.agent-harness/runs/$run_id/context/current/context.sha256")
    assert_eq "$second" "$first"
}

case_context_oversized_selection_referenced() {
    local run_id selections result
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; dd if=/dev/zero of="$FIXTURE/app/large.txt" bs=1024 count=80 2>/dev/null; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    selections="$FIXTURE/.agent-harness/runs/$run_id/context/selections.tsv"
    printf 'app/large.txt\t0\t0\tlarge relevant source\n' >"$selections"
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'oversized selection stopped context generation'
    result=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" RESULT)
    assert_eq "$result" CHUNKED
    grep -F $'REFERENCE\tapp/large.txt\t0\t0\tNO' "$FIXTURE/.agent-harness/runs/$run_id/context/current/index.tsv" >/dev/null || fail 'oversized source was not safely referenced'
    assert_eq "$(active_state)" IMPLEMENTING
}

case_context_invalid_selection_nonfatal() {
    local run_id selections result
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    selections="$FIXTURE/.agent-harness/runs/$run_id/context/selections.tsv"
    printf '../outside\t0\t0\tinvalid\n' >"$selections"
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'invalid context selection stopped the harness command'
    result=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" RESULT)
    assert_eq "$result" INCOMPLETE
    assert_eq "$(active_state)" IMPLEMENTING
}

case_context_show_read_only() {
    local run_id current before_context before_pointer after_context after_pointer
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    current="$FIXTURE/.agent-harness/runs/$run_id/context/current"
    before_context=$(sha256_text "$(cat "$current/context.sha256")|$(sha256_file "$current/status.conf")|$(sha256_file "$current/base.md")")
    before_pointer=$(sha256_file "$FIXTURE/.agent-harness/runtime/active-run.conf")
    (cd "$FIXTURE" && ./.agent-harness/harness context show) >/dev/null
    after_context=$(sha256_text "$(cat "$current/context.sha256")|$(sha256_file "$current/status.conf")|$(sha256_file "$current/base.md")")
    after_pointer=$(sha256_file "$FIXTURE/.agent-harness/runtime/active-run.conf")
    assert_eq "$after_context" "$before_context"
    assert_eq "$after_pointer" "$before_pointer"
}


case_context_show_detects_stale_source() {
    local output
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf changed >"$FIXTURE/app/value.txt"
    output=$(cd "$FIXTURE" && ./.agent-harness/harness context show)
    assert_contains "$output" 'SOURCE_STATUS=STALE'
    assert_contains "$output" 'Run `context build` before using source bundles'
    assert_eq "$(active_state)" IMPLEMENTING
}


case_context_clears_failure_summary_after_pass() {
    local run_id summary
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf bad >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null || fail 'remediated verification did not pass'
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    summary="$FIXTURE/.agent-harness/runs/$run_id/context/current/failure-summary.md"
    [ ! -s "$summary" ] || fail 'stale failure summary remained after verification passed'
    assert_eq "$(active_state)" PASSED
}

case_context_failure_summary_bounded() {
    local run_id summary maximum
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf bad >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    summary="$FIXTURE/.agent-harness/runs/$run_id/context/current/failure-summary.md"
    [ -s "$summary" ] || fail 'failure summary was not generated'
    maximum=$(conf_get "$FIXTURE/.agent-harness/policy/controls.conf" CONTEXT_CHECK_SUMMARY_MAXIMUM_BYTES)
    [ "$(file_size "$summary")" -le "$maximum" ] || fail 'failure summary exceeded its budget'
    grep -F 'Full log SHA-256' "$summary" >/dev/null || fail 'failure summary did not reference full evidence'
    assert_eq "$(active_state)" REMEDIATING
}


case_context_contract_drift_preserves_generation() {
    local run_id task_id current before after result
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    current="$FIXTURE/.agent-harness/runs/$run_id/context/current"
    before=$(cat "$current/context.sha256")
    sed 's/^GOAL=.*/GOAL=Unapproved changed goal/' "$FIXTURE/.agent-harness/tasks/$task_id/spec.conf" >"$FIXTURE/spec.tmp"
    mv "$FIXTURE/spec.tmp" "$FIXTURE/.agent-harness/tasks/$task_id/spec.conf"
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'contract drift stopped the context command'
    after=$(cat "$current/context.sha256")
    assert_eq "$after" "$before"
    result=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/last-build.conf" RESULT)
    assert_eq "$result" RECOVERY
    grep -F 'Set the value to good' "$current/base.md" >/dev/null || fail 'approved context was replaced by drifted task content'
    ! grep -F 'Unapproved changed goal' "$current/base.md" >/dev/null || fail 'drifted task content entered context'
    assert_eq "$(active_state)" IMPLEMENTING
}

case_context_parent_symlink_escape_rejected() {
    local run_id selections external result
    new_fixture; mkdir -p "$FIXTURE/app"; printf safe >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    selections="$FIXTURE/.agent-harness/runs/$run_id/context/selections.tsv"
    external=$(mktemp -d "${TMPDIR:-/tmp}/context-external.XXXXXX") || fail 'cannot create external source'
    printf 'EXTERNAL_SECRET_MARKER\n' >"$external/value.txt"
    rm -rf "$FIXTURE/app"; ln -s "$external" "$FIXTURE/app"
    printf 'app/value.txt\t0\t0\ttarget\n' >"$selections"
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'symlink escape stopped context command'
    result=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" RESULT)
    assert_eq "$result" INCOMPLETE
    ! grep -R -F 'EXTERNAL_SECRET_MARKER' "$FIXTURE/.agent-harness/runs/$run_id/context/current" >/dev/null || fail 'external content escaped into context'
    rm -rf "$external"
    assert_eq "$(active_state)" IMPLEMENTING
}

case_context_generation_tamper_detected() {
    local run_id current
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    current="$FIXTURE/.agent-harness/runs/$run_id/context/current"
    printf '\nINJECTED_CONTEXT_MARKER\n' >>"$current/base.md"
    assert_status 4 bash -c "cd '$FIXTURE' && ./.agent-harness/harness context show"
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"
}

case_context_base_hard_limit_enforced() {
    local task_id run_id goal maximum actual
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    goal=$(awk 'BEGIN {for (i=0;i<30000;i++) printf "G"}')
    awk -v goal="$goal" 'BEGIN{FS=OFS="="} $1=="GOAL" {$0="GOAL=" goal} {print}' "$FIXTURE/.agent-harness/tasks/$task_id/spec.conf" >"$FIXTURE/spec.tmp"
    mv "$FIXTURE/spec.tmp" "$FIXTURE/.agent-harness/tasks/$task_id/spec.conf"
    approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    maximum=$(conf_get "$FIXTURE/.agent-harness/policy/controls.conf" CONTEXT_BASE_MAXIMUM_BYTES)
    actual=$(file_size "$FIXTURE/.agent-harness/runs/$run_id/context/current/base.md")
    [ "$actual" -le "$maximum" ] || fail "base context exceeded hard limit: $actual > $maximum"
    grep -F 'BASE_REFERENCE_ONLY' "$FIXTURE/.agent-harness/runs/$run_id/context/current/warnings.tsv" >/dev/null || fail 'reference-only base warning missing'
}

case_context_bundle_count_bounded() {
    local run_id selections index result count maximum file_number total
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    selections="$FIXTURE/.agent-harness/runs/$run_id/context/selections.tsv"; : >"$selections"
    file_number=1
    while [ "$file_number" -le 6 ]; do
        awk -v marker="$file_number" 'BEGIN {for (i=0;i<40000;i++) printf "%s", marker; printf "\n"}' >"$FIXTURE/app/file-$file_number.txt"
        printf 'app/file-%s.txt\t0\t0\tbundle source %s\n' "$file_number" "$file_number" >>"$selections"
        file_number=$((file_number + 1))
    done
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'bundle overflow stopped context command'
    index="$FIXTURE/.agent-harness/runs/$run_id/context/current/index.tsv"
    result=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" RESULT)
    assert_eq "$result" INCOMPLETE
    count=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" BUNDLE_COUNT)
    maximum=$(conf_get "$FIXTURE/.agent-harness/policy/controls.conf" CONTEXT_MAXIMUM_BUNDLES)
    [ "$count" -le "$maximum" ] || fail 'bundle count exceeded configured maximum'
    grep -F $'LIMIT_REFERENCE\tapp/file-5.txt' "$index" >/dev/null || fail 'overflow source was not referenced'
    total=$(find "$FIXTURE/.agent-harness/runs/$run_id/context/current" -name 'bundle-*.md' -type f -exec wc -c {} \; | awk '{sum+=$1} END {print sum+0}')
    [ "$total" -le $((maximum * 49152)) ] || fail 'total embedded bundle size is unbounded'
    while IFS= read -r bundle; do
        [ "$(file_size "$bundle")" -le 49152 ] || fail "bundle exceeded hard limit: $bundle"
    done <<EOF_BUNDLES
$(find "$FIXTURE/.agent-harness/runs/$run_id/context/current" -name 'bundle-*.md' -type f -print | LC_ALL=C sort)
EOF_BUNDLES
}

case_context_working_memory_oversized_referenced() {
    local run_id memory status result maximum actual digest
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    memory="$FIXTURE/.agent-harness/runs/$run_id/context/working-memory.md"
    awk 'BEGIN {print "# Working Memory"; for (i=0;i<30000;i++) printf "M"; printf "\n"}' >"$memory"
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'oversized working memory stopped context command'
    status="$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf"
    result=$(conf_get "$status" RESULT); assert_eq "$result" CHUNKED
    assert_eq "$(conf_get "$status" WORKING_MEMORY_EMBEDDED)" 0
    maximum=$(conf_get "$status" WORKING_MEMORY_MAXIMUM_BYTES); actual=$(conf_get "$status" WORKING_MEMORY_BYTES)
    [ "$actual" -gt "$maximum" ] || fail 'working-memory test did not exceed budget'
    digest=$(sha256_file "$memory")
    grep -F "$digest" "$FIXTURE/.agent-harness/runs/$run_id/context/current/base.md" >/dev/null || fail 'oversized memory digest was not referenced'
}

case_context_duplicate_selections_deduplicated() {
    local run_id selections index count duplicates
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    selections="$FIXTURE/.agent-harness/runs/$run_id/context/selections.tsv"
    printf 'app/value.txt\t0\t0\tfirst\napp/value.txt\t0\t0\tsecond\n' >"$selections"
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'duplicate selection stopped context command'
    index="$FIXTURE/.agent-harness/runs/$run_id/context/current/index.tsv"
    count=$(awk -F '\t' '$2 == "app/value.txt" {count++} END {print count+0}' "$index")
    assert_eq "$count" 1
    duplicates=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" DUPLICATE_SELECTIONS)
    assert_eq "$duplicates" 1
}

case_context_selection_count_bounded() {
    local run_id selections number result omitted maximum
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    selections="$FIXTURE/.agent-harness/runs/$run_id/context/selections.tsv"; : >"$selections"
    number=1
    while [ "$number" -le 51 ]; do
        printf '%s\n' "$number" >"$FIXTURE/app/selection-$number.txt"
        printf 'app/selection-%s.txt\t0\t0\tselection %s\n' "$number" "$number" >>"$selections"
        number=$((number + 1))
    done
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'selection overflow stopped context command'
    result=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" RESULT); assert_eq "$result" INCOMPLETE
    omitted=$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" OMITTED_SELECTIONS); assert_eq "$omitted" 1
    maximum=$(conf_get "$FIXTURE/.agent-harness/policy/controls.conf" CONTEXT_MAXIMUM_SELECTIONS)
    [ "$(conf_get "$FIXTURE/.agent-harness/runs/$run_id/context/current/status.conf" EMBEDDED_SELECTIONS)" -le "$maximum" ] || fail 'embedded selection count exceeded maximum'
}

case_context_dynamic_markdown_fence() {
    local run_id selections bundle
    new_fixture; mkdir -p "$FIXTURE/app"; printf 'before\n```\ninside\n```\nafter\n' >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    selections="$FIXTURE/.agent-harness/runs/$run_id/context/selections.tsv"
    printf 'app/value.txt\t0\t0\tmarkdown source\n' >"$selections"
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'markdown source stopped context command'
    bundle="$FIXTURE/.agent-harness/runs/$run_id/context/current/bundle-001.md"
    grep -F '```` text' "$bundle" >/dev/null || fail 'source fence did not expand around embedded backticks'
}

case_context_publication_recovery() {
    local run_id root output
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    root="$FIXTURE/.agent-harness/runs/$run_id/context"
    mv "$root/current" "$root/previous"
    printf 'STATUS=SWITCHING\n' >"$root/publication.conf"
    output=$(cd "$FIXTURE" && ./.agent-harness/harness context show)
    assert_contains "$output" 'GENERATION_INTEGRITY=VALID'
    (cd "$FIXTURE" && ./.agent-harness/harness context build) >/dev/null || fail 'publication recovery failed'
    [ -d "$root/current" ] || fail 'current generation was not recovered'
    [ ! -f "$root/publication.conf" ] || fail 'publication recovery marker remained'
}

case_custom_inspector() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks"; printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/checks/inspect.sh" <<'EOF_INSPECT'
#!/usr/bin/env bash
printf 'architecture\tCustom architecture boundary detected\tHIGH\t1\t1\tapp/value.txt\tproject scan\tHuman confirmation required\n'
printf 'custom inspector diagnostic\n' >&2
EOF_INSPECT
    chmod +x "$FIXTURE/checks/inspect.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/project-inspector.conf" <<'EOF_INSPECT_CONF'
ID=project-inspector
EXECUTABLE=checks/inspect.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
PURPOSE=INSPECTION
OUTPUT_SCHEMA=observations-v1
TRUSTED_INPUT_1=checks/inspect.sh
EOF_INSPECT_CONF
    (cd "$FIXTURE" && ./.agent-harness/harness inspect) >/dev/null
    grep -F 'custom:project-inspector:project scan' "$FIXTURE/.agent-harness/runtime/convention-observations.tsv" >/dev/null || fail 'custom inspector observation missing'
    grep -F 'custom inspector diagnostic' "$FIXTURE/.agent-harness/runtime/inspection-checks/project-inspector.stderr.log" >/dev/null || fail 'custom inspector stderr evidence missing'
    assert_status 2 bash -c "cd '$FIXTURE' && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check project-inspector --coverage 'AC-001|project-inspector|static_check|Invalid verification use'"
}

case_task_amendment() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    result=$(cd "$FIXTURE" && ./.agent-harness/harness task amend --by reviewer --reason 'Scope requires amendment')
    assert_contains "$result" 'Created amended task'
    assert_eq "$(active_state)" INTAKE
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    [ ! -s "$FIXTURE/.agent-harness/tasks/$task_id/applicable-conventions.tsv" ] || fail 'amended conventions were not reset'
    [ ! -s "$FIXTURE/.agent-harness/tasks/$task_id/applicable-exceptions.tsv" ] || fail 'amended exceptions were not reset'
}

case_rethink_hold_acknowledgement() {
    local packet guidance
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task; printf bad >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    packet=$(cd "$FIXTURE" && ./.agent-harness/harness next --json)
    guidance=$(cd "$FIXTURE" && ./.agent-harness/harness next)
    assert_contains "$packet" '"next_action":{"command":"harness task acknowledge --by <name> --reason <text>"'
    assert_contains "$guidance" 'harness task acknowledge --by <name> --reason <text>'
    (cd "$FIXTURE" && ./.agent-harness/harness task acknowledge --by reviewer --reason 'Reviewed repeated failure and changed the repair plan') >/dev/null
    printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
}

case_rule_replacement() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id OLD-001 --category helpers --level SHOULD --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement MANUAL --example app/value.txt --rule 'Use the old helper convention.' --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id NEW-001 --category helpers --level SHOULD --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement MANUAL --example app/value.txt --rule 'Use the new helper convention.' --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions replace --id OLD-001 --with NEW-001 --reason 'New canonical helper pattern.' --by lead --trigger NEW_OR_MODIFIED --removal-date 2027-01-01) >/dev/null
    grep -F $'OLD-001	helpers	SHOULD	REPLACED' "$FIXTURE/.agent-harness/project/conventions/rules.tsv" >/dev/null || fail 'old rule not replaced'
}


case_allowed_hardlink() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; ln "$FIXTURE/app/value.txt" "$FIXTURE/app/copy.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness inventory policy add --type ALLOW_HARDLINK --path 'app/**' --reason 'Approved repository-local aliases.' --by reviewer) >/dev/null
    create_basic_task; approve_basic_task
}

case_allowed_submodule_metadata() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/vendor/repo/.git"; printf old >"$FIXTURE/app/value.txt"; printf pinned >"$FIXTURE/vendor/repo/.git/config"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness inventory policy add --type ALLOW_SUBMODULE --path vendor/repo --reason 'Pinned read-only submodule metadata.' --by reviewer) >/dev/null
    create_basic_task; approve_basic_task
    (cd "$FIXTURE" && ./.agent-harness/harness audit) >/dev/null
}

case_convention_dimensions() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; printf 'package app
' >"$FIXTURE/app/value.go"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness conventions module add --id backend --root 'app/**' --language go --framework standard --owner backend --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id DIM-YES --category functions --level SHOULD --source DECLARED --module backend --path 'app/**' --language go --file-type go --task-profile feature --risk high --trigger NEW_OR_MODIFIED --enforcement MANUAL --example app/value.go --rule 'High-risk Go features should preserve function conventions.' --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id DIM-NO --category functions --level SHOULD --source DECLARED --module backend --path 'app/**' --language go --file-type go --task-profile bugfix --risk high --trigger NEW_OR_MODIFIED --enforcement MANUAL --example app/value.go --rule 'Bugfix-only convention.' --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Feature --goal Goal --stakeholders users --profile feature --risk high --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct check') >/dev/null
    understand_active_task; approve_basic_task
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    grep -F DIM-YES "$FIXTURE/.agent-harness/tasks/$task_id/applicable-conventions.tsv" >/dev/null || fail 'matching dimension rule missing'
    ! grep -F DIM-NO "$FIXTURE/.agent-harness/tasks/$task_id/applicable-conventions.tsv" >/dev/null || fail 'nonmatching profile rule selected'
}

case_expired_exception_not_applied() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; register_failing_check expired-fail
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id EXP-001 --category persistence --level MUST --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement AUTOMATED --check expired-fail --example app/value.txt --rule 'Mandatory rule remains active after exception expiry.' --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions exception add --id EX-OLD --rule EXP-001 --path 'app/**' --expires 2000-01-01T00:00:00Z --reason 'Expired exception.' --by lead) >/dev/null
    create_basic_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
}

case_revoked_exception_not_applied() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; register_failing_check revoked-fail
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id REV-001 --category persistence --level MUST --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement AUTOMATED --check revoked-fail --example app/value.txt --rule 'Mandatory rule remains after revocation.' --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions exception add --id EX-REV --rule REV-001 --path 'app/**' --reason 'Temporary exception.' --by lead) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness conventions exception revoke --id EX-REV --reason 'Exception no longer approved.' --by lead) >/dev/null
    create_basic_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
}

case_project_conventions_preserved_by_release_overlay() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id KEEP-001 --category errors --level SHOULD --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement MANUAL --example app/value.txt --rule 'Preserve project authority during updates.' --by reviewer) >/dev/null
    before=$(sha256_file "$FIXTURE/.agent-harness/project/conventions/rules.tsv")
    (cd "$SOURCE_ROOT" && tar -cf - -T .agent-harness/release-files.txt .agent-harness/manifest.tsv) | (cd "$FIXTURE" && tar -xf -)
    after=$(sha256_file "$FIXTURE/.agent-harness/project/conventions/rules.tsv")
    assert_eq "$after" "$before"
}

case_advisory_mutation_isolated() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    cat >"$FIXTURE/checks/advisory.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
printf poisoned > app/value.txt
exit 1
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/advisory.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/advisory-mutate.conf" <<'EOF_CHECK'
ID=advisory-mutate
EXECUTABLE=checks/advisory.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
PHASE=STATIC
ORDER=1
TRUSTED_INPUT_1=checks/advisory.sh
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness conventions add --id SAFE-ADVISORY --category architecture --level SHOULD --source DECLARED --path 'app/**' --trigger NEW_OR_MODIFIED --enforcement AUTOMATED --check advisory-mutate --example app/value.txt --phase STATIC --order 1 --rule 'Advisory checks cannot alter later mandatory evidence.' --by reviewer) >/dev/null
    create_basic_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    assert_eq "$(active_state)" PASSED
    grep -q '^good$' "$FIXTURE/app/value.txt" || fail 'advisory check mutated repository'
}

case_prepare_outputs_promoted() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks"; printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/checks/prepare.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
mkdir -p generated
printf prepared > generated/out.txt
EOF_SCRIPT
    cat >"$FIXTURE/checks/check-generated.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
grep -q prepared generated/out.txt
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/prepare.sh" "$FIXTURE/checks/check-generated.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/prepare-generated.conf" <<'EOF_CHECK'
ID=prepare-generated
EXECUTABLE=checks/prepare.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
PHASE=PREPARE
ORDER=10
TRUSTED_INPUT_1=checks/prepare.sh
TOOL_1=mkdir
OUTPUT_1=generated/**
EOF_CHECK
    cat >"$FIXTURE/.agent-harness/config/commands/check-generated.conf" <<'EOF_CHECK'
ID=check-generated
EXECUTABLE=checks/check-generated.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=automated_test
PHASE=TEST
ORDER=10
TOOL_1=grep
TRUSTED_INPUT_1=checks/check-generated.sh
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Generate --goal 'Validate generated output' --stakeholders users --criterion 'AC-001|Generated output is valid' --scope 'app/**' --scope 'generated/**' --check prepare-generated --check check-generated --coverage 'AC-001|check-generated|automated_test|Checks promoted generated output') >/dev/null
    understand_active_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    assert_eq "$(active_state)" PASSED
    [ ! -e "$FIXTURE/generated/out.txt" ] || fail 'prepare output leaked into repository'
}

case_prepare_output_outside_scope_blocked() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    cat >"$FIXTURE/checks/prepare.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
mkdir -p generated
printf prepared > generated/out.txt
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/prepare.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/prepare-generated.conf" <<'EOF_CHECK'
ID=prepare-generated
EXECUTABLE=checks/prepare.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
PHASE=PREPARE
ORDER=10
TRUSTED_INPUT_1=checks/prepare.sh
TOOL_1=mkdir
OUTPUT_1=generated/**
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Generate --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check check-app --check prepare-generated --coverage 'AC-001|check-app|automated_test|Checks value') >/dev/null
    understand_active_task
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_git_commit_after_approval() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && git init -q && git config user.name Test && git config user.email test@example.invalid && git add -A && git commit -qm baseline)
    create_basic_task; approve_basic_task
    (cd "$FIXTURE" && printf good >app/value.txt && git add app/value.txt && git commit -qm implementation)
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    assert_eq "$(active_state)" PASSED
}

case_git_staging_after_approval() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && git init -q && git config user.name Test && git config user.email test@example.invalid && git add -A && git commit -qm baseline)
    create_basic_task; approve_basic_task
    (cd "$FIXTURE" && printf good >app/value.txt && git add app/value.txt)
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    assert_eq "$(active_state)" PASSED
}

case_git_snapshot_check() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks"; printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/checks/git-check.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
git rev-parse --is-inside-work-tree | grep -q true
git rev-parse harness-snapshot >/dev/null
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/git-check.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/git-check.conf" <<'EOF_CHECK'
ID=git-check
EXECUTABLE=checks/git-check.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=automated_test
GIT_MODE=READ_ONLY_SNAPSHOT
TOOL_1=git
TOOL_2=grep
TRUSTED_INPUT_1=checks/git-check.sh
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Git --goal Goal --stakeholders users --criterion 'AC-001|Git metadata available' --scope 'app/**' --check git-check --coverage 'AC-001|git-check|automated_test|Checks controlled Git metadata') >/dev/null
    understand_active_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
}

case_understanding_evidence_missing_path() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task understand --by reviewer --current-behavior existing --entry-points app/value.txt --data-flow local --dependencies none --interface-impact none --compatibility-risk low --scope-rationale focused --check-rationale direct --rollback-plan restore --security-impact none --data-impact none --operational-impact none --nfr-impact none --module 'repository|All' --evidence 'OTHER|missing/file.txt|-|Missing evidence' --inspection-skip-reason 'Synthetic fixture' --step modify) >/dev/null
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_inspection_binding_detects_drift() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness inspect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task understand --by reviewer --current-behavior existing --entry-points app/value.txt --data-flow local --dependencies none --interface-impact none --compatibility-risk low --scope-rationale focused --check-rationale direct --rollback-plan restore --security-impact none --data-impact none --operational-impact none --nfr-impact none --module 'repository|All' --evidence 'OTHER|app/value.txt|-|Evidence' --inspection-current --step modify) >/dev/null
    printf drift >"$FIXTURE/unrelated.txt"
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_greenfield_project_contract() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness project define --name Demo --goal 'Provide a service' --success 'Acceptance checks pass' --architecture 'Layered service' --technology-constraints 'Bash-compatible project harness' --data-model 'Repository files and contracts' --api-strategy 'Repository-local CLI' --security 'Authenticated boundary' --reliability 'Graceful failure' --deployment 'Container platform' --migration-strategy 'Forward-compatible project changes' --owner team --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness project architecture --id ARCH-001 --a service --b app --c 'Application module' --d team --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness project nfr --id NFR-001 --a availability --b '99.9%' --c monthly --d owner --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness project decision --id ADR-001 --a architecture --b 'Use layers' --c 'Keeps boundaries explicit' --d ACCEPTED --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness project interface --id API-001 --a HTTP --b '/value' --c request --d response --e owner --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness project validate) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Green --goal Goal --stakeholders users --project-mode greenfield --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task understand --by architect --current-behavior 'New project' --entry-points app/value.txt --data-flow local --dependencies none --interface-impact none --compatibility-risk none --scope-rationale focused --check-rationale direct --rollback-plan restore --security-impact reviewed --data-impact none --operational-impact none --nfr-impact tracked --module 'repository|Initial repository' --step implement) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by architect) >/dev/null
}

case_malformed_identifiers_rejected() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness conventions add --id '../BAD' --category errors --level MUST --source DECLARED --path 'app/**' --trigger ANY --enforcement MANUAL --example app/value.txt --rule bad --by reviewer"
}

case_unsupported_filename_rejected() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; printf bad >"$FIXTURE/app/"$'bad\tname'
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness doctor"
}

case_toolchain_drift_rejected() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks" "$FIXTURE/toolbin"; printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/toolbin/helper" <<'EOF_TOOL'
#!/usr/bin/env bash
exit 0
EOF_TOOL
    chmod +x "$FIXTURE/toolbin/helper"
    cat >"$FIXTURE/checks/tool-check.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
helper
grep -q good app/value.txt
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/tool-check.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/tool-check.conf" <<'EOF_CHECK'
ID=tool-check
EXECUTABLE=checks/tool-check.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=automated_test
TOOL_1=helper
TOOL_2=grep
TRUSTED_INPUT_1=checks/tool-check.sh
EOF_CHECK
    (cd "$FIXTURE" && PATH="$FIXTURE/toolbin:$PATH" ./.agent-harness/harness task create --title Tool --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check tool-check --coverage 'AC-001|tool-check|automated_test|Direct') >/dev/null
    understand_active_task
    (cd "$FIXTURE" && PATH="$FIXTURE/toolbin:$PATH" ./.agent-harness/harness approve --by reviewer) >/dev/null
    printf '#!/usr/bin/env bash\nexit 1\n' >"$FIXTURE/toolbin/helper"; chmod +x "$FIXTURE/toolbin/helper"; printf good >"$FIXTURE/app/value.txt"
    assert_status 3 bash -c "cd '$FIXTURE' && PATH='$FIXTURE/toolbin:$PATH' ./.agent-harness/harness verify"
}



case_bound_toolchain_ignores_current_path() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks" "$FIXTURE/toolbin"; printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/toolbin/helper" <<'EOF_TOOL'
#!/usr/bin/env bash
exit 0
EOF_TOOL
    chmod +x "$FIXTURE/toolbin/helper"
    cat >"$FIXTURE/checks/bound-tool.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
helper
grep -q good app/value.txt
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/bound-tool.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/bound-tool.conf" <<'EOF_CHECK'
ID=bound-tool
EXECUTABLE=checks/bound-tool.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=automated_test
TOOL_1=helper
TOOL_2=grep
TRUSTED_INPUT_1=checks/bound-tool.sh
EOF_CHECK
    (cd "$FIXTURE" && PATH="$FIXTURE/toolbin:$PATH" ./.agent-harness/harness task create --title Tool --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check bound-tool --coverage 'AC-001|bound-tool|automated_test|Uses approved toolchain paths') >/dev/null
    understand_active_task
    (cd "$FIXTURE" && PATH="$FIXTURE/toolbin:$PATH" ./.agent-harness/harness approve --by reviewer) >/dev/null
    printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && PATH=/usr/bin:/bin ./.agent-harness/harness verify) >/dev/null
    assert_eq "$(active_state)" PASSED
}

case_undeclared_tool_unavailable() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks"; printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/checks/undeclared.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
grep -q good app/value.txt
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/undeclared.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/undeclared.conf" <<'EOF_CHECK'
ID=undeclared
EXECUTABLE=checks/undeclared.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=automated_test
TRUSTED_INPUT_1=checks/undeclared.sh
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Tool --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check undeclared --coverage 'AC-001|undeclared|automated_test|Requires declared subprocess tool') >/dev/null
    understand_active_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
}

case_external_anchor_attestation() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    anchor=$(mktemp "${TMPDIR:-/tmp}/harness-anchor.XXXXXX"); rm -f "$anchor"
    (cd "$FIXTURE" && ./.agent-harness/harness anchor configure --file "$anchor" --by reviewer) >/dev/null
    create_basic_task; approve_basic_task; printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify >/dev/null && ./.agent-harness/harness finalize >/dev/null)
    [ -s "$anchor" ] || fail 'external anchor was not written'
    run_id=$(find "$FIXTURE/.agent-harness/runs" -mindepth 1 -maxdepth 1 -type d | head -1)
    (cd "$FIXTURE" && ./.agent-harness/harness attest verify "$run_id/attestation.conf") >/dev/null
    rm -f "$anchor"
}


case_explicit_inspection_decision_required() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct') >/dev/null
    assert_status 2 bash -c "cd '$FIXTURE' && ./.agent-harness/harness task understand --by reviewer --current-behavior existing --entry-points app/value.txt --data-flow local --dependencies none --interface-impact none --compatibility-risk low --scope-rationale focused --check-rationale direct --rollback-plan restore --security-impact none --data-impact none --operational-impact none --nfr-impact none --module 'repository|All' --evidence 'OTHER|app/value.txt|-|Evidence' --step modify"
}

case_os_user_identity_policy() {
    local current_user
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    current_user=$(id -un)
    (cd "$FIXTURE" && ./.agent-harness/harness identity policy set --mode OS_USER --by "$current_user") >/dev/null
    create_basic_task
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by not-the-current-user"
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by "$current_user") >/dev/null
}

case_high_risk_independent_final_review() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness identity policy set --mode ENVIRONMENT --env-key HARNESS_TEST_PRINCIPAL --by administrator) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title High --goal Goal --stakeholders users --risk high --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct') >/dev/null
    understand_active_task
    (cd "$FIXTURE" && HARNESS_TEST_PRINCIPAL=reviewer ./.agent-harness/harness approve --by reviewer) >/dev/null
    printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    assert_status 3 bash -c "cd '$FIXTURE' && HARNESS_TEST_PRINCIPAL=reviewer ./.agent-harness/harness approve --final --by reviewer"
    (cd "$FIXTURE" && HARNESS_TEST_PRINCIPAL=final-reviewer ./.agent-harness/harness approve --final --by final-reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness finalize) >/dev/null
}

case_submodule_write_scope_blocked() {
    new_fixture; mkdir -p "$FIXTURE/vendor/repo/.git"; printf pinned >"$FIXTURE/vendor/repo/.git/config"; printf old >"$FIXTURE/vendor/repo/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness inventory policy add --type ALLOW_SUBMODULE --path vendor/repo --reason 'Pinned read-only submodule metadata.' --by reviewer) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Submodule --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'vendor/repo/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task understand --by reviewer --current-behavior existing --entry-points vendor/repo/value.txt --data-flow local --dependencies none --interface-impact none --compatibility-risk low --scope-rationale focused --check-rationale direct --rollback-plan restore --security-impact none --data-impact none --operational-impact none --nfr-impact none --module 'repository|All' --evidence 'OTHER|vendor/repo/value.txt|-|Evidence' --inspection-skip-reason 'Synthetic fixture' --step modify) >/dev/null
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}


case_finalization_phase_recovery() {
    local phase run_id task_id verification tree journal status
    for phase in ${HARNESS_FINALIZATION_PHASES:-PREPARED STATE_FINALIZED TASK_MARKED ATTESTED ANCHORED}; do
        new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
        printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
        run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
        task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
        journal="$FIXTURE/.agent-harness/runs/$run_id/finalization-journal.conf"
        if [ "$phase" = PREPARED ]; then
            verification="$FIXTURE/.agent-harness/runs/$run_id/verification.conf"
            tree=$(sed -n 's/^VERIFIED_TREE_HASH=//p' "$verification")
            cat >"$FIXTURE/.agent-harness/runs/$run_id/finalization.conf" <<EOF_FINAL
TASK_ID=$task_id
RUN_ID=$run_id
VERIFICATION_HASH=$(sha256_file "$verification")
FINAL_TREE_HASH=$tree
FINALIZED_AT=2099-01-01T00:00:00Z
EOF_FINAL
            cat >"$journal" <<EOF_JOURNAL
STATUS=PREPARED
RUN_ID=$run_id
TASK_ID=$task_id
UPDATED_AT=2099-01-01T00:00:00Z
EOF_JOURNAL
        else
            (cd "$FIXTURE" && ./.agent-harness/harness finalize) >/dev/null
            cat >"$FIXTURE/.agent-harness/runtime/active-run.conf" <<EOF_POINTER
TASK_ID=$task_id
RUN_ID=$run_id
WORKTREE_ID=standalone
UPDATED_AT=2099-01-01T00:00:00Z
EOF_POINTER
            sed "s/^STATUS=.*/STATUS=$phase/" "$journal" >"$journal.tmp" && mv "$journal.tmp" "$journal"
            case "$phase" in
                STATE_FINALIZED)
                    sed 's/^STATUS=.*/STATUS=LOCKED/' "$FIXTURE/.agent-harness/tasks/$task_id/spec.conf" >"$FIXTURE/.agent-harness/tasks/$task_id/spec.conf.tmp" && mv "$FIXTURE/.agent-harness/tasks/$task_id/spec.conf.tmp" "$FIXTURE/.agent-harness/tasks/$task_id/spec.conf"
                    rm -f "$FIXTURE/.agent-harness/runs/$run_id/attestation.conf"
                    ;;
                TASK_MARKED) rm -f "$FIXTURE/.agent-harness/runs/$run_id/attestation.conf" ;;
            esac
        fi
        (cd "$FIXTURE" && ./.agent-harness/harness recover) >/dev/null || fail "finalization recovery failed for $phase"
        status=$(sed -n 's/^STATUS=//p' "$journal")
        assert_eq "$status" COMPLETED
        assert_eq "$(active_state)" NO_TASK
        (cd "$FIXTURE" && ./.agent-harness/harness audit) >/dev/null || fail "audit failed after finalization recovery $phase"
        rm -rf "$FIXTURE"
    done
    FIXTURE=""
}

case_amendment_phase_recovery() {
    local phase expected_status expected_state old_run old_task new_task new_run journal
    for phase in PREPARED PREDECESSOR_TERMINATED SUCCESSOR_CREATED POINTER_SWITCHED; do
        new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
        old_run=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
        old_task=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
        new_task="TASK-20990101000000-${RANDOM}"
        new_run="RUN-20990101000000-${RANDOM}"
        PHASE="$phase" OLD_RUN="$old_run" OLD_TASK="$old_task" NEW_TASK="$new_task" NEW_RUN="$new_run" bash -s -- "$FIXTURE" <<'EOF_PHASE' || fail "cannot construct amendment phase $phase"
set -eu
root=$1
cd "$root"
. .agent-harness/lib/common.sh
. .agent-harness/lib/store.sh
. .agent-harness/lib/inventory_policy.sh
. .agent-harness/lib/project_contract.sh
. .agent-harness/lib/identity.sh
. .agent-harness/lib/toolchain.sh
. .agent-harness/lib/policy.sh
. .agent-harness/lib/conventions.sh
. .agent-harness/lib/workflow.sh
. .agent-harness/lib/understanding.sh
harness_init_paths "$PWD"
harness_ensure_layout
journal=$HARNESS_RUNTIME_DIR/supersede.conf
if [ "$PHASE" != PREPARED ]; then
    old_dir=$(task_dir "$OLD_TASK"); new_dir=$(task_dir "$NEW_TASK")
    mkdir -p "$new_dir"
    cp "$old_dir"/* "$new_dir" 2>/dev/null || true
    sed "s/^TASK_ID=.*/TASK_ID=$NEW_TASK/; s/^STATUS=.*/STATUS=DRAFT/" "$old_dir/spec.conf" | atomic_write "$new_dir/spec.conf"
    sed "s/^TASK_ID=.*/TASK_ID=$NEW_TASK/; s/^STATUS=.*/STATUS=DRAFT/" "$old_dir/plan.conf" | atomic_write "$new_dir/plan.conf"
    sed "s/^TASK_ID=.*/TASK_ID=$NEW_TASK/; s/^STATUS=.*/STATUS=REVIEWED/" "$old_dir/understanding.conf" | atomic_write "$new_dir/understanding.conf"
    rm -f "$new_dir/approval.conf" "$new_dir/final-review.conf" "$new_dir/convention-review.tsv" "$new_dir/approval-identity.conf" "$new_dir/second-approval-identity.conf"
    : >"$new_dir/applicable-conventions.tsv"; : >"$new_dir/applicable-exceptions.tsv"
    transition_run "$OLD_RUN" CANCELLED human 'simulated amendment interruption'
    sed 's/^STATUS=.*/STATUS=SUPERSEDED/' "$old_dir/spec.conf" | atomic_write "$old_dir/spec.conf"
fi
if [ "$PHASE" = SUCCESSOR_CREATED ] || [ "$PHASE" = POINTER_SWITCHED ]; then
    create_run_with_id "$NEW_TASK" "$OLD_RUN" "$NEW_RUN" 0 >/dev/null
fi
if [ "$PHASE" = POINTER_SWITCHED ]; then
    write_active_pointer "$NEW_TASK" "$NEW_RUN"
fi
task_amend_journal_write "$journal" "$PHASE" "$OLD_RUN" "$OLD_TASK" "$NEW_TASK" "$NEW_RUN" reviewer 'simulated crash'
EOF_PHASE
        (cd "$FIXTURE" && ./.agent-harness/harness recover) >/dev/null || fail "recover failed for $phase"
        journal="$FIXTURE/.agent-harness/runtime/supersede.conf"
        if [ "$phase" = PREPARED ]; then
            expected_status=ROLLED_BACK; expected_state=IMPLEMENTING
            assert_eq "$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")" "$old_task"
        else
            expected_status=COMPLETED; expected_state=INTAKE
            assert_eq "$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")" "$new_task"
        fi
        assert_eq "$(sed -n 's/^STATUS=//p' "$journal")" "$expected_status"
        assert_eq "$(active_state)" "$expected_state"
        rm -rf "$FIXTURE"
    done
    FIXTURE=""
}


case_duplicate_and_unknown_config_rejected() {
    new_fixture
    cat >"$FIXTURE/.agent-harness/config/commands/duplicate.conf" <<'EOF_CHECK'
ID=duplicate
ID=other
EXECUTABLE=true
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
EOF_CHECK
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness doctor"
    rm -f "$FIXTURE/.agent-harness/config/commands/duplicate.conf"
    cat >"$FIXTURE/.agent-harness/config/commands/unknown.conf" <<'EOF_CHECK'
ID=unknown
EXECUTABLE=true
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
UNSUPPORTED_POLICY=yes
EOF_CHECK
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness doctor"
    rm -f "$FIXTURE/.agent-harness/config/commands/unknown.conf"
    cat >"$FIXTURE/.agent-harness/config/commands/gap.conf" <<'EOF_CHECK'
ID=gap
EXECUTABLE=true
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
ARG_2=value
EOF_CHECK
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness doctor"
}

case_required_generated_output() {
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/checks"; printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/checks/generate.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
mkdir -p generated
printf canonical > generated/out.txt
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/generate.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/required-generated.conf" <<'EOF_CHECK'
ID=required-generated
EXECUTABLE=checks/generate.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
PHASE=PREPARE
ORDER=10
OUTPUT_DISPOSITION=REQUIRED_IN_REPOSITORY
TRUSTED_INPUT_1=checks/generate.sh
TOOL_1=mkdir
OUTPUT_1=generated/**
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Generated --goal 'Commit canonical generated output' --stakeholders users --criterion 'AC-001|Generated output is current' --scope 'app/**' --scope 'generated/**' --check required-generated --coverage 'AC-001|required-generated|static_check|Regeneration must produce no diff') >/dev/null
    understand_active_task; approve_basic_task
    printf good >"$FIXTURE/app/value.txt"
    assert_status 5 bash -c "cd '$FIXTURE' && ./.agent-harness/harness verify"
    mkdir -p "$FIXTURE/generated"; printf canonical >"$FIXTURE/generated/out.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    assert_eq "$(active_state)" PASSED
}

case_external_verified_identity() {
    local verifier evidence subject
    new_fixture
    verifier=$(mktemp "${TMPDIR:-/tmp}/identity-verifier.XXXXXX")
    cat >"$verifier" <<'EOF_VERIFIER'
#!/usr/bin/env bash
set -u
evidence=$HARNESS_IDENTITY_EVIDENCE
subject=$(sed -n 's/^SUBJECT_HASH=//p' "$evidence")
signature=$(sed -n 's/^SIGNATURE=//p' "$evidence")
issuer=$(sed -n 's/^ISSUER=//p' "$evidence")
[ "$subject" = "$HARNESS_IDENTITY_SUBJECT_HASH" ]
[ "$issuer" = "$HARNESS_IDENTITY_ISSUER" ]
[ "$signature" = "signed:$subject:$issuer" ]
EOF_VERIFIER
    chmod +x "$verifier"
    (cd "$FIXTURE" && ./.agent-harness/harness identity policy set --mode EXTERNAL_VERIFIED --verifier "$verifier" --issuer company-ci --by security-admin) >/dev/null
    mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task
    subject=$(cd "$FIXTURE" && ./.agent-harness/harness task approval-subject)
    evidence=$(mktemp "${TMPDIR:-/tmp}/identity-evidence.XXXXXX")
    cat >"$evidence" <<EOF_EVIDENCE
PRINCIPAL=reviewer
DECISION=APPROVE
SUBJECT_HASH=$subject
ISSUER=company-ci
SIGNATURE=signed:$subject:company-ci
SIGNATURE_FORMAT=test
SIGNED_AT=2099-01-01T00:00:00Z
EOF_EVIDENCE
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by reviewer --identity-evidence "$evidence") >/dev/null
    assert_eq "$(active_state)" IMPLEMENTING
    rm -f "$verifier" "$evidence"
}

case_external_anchor_adapter() {
    local adapter ledger
    new_fixture
    ledger=$(mktemp "${TMPDIR:-/tmp}/anchor-ledger.XXXXXX"); : >"$ledger"
    adapter=$(mktemp "${TMPDIR:-/tmp}/anchor-adapter.XXXXXX")
    cat >"$adapter" <<EOF_ADAPTER
#!/usr/bin/env bash
set -u
ledger='$ledger'
case "\$HARNESS_ANCHOR_ACTION" in
  APPEND)
    grep -Fx "\$HARNESS_ATTESTATION_HASH" "\$ledger" >/dev/null 2>&1 || printf '%s\n' "\$HARNESS_ATTESTATION_HASH" >>"\$ledger"
    ;;
  CONTAINS)
    grep -Fx "\$HARNESS_ATTESTATION_HASH" "\$ledger" >/dev/null 2>&1
    ;;
  *) exit 2 ;;
esac
EOF_ADAPTER
    chmod +x "$adapter"
    (cd "$FIXTURE" && ./.agent-harness/harness anchor configure --adapter "$adapter" --by security-admin) >/dev/null
    mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify >/dev/null && ./.agent-harness/harness finalize >/dev/null)
    [ -s "$ledger" ] || fail 'anchor adapter did not record attestation'
    (cd "$FIXTURE" && ./.agent-harness/harness audit) >/dev/null
    rm -f "$adapter" "$ledger"
}

case_force_cross_host_lock_recovery() {
    new_fixture
    mkdir -p "$FIXTURE/.agent-harness/runtime/.lock"
    cat >"$FIXTURE/.agent-harness/runtime/.lock/owner.conf" <<'EOF_OWNER'
PID=999999
HOST=retired-build-host
OPERATION=verify
STARTED_AT=2099-01-01T00:00:00Z
EOF_OWNER
    assert_status 4 bash -c "cd '$FIXTURE' && ./.agent-harness/harness recover"
    (cd "$FIXTURE" && ./.agent-harness/harness recover --force-lock --reason 'Retired host cannot release the lock.' --by reviewer) >/dev/null
    [ ! -d "$FIXTURE/.agent-harness/runtime/.lock" ] || fail 'forced recovery did not clear lock'
    find "$FIXTURE/.agent-harness/runtime/forced-lock-recoveries" -type f -name '*.conf' -print | grep . >/dev/null 2>&1 || fail 'forced recovery was not audited'
}

case_verification_metrics() {
    local run_id metrics
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    run_id=$(sed -n 's/^RUN_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    metrics="$FIXTURE/.agent-harness/runs/$run_id/artifacts/verification-metrics.conf"
    [ -s "$metrics" ] || fail 'verification metrics missing'
    grep -q '^STATUS=PASSED$' "$metrics" || fail 'verification metrics status missing'
    grep -q '^CHECK_COUNT=1$' "$metrics" || fail 'verification metrics check count incorrect'
}

case_local_anchor_chain_tamper_detected() {
    local anchor
    new_fixture; anchor=$(mktemp "${TMPDIR:-/tmp}/local-anchor.XXXXXX"); rm -f "$anchor"
    (cd "$FIXTURE" && ./.agent-harness/harness anchor configure --file "$anchor" --by reviewer) >/dev/null
    mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify >/dev/null && ./.agent-harness/harness finalize >/dev/null)
    sed 's/GENESIS/TAMPERED/' "$anchor" >"$anchor.tmp" && mv "$anchor.tmp" "$anchor"
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"
    rm -f "$anchor"
}


case_audit_read_only() {
    local package before after
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-readonly-package.XXXXXX") || fail 'cannot create package path'
    rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export clean package'
    before=$(test_tree_digest "$package") || fail 'cannot digest clean package before audit'
    (cd "$package" && ./.agent-harness/harness doctor >/dev/null && ./.agent-harness/harness audit >/dev/null) || fail 'read-only diagnostics failed'
    after=$(test_tree_digest "$package") || fail 'cannot digest clean package after audit'
    assert_eq "$after" "$before"
    [ ! -e "$package/.agent-harness/runtime" ] || fail 'audit materialized runtime state'
    [ ! -e "$package/.agent-harness/project" ] || fail 'audit materialized project state'
    rm -rf "$package"
}

case_intake_json_defaults() {
    local packet
    new_fixture
    mkdir -p "$FIXTURE/app"
    printf old >"$FIXTURE/app/value.txt"
    mkdir -p "$FIXTURE/.agent-harness/config/commands"
    cat >"$FIXTURE/.agent-harness/config/commands/default-metadata.conf" <<'EOF_CHECK'
ID=default-metadata
EXECUTABLE=grep
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=automated_test
ARG_1=-qx
ARG_2=good
ARG_3=app/value.txt
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Defaults --goal Goal --stakeholders users --criterion 'AC-001|Good' --scope 'app/**' --check default-metadata --coverage 'AC-001|default-metadata|automated_test|Direct') >/dev/null
    packet=$(cd "$FIXTURE" && ./.agent-harness/harness next --json) || fail 'cannot emit intake packet'
    assert_contains "$packet" '"phase":"TEST"'
    assert_contains "$packet" '"order":100'
    if printf '%s' "$packet" | grep -E '"order":[,}]' >/dev/null 2>&1; then
        fail 'intake packet contains an empty numeric field'
    fi
    return 0
}

case_package_validate_strict() {
    local package
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-strict-package.XXXXXX") || fail 'cannot create package path'
    rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export strict package'
    (cd "$package" && ./.agent-harness/harness.sh validate-package --strict >/dev/null) || fail 'strict package validation failed'
    rm -rf "$package"
}

case_install_preserves_repository() {
    local package repository before after
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-install-package.XXXXXX") || fail 'cannot create package path'
    repository=$(mktemp -d "${TMPDIR:-/tmp}/harness-install-target.XXXXXX") || fail 'cannot create repository'
    rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    printf 'business-owned README\n' >"$repository/README.md"
    mkdir -p "$repository/app"; printf keep >"$repository/app/canary.txt"
    before=$(sha256_text "$(cat "$repository/README.md")|$(cat "$repository/app/canary.txt")")
    (cd "$package" && ./.agent-harness/harness.sh install --repository "$repository" >/dev/null) || fail 'install failed'
    after=$(sha256_text "$(cat "$repository/README.md")|$(cat "$repository/app/canary.txt")")
    assert_eq "$after" "$before"
    (cd "$repository" && ./.agent-harness/harness doctor >/dev/null) || fail 'installed doctor failed'
    rm -rf "$package" "$repository"
}

case_greenfield_lifecycle_e2e() {
    new_fixture
    mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    (cd "$FIXTURE" && ./.agent-harness/harness project define --name Green --goal 'Create a service' --success 'Acceptance checks pass' --architecture 'Layered service' --technology-constraints 'Portable repository implementation' --data-model 'Repository files' --api-strategy 'Repository-local interface' --security 'Reviewed boundary' --reliability 'Fail closed' --deployment 'Container platform' --migration-strategy 'Forward-compatible changes' --owner team --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness project architecture --id ARCH-001 --a service --b app --c 'Application boundary' --d team --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness project nfr --id NFR-001 --a reliability --b 'All checks pass' --c release --d team --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness project decision --id ADR-001 --a architecture --b 'Use layers' --c 'Explicit boundary' --d ACCEPTED --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness project interface --id API-001 --a CLI --b value --c request --d response --e team --by architect) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Greenfield --goal 'Deliver initial value' --stakeholders users --project-mode greenfield --risk high --criterion 'AC-001|Value is good' --scope 'app/**' --check check-app --coverage 'AC-001|check-app|automated_test|Direct value check') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task understand --by architect --current-behavior 'New project contract' --entry-points app/value.txt --data-flow 'Check reads value' --dependencies none --interface-impact 'Initial interface' --compatibility-risk none --scope-rationale focused --check-rationale direct --rollback-plan restore --security-impact reviewed --data-impact none --operational-impact none --nfr-impact tracked --module 'repository|Initial module' --inspection-skip-reason 'Greenfield fixture' --step implement) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by architect) >/dev/null
    printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify >/dev/null) || fail 'greenfield verification failed'
    (cd "$FIXTURE" && ./.agent-harness/harness approve --final --by release-reviewer >/dev/null && ./.agent-harness/harness finalize >/dev/null && ./.agent-harness/harness audit >/dev/null) || fail 'greenfield finalization failed'
}

case_upgrade_preserves_state() {
    local package repository command_hash module_hash
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-upgrade-package.XXXXXX") || fail 'cannot create package'
    repository=$(mktemp -d "${TMPDIR:-/tmp}/harness-upgrade-target.XXXXXX") || fail 'cannot create repository'
    rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    (cd "$package" && ./.agent-harness/harness.sh install --repository "$repository" >/dev/null) || fail 'install failed'
    mkdir -p "$repository/app"; printf value >"$repository/app/value.txt"
    (cd "$repository" && ./.agent-harness/harness conventions module add --id app --root 'app/**' --language text --framework none --owner team --by architect >/dev/null) || fail 'cannot create preserved project state'
    cat >"$repository/.agent-harness/config/commands/custom-check.conf" <<'EOF_CHECK'
ID=custom-check
EXECUTABLE=test
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
ARG_1=-f
ARG_2=app/value.txt
EOF_CHECK
    command_hash=$(sha256_file "$repository/.agent-harness/config/commands/custom-check.conf")
    module_hash=$(sha256_file "$repository/.agent-harness/project/modules.tsv")
    (cd "$package" && ./.agent-harness/harness.sh upgrade --repository "$repository" >/dev/null) || fail 'upgrade failed'
    assert_eq "$(sha256_file "$repository/.agent-harness/config/commands/custom-check.conf")" "$command_hash"
    assert_eq "$(sha256_file "$repository/.agent-harness/project/modules.tsv")" "$module_hash"
    (cd "$repository" && ./.agent-harness/harness doctor >/dev/null) || fail 'upgraded doctor failed'
    rm -rf "$package" "$repository"
}

case_active_task_package_evolution_blocked() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task; approve_basic_task
    assert_status 3 bash -c "cd '$SOURCE_ROOT' && ./.agent-harness/harness.sh upgrade --source '$SOURCE_ROOT' --repository '$FIXTURE'"
    assert_eq "$(active_state)" IMPLEMENTING
}

case_install_recovery() {
    local package repository journal
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-install-recovery-package.XXXXXX") || fail 'cannot create package'
    repository=$(mktemp -d "${TMPDIR:-/tmp}/harness-install-recovery-target.XXXXXX") || fail 'cannot create target'
    rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    (cd "$package" && ./.agent-harness/harness.sh install --repository "$repository" >/dev/null) || fail 'install failed'
    journal=$(find "$repository/.harness-operations" -name journal.conf -type f | LC_ALL=C sort | tail -n 1)
    sed 's/^PHASE=.*/PHASE=PUBLISHED/' "$journal" >"$journal.tmp"; mv "$journal.tmp" "$journal"
    (cd "$package" && ./.agent-harness/harness.sh recover-package --repository "$repository" >/dev/null) || fail 'install recovery failed'
    assert_eq "$(conf_get "$journal" PHASE)" COMPLETED
    rm -rf "$package" "$repository"
}

case_upgrade_recovery_rollback() {
    local package repository operation old_digest
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-upgrade-recovery-package.XXXXXX") || fail 'cannot create package'
    repository=$(mktemp -d "${TMPDIR:-/tmp}/harness-upgrade-recovery-target.XXXXXX") || fail 'cannot create target'
    rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    (cd "$package" && ./.agent-harness/harness.sh install --repository "$repository" >/dev/null) || fail 'install failed'
    old_digest=$(package_tree_digest "$repository" installed) || fail 'cannot digest installed package'
    operation="$repository/.harness-operations/upgrade-99999999999999-test"
    mkdir -p "$operation/backup-root"
    cp -Rp "$repository/.agent-harness" "$operation/backup-root/.agent-harness"
    cat >"$operation/journal.conf" <<EOF_JOURNAL
SCHEMA_VERSION=1
KIND=UPGRADE
PHASE=PUBLISHED
REPOSITORY=$repository
OLD_PACKAGE_DIGEST=$old_digest
NEW_PACKAGE_DIGEST=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
UPDATED_AT=1970-01-01T00:00:00Z
EOF_JOURNAL
    printf tampered >>"$repository/.agent-harness/lib/common.sh"
    (cd "$package" && ./.agent-harness/harness.sh recover-package --repository "$repository" >/dev/null) || fail 'upgrade rollback recovery failed'
    assert_eq "$(conf_get "$operation/journal.conf" PHASE)" ROLLED_BACK
    (cd "$repository" && ./.agent-harness/harness doctor >/dev/null) || fail 'rollback package is unhealthy'
    rm -rf "$package" "$repository"
}

case_package_rejects_extra_file() {
    local package
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-extra-package.XXXXXX") || fail 'cannot create package'; rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    printf extra >"$package/undeclared.txt"
    assert_status 4 bash -c "cd '$package' && ./.agent-harness/harness.sh validate-package --strict"
    rm -rf "$package"
}

case_package_rejects_hardlink() {
    local package
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-hardlink-package.XXXXXX") || fail 'cannot create package'; rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    ln "$package/README.md" "$package/hardlink-copy"
    assert_status 4 bash -c "cd '$package' && ./.agent-harness/harness.sh validate-package --strict"
    rm -rf "$package"
}

case_package_rejects_special_file() {
    local package
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-special-package.XXXXXX") || fail 'cannot create package'; rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    mkfifo "$package/undeclared.fifo"
    assert_status 4 bash -c "cd '$package' && ./.agent-harness/harness.sh validate-package --strict"
    rm -rf "$package"
}

case_package_digest_binding() {
    assert_status 6 bash -c "cd '$SOURCE_ROOT' && HARNESS_DECLARED_PACKAGE_DIGEST=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff ./.agent-harness/harness status --json"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh status --json >/dev/null) || fail 'wrapper digest binding rejected valid bytes'
}

case_timeout_process_tree() {
    local directory script output pidfile result child
    directory=$(mktemp -d "${TMPDIR:-/tmp}/harness-timeout-tree.XXXXXX") || fail 'cannot create timeout fixture'
    script=$directory/spawn.sh; output=$directory/output; pidfile=$directory/child.pid
    cat >"$script" <<EOF_SCRIPT
#!/usr/bin/env bash
trap '' TERM
sleep 30 &
echo \$! >'$pidfile'
wait
EOF_SCRIPT
    chmod +x "$script"
    set +e; run_with_timeout 1 "$output" "$script"; result=$?; set -e
    [ "$result" -eq 124 ] || fail 'process-tree timeout did not return 124'
    child=$(cat "$pidfile" 2>/dev/null || printf '')
    sleep 1
    [ -z "$child" ] || ! kill -0 "$child" 2>/dev/null || fail 'timeout left a child process running'
    rm -rf "$directory"
}

case_locale_fallback() {
    local selected output errors result warning_lines
    selected=$(unset LC_ALL; LANG=definitely_missing_locale; select_supported_locale)
    assert_eq "$selected" C

    output=$(mktemp "${TMPDIR:-/tmp}/harness-locale-output.XXXXXX") || fail 'cannot create locale output'
    errors=$(mktemp "${TMPDIR:-/tmp}/harness-locale-errors.XXXXXX") || fail 'cannot create locale errors'
    set +e
    (cd "$SOURCE_ROOT" && LC_ALL=definitely_missing_locale LANG=definitely_missing_locale ./.agent-harness/harness.sh status >"$output" 2>"$errors")
    result=$?
    set -e
    [ "$result" -eq 0 ] || { cat "$errors" >&2; fail 'public wrapper failed under an unsupported caller locale'; }
    assert_contains "$(cat "$output")" NO_TASK
    warning_lines=$(wc -l <"$errors" | tr -d ' ')
    [ "$warning_lines" -le 3 ] || fail "unsupported locale leaked into child commands ($warning_lines stderr lines)"

    : >"$output"
    : >"$errors"
    set +e
    (cd "$SOURCE_ROOT" && LC_ALL=definitely_missing_locale LANG=definitely_missing_locale bash .agent-harness/tests/run.sh --json --gate release --filter export_clean_deterministic_copy_only >"$output" 2>"$errors")
    result=$?
    set -e
    [ "$result" -eq 0 ] || { cat "$errors" >&2; fail 'direct runner failed under an unsupported caller locale'; }
    assert_contains "$(cat "$output")" '"total":1'
    warning_lines=$(wc -l <"$errors" | tr -d ' ')
    [ "$warning_lines" -le 3 ] || fail "direct runner leaked unsupported locale into child commands ($warning_lines stderr lines)"
    rm -f "$output" "$errors"
}

case_real_business_native_check_adapter() {
    new_fixture
    mkdir -p "$FIXTURE/app" "$FIXTURE/scripts"
    printf old >"$FIXTURE/app/value.txt"
    cat >"$FIXTURE/scripts/repository-check" <<'EOF_SCRIPT'
#!/usr/bin/env bash
exec grep -qx good app/value.txt
EOF_SCRIPT
    chmod +x "$FIXTURE/scripts/repository-check"
    cat >"$FIXTURE/.agent-harness/config/commands/native-check.conf" <<'EOF_CHECK'
ID=native-check
EXECUTABLE=scripts/repository-check
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=integration_test
TRUSTED_INPUT_1=scripts/repository-check
TOOL_1=grep
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create --title Native --goal 'Use repository-native verification' --stakeholders maintainers --criterion 'AC-001|Native check passes' --scope 'app/**' --read 'scripts/**' --check native-check --coverage 'AC-001|native-check|integration_test|Repository-native executable') >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness task understand --by reviewer --current-behavior 'Repository check reads app value' --entry-points app/value.txt --data-flow 'Native script validates application file' --dependencies grep --interface-impact none --compatibility-risk low --scope-rationale focused --check-rationale native --rollback-plan restore --security-impact reviewed --data-impact none --operational-impact none --nfr-impact none --module 'repository|Native fixture' --evidence 'OTHER|scripts/repository-check|-|Repository-native check implementation' --inspection-skip-reason 'Synthetic native fixture' --step modify) >/dev/null
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by reviewer) >/dev/null
    printf good >"$FIXTURE/app/value.txt"
    (cd "$FIXTURE" && ./.agent-harness/harness verify >/dev/null && ./.agent-harness/harness finalize >/dev/null) || fail 'native adapter lifecycle failed'
}

case_audit_metrics() {
    local package packet
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-audit-metrics.XXXXXX") || fail 'cannot create package'; rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    packet=$(cd "$package" && ./.agent-harness/harness audit --json) || fail 'audit metrics command failed'
    assert_contains "$packet" '"duration_seconds":'
    assert_contains "$packet" '"run_count":0'
    assert_contains "$packet" '"finalized_run_count":0'
    assert_contains "$packet" '"task_count":0'
    rm -rf "$package"
}

case_direct_test_runner_arguments() {
    local packet
    packet=$(cd "$SOURCE_ROOT" && bash .agent-harness/tests/run.sh --json --filter bash32) || fail 'direct runner flags failed'
    assert_contains "$packet" '"result":"PASS"'
    assert_contains "$packet" '"total":1'

    packet=$(cd "$SOURCE_ROOT" && ./.agent-harness/harness test --json --filter bash32) || fail 'public runner did not forward the filter'
    assert_contains "$packet" '"result":"PASS"'
    assert_contains "$packet" '"total":1'

    assert_status 2 bash -c "cd '$SOURCE_ROOT' && bash .agent-harness/tests/run.sh --json --filter definitely_missing"
    assert_contains "$(cat "$HARNESS_LAST_OUTPUT")" 'no tests matched'
    assert_status 2 bash -c "cd '$SOURCE_ROOT' && bash .agent-harness/tests/run.sh --json --filter locale_fallback"
    assert_contains "$(cat "$HARNESS_LAST_OUTPUT")" 'no tests matched'
    assert_status 2 bash -c "cd '$SOURCE_ROOT' && ./.agent-harness/harness test --json --filter definitely_missing"
    assert_contains "$(cat "$HARNESS_LAST_OUTPUT")" '"result":"ERROR"'
    assert_contains "$(cat "$HARNESS_LAST_OUTPUT")" '"exit_code":2'
    assert_contains "$(cat "$HARNESS_LAST_OUTPUT")" '"artifact":{'
}

case_artifact_first_public_test_output() {
    local artifact_dir packet verbose status artifact reported_bytes reported_hash actual_bytes actual_hash packet_bytes maximum
    artifact_dir=$(mktemp -d "${TMPDIR:-/tmp}/harness-public-artifacts.XXXXXX") || fail 'cannot create artifact directory'
    set +e
    packet=$(cd "$SOURCE_ROOT" && HARNESS_TEST_ARTIFACT_DIR="$artifact_dir" ./.agent-harness/harness test --json --filter definitely_missing)
    status=$?
    set -e
    assert_eq "$status" 2
    assert_contains "$packet" '"result":"ERROR"'
    assert_contains "$packet" '"gate":"fast"'
    assert_contains "$packet" '"exit_code":2'
    assert_contains "$packet" '"artifact":{'
    artifact=$(printf '%s\n' "$packet" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')
    reported_bytes=$(printf '%s\n' "$packet" | sed -n 's/.*"bytes":\([0-9][0-9]*\).*/\1/p')
    reported_hash=$(printf '%s\n' "$packet" | sed -n 's/.*"sha256":"\([0-9a-f][0-9a-f]*\)".*/\1/p')
    [ -n "$artifact" ] && [ -f "$artifact" ] || fail 'failure artifact was not retained'
    actual_bytes=$(wc -c <"$artifact" | tr -d ' ')
    actual_hash=$(sha256_file "$artifact") || fail 'cannot hash failure artifact'
    assert_eq "$reported_bytes" "$actual_bytes"
    assert_eq "$reported_hash" "$actual_hash"
    assert_contains "$(cat "$artifact")" 'NoTestsMatched'
    packet_bytes=$(printf '%s\n' "$packet" | wc -c | tr -d ' ')
    maximum=$(conf_get "$SOURCE_ROOT/.agent-harness/policy/controls.conf" PUBLIC_RESULT_MAXIMUM_BYTES)
    [ "$packet_bytes" -le "$maximum" ] || fail "public failure summary exceeded $maximum bytes"
    packet=$(cd "$SOURCE_ROOT" && ./.agent-harness/harness test --gate fast --filter bash32) || fail 'summary-only success command failed'
    assert_contains "$packet" 'Test gate fast: 1 passed, 0 skipped, 1 total'
    case "$packet" in *'PASS: bash32'*) fail 'default successful output included the per-case transcript' ;; esac
    verbose=$(cd "$SOURCE_ROOT" && ./.agent-harness/harness test --gate fast --verbose --filter bash32) || fail 'verbose success command failed'
    assert_contains "$verbose" 'PASS: bash32'
    rm -rf "$artifact_dir"
}

case_test_gate_routing() {
    local packet
    packet=$(cd "$SOURCE_ROOT" && ./.agent-harness/harness test --gate fast --json --filter bash32) || fail 'fast gate did not execute its focused case'
    assert_contains "$packet" '"result":"PASS"'
    assert_contains "$packet" '"gate":"fast"'
    assert_contains "$packet" '"total":1'

    packet=$(cd "$SOURCE_ROOT" && ./.agent-harness/harness test --gate lifecycle --json --filter success) || fail 'lifecycle gate did not execute lifecycle behavior'
    assert_contains "$packet" '"gate":"lifecycle"'
    assert_contains "$packet" '"total":1'

    packet=$(cd "$SOURCE_ROOT" && ./.agent-harness/harness test --gate adversarial --json --filter scope_violation) || fail 'adversarial gate did not execute denial behavior'
    assert_contains "$packet" '"gate":"adversarial"'
    assert_contains "$packet" '"total":1'

    packet=$(cd "$SOURCE_ROOT" && ./.agent-harness/harness test --full --json --filter bash32) || fail '--full no longer aliases the release gate'
    assert_contains "$packet" '"gate":"release"'
    assert_contains "$packet" '"total":1'

    assert_status 2 bash -c "cd '$SOURCE_ROOT' && ./.agent-harness/harness test --gate fast --json --filter synthetic_business_e2e"
    assert_contains "$(cat "$HARNESS_LAST_OUTPUT")" '"result":"ERROR"'
    assert_status 2 bash -c "cd '$SOURCE_ROOT' && ./.agent-harness/harness test --full --gate fast --json --filter bash32"
}

case_workflow_packet_output_budget() {
    local packet digest unchanged large maximum packet_bytes details task_id
    new_fixture
    mkdir -p "$FIXTURE/app"
    printf old >"$FIXTURE/app/value.txt"
    register_grep_check good
    create_basic_task
    packet=$(cd "$FIXTURE" && ./.agent-harness/harness next --json) || fail 'cannot render normal workflow packet'
    assert_contains "$packet" '"packet_digest":"'
    digest=$(printf '%s\n' "$packet" | sed -n 's/.*"packet_digest":"\([0-9a-f][0-9a-f]*\)".*/\1/p')
    [ -n "$digest" ] || fail 'workflow packet digest is missing'
    unchanged=$(cd "$FIXTURE" && ./.agent-harness/harness next --json --since "$digest") || fail 'unchanged packet request failed'
    assert_contains "$unchanged" '"unchanged":true'
    assert_contains "$unchanged" "\"packet_digest\":\"$digest\""
    case "$unchanged" in *'"acceptance_criteria"'*) fail 'unchanged response repeated task tables' ;; esac
    rm -rf "$FIXTURE"

    new_fixture
    mkdir -p "$FIXTURE/app"
    printf old >"$FIXTURE/app/value.txt"
    register_grep_check good
    large=$(awk 'BEGIN { for (i=0; i<24000; i++) printf "x" }')
    (cd "$FIXTURE" && ./.agent-harness/harness task create \
      --title Large --goal 'Prove packet output remains bounded' --stakeholders maintainers \
      --criterion "AC-001|$large" --scope 'app/**' --check check-app \
      --coverage 'AC-001|check-app|automated_test|Exercises a valid oversized contract') >/dev/null || fail 'cannot create oversized task contract'
    understand_active_task
    packet=$(cd "$FIXTURE" && ./.agent-harness/harness next --json) || fail 'bounded workflow packet failed'
    assert_contains "$packet" '"truncated":true'
    assert_contains "$packet" '"contract_path":".agent-harness/tasks/'
    maximum=$(conf_get "$FIXTURE/.agent-harness/policy/controls.conf" PUBLIC_RESULT_MAXIMUM_BYTES)
    packet_bytes=$(printf '%s\n' "$packet" | wc -c | tr -d ' ')
    [ "$packet_bytes" -le "$maximum" ] || fail "bounded workflow packet exceeded $maximum bytes"
    details=$(cd "$FIXTURE" && ./.agent-harness/harness next --json --details) || fail 'explicit full packet failed'
    assert_contains "$details" '"acceptance_criteria"'
    [ "$(printf '%s\n' "$details" | wc -c | tr -d ' ')" -gt "$packet_bytes" ] || fail 'details did not return the complete packet'
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    assert_contains "$packet" "$task_id"
}

case_operation_path_confinement() {
    local package repository outside
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-confined-package.XXXXXX") || fail 'cannot create package'
    repository=$(mktemp -d "${TMPDIR:-/tmp}/harness-confined-target.XXXXXX") || fail 'cannot create target'
    outside=$(mktemp -d "${TMPDIR:-/tmp}/harness-confined-outside.XXXXXX") || fail 'cannot create outside directory'
    rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    ln -s "$outside" "$repository/.harness-operations"
    assert_status 4 bash -c "cd '$package' && ./.agent-harness/harness.sh install --repository '$repository'"
    [ -z "$(find "$outside" -mindepth 1 -print -quit)" ] || fail 'operation escaped repository confinement'
    rm -rf "$package" "$repository" "$outside"
}


case_status_read_only_strict() {
    local package before after
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-status-readonly.XXXXXX") || fail 'cannot create package'; rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    before=$(test_tree_digest "$package") || fail 'cannot digest package before status'
    (cd "$package" && ./.agent-harness/harness status >/dev/null) || fail 'status failed on clean package'
    after=$(test_tree_digest "$package") || fail 'cannot digest package after status'
    assert_eq "$after" "$before"
    [ ! -e "$package/.agent-harness/runtime" ] || fail 'status materialized runtime state'
    [ ! -e "$package/.agent-harness/project" ] || fail 'status materialized project state'
    rm -rf "$package"
}

case_corrupt_active_pointer_fails_closed() {
    local package
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; create_basic_task
    printf 'STATE=NO_TASK\n' >>"$FIXTURE/.agent-harness/runtime/active-run.conf"
    assert_status 4 bash -c "cd '$FIXTURE' && ./.agent-harness/harness status"
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness audit"
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-pointer-package.XXXXXX") || fail 'cannot create package'; rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    assert_status 3 bash -c "cd '$package' && ./.agent-harness/harness.sh upgrade --repository '$FIXTURE'"
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness project define --name X --goal G --success S --architecture A --technology-constraints T --data-model D --api-strategy API --security SEC --reliability REL --deployment DEP --migration-strategy M --owner O --by reviewer"
    rm -rf "$package"
}

case_large_trusted_input_conflict_closed() {
    local index
    new_fixture; mkdir -p "$FIXTURE/app" "$FIXTURE/vendor"; printf old >"$FIXTURE/app/value.txt"; printf fixture >"$FIXTURE/vendor/check.txt"; register_grep_check good
    index=1
    while [ "$index" -le 5000 ]; do printf 'TRUSTED_INPUT_%s=vendor/path-%s\n' "$index" "$index" >>"$FIXTURE/.agent-harness/config/commands/check-app.conf"; index=$((index + 1)); done
    printf 'TRUSTED_INPUT_5001=vendor/check.txt\n' >>"$FIXTURE/.agent-harness/config/commands/check-app.conf"
    (cd "$FIXTURE" && ./.agent-harness/harness inventory policy add --type EXCLUDE --path 'vendor/**' --reason 'Third-party content.' --by reviewer) >/dev/null
    create_basic_task
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_project_rows_closed() {
    new_fixture
    (cd "$FIXTURE" && ./.agent-harness/harness project define --name Demo --goal Goal --success Success --architecture Architecture --technology-constraints Portable --data-model Files --api-strategy CLI --security Boundary --reliability Reliable --deployment Local --migration-strategy Forward --owner team --by architect) >/dev/null
    printf 'ARCH-001\tonly\t\t\t\n' >"$FIXTURE/.agent-harness/project/architecture.tsv"
    printf 'NFR-001\ta\tb\tc\td\n' >"$FIXTURE/.agent-harness/project/nfrs.tsv"
    printf 'ADR-001\ta\tb\tc\tACCEPTED\n' >"$FIXTURE/.agent-harness/project/decisions.tsv"
    printf 'API-001\ta\tb\tc\td\te\n' >"$FIXTURE/.agent-harness/project/interfaces.tsv"
    assert_status 6 bash -c "cd '$FIXTURE' && ./.agent-harness/harness project validate"
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness project architecture --id ARCH-002 --a only --b '' --c '' --d '' --by architect"
}

case_task_tables_closed() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good
    assert_status 2 bash -c "cd '$FIXTURE' && ./.agent-harness/harness task create --title Demo --goal Goal --stakeholders users --criterion 'AC-001|Done' --scope 'app/**' --check check-app --coverage 'AC-999|check-app|automated_test|Unknown criterion'"
    create_basic_task
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    cat "$FIXTURE/.agent-harness/tasks/$task_id/understanding-evidence.tsv" >>"$FIXTURE/.agent-harness/tasks/$task_id/understanding-evidence.tsv.tmp"
    cat "$FIXTURE/.agent-harness/tasks/$task_id/understanding-evidence.tsv" >>"$FIXTURE/.agent-harness/tasks/$task_id/understanding-evidence.tsv.tmp"
    mv "$FIXTURE/.agent-harness/tasks/$task_id/understanding-evidence.tsv.tmp" "$FIXTURE/.agent-harness/tasks/$task_id/understanding-evidence.tsv"
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --by reviewer"
}

case_duplicate_manual_review_rejected() {
    new_fixture; mkdir -p "$FIXTURE/app"; printf old >"$FIXTURE/app/value.txt"; register_grep_check good; add_manual_convention; create_basic_task; approve_basic_task
    printf good >"$FIXTURE/app/value.txt"; (cd "$FIXTURE" && ./.agent-harness/harness verify) >/dev/null
    assert_status 3 bash -c "cd '$FIXTURE' && ./.agent-harness/harness approve --final --by final-reviewer --rule 'ARCH-001|PASS|app/value.txt|First review' --rule 'ARCH-001|PASS|app/value.txt|Duplicate review'"
}

case_recovery_journal_schema_closed() {
    local package repository journal
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-journal-package.XXXXXX") || fail 'cannot create package'; repository=$(mktemp -d "${TMPDIR:-/tmp}/harness-journal-target.XXXXXX") || fail 'cannot create target'; rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    (cd "$package" && ./.agent-harness/harness.sh install --repository "$repository") >/dev/null || fail 'install failed'
    journal=$(find "$repository/.harness-operations" -name journal.conf -type f -print | LC_ALL=C sort | tail -n 1)
    sed 's/^SCHEMA_VERSION=.*/SCHEMA_VERSION=999/' "$journal" >"$journal.tmp"; mv "$journal.tmp" "$journal"
    printf 'UNKNOWN_KEY=value\n' >>"$journal"
    assert_status 4 bash -c "cd '$package' && ./.agent-harness/harness.sh recover-package --repository '$repository'"
    rm -rf "$package" "$repository"
}

case_install_rejects_open_source_package() {
    local package repository
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-open-package.XXXXXX") || fail 'cannot create package'; repository=$(mktemp -d "${TMPDIR:-/tmp}/harness-open-target.XXXXXX") || fail 'cannot create target'; rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export package'
    printf extra >"$package/undeclared.txt"
    assert_status 4 bash -c "cd '$package' && ./.agent-harness/harness.sh install --repository '$repository'"
    [ ! -e "$repository/.agent-harness" ] || fail 'open package was installed'
    rm -rf "$package" "$repository"
}

case_missing_option_values_controlled() {
    new_fixture
    assert_status 2 bash -c "cd '$FIXTURE' && ./.agent-harness/harness task answer --id"
    assert_status 2 bash -c "cd '$FIXTURE' && ./.agent-harness/harness project define --name"
    assert_status 2 bash -c "cd '$FIXTURE' && ./.agent-harness/harness identity policy set --mode"
}



case_test_mode_selection() {
    local paths packet explain
    paths=$(mktemp "${TMPDIR:-/tmp}/test-mode-paths.XXXXXX") || fail 'cannot create test selection input'

    printf '.agent-harness/lib/verify.sh\n' >"$paths"
    test_selection_resolve_file "$paths" path || fail 'cannot resolve verification selection'
    assert_eq "$TEST_SELECTION_MODE" standard
    assert_contains "$TEST_SELECTION_SUITES" verification
    assert_contains "$TEST_SELECTION_CASES" failure_remediation

    printf '.agent-harness/lib/common.sh\n' >"$paths"
    test_selection_resolve_file "$paths" path || fail 'cannot resolve shared selection'
    assert_eq "$TEST_SELECTION_MODE" full
    assert_contains "$TEST_SELECTION_REASONS" SHARED_FOUNDATION_CHANGE

    printf 'README.md\n' >"$paths"
    test_selection_resolve_file "$paths" path || fail 'cannot resolve documentation selection'
    assert_eq "$TEST_SELECTION_MODE" focused

    printf 'unmapped-local-file.xyz\n' >"$paths"
    test_selection_resolve_file "$paths" path || fail 'cannot resolve conservative fallback'
    assert_eq "$TEST_SELECTION_MODE" full
    assert_contains "$TEST_SELECTION_REASONS" UNKNOWN_PATH
    rm -f "$paths"

    packet=$(cd "$SOURCE_ROOT" && bash .agent-harness/tests/run.sh --mode focused --filter bash32 --json) || fail 'focused mode failed'
    assert_contains "$packet" '"mode":"focused"'
    assert_contains "$packet" '"gate":"release"'
    assert_contains "$packet" '"total":1'

    packet=$(cd "$SOURCE_ROOT" && bash .agent-harness/tests/run.sh --mode standard --filter success --json) || fail 'standard mode did not include lifecycle tests'
    assert_contains "$packet" '"mode":"standard"'
    assert_contains "$packet" '"gate":"standard"'
    assert_contains "$packet" '"total":1'

    packet=$(cd "$SOURCE_ROOT" && bash .agent-harness/tests/run.sh --mode standard --filter scope_violation --json) || fail 'standard mode did not include adversarial tests'
    assert_contains "$packet" '"total":1'

    packet=$(cd "$SOURCE_ROOT" && bash .agent-harness/tests/run.sh --mode full --filter bash32 --json) || fail 'full mode failed'
    assert_contains "$packet" '"mode":"full"'
    assert_contains "$packet" '"gate":"release"'

    explain=$(cd "$SOURCE_ROOT" && bash .agent-harness/tests/run.sh --mode focused --suite verification --explain) || fail 'suite explanation failed'
    assert_contains "$explain" 'Affected suites: verification'
    assert_contains "$explain" 'Required command:'
    assert_status 2 bash -c "cd '$SOURCE_ROOT' && bash .agent-harness/tests/run.sh --mode focused --json"
}

case_test_mode_next_guidance() {
    local packet text
    new_fixture
    mkdir -p "$FIXTURE/.agent-harness/config/commands"
    cat >"$FIXTURE/.agent-harness/config/commands/self-update-check.conf" <<'EOF_CHECK'
ID=self-update-check
EXECUTABLE=test
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
ARG_1=-s
ARG_2=.agent-harness/lib/verify.sh
EOF_CHECK
    (cd "$FIXTURE" && ./.agent-harness/harness task create \
      --title 'Testing mode guidance' --goal 'Update one managed harness file safely' --stakeholders maintainers \
      --profile feature --risk medium \
      --criterion 'AC-001|Managed file remains valid' \
      --scope '.agent-harness/lib/verify.sh' --scope '.agent-harness/manifest.tsv' \
      --check self-update-check \
      --coverage 'AC-001|self-update-check|static_check|Checks the approved managed file') >/dev/null || fail 'cannot create self-update task'
    (cd "$FIXTURE" && ./.agent-harness/harness task understand \
      --by reviewer --current-behavior 'Managed files are manifest bound.' \
      --entry-points '.agent-harness/lib/verify.sh' --data-flow 'task -> manifest -> verification' \
      --dependencies none --interface-impact none --compatibility-risk low \
      --scope-rationale 'Only one managed file and its manifest change.' \
      --check-rationale 'The registered check validates the managed file.' \
      --rollback-plan 'Restore both approved files.' --security-impact reviewed \
      --data-impact none --operational-impact none --nfr-impact integrity \
      --module 'repository|Harness self-update fixture.' \
      --evidence 'OTHER|README.md|-|Repository evidence.' \
      --inspection-skip-reason 'Synthetic self-update fixture.' --step 'Update managed file and manifest') >/dev/null || fail 'cannot understand self-update task'
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by reviewer) >/dev/null || fail 'cannot approve self-update task'

    packet=$(cd "$FIXTURE" && ./.agent-harness/harness next --json) || fail 'cannot render self-update guidance packet'
    assert_contains "$packet" '"testing":{"applicable":true'
    assert_contains "$packet" '"recommended_mode":"focused"'
    assert_contains "$packet" '"required_mode":"standard"'
    assert_contains "$packet" 'PACKAGE_MANIFEST_REFRESH'
    text=$(cd "$FIXTURE" && ./.agent-harness/harness next) || fail 'cannot render text guidance'
    assert_contains "$text" 'Recommended development tests:'
    assert_contains "$text" 'Required completion tests:'

    rm -rf "$FIXTURE"
    FIXTURE=''
    new_fixture
    mkdir -p "$FIXTURE/app"
    printf old >"$FIXTURE/app/value.txt"
    register_grep_check good
    create_basic_task
    approve_basic_task
    packet=$(cd "$FIXTURE" && ./.agent-harness/harness next --json) || fail 'cannot render business task packet'
    assert_contains "$packet" '"testing":{"applicable":false'
    assert_contains "$packet" 'BUSINESS_REPOSITORY_TASK_USES_REGISTERED_CHECKS'
}

run_case bash32 case_bash32 fast
run_case bootstrap case_bootstrap fast
run_case status_read_only_strict case_status_read_only_strict fast
run_case missing_option_values_controlled case_missing_option_values_controlled fast
run_case export_clean_package case_export_clean_package fast
run_case export_rejects_unsafe_destinations case_export_rejects_unsafe_destinations release
run_case export_clean_deterministic_copy_only case_export_is_clean_deterministic_copy_only release
run_case audit_read_only case_audit_read_only fast
run_case intake_json_defaults case_intake_json_defaults fast
run_case package_validate_strict case_package_validate_strict fast
run_case install_preserves_repository case_install_preserves_repository release
run_case success case_success lifecycle
run_case compact_context_generated case_compact_context_generated fast
run_case context_build_deterministic case_context_build_deterministic release
run_case context_oversized_selection_referenced case_context_oversized_selection_referenced release
run_case context_invalid_selection_nonfatal case_context_invalid_selection_nonfatal release
run_case context_show_read_only case_context_show_read_only release
run_case context_show_detects_stale_source case_context_show_detects_stale_source adversarial
run_case context_failure_summary_bounded case_context_failure_summary_bounded fast
run_case context_clears_failure_summary_after_pass case_context_clears_failure_summary_after_pass release
run_case context_contract_drift_preserves_generation case_context_contract_drift_preserves_generation adversarial
run_case context_parent_symlink_escape_rejected case_context_parent_symlink_escape_rejected adversarial
run_case context_generation_tamper_detected case_context_generation_tamper_detected fast,adversarial
run_case context_base_hard_limit_enforced case_context_base_hard_limit_enforced fast
run_case context_bundle_count_bounded case_context_bundle_count_bounded release
run_case context_working_memory_oversized_referenced case_context_working_memory_oversized_referenced release
run_case context_duplicate_selections_deduplicated case_context_duplicate_selections_deduplicated release
run_case context_selection_count_bounded case_context_selection_count_bounded release
run_case context_dynamic_markdown_fence case_context_dynamic_markdown_fence release
run_case context_publication_recovery case_context_publication_recovery release
run_case scope_violation case_scope_violation adversarial
run_case failure_remediation case_failure_remediation lifecycle
run_case trusted_input_drift case_trusted_drift adversarial
run_case control_scope case_control_scope fast,adversarial
run_case package_tamper case_package_tamper fast,adversarial
run_case scoped_manifest_self_update case_scoped_manifest_self_update release
run_case low_risk_manifest_self_update_denied case_low_risk_manifest_self_update_denied adversarial
run_case clarification case_clarification lifecycle
run_case final_review case_final_review lifecycle
run_case finalize_drift case_finalize_drift adversarial
run_case recover_verifying case_recover_verifying lifecycle
run_case json_contract case_json fast
run_case convention_deduplicated_check case_convention_deduplicated_check release
run_case inspection_runtime_only case_inspection_runtime_only release
run_case manual_convention_review case_manual_convention_review lifecycle
run_case duplicate_manual_review_rejected case_duplicate_manual_review_rejected release
run_case understanding_required case_understanding_required release
run_case allowed_external_linked_doc case_allowed_external_linked_doc release
run_case known_stale_runtime_migrated case_known_stale_runtime_migrated release
run_case unknown_stale_runtime_preserved case_unknown_stale_runtime_preserved release
run_case worker_packet_json case_worker_packet_json fast
run_case append_only_remediation_attempts case_append_only_remediation_attempts lifecycle
run_case synthetic_business_e2e case_synthetic_business_e2e lifecycle
run_case finalized_approval_survives_package_evolution case_finalized_approval_survives_package_evolution lifecycle
run_case artifact_first_public_test_output case_artifact_first_public_test_output fast
run_case test_gate_routing case_test_gate_routing release
run_case test_mode_selection case_test_mode_selection release
run_case test_mode_next_guidance case_test_mode_next_guidance release
run_case workflow_packet_output_budget case_workflow_packet_output_budget fast
run_case nested_vcs case_nested_vcs adversarial
run_case invalid_glob case_invalid_glob adversarial
run_case event_recovery case_event_recovery adversarial
run_case event_owner case_event_owner adversarial
run_case relocation case_relocation release
run_case raw_shell case_raw_shell release
run_case check_mutation case_check_mutation adversarial
run_case symlink case_symlink adversarial
run_case hardlink case_hardlink adversarial
run_case timeout case_timeout adversarial
run_case hash_fallback case_hash_fallback release
run_case unmanaged_core case_unmanaged_core adversarial
run_case convention_contract_drift case_convention_contract_drift adversarial
run_case convention_mutation_blocked case_convention_mutation_blocked_during_task adversarial
run_case convention_example_read_context case_convention_example_read_context release
run_case convention_module_registration case_convention_module_registration release
run_case convention_update_recovery case_convention_update_recovery release
run_case open_assumption_blocked case_open_assumption_blocked adversarial
run_case candidate_promotion case_candidate_promotion release
run_case exception_applied case_exception_applied release
run_case should_warning case_should_warning release
run_case may_warning_nonblocking case_may_warning_nonblocking release
run_case conflicting_rules_blocked case_conflicting_rules_blocked adversarial
run_case inventory_exclusion case_inventory_exclusion adversarial
run_case inventory_trusted_conflict case_inventory_trusted_conflict adversarial
run_case large_trusted_input_conflict_closed case_large_trusted_input_conflict_closed adversarial
run_case allowed_symlink case_allowed_symlink adversarial
run_case environment_allowlist case_environment_allowlist adversarial
run_case ordered_failure_collection case_ordered_failure_collection adversarial
run_case critical_two_person_approval case_critical_two_person_approval adversarial
run_case context_budget case_context_budget release
run_case custom_inspector case_custom_inspector release
run_case task_amendment case_task_amendment lifecycle
run_case rethink_hold_acknowledgement case_rethink_hold_acknowledgement lifecycle
run_case rule_replacement case_rule_replacement release
run_case allowed_hardlink case_allowed_hardlink release
run_case allowed_submodule_metadata case_allowed_submodule_metadata release
run_case convention_dimensions case_convention_dimensions release
run_case expired_exception_not_applied case_expired_exception_not_applied release
run_case revoked_exception_not_applied case_revoked_exception_not_applied release
run_case project_conventions_preserved case_project_conventions_preserved_by_release_overlay release
run_case advisory_mutation_isolated case_advisory_mutation_isolated release
run_case prepare_outputs_promoted case_prepare_outputs_promoted release
run_case prepare_output_outside_scope_blocked case_prepare_output_outside_scope_blocked adversarial
run_case git_commit_after_approval case_git_commit_after_approval release
run_case git_staging_after_approval case_git_staging_after_approval release
run_case real_business_repo_smoke case_real_business_repo_smoke lifecycle
run_case git_snapshot_check case_git_snapshot_check release
run_case understanding_evidence_missing_path case_understanding_evidence_missing_path adversarial
run_case inspection_binding_detects_drift case_inspection_binding_detects_drift adversarial
run_case greenfield_project_contract case_greenfield_project_contract release
run_case project_rows_closed case_project_rows_closed release
run_case task_tables_closed case_task_tables_closed release
run_case malformed_identifiers_rejected case_malformed_identifiers_rejected adversarial
run_case unsupported_filename_rejected case_unsupported_filename_rejected adversarial
run_case toolchain_drift_rejected case_toolchain_drift_rejected adversarial
run_case explicit_inspection_decision case_explicit_inspection_decision_required release
run_case os_user_identity case_os_user_identity_policy release
run_case high_risk_independent_review case_high_risk_independent_final_review lifecycle
run_case submodule_write_scope_blocked case_submodule_write_scope_blocked adversarial
run_case amendment_phase_recovery case_amendment_phase_recovery adversarial
run_case finalization_phase_recovery case_finalization_phase_recovery adversarial
run_case bound_toolchain_path case_bound_toolchain_ignores_current_path release
run_case undeclared_tool_unavailable case_undeclared_tool_unavailable adversarial
run_case external_anchor_attestation case_external_anchor_attestation release
run_case duplicate_unknown_config_rejected case_duplicate_and_unknown_config_rejected release
run_case required_generated_output case_required_generated_output release
run_case external_verified_identity case_external_verified_identity release
run_case external_anchor_adapter case_external_anchor_adapter release
run_case force_cross_host_lock_recovery case_force_cross_host_lock_recovery adversarial
run_case verification_metrics case_verification_metrics release
run_case local_anchor_chain_tamper case_local_anchor_chain_tamper_detected adversarial
run_case greenfield_lifecycle_e2e case_greenfield_lifecycle_e2e lifecycle
run_case upgrade_preserves_state case_upgrade_preserves_state lifecycle
run_case active_task_package_evolution_blocked case_active_task_package_evolution_blocked release
run_case corrupt_active_pointer_fails_closed case_corrupt_active_pointer_fails_closed adversarial
run_case install_recovery case_install_recovery adversarial
run_case recovery_journal_schema_closed case_recovery_journal_schema_closed adversarial
run_case install_rejects_open_source_package case_install_rejects_open_source_package adversarial
run_case upgrade_recovery_rollback case_upgrade_recovery_rollback adversarial
run_case package_rejects_extra_file case_package_rejects_extra_file adversarial
run_case package_rejects_hardlink case_package_rejects_hardlink adversarial
run_case package_rejects_special_file case_package_rejects_special_file adversarial
run_case package_digest_binding case_package_digest_binding release
run_case timeout_process_tree case_timeout_process_tree adversarial
run_case locale_fallback case_locale_fallback release
run_case real_business_native_check_adapter case_real_business_native_check_adapter lifecycle
run_case audit_metrics case_audit_metrics release
run_case direct_test_runner_arguments case_direct_test_runner_arguments release
run_case operation_path_confinement case_operation_path_confinement adversarial

if [ "$TOTAL" -eq 0 ]; then
    if [ "$TEST_JSON" = "1" ]; then
        printf '{"error":"NoTestsMatched","message":"no tests matched the selected gate and filter","mode":"%s","gate":"%s","exit_code":2}\n' "$(json_escape "${TEST_MODE:-legacy-gate}")" "$(json_escape "$TEST_GATE")"
    else
        printf 'ERROR: no tests matched the selected gate and filter\n' >&2
    fi
    exit 2
fi

if [ "$TEST_JSON" = "1" ]; then
    if [ -n "$TEST_MODE" ]; then
        printf '{"result":"PASS","mode":"%s","gate":"%s","passed":%s,"skipped":%s,"total":%s}\n' "$(json_escape "$TEST_MODE")" "$(json_escape "$TEST_GATE")" "$PASSED" "$SKIPPED" "$TOTAL"
    else
        printf '{"result":"PASS","gate":"%s","passed":%s,"skipped":%s,"total":%s}\n' "$(json_escape "$TEST_GATE")" "$PASSED" "$SKIPPED" "$TOTAL"
    fi
else
    if [ -n "$TEST_MODE" ]; then
        printf 'Test mode %s (gate %s): %s passed, %s skipped, %s total\n' "$TEST_MODE" "$TEST_GATE" "$PASSED" "$SKIPPED" "$TOTAL"
    else
        printf 'Test gate %s: %s passed, %s skipped, %s total\n' "$TEST_GATE" "$PASSED" "$SKIPPED" "$TOTAL"
    fi
fi
