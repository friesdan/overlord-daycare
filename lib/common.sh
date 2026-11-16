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
    env_WORKTREE_ROOT="${OVERLORD_WORKTREE_ROOT-}"
    env_WORKER_TIMEOUT="${OVERLORD_WORKER_TIMEOUT-}"
    env_REVIEWER_TIMEOUT="${OVERLORD_REVIEWER_TIMEOUT-}"
    env_PASS_ENV="${OVERLORD_PASS_ENV-}"
    env_ALLOW_ENV="${OVERLORD_ALLOW_ENV-}"

    # shellcheck disable=SC1090
    . "$OVERLORD_CONFIG"

    [ -n "$env_PROJECT_DIR" ]    && OVERLORD_PROJECT_DIR="$env_PROJECT_DIR"
    [ -n "$env_BASE_BRANCH" ]    && OVERLORD_BASE_BRANCH="$env_BASE_BRANCH"
    [ -n "$env_TEST_CMD" ]       && OVERLORD_TEST_CMD="$env_TEST_CMD"
    [ -n "$env_WORKER_CMD" ]     && OVERLORD_WORKER_CMD="$env_WORKER_CMD"
    [ -n "$env_REVIEWER_CMD" ]   && OVERLORD_REVIEWER_CMD="$env_REVIEWER_CMD"
    [ -n "$env_WORKTREE_ROOT" ]  && OVERLORD_WORKTREE_ROOT="$env_WORKTREE_ROOT"
    [ -n "$env_WORKER_TIMEOUT" ] && OVERLORD_WORKER_TIMEOUT="$env_WORKER_TIMEOUT"
    [ -n "$env_REVIEWER_TIMEOUT" ] && OVERLORD_REVIEWER_TIMEOUT="$env_REVIEWER_TIMEOUT"
    [ -n "$env_PASS_ENV" ]       && OVERLORD_PASS_ENV="$env_PASS_ENV"
    [ -n "$env_ALLOW_ENV" ]      && OVERLORD_ALLOW_ENV="$env_ALLOW_ENV"

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
    OVERLORD_WORKTREE_ROOT="${OVERLORD_WORKTREE_ROOT:-$HOME/.overlord-daycare/worktrees/$(basename "$OVERLORD_PROJECT_DIR")}"
    OVERLORD_WORKER_TIMEOUT="${OVERLORD_WORKER_TIMEOUT:-1800}"
    OVERLORD_REVIEWER_TIMEOUT="${OVERLORD_REVIEWER_TIMEOUT:-900}"
    OVERLORD_ALLOW_ENV="${OVERLORD_ALLOW_ENV:-PATH HOME LANG LC_* TERM TMPDIR}"
    OVERLORD_PASS_ENV="${OVERLORD_PASS_ENV:-}"
}

# ---- Per-task environment allowlist (minimal) --------------------------------
# Workers get only the credentials their task needs, via a per-task profile.
# This is an allowlist helper for launching workers, not a sandbox: it decides
# which variables a launched process starts with. Production credentials must
# never be listed here at all (see HOW-WE-WORK.md).
#
# Two small invariants are enforced:
#   1. Control characters are rejected in variable names and values — a
#      profile line or pass-through name containing them fails closed.
#   2. The allowlist and profile live outside worker-writable paths. The
#      profile for a task is $OVERLORD_DIR/profiles/<task>.env (kit state,
#      never inside a worktree); if a profile path ever resolves inside the
#      task worktree, launching refuses.

# valid_env_name <name> — shell identifier shape, nothing else.
valid_env_name() {
    case "$1" in
        ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
        *) return 0 ;;
    esac
}

# env_has_control <string> — true (0) if it contains a control character.
env_has_control() {
    printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

# task_env_profile <task> — where the per-task profile lives (outside worktrees).
task_env_profile() { printf '%s/profiles/%s.env' "$OVERLORD_DIR" "$1"; }

# assert_profile_outside_worktree <profile> <worktree>
assert_profile_outside_worktree() {
    case "$1" in
        "$2"|"$2"/*) die "env profile '$1' is inside the worker-writable worktree '$2' — move it outside (profiles belong under $OVERLORD_DIR/profiles/)" ;;
    esac
}

# load_task_profile <task> <worktree> — validate and export the per-task profile.
# Format: one KEY=VALUE per line; blank lines and # comments are ignored.
# Any control character, bad name, or in-worktree location refuses the launch.
load_task_profile() {
    local task="$1" worktree="$2" profile line key val
    profile="$(task_env_profile "$task")"
    [ -f "$profile" ] || return 0
    assert_profile_outside_worktree "$profile" "$worktree"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        if env_has_control "$line"; then
            die "env profile $profile: line contains a control character — refusing to launch (fix the profile)"
        fi
        case "$line" in
            *=*) ;;
            *) die "env profile $profile: expected KEY=VALUE, got: $line" ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        valid_env_name "$key" || die "env profile $profile: invalid variable name '$key'"
        export "$key=$val"
        # Remember the name so run_bounded allowlists it for this launch.
        OVERLORD_PROFILE_VARS="${OVERLORD_PROFILE_VARS:-} $key"
    done < "$profile"
}

# lane_env_allowlist — names/patterns a launched worker or reviewer may keep.
lane_env_allowlist() {
    printf '%s %s %s %s\n' \
        "${OVERLORD_ALLOW_ENV:-PATH HOME LANG LC_* TERM TMPDIR}" \
        "PROMPT PROMPT_FILE OVERLORD_WORKTREE OVERLORD_TASK" \
        "${OVERLORD_PASS_ENV:-}" \
        "${OVERLORD_PROFILE_VARS:-}"
}

# Validate every pass-through/profile name once; bad names fail closed here
# rather than silently never matching in the child environment.
validate_allowlist_names() {
    local name
    for name in $(lane_env_allowlist); do
        case "$name" in
            *'*') continue ;;  # patterns like LC_* are intentional
        esac
        if env_has_control "$name"; then
            die "environment allowlist entry contains a control character: refusing to launch"
        fi
        valid_env_name "$name" || die "invalid environment variable name in allowlist: '$name'"
    done
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
# The command runs from an empty environment (env -i) plus the allowlist:
# base allowlist + per-task profile (already exported by load_task_profile).
# An allowlisted variable whose value contains a control character refuses
# the launch — secrets and paths never need one.
run_bounded() {
    local secs="$1" cmd="$2" t="" rc=0
    if command -v timeout >/dev/null 2>&1; then t=timeout
    elif command -v gtimeout >/dev/null 2>&1; then t=gtimeout
    fi

    validate_allowlist_names

    local allowlist v pat allowed
    allowlist="$(lane_env_allowlist)"
    local -a env_args=()
    local -a present=()
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        present+=("$v")
    done < <(
        export -p | grep -E '^(declare -x|export) [A-Za-z_][A-Za-z0-9_]*=' \
            | sed -E 's/^(declare -x|export) ([A-Za-z_][A-Za-z0-9_]*)=.*/\2/'
    )
    for v in "${present[@]}"; do
        allowed=0
        for pat in $allowlist; do
            # shellcheck disable=SC2053
            if [[ "$v" == $pat ]]; then
                allowed=1
                break
            fi
        done
        [ "$allowed" -eq 1 ] || continue
        if env_has_control "${!v}"; then
            die "environment variable $v contains a control character — refusing to launch (unset it or fix its value)"
        fi
        env_args+=("$v=${!v}")
    done

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
