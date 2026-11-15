#!/usr/bin/env bash
# Shared helpers for the Overlord Daycare scripts. Sourced by bin/* — not run
# directly. Bash 3.2 compatible (macOS + Linux).

OVERLORD_KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLORD_DIR="$OVERLORD_KIT/.overlord"
OVERLORD_CONFIG="$OVERLORD_DIR/config.env"
OVERLORD_STATE="$OVERLORD_KIT/STATE.md"

info() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Print $1 single-quoted, safe to write into config.env and source back.
shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

load_config() {
    [ -f "$OVERLORD_CONFIG" ] || die "no configuration found at $OVERLORD_CONFIG
Run ./init first (see ./init --help), or ./init --demo for the built-in demo."

    # Environment overrides must be captured BEFORE sourcing config.env:
    # sourcing re-assigns the same variable names and would shadow the
    # environment values (OVERLORD_WORKER_CMD=... bin/worker demo is a documented
    # escape hatch, and tests/smoke.sh depends on it).
    env_PROJECT_DIR="${OVERLORD_PROJECT_DIR-}"
    env_BASE_BRANCH="${OVERLORD_BASE_BRANCH-}"
    env_TEST_CMD="${OVERLORD_TEST_CMD-}"
    env_WORKER_CMD="${OVERLORD_WORKER_CMD-}"
    env_REVIEWER_CMD="${OVERLORD_REVIEWER_CMD-}"
    env_APPROVAL_RULE="${OVERLORD_APPROVAL_RULE-}"
    env_WORKTREE_ROOT="${OVERLORD_WORKTREE_ROOT-}"
    env_WORKER_TIMEOUT="${OVERLORD_WORKER_TIMEOUT-}"
    env_REVIEWER_TIMEOUT="${OVERLORD_REVIEWER_TIMEOUT-}"
    env_TEST_TIMEOUT="${OVERLORD_TEST_TIMEOUT-}"
    env_PASS_ENV="${OVERLORD_PASS_ENV-}"
    env_ALLOW_ENV="${OVERLORD_ALLOW_ENV-}"
    env_TEST_PASS_ENV="${OVERLORD_TEST_PASS_ENV-}"

    # shellcheck disable=SC1090
    . "$OVERLORD_CONFIG"

    [ -n "$env_PROJECT_DIR" ]    && OVERLORD_PROJECT_DIR="$env_PROJECT_DIR"
    [ -n "$env_BASE_BRANCH" ]    && OVERLORD_BASE_BRANCH="$env_BASE_BRANCH"
    [ -n "$env_TEST_CMD" ]       && OVERLORD_TEST_CMD="$env_TEST_CMD"
    [ -n "$env_WORKER_CMD" ]     && OVERLORD_WORKER_CMD="$env_WORKER_CMD"
    [ -n "$env_REVIEWER_CMD" ]   && OVERLORD_REVIEWER_CMD="$env_REVIEWER_CMD"
    [ -n "$env_APPROVAL_RULE" ]  && OVERLORD_APPROVAL_RULE="$env_APPROVAL_RULE"
    [ -n "$env_WORKTREE_ROOT" ]  && OVERLORD_WORKTREE_ROOT="$env_WORKTREE_ROOT"
    [ -n "$env_WORKER_TIMEOUT" ] && OVERLORD_WORKER_TIMEOUT="$env_WORKER_TIMEOUT"
    [ -n "$env_REVIEWER_TIMEOUT" ] && OVERLORD_REVIEWER_TIMEOUT="$env_REVIEWER_TIMEOUT"
    [ -n "$env_TEST_TIMEOUT" ]   && OVERLORD_TEST_TIMEOUT="$env_TEST_TIMEOUT"
    [ -n "$env_PASS_ENV" ]       && OVERLORD_PASS_ENV="$env_PASS_ENV"
    [ -n "$env_ALLOW_ENV" ]      && OVERLORD_ALLOW_ENV="$env_ALLOW_ENV"
    [ -n "$env_TEST_PASS_ENV" ]  && OVERLORD_TEST_PASS_ENV="$env_TEST_PASS_ENV"

    # config may keep the worktree root symbolic ('$HOME/...'); expand that
    # one prefix without eval, then insist on an absolute path.
    # shellcheck disable=SC2016
    case "$OVERLORD_WORKTREE_ROOT" in
        '$HOME'*) OVERLORD_WORKTREE_ROOT="$HOME${OVERLORD_WORKTREE_ROOT#\$HOME}" ;;
    esac
    case "$OVERLORD_WORKTREE_ROOT" in
        /*) : ;;
        *) die "OVERLORD_WORKTREE_ROOT must be an absolute path, got: $OVERLORD_WORKTREE_ROOT" ;;
    esac

    [ -n "${OVERLORD_PROJECT_DIR:-}" ]  || die "OVERLORD_PROJECT_DIR is not set in $OVERLORD_CONFIG — re-run ./init"
    [ -d "$OVERLORD_PROJECT_DIR/.git" ] || [ -f "$OVERLORD_PROJECT_DIR/.git" ] || \
        die "OVERLORD_PROJECT_DIR ('$OVERLORD_PROJECT_DIR') is not a git repository — re-run ./init"
    [ -n "${OVERLORD_BASE_BRANCH:-}" ] || die "OVERLORD_BASE_BRANCH is not set in $OVERLORD_CONFIG — re-run ./init"
    [ -n "${OVERLORD_TEST_CMD:-}" ]    || die "OVERLORD_TEST_CMD is not set in $OVERLORD_CONFIG — re-run ./init"
    [ -n "${OVERLORD_WORKER_CMD:-}" ]  || die "OVERLORD_WORKER_CMD is not set in $OVERLORD_CONFIG — re-run ./init"
    [ -n "${OVERLORD_REVIEWER_CMD:-}" ] || die "OVERLORD_REVIEWER_CMD is not set in $OVERLORD_CONFIG — re-run ./init"
    OVERLORD_APPROVAL_RULE="${OVERLORD_APPROVAL_RULE:-human}"
    OVERLORD_WORKTREE_ROOT="${OVERLORD_WORKTREE_ROOT:-$HOME/.overlord-daycare/worktrees/$(basename "$OVERLORD_PROJECT_DIR")}"
    OVERLORD_WORKER_TIMEOUT="${OVERLORD_WORKER_TIMEOUT:-1800}"
    OVERLORD_REVIEWER_TIMEOUT="${OVERLORD_REVIEWER_TIMEOUT:-900}"
    OVERLORD_TEST_TIMEOUT="${OVERLORD_TEST_TIMEOUT:-1200}"
    OVERLORD_ALLOW_ENV="${OVERLORD_ALLOW_ENV:-PATH HOME LANG LC_* TERM TMPDIR}"
    OVERLORD_PASS_ENV="${OVERLORD_PASS_ENV:-}"
    OVERLORD_TEST_PASS_ENV="${OVERLORD_TEST_PASS_ENV:-}"
}

# ---- Environment allowlist and scrubbing -----------------------------------
# Worktrees isolate files, not credentials: child processes inherit the shell
# environment. Worker, reviewer, and final test commands all run in a scrubbed
# environment starting from an empty env (env -i) plus an explicit allowlist.
# Safe default allowlist:
#   PATH HOME LANG LC_* TERM TMPDIR
# Configurable via OVERLORD_ALLOW_ENV in config.env. Additional variables
# needed by a lane or test suite are passed via OVERLORD_PASS_ENV or
# OVERLORD_TEST_PASS_ENV.
lane_env_allowlist() {
    printf '%s %s %s %s\n' \
        "${OVERLORD_ALLOW_ENV:-PATH HOME LANG LC_* TERM TMPDIR}" \
        "PROMPT PROMPT_FILE OVERLORD_WORKTREE OVERLORD_TASK" \
        "${OVERLORD_PASS_ENV:-}" \
        "${OVERLORD_TEST_PASS_ENV:-}"
}

lane_scrub_env() {
    local v pat allowed
    local allowlist
    allowlist="$(lane_env_allowlist)"

    while IFS= read -r v; do
        [ -z "$v" ] && continue
        allowed=0
        for pat in $allowlist; do
            # shellcheck disable=SC2053
            if [[ "$v" == $pat ]]; then
                allowed=1
                break
            fi
        done
        if [ "$allowed" -eq 0 ]; then
            unset "$v" 2>/dev/null || true
        fi
    done < <(
        export -p | grep -E '^(declare -x|export) [A-Za-z_][A-Za-z0-9_]*=' \
            | sed -E 's/^(declare -x|export) ([A-Za-z_][A-Za-z0-9_]*)=.*/\2/'
    )
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
task_worktree() { printf '%s/%s' "$OVERLORD_WORKTREE_ROOT" "$1"; }
task_run_dir() { printf '%s/runs/%s' "$OVERLORD_DIR" "$1"; }

# Run a shell command string under a time bound if `timeout`/`gtimeout` exists
# (macOS has neither by default; then the run is unbounded and we say so).
# Commands execute in an empty environment (env -i) plus the allowlist.
run_bounded() {
    local secs="$1" cmd="$2" t="" rc=0
    if command -v timeout >/dev/null 2>&1; then t=timeout
    elif command -v gtimeout >/dev/null 2>&1; then t=gtimeout
    fi

    # Scrub environment starting from empty env (env -i) plus explicit allowlist
    lane_scrub_env

    local -a env_args=()
    local v
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        env_args+=("$v=${!v}")
    done < <(
        export -p | grep -E '^(declare -x|export) [A-Za-z_][A-Za-z0-9_]*=' \
            | sed -E 's/^(declare -x|export) ([A-Za-z_][A-Za-z0-9_]*)=.*/\2/'
    )

    local old_ifs="$IFS"
    IFS=$'\x1f'
    if [ -n "$t" ]; then
        # shellcheck disable=SC2048,SC2086
        $t "$secs" env -i ${env_args[*]} bash -c "$cmd" || rc=$?
    else
        echo "note: no 'timeout' command found; running without a time bound" >&2
        # shellcheck disable=SC2048,SC2086
        env -i ${env_args[*]} bash -c "$cmd" || rc=$?
    fi
    IFS="$old_ifs"
    return "$rc"
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
    if [ ! -f "$OVERLORD_STATE" ]; then
        cat > "$OVERLORD_STATE" <<'EOF'
# Overlord Daycare state

Auto-maintained by the bin/* scripts — do not edit while they run.
One block per task: status, branch, worktree, last step, next step.
A coordinator (human or agent) reads this file to resume after a restart.
EOF
    fi
}

state_lock() {
    local lockdir="$OVERLORD_DIR/.state.lock"
    local i=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        sleep 0.05
        i=$((i + 1))
        if [ "$i" -gt 300 ]; then
            rm -rf "$lockdir"
        fi
    done
}

state_unlock() {
    rm -rf "$OVERLORD_DIR/.state.lock"
}

state_set() {
    # state_set <task> <key> <value>
    state_init
    local task="$1" key="$2" val="$3" tmp
    tmp="$(mktemp "$OVERLORD_STATE.tmp.XXXXXX")"
    state_lock
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
    ' "$OVERLORD_STATE" > "$tmp" && mv "$tmp" "$OVERLORD_STATE"
    rm -f "$tmp"
    state_unlock
}

# state_get <task> <key> — print value or nothing if absent.
state_get() {
    [ -f "$OVERLORD_STATE" ] || return 0
    awk -v hdr="## $1" -v key="$2" '
        /^## / { inblock = ($0 == hdr) ? 1 : 0; next }
        inblock && index($0, "- " key ": ") == 1 {
            sub("^- " key ": ", ""); print; exit
        }
    ' "$OVERLORD_STATE"
}
