#!/usr/bin/env bash
# Shared helpers for the agent-merge-train scripts. Sourced by bin/* — not run
# directly. Bash 3.2 compatible (macOS + Linux).

MTC_KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MTC_DIR="$MTC_KIT/.mtc"
MTC_CONFIG="$MTC_DIR/config.env"
MTC_STATE="$MTC_KIT/STATE.md"

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Print $1 single-quoted, safe to write into config.env and source back.
shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

load_config() {
    [ -f "$MTC_CONFIG" ] || die "no configuration found at $MTC_CONFIG
Run ./init first (see ./init --help), or ./init --demo for the built-in demo."

    # Environment overrides must be captured BEFORE sourcing config.env:
    # sourcing re-assigns the same variable names and would shadow the
    # environment values (MTC_WORKER_CMD=... bin/worker demo is a documented
    # escape hatch, and tests/smoke.sh depends on it).
    env_PROJECT_DIR="${MTC_PROJECT_DIR-}"
    env_BASE_BRANCH="${MTC_BASE_BRANCH-}"
    env_TEST_CMD="${MTC_TEST_CMD-}"
    env_WORKER_CMD="${MTC_WORKER_CMD-}"
    env_REVIEWER_CMD="${MTC_REVIEWER_CMD-}"
    env_APPROVAL_RULE="${MTC_APPROVAL_RULE-}"
    env_WORKTREE_ROOT="${MTC_WORKTREE_ROOT-}"
    env_WORKER_TIMEOUT="${MTC_WORKER_TIMEOUT-}"
    env_REVIEWER_TIMEOUT="${MTC_REVIEWER_TIMEOUT-}"
    env_TEST_TIMEOUT="${MTC_TEST_TIMEOUT-}"

    # shellcheck disable=SC1090
    . "$MTC_CONFIG"

    [ -n "$env_PROJECT_DIR" ]    && MTC_PROJECT_DIR="$env_PROJECT_DIR"
    [ -n "$env_BASE_BRANCH" ]    && MTC_BASE_BRANCH="$env_BASE_BRANCH"
    [ -n "$env_TEST_CMD" ]       && MTC_TEST_CMD="$env_TEST_CMD"
    [ -n "$env_WORKER_CMD" ]     && MTC_WORKER_CMD="$env_WORKER_CMD"
    [ -n "$env_REVIEWER_CMD" ]   && MTC_REVIEWER_CMD="$env_REVIEWER_CMD"
    [ -n "$env_APPROVAL_RULE" ]  && MTC_APPROVAL_RULE="$env_APPROVAL_RULE"
    [ -n "$env_WORKTREE_ROOT" ]  && MTC_WORKTREE_ROOT="$env_WORKTREE_ROOT"
    [ -n "$env_WORKER_TIMEOUT" ] && MTC_WORKER_TIMEOUT="$env_WORKER_TIMEOUT"
    [ -n "$env_REVIEWER_TIMEOUT" ] && MTC_REVIEWER_TIMEOUT="$env_REVIEWER_TIMEOUT"
    [ -n "$env_TEST_TIMEOUT" ]   && MTC_TEST_TIMEOUT="$env_TEST_TIMEOUT"

    # config may keep the worktree root symbolic ('$HOME/...'); expand that
    # one prefix without eval, then insist on an absolute path.
    # shellcheck disable=SC2016
    case "$MTC_WORKTREE_ROOT" in
        '$HOME'*) MTC_WORKTREE_ROOT="$HOME${MTC_WORKTREE_ROOT#\$HOME}" ;;
    esac
    case "$MTC_WORKTREE_ROOT" in
        /*) : ;;
        *) die "MTC_WORKTREE_ROOT must be an absolute path, got: $MTC_WORKTREE_ROOT" ;;
    esac

    [ -n "${MTC_PROJECT_DIR:-}" ]  || die "MTC_PROJECT_DIR is not set in $MTC_CONFIG — re-run ./init"
    [ -d "$MTC_PROJECT_DIR/.git" ] || [ -f "$MTC_PROJECT_DIR/.git" ] || \
        die "MTC_PROJECT_DIR ('$MTC_PROJECT_DIR') is not a git repository — re-run ./init"
    [ -n "${MTC_BASE_BRANCH:-}" ] || die "MTC_BASE_BRANCH is not set in $MTC_CONFIG — re-run ./init"
    [ -n "${MTC_TEST_CMD:-}" ]    || die "MTC_TEST_CMD is not set in $MTC_CONFIG — re-run ./init"
    [ -n "${MTC_WORKER_CMD:-}" ]  || die "MTC_WORKER_CMD is not set in $MTC_CONFIG — re-run ./init"
    [ -n "${MTC_REVIEWER_CMD:-}" ] || die "MTC_REVIEWER_CMD is not set in $MTC_CONFIG — re-run ./init"
    MTC_APPROVAL_RULE="${MTC_APPROVAL_RULE:-human-approve}"
    MTC_WORKTREE_ROOT="${MTC_WORKTREE_ROOT:-$HOME/.agent-merge-train/worktrees/$(basename "$MTC_PROJECT_DIR")}"
    MTC_WORKER_TIMEOUT="${MTC_WORKER_TIMEOUT:-1800}"
    MTC_REVIEWER_TIMEOUT="${MTC_REVIEWER_TIMEOUT:-900}"
    MTC_TEST_TIMEOUT="${MTC_TEST_TIMEOUT:-1200}"
}

# Validate a task name (it becomes a branch name mt/<task> and a directory).
valid_task_name() {
    case "$1" in
        *[!A-Za-z0-9._-]*|'') return 1 ;;
        .*) return 1 ;;
        *) return 0 ;;
    esac
}

task_branch() { printf 'mt/%s' "$1"; }
task_worktree() { printf '%s/%s' "$MTC_WORKTREE_ROOT" "$1"; }
task_run_dir() { printf '%s/runs/%s' "$MTC_DIR" "$1"; }

# Run a shell command string under a time bound if `timeout`/`gtimeout` exists
# (macOS has neither by default; then the run is unbounded and we say so).
# PROMPT / PROMPT_FILE / MTC_WORKTREE / MTC_TASK are exported for the command.
run_bounded() {
    local secs="$1" cmd="$2" t=""
    if command -v timeout >/dev/null 2>&1; then t=timeout
    elif command -v gtimeout >/dev/null 2>&1; then t=gtimeout
    fi
    if [ -n "$t" ]; then
        # shellcheck disable=SC2086
        $t "$secs" bash -c "$cmd"
    else
        echo "note: no 'timeout' command found; running without a time bound" >&2
        bash -c "$cmd"
    fi
}

# ---- STATE.md ------------------------------------------------------------
# One block per task:
#
#   ## demo
#   - status: open
#   - branch: mt/demo
#   - worktree: /absolute/path
#   - last_step: worker
#   - next_step: review
#   - updated: 2026-01-01T00:00:00Z
#
# state_set inserts or updates one key inside the task's block, creating the
# block (with status: open) if needed. A coordinator agent can resume after a
# restart by reading this file.

state_init() {
    if [ ! -f "$MTC_STATE" ]; then
        cat > "$MTC_STATE" <<'EOF'
# Merge-train state

Auto-maintained by the bin/* scripts — do not edit while they run.
One block per task: status, branch, worktree, last step, next step.
A coordinator (human or agent) reads this file to resume after a restart.
EOF
    fi
}

state_set() {
    # state_set <task> <key> <value>
    state_init
    local task="$1" key="$2" val="$3" tmp="$MTC_STATE.tmp"
    awk -v hdr="## $task" -v key="$key" -v val="$val" -v now="$(now_iso)" '
        function endblock() {
            if (inblock) {
                if (!wrote) print "- " key ": " val
                print "- updated: " now
            }
        }
        /^## / {
            endblock()
            inblock = ($0 == hdr) ? 1 : 0
            if (inblock) existed = 1
            wrote = 0; hadupdate = 0
            print; next
        }
        inblock && /^- updated: / {
            if (!wrote) { print "- " key ": " val; wrote = 1 }
            print "- updated: " now; hadupdate = 1; next
        }
        inblock && index($0, "- " key ": ") == 1 {
            print "- " key ": " val; wrote = 1; next
        }
        { print }
        END {
            endblock()
            if (!existed) {
                print ""
                print hdr
                print "- status: open"
                print "- " key ": " val
                print "- updated: " now
            }
        }
    ' "$MTC_STATE" > "$tmp" && mv "$tmp" "$MTC_STATE"
}

# state_get <task> <key> — print value or nothing if absent.
state_get() {
    [ -f "$MTC_STATE" ] || return 0
    awk -v hdr="## $1" -v key="$2" '
        /^## / { inblock = ($0 == hdr) ? 1 : 0; next }
        inblock && index($0, "- " key ": ") == 1 {
            sub("^- " key ": ", ""); print; exit
        }
    ' "$MTC_STATE"
}
