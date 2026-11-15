#!/usr/bin/env bash
# tests/smoke.sh — CI verification of the whole loop with NO AI: stub worker
# and reviewer commands (plain shell) stand in for claude/codex.
#
#   0. ./init --demo configures the kit
#   1. happy path:  stub fix + CLEAN verdict + auto approval -> merges
#   2. findings:    FINDINGS verdict + auto approval -> merge refused
#   3. red tests:   worker's change breaks nothing-fixing -> merge refused
#   4. bin/status runs and lists the tasks
#   5. exact-commit review binding: commit after a CLEAN review -> merge
#      refused; re-review the new head -> merge allowed
#   6. credentials: secret env vars set in the parent do not reach the worker
#      (OVERLORD_PASS_ENV allowlisted ones do)
#   7. example usage collector: fixtures -> pacing input format -> bin/pace
#      reads it (no network; unit tests in tests/example-collector.test.mjs)
#   8. credentials: fake secret not visible to final test; allowlisted var is
#   9. concurrency: two workers finishing at once do not corrupt shared state
#  10. integrated merge: merging two green branches re-runs gate on combined result
#
# Requires: git, bash, python3. Run from anywhere: tests/smoke.sh
# Logs of each loop run are left in /tmp/overlord-smoke-*.log for debugging.
set -u
# shellcheck disable=SC1091

KIT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091  # for state_get, used by the scenario 5 checks
. "$KIT/lib/common.sh"
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
    # Drop leftover demo worktrees first: ./init --demo rebuilds the repo, and
    # a worktree left by an earlier scenario (or an earlier run of this suite)
    # would make bin/worker refuse the same task name — scenarios 2, 3 and 6
    # never merge, so their worktrees would otherwise survive.
    rm -rf "$HOME/.overlord-daycare/worktrees/demo-project"
    if ./init --demo > "/tmp/overlord-smoke-init$n.log" 2>&1; then ok "demo repo reset"; else bad "./init --demo reset failed"; fi
}
run_loop() { # run_loop <label> <task> <worker-cmd> <reviewer-cmd> <approval> [bin/loop options...]
    local label="$1" task="$2" w="$3" r="$4" a="$5"; shift 5
    OVERLORD_WORKER_CMD="$w" OVERLORD_REVIEWER_CMD="$r" OVERLORD_APPROVAL_RULE="$a" \
    OVERLORD_WORKER_TIMEOUT=60 OVERLORD_REVIEWER_TIMEOUT=60 OVERLORD_TEST_TIMEOUT=60 \
        "$KIT/bin/loop" "$task" "$KIT/examples/demo-task.md" "$@" \
        > "/tmp/overlord-smoke-$label.log" 2>&1
}
run_stage() { # run_stage <label> <script> [args...] — one kit script with the stub config
    local label="$1"; shift
    OVERLORD_WORKER_CMD="$STUB_FIX" OVERLORD_REVIEWER_CMD="$STUB_CLEAN" \
    OVERLORD_WORKER_TIMEOUT=60 OVERLORD_REVIEWER_TIMEOUT=60 OVERLORD_TEST_TIMEOUT=60 \
        "$@" > "/tmp/overlord-smoke-$label.log" 2>&1
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
DEMO_REPO="$KIT/.overlord/demo-project"

echo "== scenario 0: ./init --demo =="
if ./init --demo >/tmp/overlord-smoke-init.log 2>&1; then ok "./init --demo exited 0"; else bad "./init --demo failed (see /tmp/overlord-smoke-init.log)"; fi
check ".overlord/config.env written" test -f .overlord/config.env
check ".overlord/SKILL.md written" test -f .overlord/SKILL.md
if grep -q '<<YOUR [A-Z]' .overlord/SKILL.md; then bad "skill copy still has <<YOUR ...>> placeholders"; else ok "skill placeholders filled"; fi
check "skill template untouched" grep -q '<<YOUR VALUES FILE>>' coordinator-skill/SKILL.md
check "demo repo created on main" git -C "$DEMO_REPO" rev-parse --verify -q refs/heads/main

echo "== scenario 1: full loop, CLEAN review, auto approval -> merges =="
if run_loop 1 demo "$STUB_FIX" "$STUB_CLEAN" auto; then ok "bin/loop demo exited 0"; else bad "bin/loop demo failed (see /tmp/overlord-smoke-1.log)"; fi
check "review.md saved with CLEAN verdict" grep -q 'VERDICT: CLEAN' .overlord/runs/demo/review.md
check "worker.log saved" test -s .overlord/runs/demo/worker.log
check "STATE.md marks demo merged" bash -c "awk '/^## demo$/{f=1;next}/^## /{f=0}f&&/^- status: /{print;exit}' STATE.md | grep -q merged"
check "demo branch kept as record" git -C "$DEMO_REPO" show-ref --verify -q refs/heads/mt/demo
check "worktree removed after merge" test ! -d "$HOME/.overlord-daycare/worktrees/demo-project/demo"
check "fix merged into main" git -C "$DEMO_REPO" log --oneline main -1 --grep='fix mean'
if (cd "$DEMO_REPO" && python3 -m unittest discover >/dev/null 2>&1); then
    ok "demo tests pass on merged main"
else
    bad "demo tests fail on merged main"
fi

echo "== scenario 2: FINDINGS verdict blocks auto-merge =="
reset_demo 2   # scenario 1 merged the fix; this scenario needs it unfixed
if run_loop 2 demo2 "$STUB_FIX" "$STUB_FINDINGS" auto; then bad "loop merged despite FINDINGS verdict"; else ok "loop refused auto-merge on FINDINGS"; fi
check "review.md saved with FINDINGS verdict" grep -q 'VERDICT: FINDINGS' .overlord/runs/demo2/review.md
if git -C "$DEMO_REPO" merge-base --is-ancestor mt/demo2 main; then bad "mt/demo2 was merged into main"; else ok "mt/demo2 NOT merged into main"; fi
check "worktree kept after refusal" test -d "$HOME/.overlord-daycare/worktrees/demo-project/demo2"

echo "== scenario 3: failing tests block merge even with --yes =="
reset_demo 3   # and here: the worker must NOT fix the bug, so tests must fail
if run_loop 3 demo3 "$STUB_NOFIX" "$STUB_CLEAN" human --yes; then bad "loop merged with failing tests"; else ok "loop refused merge on failing tests"; fi
if git -C "$DEMO_REPO" merge-base --is-ancestor mt/demo3 main; then bad "mt/demo3 was merged into main"; else ok "mt/demo3 NOT merged into main"; fi
check "worktree kept after refusal" test -d "$HOME/.overlord-daycare/worktrees/demo-project/demo3"
check "STATE.md records failed tests" grep -q '^- tests: fail' STATE.md

echo "== scenario 4: bin/status =="
if bin/status >/tmp/overlord-smoke-4.log 2>&1; then ok "bin/status exited 0"; else bad "bin/status failed"; fi
check "bin/status lists tasks" grep -q '## demo3' /tmp/overlord-smoke-4.log

echo "== scenario 5: a new commit cannot inherit an old CLEAN review =="
reset_demo 5   # scenario 1 merged the fix; this scenario needs it unfixed
W5="$HOME/.overlord-daycare/worktrees/demo-project/demo5"
if run_stage 5a "$KIT/bin/worker" demo5 "$KIT/examples/demo-task.md"; then ok "bin/worker demo5 ran (commit A)"; else bad "bin/worker demo5 failed (see /tmp/overlord-smoke-5a.log)"; fi
if run_stage 5b "$KIT/bin/review" demo5; then ok "bin/review demo5 recorded CLEAN"; else bad "bin/review demo5 failed (see /tmp/overlord-smoke-5b.log)"; fi
commit_a="$(git -C "$DEMO_REPO" rev-parse mt/demo5)"
if [ "$(state_get demo5 review_commit)" = "$commit_a" ]; then ok "review bound to commit A ($commit_a)"; else bad "STATE.md did not record the reviewed commit A"; fi
# commit B lands after the review — no reviewer has seen it
if ( cd "$W5" && echo "# demo5: follow-up commit B (unreviewed)" >> calc.py \
        && git add -A && git commit -qm "demo5: follow-up commit B" ); then
    ok "commit B added on mt/demo5"
else
    bad "could not add commit B in $W5"
fi
commit_b="$(git -C "$DEMO_REPO" rev-parse mt/demo5)"
if [ "$commit_a" != "$commit_b" ]; then ok "mt/demo5 moved to a new commit B"; else bad "commit B did not land"; fi
if run_stage 5c "$KIT/bin/check-and-merge" --yes demo5; then
    bad "merge gate merged unreviewed commit B on an old CLEAN review"
else
    ok "merge gate refused the stale review (exit non-zero)"
fi
check "refusal says why (stale review)" grep -q "stale review" /tmp/overlord-smoke-5c.log
if git -C "$DEMO_REPO" merge-base --is-ancestor mt/demo5 main; then bad "mt/demo5 merged despite a stale review"; else ok "mt/demo5 NOT merged into main"; fi
check "worktree kept after refusal" test -d "$W5"
if run_stage 5d "$KIT/bin/review" demo5; then ok "bin/review re-ran on commit B"; else bad "re-review of demo5 failed"; fi
if [ "$(state_get demo5 review_commit)" = "$commit_b" ]; then ok "review now bound to commit B"; else bad "re-review did not bind to commit B"; fi
if run_stage 5e "$KIT/bin/check-and-merge" --yes demo5; then
    ok "merge allowed after the re-review of commit B"
else
    bad "merge gate refused a fresh review (see /tmp/overlord-smoke-5e.log)"
fi
if git -C "$DEMO_REPO" merge-base --is-ancestor "$commit_b" main; then ok "exactly commit B merged into main"; else bad "commit B did not reach main"; fi
check "worktree removed after merge" test ! -d "$W5"

echo "== scenario 6: a secret set in the parent does not reach the worker =="
reset_demo 6
W6="$HOME/.overlord-daycare/worktrees/demo-project/demo6"
# The probe records only the variables under test (never a copy of the whole
# environment) and commits, so bin/worker sees a completed task.
PROBE='env | grep -E "^(GITHUB_TOKEN|DEMO_API_KEY|DEMO_CLIENT_SECRET|DATABASE_URL|AWS_SECRET_ACCESS_KEY|STRIPE_API_KEY|SAFE_LANE_TOKEN|PATH)=" | sort > env-probe.txt && git add -A && git commit -qm "demo6: env probe"'
if GITHUB_TOKEN=gh_secret DEMO_API_KEY=ak_secret DEMO_CLIENT_SECRET=cs_secret \
   DATABASE_URL=postgres://prod AWS_SECRET_ACCESS_KEY=aws_secret STRIPE_API_KEY=sk_live_secret \
   SAFE_LANE_TOKEN=allowed-through OVERLORD_PASS_ENV="SAFE_LANE_TOKEN" \
   OVERLORD_WORKER_CMD="$PROBE" OVERLORD_WORKER_TIMEOUT=60 \
   "$KIT/bin/worker" demo6 "$KIT/examples/demo-task.md" > /tmp/overlord-smoke-6.log 2>&1; then
    ok "bin/worker demo6 ran"
else
    bad "bin/worker demo6 failed (see /tmp/overlord-smoke-6.log)"
fi
PROBE_FILE="$W6/env-probe.txt"
check "env probe committed" test -f "$PROBE_FILE"
for v in GITHUB_TOKEN DEMO_API_KEY DEMO_CLIENT_SECRET DATABASE_URL AWS_SECRET_ACCESS_KEY STRIPE_API_KEY; do
    if grep -q "^$v=" "$PROBE_FILE" 2>/dev/null; then bad "$v leaked into the worker shell"; else ok "$v did not reach the worker"; fi
done
check "OVERLORD_PASS_ENV variable passed through" grep -q "^SAFE_LANE_TOKEN=allowed-through$" "$PROBE_FILE"
check "PATH still passed through" grep -q "^PATH=" "$PROBE_FILE"

echo "== scenario 7: example usage collector (fixture -> meters -> pacing) =="
if command -v node >/dev/null 2>&1; then
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ "${node_major:-0}" -lt 20 ] 2>/dev/null; then
        echo "== node < 20 found — skipping the collector scenario =="
    else
        if node --test tests/ > /tmp/overlord-smoke-7.log 2>&1; then
            ok "example-collector unit tests pass"
        else
            bad "example-collector tests failed (see /tmp/overlord-smoke-7.log)"
        fi
        # and the chain end to end: collector writes a meters file, bin/pace reads it
        smoke_meters="$(mktemp -d)/meters.json"
        if node collectors/example-collector/collector.mjs --pool smoke-plan \
            --fixture collectors/example-collector/fixtures/cli-status.txt \
            --burn-per-lane-hour 4 --meters "$smoke_meters" > /tmp/overlord-smoke-7b.log 2>&1 \
            && grep -q '"usedPercent": 40' "$smoke_meters" \
            && "$KIT/bin/pace" "$smoke_meters" --json 2>>/tmp/overlord-smoke-7b.log | grep -q '"smoke-plan"'; then
            ok "collector output paces (bin/pace reads what it wrote)"
        else
            bad "collector -> bin/pace chain failed (see /tmp/overlord-smoke-7b.log)"
        fi
        rm -f "$smoke_meters"
    fi
else
    echo "== node not found — skipping the collector scenario (bin/pace needs it too) =="
fi

echo "== scenario 8: secret does not reach final test; allowlisted var does =="
reset_demo 8
W8="$HOME/.overlord-daycare/worktrees/demo-project/demo8"
if run_stage 8a "$KIT/bin/worker" demo8 "$KIT/examples/demo-task.md"; then
    ok "bin/worker demo8 ran"
else
    bad "bin/worker demo8 failed (see /tmp/overlord-smoke-8a.log)"
fi
if run_stage 8b "$KIT/bin/review" demo8; then
    ok "bin/review demo8 recorded CLEAN"
else
    bad "bin/review demo8 failed (see /tmp/overlord-smoke-8b.log)"
fi

PROBE_TEST='python3 -c "import os, sys; ok = (\"OVERLORD_TEST_FAKE_TOKEN\" not in os.environ and os.environ.get(\"SAFE_TEST_VAR\") == \"allow-ok\"); sys.exit(0 if ok else 1)"'

if OVERLORD_TEST_FAKE_TOKEN=secret_val \
   SAFE_TEST_VAR=allow-ok OVERLORD_PASS_ENV="SAFE_TEST_VAR" \
   OVERLORD_TEST_CMD="$PROBE_TEST" OVERLORD_TEST_TIMEOUT=60 \
   run_stage 8c "$KIT/bin/check-and-merge" --yes demo8; then
    ok "final test command ran scrubbed (fake secret hidden, allowlisted var visible)"
else
    bad "final test command leaked secret or dropped allowlisted var (see /tmp/overlord-smoke-8c.log)"
fi
check "demo8 merged into main" git -C "$DEMO_REPO" merge-base --is-ancestor mt/demo8 main
check "demo8 worktree removed after merge" test ! -d "$W8"

echo "== scenario 9: concurrency — two workers finishing at once =="
reset_demo 9
W9A="$HOME/.overlord-daycare/worktrees/demo-project/demo9a"
W9B="$HOME/.overlord-daycare/worktrees/demo-project/demo9b"

if run_stage 9a "$KIT/bin/worker" demo9a "$KIT/examples/demo-task.md"; then
    ok "bin/worker demo9a ran"
else
    bad "bin/worker demo9a failed"
fi
( cd "$W9A" && echo "# conflict alpha" >> calc.py && git commit -qam "demo9a: add conflict line" )
if run_stage 9b "$KIT/bin/review" demo9a; then
    ok "bin/review demo9a recorded CLEAN"
else
    bad "bin/review demo9a failed"
fi

if run_stage 9c "$KIT/bin/worker" demo9b "$KIT/examples/demo-task.md"; then
    ok "bin/worker demo9b ran"
else
    bad "bin/worker demo9b failed"
fi
( cd "$W9B" && echo "# conflict beta" >> calc.py && git commit -qam "demo9b: add conflict line" )
if run_stage 9d "$KIT/bin/review" demo9b; then
    ok "bin/review demo9b recorded CLEAN"
else
    bad "bin/review demo9b failed"
fi

run_stage 9e "$KIT/bin/check-and-merge" --yes demo9a &
PID_A=$!
run_stage 9f "$KIT/bin/check-and-merge" --yes demo9b &
PID_B=$!

RC_A=0
RC_B=0
wait "$PID_A" || RC_A=$?
wait "$PID_B" || RC_B=$?

if { [ "$RC_A" -eq 0 ] && [ "$RC_B" -ne 0 ]; } || { [ "$RC_A" -ne 0 ] && [ "$RC_B" -eq 0 ]; }; then
    ok "exactly one merge succeeded; competing merge refused"
else
    bad "concurrency error: RC_A=$RC_A RC_B=$RC_B"
fi
if { test ! -d "$W9A" && test -d "$W9B"; } || { test -d "$W9A" && test ! -d "$W9B"; }; then
    ok "merged worktree removed; refused worktree kept"
else
    bad "worktree state invalid after concurrent merge"
fi
check "STATE.md demo9a entry valid" grep -q "## demo9a" "$OVERLORD_STATE"
check "STATE.md demo9b entry valid" grep -q "## demo9b" "$OVERLORD_STATE"
check "main repo working tree clean" test -z "$(git -C "$DEMO_REPO" status --porcelain)"

echo "== scenario 10: integrated merge re-runs gate on combined result =="
reset_demo 10
W10A="$HOME/.overlord-daycare/worktrees/demo-project/demo10a"
W10B="$HOME/.overlord-daycare/worktrees/demo-project/demo10b"

if run_stage 10a "$KIT/bin/worker" demo10a "$KIT/examples/demo-task.md"; then
    ok "bin/worker demo10a ran"
else
    bad "bin/worker demo10a failed"
fi
( cd "$W10A" && printf 'FLAG = True\n' > helper_flag.py && git add helper_flag.py && git commit -qm "add helper_flag.py" )
if run_stage 10b "$KIT/bin/review" demo10a; then
    ok "bin/review demo10a recorded CLEAN"
else
    bad "bin/review demo10a failed"
fi

if run_stage 10c "$KIT/bin/worker" demo10b "$KIT/examples/demo-task.md"; then
    ok "bin/worker demo10b ran"
else
    bad "bin/worker demo10b failed"
fi
( cd "$W10B" && cat << 'EOFSCRIPT' > test_sem_check.py
import unittest
class TestSem(unittest.TestCase):
    def test_flag(self):
        try:
            import helper_flag
            self.assertFalse(helper_flag.FLAG)
        except ImportError:
            pass
EOFSCRIPT
  git add test_sem_check.py && git commit -qm "demo10b: add test_sem_check.py"
)

if ( cd "$W10B" && python3 -m unittest discover >/dev/null 2>&1 ); then
    ok "demo10b tests pass in isolation"
else
    bad "demo10b tests failed in isolation"
fi

if run_stage 10d "$KIT/bin/review" demo10b; then
    ok "bin/review demo10b recorded CLEAN"
else
    bad "bin/review demo10b failed"
fi

if run_stage 10e "$KIT/bin/check-and-merge" --yes demo10a; then
    ok "demo10a merged into main"
else
    bad "demo10a failed to merge"
fi

if run_stage 10f "$KIT/bin/check-and-merge" --yes demo10b; then
    bad "merge gate merged incompatible changes without catching combined test failure"
else
    ok "merge gate refused combined result on integrated test failure"
fi
check "rollback log mentions integrated test failure" grep -q "integrated" /tmp/overlord-smoke-10f.log
if git -C "$DEMO_REPO" merge-base --is-ancestor mt/demo10b main; then
    bad "demo10b was merged into main despite combined test failure"
else
    ok "demo10b was NOT merged into main"
fi
check "worktree kept after integrated refusal" test -d "$W10B"

echo
printf 'smoke: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
