#!/usr/bin/env bash
set -u

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
SOURCE_ROOT=$(CDPATH= cd -- "$TEST_DIR/../.." && pwd -P)

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$1' to equal '$2'"; }
assert_contains() { case "$1" in *"$2"*) return 0 ;; *) fail "expected output to contain '$2'" ;; esac; }
assert_status() { expected=$1; shift; output_file=$(mktemp "${TMPDIR:-/tmp}/harness-assert.XXXXXX") || fail "cannot create assertion output"; HARNESS_LAST_OUTPUT=$output_file; set +e; "$@" >"$output_file" 2>&1; actual=$?; set -e; [ "$actual" -eq "$expected" ] || { cat "$output_file" >&2; fail "expected exit $expected, got $actual"; }; }

new_fixture() {
    FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/harness-fixture.XXXXXX") || fail "cannot create fixture"
    rm -rf "$FIXTURE"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$FIXTURE") >/dev/null || fail "cannot export fixture package"
    mkdir -p "$FIXTURE/.agent-harness/config/commands" || fail "cannot initialize fixture command directory"
}

install_clean_harness() {
    local destination package
    destination=$1
    package=$(mktemp -d "${TMPDIR:-/tmp}/harness-install.XXXXXX") || fail 'cannot create harness installation stage'
    chmod 700 "$package"
    rm -rf "$package"
    (cd "$SOURCE_ROOT" && ./.agent-harness/harness.sh export --output "$package") >/dev/null || fail 'cannot export harness for installation'
    [ -d "$destination" ] || fail 'harness installation destination does not exist'
    [ ! -e "$destination/.agent-harness" ] || fail 'harness installation destination already has .agent-harness'
    (cd "$package" && tar -cf - .agent-harness) | (cd "$destination" && tar -xf -) || fail 'cannot install clean harness package'
    rm -rf "$package"
}

register_grep_check() {
    expected=${1:-good}
    mkdir -p "$FIXTURE/.agent-harness/config/commands"
    cat >"$FIXTURE/.agent-harness/config/commands/check-app.conf" <<EOF_CHECK
ID=check-app
EXECUTABLE=grep
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=automated_test
ARG_1=-q
ARG_2=$expected
ARG_3=app/value.txt
EOF_CHECK
}

register_script_check() {
    mkdir -p "$FIXTURE/checks" "$FIXTURE/.agent-harness/config/commands"
    cat >"$FIXTURE/checks/verify.sh" <<'EOF_SCRIPT'
#!/usr/bin/env bash
grep -q 'good' app/value.txt
EOF_SCRIPT
    chmod +x "$FIXTURE/checks/verify.sh"
    cat >"$FIXTURE/.agent-harness/config/commands/script-check.conf" <<'EOF_CHECK'
ID=script-check
EXECUTABLE=checks/verify.sh
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=integration_test
TOOL_1=grep
TRUSTED_INPUT_1=checks/verify.sh
EOF_CHECK
}

create_basic_task() {
    check_id=${1:-check-app}
    evidence=${2:-automated_test}
    (
        cd "$FIXTURE" || exit 1
        ./.agent-harness/harness task create \
          --title Demo \
          --goal 'Set the value to good' \
          --stakeholders users \
          --criterion 'AC-001|Value is good' \
          --scope 'app/**' \
          --check "$check_id" \
          --coverage "AC-001|$check_id|$evidence|Checks the expected value"
    ) >/dev/null || fail "cannot create task"
    understand_active_task
}

understand_active_task() {
    task_id=$(sed -n 's/^TASK_ID=//p' "$FIXTURE/.agent-harness/runtime/active-run.conf")
    (
      cd "$FIXTURE" || exit 1
      ./.agent-harness/harness task understand \
        --by reviewer \
        --current-behavior 'The existing repository stores an application value that must be changed consistently.' \
        --entry-points 'app/value.txt' \
        --data-flow 'The registered check reads app/value.txt and validates the expected value.' \
        --dependencies 'No external dependencies.' \
        --interface-impact 'No public interface change.' \
        --compatibility-risk 'Low; one repository-local value changes.' \
        --scope-rationale 'Only app/** is required for this task.' \
        --check-rationale 'The registered check directly validates the acceptance criterion.' \
        --rollback-plan 'Restore the approved baseline value.' \
        --security-impact 'None identified.' \
        --data-impact 'No persistent data migration.' \
        --operational-impact 'None identified.' \
        --nfr-impact 'No measurable NFR change.' \
        --module 'repository|Repository-wide task fixture.' \
        --evidence 'OTHER|app/value.txt|-|The acceptance check and implementation both use this repository file.' \
        --inspection-skip-reason 'Synthetic test fixture; structural inspection is unnecessary.' \
        --step 'Modify the approved application file.' \
        --step 'Run the registered verification check.'
    ) >/dev/null || fail "cannot record repository understanding"
}

approve_basic_task() {
    (cd "$FIXTURE" && ./.agent-harness/harness approve --by reviewer) >/dev/null || fail "cannot approve task"
}

active_state() {
    (cd "$FIXTURE" && ./.agent-harness/harness status --json) | sed -n 's/.*"state":"\([^"]*\)".*/\1/p'
}

add_automated_convention() {
    rule_id=${1:-REPO-001}
    check_id=${2:-check-app}
    (
        cd "$FIXTURE" || exit 1
        ./.agent-harness/harness conventions add \
          --id "$rule_id" \
          --category persistence \
          --level MUST \
          --source DECLARED \
          --path 'app/**' \
          --trigger NEW_OR_MODIFIED \
          --enforcement AUTOMATED \
          --check "$check_id" \
          --example app/value.txt \
          --rule 'Application files must satisfy the registered repository check.' \
          --by reviewer
    ) >/dev/null || fail "cannot add automated convention"
}

add_manual_convention() {
    rule_id=${1:-ARCH-001}
    (
        cd "$FIXTURE" || exit 1
        ./.agent-harness/harness conventions add \
          --id "$rule_id" \
          --category architecture \
          --level MUST \
          --source DECLARED \
          --path 'app/**' \
          --trigger NEW_OR_MODIFIED \
          --enforcement MANUAL \
          --example app/value.txt \
          --rule 'Changes must preserve the approved application boundary.' \
          --by reviewer
    ) >/dev/null || fail "cannot add manual convention"
}

register_failing_check() {
    id=${1:-convention-fail}
    phase=${2:-TEST}
    order=${3:-100}
    mkdir -p "$FIXTURE/.agent-harness/config/commands"
    cat >"$FIXTURE/.agent-harness/config/commands/$id.conf" <<EOF_CHECK
ID=$id
EXECUTABLE=false
CWD=.
TIMEOUT_SECONDS=30
EVIDENCE_TYPE=static_check
PHASE=$phase
ORDER=$order
PURPOSE=VERIFICATION
EOF_CHECK
}

record_understanding_with_assumption() {
    status=$1
    (
      cd "$FIXTURE" || exit 1
      ./.agent-harness/harness task understand \
        --by reviewer --current-behavior existing --entry-points app/value.txt \
        --data-flow local --dependencies none --interface-impact none \
        --compatibility-risk low --scope-rationale focused --check-rationale direct \
        --rollback-plan restore --security-impact none --data-impact none \
        --operational-impact none --nfr-impact none \
        --module 'repository|Repository-wide fixture' --evidence 'OTHER|app/value.txt|-|Synthetic fixture evidence.' \
        --inspection-skip-reason 'Synthetic fixture.' --assumption "Unknown behavior|$status" --step modify
    )
}

test_tree_digest() {
    local root listing path relative kind mode value
    root=$1
    listing=$(mktemp "${TMPDIR:-/tmp}/harness-test-tree.XXXXXX") || return 1
    : >"$listing"
    while IFS= read -r path; do
        relative=${path#"$root/"}
        if [ -L "$path" ]; then
            kind=symlink; mode=-; value=$(readlink "$path") || { rm -f "$listing"; return 1; }
        elif [ -f "$path" ]; then
            kind=file; mode=$(file_mode "$path") || { rm -f "$listing"; return 1; }; value=$(sha256_file "$path") || { rm -f "$listing"; return 1; }
        else
            continue
        fi
        printf '%s\t%s\t%s\t%s\n' "$relative" "$kind" "$mode" "$value" >>"$listing"
    done <<EOF_TREE
$(find "$root" -mindepth 1 \( -path "$root/.git" -o -path "$root/.git/*" \) -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort)
EOF_TREE
    digest=$(sha256_file "$listing")
    result=$?
    rm -f "$listing"
    [ "$result" -eq 0 ] && printf '%s\n' "$digest"
    return "$result"
}
