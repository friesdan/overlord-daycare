#!/usr/bin/env bash
# tests/smoke.sh — CI verification of the whole loop with NO AI: stub worker
# and reviewer commands (plain shell) stand in for claude/codex.
#
#   0. ./init --demo configures the kit
#   1. happy path:  stub fix + CLEAN verdict + auto approval -> merges
#   2. findings:    FINDINGS verdict + auto approval -> merge refused
#   3. red tests:   worker's change breaks nothing-fixing -> merge refused
#   4. bin/status runs and lists the tasks
#
# Requires: git, bash, python3. Run from anywhere: tests/smoke.sh
# Logs of each loop run are left in /tmp/mtc-smoke-*.log for debugging.
set -u
# shellcheck disable=SC1091

KIT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
reset_demo() { # recreate the demo repo fresh (each scenario needs a failing test)
    local n="$1"
    if ./init --demo > "/tmp/mtc-smoke-init$n.log" 2>&1; then ok "demo repo reset"; else bad "./init --demo reset failed"; fi
}
run_loop() { # run_loop <label> <task> <worker-cmd> <reviewer-cmd> <approval> [bin/loop options...]
    local label="$1" task="$2" w="$3" r="$4" a="$5"; shift 5
    MTC_WORKER_CMD="$w" MTC_REVIEWER_CMD="$r" MTC_APPROVAL_RULE="$a" \
    MTC_WORKER_TIMEOUT=60 MTC_REVIEWER_TIMEOUT=60 MTC_TEST_TIMEOUT=60 \
        "$KIT/bin/loop" "$task" "$KIT/examples/demo-task.md" "$@" \
        > "/tmp/mtc-smoke-$label.log" 2>&1
}

command -v git >/dev/null 2>&1     || { echo "git not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

if command -v shellcheck >/dev/null 2>&1; then
    echo "== shellcheck =="
    if shellcheck -x "$KIT/init" "$KIT/lib/common.sh" "$KIT"/bin/* "$KIT"/tests/smoke.sh "$KIT"/examples/stubs/*.sh; then
        ok "all scripts shellcheck-clean"
    else
        bad "shellcheck reported findings (above)"
    fi
else
    echo "== shellcheck not installed — skipping =="
fi

cd "$KIT" || exit 1
STUB_FIX="\"$KIT/examples/stubs/fix-demo-worker.sh\""
STUB_CLEAN="\"$KIT/examples/stubs/clean-reviewer.sh\""
STUB_FINDINGS='printf "1. BLOCKING: example finding (stub).\nVERDICT: FINDINGS\n"'
STUB_NOFIX='echo "# unrelated comment" >> calc.py && git add -A && git commit -qm "demo3: unrelated change"'
DEMO_REPO="$KIT/.mtc/demo-project"

echo "== scenario 0: ./init --demo =="
if ./init --demo >/tmp/mtc-smoke-init.log 2>&1; then ok "./init --demo exited 0"; else bad "./init --demo failed (see /tmp/mtc-smoke-init.log)"; fi
check ".mtc/config.env written" test -f .mtc/config.env
check ".mtc/SKILL.md written" test -f .mtc/SKILL.md
if grep -q '<<YOUR [A-Z]' .mtc/SKILL.md; then bad "skill copy still has <<YOUR ...>> placeholders"; else ok "skill placeholders filled"; fi
check "skill template untouched" grep -q '<<YOUR VALUES FILE>>' coordinator-skill/SKILL.md
check "demo repo created on main" git -C "$DEMO_REPO" rev-parse --verify -q refs/heads/main

echo "== scenario 1: full loop, CLEAN review, auto approval -> merges =="
if run_loop 1 demo "$STUB_FIX" "$STUB_CLEAN" auto; then ok "bin/loop demo exited 0"; else bad "bin/loop demo failed (see /tmp/mtc-smoke-1.log)"; fi
check "review.md saved with CLEAN verdict" grep -q 'VERDICT: CLEAN' .mtc/runs/demo/review.md
check "worker.log saved" test -s .mtc/runs/demo/worker.log
check "STATE.md marks demo merged" bash -c "awk '/^## demo$/{f=1;next}/^## /{f=0}f&&/^- status: /{print;exit}' STATE.md | grep -q merged"
check "demo branch kept as record" git -C "$DEMO_REPO" show-ref --verify -q refs/heads/mt/demo
check "worktree removed after merge" test ! -d "$HOME/.agent-merge-train/worktrees/demo-project/demo"
check "fix merged into main" git -C "$DEMO_REPO" log --oneline main -1 --grep='fix mean'
if (cd "$DEMO_REPO" && python3 -m unittest discover >/dev/null 2>&1); then
    ok "demo tests pass on merged main"
else
    bad "demo tests fail on merged main"
fi

echo "== scenario 2: FINDINGS verdict blocks auto-merge =="
reset_demo 2   # scenario 1 merged the fix; this scenario needs it unfixed
if run_loop 2 demo2 "$STUB_FIX" "$STUB_FINDINGS" auto; then bad "loop merged despite FINDINGS verdict"; else ok "loop refused auto-merge on FINDINGS"; fi
check "review.md saved with FINDINGS verdict" grep -q 'VERDICT: FINDINGS' .mtc/runs/demo2/review.md
if git -C "$DEMO_REPO" merge-base --is-ancestor mt/demo2 main; then bad "mt/demo2 was merged into main"; else ok "mt/demo2 NOT merged into main"; fi
check "worktree kept after refusal" test -d "$HOME/.agent-merge-train/worktrees/demo-project/demo2"

echo "== scenario 3: failing tests block merge even with --yes =="
reset_demo 3   # and here: the worker must NOT fix the bug, so tests must fail
if run_loop 3 demo3 "$STUB_NOFIX" "$STUB_CLEAN" human-approve --yes; then bad "loop merged with failing tests"; else ok "loop refused merge on failing tests"; fi
if git -C "$DEMO_REPO" merge-base --is-ancestor mt/demo3 main; then bad "mt/demo3 was merged into main"; else ok "mt/demo3 NOT merged into main"; fi
check "worktree kept after refusal" test -d "$HOME/.agent-merge-train/worktrees/demo-project/demo3"
check "STATE.md records failed tests" grep -q '^- tests: fail' STATE.md

echo "== scenario 4: bin/status =="
if bin/status >/tmp/mtc-smoke-4.log 2>&1; then ok "bin/status exited 0"; else bad "bin/status failed"; fi
check "bin/status lists tasks" grep -q '## demo3' /tmp/mtc-smoke-4.log

echo
printf 'smoke: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
