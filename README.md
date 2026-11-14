# agent-merge-train

A small open-source starter kit for supervised AI coding: you (or a coordinator
agent) hand a task to a **worker** AI, which fixes it in an isolated git
worktree; the tests run; a **different** reviewer AI reads the diff; a human
approves; it merges. One command runs the whole loop. It implements the method
described in [`HOW-WE-WORK.md`](HOW-WE-WORK.md) — read that for the reasoning;
this repo is the runnable, minimal version: sensible defaults, everything else
optional. Plain bash; needs only git and bash (python3 for the demo; jq not
required).

## First loop in 10 minutes

Prerequisites: `git`, `bash`, `python3`, and one AI coding CLI on your PATH —
`claude` and/or `codex` (optional for the demo: with neither installed it runs
on dumb stub commands, so you can see the machinery first).

```bash
./init --demo                # configures the built-in demo project
bin/loop demo examples/demo-task.md
```

You will see, in order:

1. a git worktree + branch `mt/demo` created for the task (under
   `~/.agent-merge-train/worktrees/`),
2. the **worker** run inside that worktree — it edits `calc.py`, runs the
   tests, commits, and stops (log: `.mtc/runs/demo/worker.log`),
3. the **reviewer** run on `git diff main...mt/demo`, ending in a verdict line
   (saved: `.mtc/runs/demo/review.md`),
4. the tests run again at the **merge gate**, a summary like:

   ```
   ================= merge gate: demo =================
     tests   : pass
     review  : CLEAN
     diff    : 1 file changed, 1 insertion(+), 1 deletion(-)
     branch  : mt/demo -> merge into main
   =====================================================
   Merge into main? [y/N]
   ```

5. answer `y` → the branch merges into `main`, the worktree is removed, and
   nothing is ever pushed. Answer anything else → everything is left in place.

`bin/status` shows where every task is (branch, last step, next step) from
`STATE.md`; `./init --demo && bin/loop demo examples/demo-task.md --yes` runs
the whole thing without a terminal prompt (that's what CI does, see
[`tests/smoke.sh`](tests/smoke.sh)).

## Use it on your own project

```bash
./init
```

Seven questions, each with a default (Enter accepts): target project path, base
branch, test command, worker command, reviewer command, approval rule, worktree
directory. `./init` detects which of `claude`/`codex` you have and suggests
command templates such as:

- worker: `claude -p "$PROMPT" --permission-mode acceptEdits ...`
- reviewer: `codex exec --sandbox read-only "$PROMPT"`

These are templates you can edit afterwards in `.mtc/config.env` — the AI sees
its task as `$PROMPT` (or `$PROMPT_FILE`). If you only have one CLI installed it
is used for both roles, with a warning: an **independent reviewer** (a different
model family) catches blind spots the builder shares ([HOW-WE-WORK.md §1](HOW-WE-WORK.md#1-the-shape-coordinator-lanes-reviewers)).

Then write a small task file — a few lines naming what breaks, for whom, and
the scope (see `examples/demo-task.md` for the shape) — and run:

```bash
bin/loop <task-name> <task-file>       # worker -> review -> merge gate
```

or drive the stages yourself:

| Command | What it does |
| --- | --- |
| `bin/worker <task> <task-file>` | worktree + branch `mt/<task>`, worker AI runs there, commits, stops |
| `bin/review <task>` | reviewer AI reads `diff <base>...mt/<task>`, writes `review.md` with a `VERDICT:` line |
| `bin/check-and-merge <task>` | runs tests in the worktree, shows the summary, asks `Merge into <base>? [y/N]`, merges (never pushes) |
| `bin/loop <task> <task-file>` | all three in sequence |
| `bin/status` | prints `STATE.md` + liveness of each task's branch/worktree |

Everything the kit writes is local and git-ignored: `.mtc/` (config, the filled
skill copy, per-task logs) and `STATE.md`. Approval is `human-approve` by
default; `auto` merges without asking only when tests pass AND the review is
`CLEAN`.

### STATE.md: resuming after a restart

Every script updates `STATE.md` (task → status, branch, worktree, last step,
next step). After any restart — yours or an agent's — `bin/status` (or just
reading `STATE.md`) says exactly where the train is and what happens next.
`./init` also fills in a copy of the coordinator skill at `.mtc/SKILL.md`
(the template at [`coordinator-skill/SKILL.md`](coordinator-skill/SKILL.md) is
never edited), plus starter files it points at (values, handoff, heartbeat
checklist, board, critical list).

## Grow it later (all optional)

The kit is deliberately the smallest thing that works. As it starts to hurt,
add pieces in this order ([HOW-WE-WORK.md §11](HOW-WE-WORK.md#11-start-small-bootstrap-checklist)):

- **Heartbeat schedule** — a ~30-minute prompt that only points at
  `.mtc/HEARTBEAT.md` ([§6](HOW-WE-WORK.md#6-the-heartbeat-and-watchers)).
- **Compaction hooks** — snapshot state before summarizing, re-inject resume
  steps after ([§7](HOW-WE-WORK.md#7-surviving-long-sessions-compaction-and-the-handoff)).
- **Status board** — a phone-glanceable board and a Decisions tab
  ([§8](HOW-WE-WORK.md#8-talking-to-the-owner-a-phone-first-board)).
- **Usage dashboard** — one machine-readable answer per plan on how many lanes
  may run now ([§2](HOW-WE-WORK.md#2-compute-a-usage-dashboard-decides-how-many-lanes-run)).

The method write-up [`HOW-WE-WORK.md`](HOW-WE-WORK.md) covers all of it;
[`coordinator-skill/SKILL.md`](coordinator-skill/SKILL.md) is the same method
as an installable operating manual.

## Safety notes

- Worker agents run with **edit permissions inside one isolated worktree** and
  are instructed to commit and stop; lanes never merge, never push.
- **Never give agents production credentials.** Shell profiles often export
  live keys that every spawned agent inherits ([HOW-WE-WORK.md §10](HOW-WE-WORK.md#10-hard-won-lessons-generalized)).
- **Review before merge** is the default: a human approves every merge, and the
  `auto` rule still requires a CLEAN independent review plus green tests.
- Nothing here ever runs `git push` — pushing stays a human (or your explicit
  CI) decision.

## Development

`tests/smoke.sh` runs the whole loop with stub worker/reviewer commands — no
AI, no network; it is what CI should run:

```bash
tests/smoke.sh        # also verifies shellcheck cleanliness of the scripts
```

MIT license — see [LICENSE](LICENSE).
