# Overlord Daycare

<img src="assets/hero.jpg" alt="A supervisor watching over a room of busy AI coding agents at work" width="720">

> The AIs think they run things. You're the babysitter.

Website: https://overlord-daycare.danfries.us

A small open-source starter kit for supervised AI coding: you (or a coordinator
agent) hand a task to a **worker** AI, which fixes it in an isolated git
worktree; the tests run; a **different** reviewer AI reads the diff; it merges.
One command runs the whole loop. It implements the method described in
[`HOW-WE-WORK.md`](HOW-WE-WORK.md) — read that for the reasoning; this repo is
the runnable, minimal version: sensible defaults, everything else optional.
Plain bash; needs only git and bash (python3 for the demo; jq not required).

Pacing is the secret sauce: a small dashboard tells the coordinator how many
agents each AI subscription can run right now, so every plan is spent evenly —
nothing sits unused at reset, nothing runs dry early. The design guide is
[`docs/pacing.md`](docs/pacing.md) and the kit ships a tiny reference engine
(`bin/pace`, below).

## First loop in 10 minutes

<img src="assets/coordinator.jpg" alt="The coordinator at work, directing several AI coding lanes from a single desk" width="640">

Prerequisites: `git`, `bash`, `python3`, and one AI coding CLI on your PATH —
`claude` and/or `codex` (optional for the demo: with neither installed it runs
on dumb stub commands, so you can see the machinery first). Already have a CLI
installed but want the free stub run first? Force it:

```bash
OVERLORD_WORKER_CMD="\"$PWD/examples/stubs/fix-demo-worker.sh\"" \
OVERLORD_REVIEWER_CMD="\"$PWD/examples/stubs/clean-reviewer.sh\"" ./init --demo
```

```bash
./init --demo                # configures the built-in demo project
bin/loop demo examples/demo-task.md
```

You will see, in order:

1. a git worktree + branch `mt/demo` created for the task (under
   `~/.overlord-daycare/worktrees/`),
2. the **worker** run inside that worktree — it edits `calc.py`, runs the
   tests, commits, and stops (log: `.overlord/runs/demo/worker.log`),
3. the **reviewer** run on `git diff main...mt/demo`, ending in a verdict line
   (saved: `.overlord/runs/demo/review.md`),
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
   nothing is ever pushed. Answer anything else → everything is left in place;
   run `bin/check-and-merge demo` later to pick up at the merge gate
   (`bin/status` always shows the next step). Without a terminal (a pipe, a
   script) the gate treats the answer as "no" — approve with
   `bin/loop demo examples/demo-task.md --yes` instead.

`bin/status` shows where every task is (branch, last step, next step) from
`STATE.md`; `./init --demo && bin/loop demo examples/demo-task.md --yes` runs
the whole thing without a terminal prompt (that's what CI does, see
[`tests/smoke.sh`](tests/smoke.sh)).

## Use it on your own project

```bash
./init
```

Seven questions, each with a default (Enter accepts): target project path, base
branch, test command, worker command, reviewer command, approval mode, worktree
directory. `./init` detects which of `claude`/`codex` you have and suggests
command templates such as:

- worker: `claude -p "$PROMPT" --permission-mode acceptEdits ...`
- reviewer: `codex exec --sandbox read-only "$PROMPT"`

These are templates you can edit afterwards in `.overlord/config.env` — the AI
sees its task as `$PROMPT` (or `$PROMPT_FILE`). If you only have one CLI
installed it is used for both roles, with a warning: an **independent
reviewer** (a different model family) catches blind spots the builder shares
([HOW-WE-WORK.md §1](HOW-WE-WORK.md#1-the-shape-coordinator-lanes-reviewers)).

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
| `bin/check-and-merge <task>` | runs tests in the worktree, shows the summary, applies the approval rule, merges (never pushes) |
| `bin/loop <task> <task-file>` | all three in sequence |
| `bin/status` | prints `STATE.md` + liveness of each task's branch/worktree |
| `bin/pace [meters.json] [--json]` | prints per-pool pace and advised lanes from a meters file |

Everything the kit writes is local and git-ignored: `.overlord/` (config, the
filled skill copy, per-task logs) and `STATE.md`.

### Who merges: the approval mode

Merging is not necessarily human. The principle: **the human sets the rules
and the gates; the coordinator may merge on its own once you trust those
gates.** Two modes, set in `.overlord/config.env` (`OVERLORD_APPROVAL_RULE`)
or at init time:

- `human` (default) — the merge gate asks `Merge into <base>? [y/N]` for every
  merge. Start here.
- `auto` — the coordinator merges without prompting, but **only** when the
  tests pass AND the independent review verdict is CLEAN; anything else stops
  the train and leaves everything in place for you. Switch to `auto` once the
  gates have caught everything you'd have caught yourself.

Neither mode ever pushes — pushing stays a human (or your explicit CI)
decision.

### STATE.md: resuming after a restart

<table>
  <tr>
    <td><img src="assets/peek-laptop.jpg" alt="Checking task status on a laptop to see where the train is" width="360"></td>
    <td><img src="assets/hike-phone.jpg" alt="Checking task status from a phone while out on a hike" width="360"></td>
  </tr>
</table>

Every script updates `STATE.md` (task → status, branch, worktree, last step,
next step). After any restart — yours or an agent's — `bin/status` (or just
reading `STATE.md`) says exactly where the train is and what happens next.
`./init` also fills in a copy of the coordinator skill at
`.overlord/SKILL.md` (the template at
[`coordinator-skill/SKILL.md`](coordinator-skill/SKILL.md) is never edited),
plus starter files it points at (values, handoff, heartbeat checklist, board,
critical list).

## Grow it later (all optional)

The kit is deliberately the smallest thing that works. As it starts to hurt,
add pieces in this order ([HOW-WE-WORK.md §11](HOW-WE-WORK.md#11-start-small-bootstrap-checklist)):

- **Pacing dashboard** — feed real subscription meters to the bundled engine
  and let it tell the coordinator how many lanes each pool may run
  ([docs/pacing.md](docs/pacing.md)).
- **Heartbeat schedule** — a ~30-minute prompt that only points at
  `.overlord/HEARTBEAT.md` ([§6](HOW-WE-WORK.md#6-the-heartbeat-and-watchers)).
- **Compaction hooks** — snapshot state before summarizing, re-inject resume
  steps after ([§7](HOW-WE-WORK.md#7-surviving-long-sessions-compaction-and-the-handoff)).
- **Status board** — a phone-glanceable board and a Decisions tab
  ([§8](HOW-WE-WORK.md#8-talking-to-the-owner-a-phone-first-board)).
- **CI and layered gates** — pre-push checks, CI on every push, exact-head
  review, one ready change at a time
  ([docs/ci-and-gates.md](docs/ci-and-gates.md)).

The method write-up [`HOW-WE-WORK.md`](HOW-WE-WORK.md) covers all of it;
[`coordinator-skill/SKILL.md`](coordinator-skill/SKILL.md) is the same method
as an installable operating manual.

## Pacing: spending every plan evenly

When one coordinator drives several AI subscriptions, the failure modes are
quiet: one plan's allowance expires unused at reset while another runs dry
days early. Pacing fixes that with one small dashboard per owner:

```bash
bin/pace                      # reads pacing/meters.example.json (synthetic)
bin/pace my-meters.json       # your real meters, same shape
bin/pace --json               # machine-readable, for the coordinator agent
```

Each pool gets a pace ratio (used % ÷ elapsed % of its window; 1.0 = an even
burn) and a lane count: how many agent lanes this pool may run right now,
derived from remaining allowance, hours to reset, a catch-up term, the
measured cost per lane-hour, and host capacity. An unreadable meter advises
0 lanes — unknown is never plenty.

[`docs/pacing.md`](docs/pacing.md) explains every idea and *why* it is there,
with a worked example and an honest-collection rule (official APIs or your own
exported data only); [`pacing/`](pacing/) holds the dependency-free reference
engine and tests.

## Safety notes

- Worker agents run with **edit permissions inside one isolated worktree** and
  are instructed to commit and stop; lanes never merge, never push.
- **Never give agents production credentials.** Shell profiles often export
  live keys that every spawned agent inherits ([HOW-WE-WORK.md §10](HOW-WE-WORK.md#10-hard-won-lessons-generalized)).
- **The human sets the rules and the gates; the coordinator may merge on its
  own once you trust those gates.** `human` mode is the default, and `auto`
  still requires a CLEAN independent review plus green tests before merging.
- Nothing here ever runs `git push` — pushing stays a human (or your explicit
  CI) decision.

## Development

`tests/smoke.sh` runs the whole loop with stub worker/reviewer commands — no
AI, no network; it is what CI should run. The pacing engine has its own unit
tests on Node's built-in runner:

```bash
tests/smoke.sh              # also verifies shellcheck cleanliness of the scripts
node --test pacing/         # pace engine unit tests (Node ≥ 20)
```

MIT license — see [LICENSE](LICENSE).
