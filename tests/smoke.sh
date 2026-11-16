#!/usr/bin/env bash
# tests/smoke.sh — CI verification of what remains, with NO AI and NO network:
# stub worker/reviewer commands stand in for the AI CLIs, and a stub `gh`
# stands in for the hosting platform.
#
#   0. ./init --demo configures the kit
#   1. happy path: stub fix + CLEAN review -> branch pushed-ready, review
#      bound to the exact head, NOTHING merged locally (platform merges)
#   2. findings: FINDINGS verdict -> loop stops; merge-when-green refuses
#   3. stale review: commit after a CLEAN review -> merge-when-green refuses;
#      re-review the new head -> check-only green
#   4. bin/status runs and lists the tasks
#   5. per-task env: parent secrets do not reach the worker; allowlisted and
#      per-task-profile variables do; a control character in the profile
#      refuses the launch; the profile lives outside the worktree
#   6. example usage collector: fixtures -> pacing input -> bin/pace reads it
#   7. merge-when-green: green checks enable platform auto-merge (fake gh
#      records the call; local main untouched); failing checks refuse
#
# Requires: git, bash, python3. Run from anywhere: tests/smoke.sh
# Logs of each run are left in /tmp/overlord-smoke-*.log for debugging.
set -u
# shellcheck disable=SC1091

KIT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091  # for state_get, used by the checks below
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
    rm -rf "$HOME/.overlord-daycare/worktrees/demo-project"
    if ./init --demo > "/tmp/overlord-smoke-init$n.log" 2>&1; then ok "demo repo reset"; else bad "./init --demo reset failed"; fi
}
run_stage() { # run_stage <label> <command...> — one kit step with the stub config
    local label="$1"; shift
    OVERLORD_WORKER_CMD="$STUB_FIX" OVERLORD_REVIEWER_CMD="$STUB_CLEAN" \
    OVERLORD_WORKER_TIMEOUT=60 OVERLORD_REVIEWER_TIMEOUT=60 \
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
DEMO_REPO="$KIT/.overlord/demo-project"

# ---- Stub platform CLI ------------------------------------------------------
# A fake `gh` on PATH: serves PR views for mt/* branches from the demo repo,
# reports checks per FAKE_GH_CHECKS, and records every `pr merge` call
# WITHOUT merging anything (the real platform merges server-side; locally,
# main must not move — the scenarios assert exactly that).
FAKE_BIN="$(mktemp -d)"
FAKE_GH_LOG="$FAKE_BIN/gh-calls.log"
cat > "$FAKE_BIN/gh" <<'FAKEEOF'
#!/usr/bin/env bash
# Fake gh for tests/smoke.sh. Env: FAKE_GH_CHECKS=pass|fail, FAKE_GH_LOG, DEMO_REPO.
printf '%s\n' "$*" >> "${FAKE_GH_LOG:-/dev/null}"
case "$1 $2" in
    "pr view")
        ref="$3"
        case "$ref" in
            mt/*) branch="$ref" ;;
            *) branch="mt/demo" ;;
        esac
        sha="$(git -C "$DEMO_REPO" rev-parse "$branch" 2>/dev/null || echo 0000000000000000000000000000000000000000)"
        printf '{"number":42,"url":"https://example.invalid/pr/42","state":"OPEN","headRefName":"%s","headRefOid":"%s","isDraft":false,"reviewDecision":"APPROVED"}\n' "$branch" "$sha"
        ;;
    "pr checks")
        if [ "${FAKE_GH_CHECKS:-pass}" = "pass" ]; then
            echo "ci  pass  1m0s"
            exit 0
        fi
        echo "ci  fail  1m0s"
        exit 1
        ;;
    "pr merge")
        echo "auto-merge enabled (fake platform)"
        exit 0
        ;;
    *) echo "fake gh: unhandled: $*" >&2; exit 1 ;;
esac
FAKEEOF
chmod +x "$FAKE_BIN/gh"
export DEMO_REPO FAKE_GH_LOG
FAKE_PATH="$FAKE_BIN:$PATH"

echo "== scenario 0: ./init --demo =="
if ./init --demo >/tmp/overlord-smoke-init.log 2>&1; then ok "./init --demo exited 0"; else bad "./init --demo failed (see /tmp/overlord-smoke-init.log)"; fi
check ".overlord/config.env written" test -f .overlord/config.env
check ".overlord/SKILL.md written" test -f .overlord/SKILL.md
if grep -q '<<YOUR [A-Z]' .overlord/SKILL.md; then bad "skill copy still has <<YOUR ...>> placeholders"; else ok "skill placeholders filled"; fi
check "skill template untouched" grep -q '<<YOUR VALUES FILE>>' coordinator-skill/SKILL.md
check "demo repo created on main" git -C "$DEMO_REPO" rev-parse --verify -q refs/heads/main
check "no local merge engine remains" test ! -e "$KIT/bin/check-and-merge"
check "merge-when-green example present" test -x "$KIT/bin/merge-when-green"

echo "== scenario 1: worker + CLEAN review -> ready, nothing merged locally =="
main_before="$(git -C "$DEMO_REPO" rev-parse main)"
if PATH="$FAKE_PATH" FAKE_GH_CHECKS=pass OVERLORD_WORKER_CMD="$STUB_FIX" OVERLORD_REVIEWER_CMD="$STUB_CLEAN" \
    OVERLORD_WORKER_TIMEOUT=60 OVERLORD_REVIEWER_TIMEOUT=60 \
    "$KIT/bin/loop" demo "$KIT/examples/demo-task.md" > /tmp/overlord-smoke-1.log 2>&1; then
    ok "bin/loop demo exited 0 (check-only merge step)"
else
    bad "bin/loop demo failed (see /tmp/overlord-smoke-1.log)"
fi
check "review.md saved with CLEAN verdict" grep -q 'VERDICT: CLEAN' .overlord/runs/demo/review.md
check "worker.log saved" test -s .overlord/runs/demo/worker.log
check "task branch kept as the PR branch" git -C "$DEMO_REPO" show-ref --verify -q refs/heads/mt/demo
check "worktree kept (platform merges the PR, not the worktree)" test -d "$HOME/.overlord-daycare/worktrees/demo-project/demo"
if [ "$(git -C "$DEMO_REPO" rev-parse main)" = "$main_before" ]; then
    ok "local main did NOT move (no local merge)"
else
    bad "local main moved — something merged locally"
fi
head1="$(git -C "$DEMO_REPO" rev-parse mt/demo)"
if [ "$(state_get demo review_commit)" = "$head1" ]; then ok "review bound to exact head"; else bad "review not bound to head"; fi

echo "== scenario 2: FINDINGS verdict blocks the merge =="
reset_demo 2
if OVERLORD_WORKER_CMD="$STUB_FIX" OVERLORD_REVIEWER_CMD="$STUB_FINDINGS" \
    OVERLORD_WORKER_TIMEOUT=60 OVERLORD_REVIEWER_TIMEOUT=60 \
    "$KIT/bin/loop" demo2 "$KIT/examples/demo-task.md" > /tmp/overlord-smoke-2.log 2>&1; then
    bad "loop continued despite FINDINGS verdict"
else
    ok "loop stopped on FINDINGS"
fi
check "review.md saved with FINDINGS verdict" grep -q 'VERDICT: FINDINGS' .overlord/runs/demo2/review.md
if PATH="$FAKE_PATH" FAKE_GH_CHECKS=pass "$KIT/bin/merge-when-green" --task demo2 > /tmp/overlord-smoke-2b.log 2>&1; then
    bad "merge-when-green enabled auto-merge despite FINDINGS"
else
    ok "merge-when-green refused FINDINGS (exit non-zero)"
fi

echo "== scenario 3: a new commit cannot inherit an old CLEAN review =="
reset_demo 3
W3="$HOME/.overlord-daycare/worktrees/demo-project/demo3"
if run_stage 3a "$KIT/bin/worker" demo3 "$KIT/examples/demo-task.md"; then ok "bin/worker demo3 ran (commit A)"; else bad "bin/worker demo3 failed (see /tmp/overlord-smoke-3a.log)"; fi
if run_stage 3b "$KIT/bin/review" demo3; then ok "bin/review demo3 recorded CLEAN"; else bad "bin/review demo3 failed (see /tmp/overlord-smoke-3b.log)"; fi
commit_a="$(git -C "$DEMO_REPO" rev-parse mt/demo3)"
if [ "$(state_get demo3 review_commit)" = "$commit_a" ]; then ok "review bound to commit A"; else bad "review not bound to commit A"; fi
if ( cd "$W3" && echo "# demo3: follow-up commit B (unreviewed)" >> calc.py \
        && git add -A && git commit -qm "demo3: follow-up commit B" ); then
    ok "commit B added on mt/demo3"
else
    bad "could not add commit B in $W3"
fi
commit_b="$(git -C "$DEMO_REPO" rev-parse mt/demo3)"
if PATH="$FAKE_PATH" FAKE_GH_CHECKS=pass "$KIT/bin/merge-when-green" --task demo3 --check-only > /tmp/overlord-smoke-3c.log 2>&1; then
    bad "merge-when-green accepted unreviewed commit B on an old CLEAN review"
else
    ok "merge-when-green refused the stale review"
fi
check "refusal says why (stale review)" grep -qi "stale review" /tmp/overlord-smoke-3c.log
if run_stage 3d "$KIT/bin/review" demo3; then ok "bin/review re-ran on commit B"; else bad "re-review failed"; fi
if [ "$(state_get demo3 review_commit)" = "$commit_b" ]; then ok "review now bound to commit B"; else bad "re-review did not bind to commit B"; fi
if PATH="$FAKE_PATH" FAKE_GH_CHECKS=pass "$KIT/bin/merge-when-green" --task demo3 --check-only > /tmp/overlord-smoke-3e.log 2>&1; then
    ok "check-only green after the re-review of commit B"
else
    bad "check-only refused a fresh review (see /tmp/overlord-smoke-3e.log)"
fi

echo "== scenario 4: bin/status =="
if bin/status >/tmp/overlord-smoke-4.log 2>&1; then ok "bin/status exited 0"; else bad "bin/status failed"; fi
check "bin/status lists tasks" grep -q '## demo3' /tmp/overlord-smoke-4.log

echo "== scenario 5: per-task env — secrets stay out, profile vars get in =="
reset_demo 5
W5="$HOME/.overlord-daycare/worktrees/demo-project/demo5"
mkdir -p .overlord/profiles
printf 'TASK_ONLY_TOKEN=task-scoped-value\n' > .overlord/profiles/demo5.env
PROBE='env | grep -E "^(GITHUB_TOKEN|DEMO_API_KEY|DATABASE_URL|SAFE_LANE_TOKEN|TASK_ONLY_TOKEN|PATH)=" | sort > env-probe.txt && git add -A && git commit -qm "demo5: env probe"'
if GITHUB_TOKEN=gh_secret DEMO_API_KEY=ak_secret DATABASE_URL=postgres://prod \
   SAFE_LANE_TOKEN=allowed-through OVERLORD_PASS_ENV="SAFE_LANE_TOKEN" \
   OVERLORD_WORKER_CMD="$PROBE" OVERLORD_WORKER_TIMEOUT=60 \
   "$KIT/bin/worker" demo5 "$KIT/examples/demo-task.md" > /tmp/overlord-smoke-5.log 2>&1; then
    ok "bin/worker demo5 ran"
else
    bad "bin/worker demo5 failed (see /tmp/overlord-smoke-5.log)"
fi
PROBE_FILE="$W5/env-probe.txt"
check "env probe committed" test -f "$PROBE_FILE"
for v in GITHUB_TOKEN DEMO_API_KEY DATABASE_URL; do
    if grep -q "^$v=" "$PROBE_FILE" 2>/dev/null; then bad "$v leaked into the worker shell"; else ok "$v did not reach the worker"; fi
done
check "OVERLORD_PASS_ENV variable passed through" grep -q "^SAFE_LANE_TOKEN=allowed-through$" "$PROBE_FILE"
check "per-task profile variable passed through" grep -q "^TASK_ONLY_TOKEN=task-scoped-value$" "$PROBE_FILE"
check "PATH still passed through" grep -q "^PATH=" "$PROBE_FILE"
profile_path="$KIT/.overlord/profiles/demo5.env"
case "$profile_path" in
    "$W5"*) bad "env profile lives inside the worker-writable worktree" ;;
    *) ok "env profile lives outside the worktree" ;;
esac
# Control characters in a profile refuse the launch, before any worker runs.
printf 'TASK_ONLY_TOKEN=bad\x01value\n' > .overlord/profiles/democtl.env
if OVERLORD_WORKER_CMD="$STUB_FIX" OVERLORD_WORKER_TIMEOUT=60 \
    "$KIT/bin/worker" democtl "$KIT/examples/demo-task.md" > /tmp/overlord-smoke-5c.log 2>&1; then
    bad "worker launched despite a control character in its profile"
else
    ok "control character in profile refused the launch"
fi
check "refusal names the control character" grep -qi "control character" /tmp/overlord-smoke-5c.log
rm -f .overlord/profiles/demo5.env .overlord/profiles/democtl.env

echo "== scenario 6: example usage collector (fixture -> meters -> pacing) =="
if command -v node >/dev/null 2>&1; then
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ "${node_major:-0}" -lt 20 ] 2>/dev/null; then
        echo "== node < 20 found — skipping the collector scenario =="
    else
        if node --test tests/example-collector.test.mjs pacing/pace.test.mjs > /tmp/overlord-smoke-6.log 2>&1; then
            ok "collector + pacing unit tests pass"
        else
            bad "unit tests failed (see /tmp/overlord-smoke-6.log)"
        fi
        smoke_meters="$(mktemp -d)/meters.json"
        if node collectors/example-collector/collector.mjs --pool smoke-plan \
            --fixture collectors/example-collector/fixtures/cli-status.txt \
            --burn-per-lane-hour 4 --meters "$smoke_meters" > /tmp/overlord-smoke-6b.log 2>&1 \
            && grep -q '"usedPercent": 40' "$smoke_meters" \
            && "$KIT/bin/pace" "$smoke_meters" --json 2>>/tmp/overlord-smoke-6b.log | grep -q '"smoke-plan"'; then
            ok "collector output paces (bin/pace reads what it wrote)"
        else
            bad "collector -> bin/pace chain failed (see /tmp/overlord-smoke-6b.log)"
        fi
        rm -f "$smoke_meters"
    fi
else
    echo "== node not found — skipping the collector scenario (bin/pace needs it too) =="
fi

echo "== scenario 7: merge-when-green hands the merge to the platform =="
# demo3 is reviewed CLEAN on its current head (scenario 3). Green checks ->
# auto-merge is enabled through gh; local main must not move.
: > "$FAKE_GH_LOG"
main_before7="$(git -C "$DEMO_REPO" rev-parse main)"
if PATH="$FAKE_PATH" FAKE_GH_CHECKS=pass "$KIT/bin/merge-when-green" --task demo3 > /tmp/overlord-smoke-7.log 2>&1; then
    ok "merge-when-green enabled auto-merge on green checks"
else
    bad "merge-when-green failed on green checks (see /tmp/overlord-smoke-7.log)"
fi
check "platform merge was requested (gh pr merge --auto)" grep -q "pr merge" "$FAKE_GH_LOG"
if [ "$(git -C "$DEMO_REPO" rev-parse main)" = "$main_before7" ]; then
    ok "local main untouched by merge-when-green (platform merges)"
else
    bad "merge-when-green moved local main"
fi
: > "$FAKE_GH_LOG"
if PATH="$FAKE_PATH" FAKE_GH_CHECKS=fail "$KIT/bin/merge-when-green" --task demo3 > /tmp/overlord-smoke-7b.log 2>&1; then
    bad "merge-when-green merged despite failing checks"
else
    ok "merge-when-green refused failing checks"
fi
if grep -q "pr merge" "$FAKE_GH_LOG"; then bad "auto-merge requested despite failing checks"; else ok "no merge requested on failing checks"; fi

echo
printf 'smoke: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
