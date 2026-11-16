# Overlord Daycare

<img src="assets/hero.jpg" alt="A person in a bathrobe with coffee peeks from a cozy kitchen into a smoky robot control floor run by a crowned robot" width="720">

> One overlord for all your AI plans.

Website: https://overlord-daycare.danfries.us

You pay for several AI subscriptions. Each has its own app, its own limits, its own reset clock. Some run out mid-week; others reset with allowance unused. Overlord Daycare gives you one place to talk to: a head overlord (a coordinator agent) that dispatches work to sub-overlords across every plan you pay for, paces each plan so it is spent evenly before reset, and has a different model review every change. Workers push pull requests; the hosting platform merges them when the checks pass. You set the rules once and check in whenever you like.

## What's in the kit

A small open-source starter kit for supervised AI coding: you (or a coordinator
agent) hand a task to a **worker** AI, which fixes it in an isolated git
worktree on its own branch and pushes a pull request; a **different** reviewer
AI reads the diff; the hosting platform merges when its checks pass. Workers
never merge. One command runs the whole loop. It implements the method
described in [`HOW-WE-WORK.md`](HOW-WE-WORK.md) — read that for the reasoning;
this repo is the runnable, minimal version: sensible defaults, everything else
optional. Plain bash; needs only git and bash (python3 for the demo; the
platform CLI `gh` only for the merge step; jq not required).

The kit is built for the multi-plan reality: you pay for several AI
subscriptions, each with its own limits and its own reset clock. Pacing is the
secret sauce: a small dashboard tells the coordinator how many agents each
subscription can run right now, so every plan is spent evenly — nothing sits
unused at reset, nothing runs dry early. The design guide is
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
   tests, commits, pushes the branch, and stops (log:
   `.overlord/runs/demo/worker.log`),
3. the **reviewer** run on `git diff main...mt/demo`, ending in a verdict line
   (saved: `.overlord/runs/demo/review.md`),
4. the PR status read through the platform — checks, review, exact head:

   ```
   ==> PR #42 (mt/demo @ 1a2b3c4d5e6f) state=OPEN draft=false review=APPROVED
   checks: ci pass
   green: PR #42 checks pass — merge-when-green would enable auto-merge
   ```

In the demo there is no remote and no PR, so step 4 is guidance, not a merge:
the branch stays reviewed and ready. On a real project the branch is already
pushed, you open its PR, and `bin/merge-when-green --task demo` enables
platform auto-merge once the required checks pass (branch protection setup:
[`docs/ci-and-gates.md`](docs/ci-and-gates.md)). The platform merges; nothing
in this kit merges locally. `bin/status` always shows the next step.

`bin/status` shows where every task is (branch, last step, next step) from
`STATE.md`; `./init --demo && bin/loop demo examples/demo-task.md` runs the
whole loop (with `--yes` it also enables auto-merge when a PR is green — that
is what CI exercises with a stub platform CLI, see
[`tests/smoke.sh`](tests/smoke.sh)).

## Use it on your own project

```bash
./init
```

Six questions, each with a default (Enter accepts): target project path, base
branch, test command, worker command, reviewer command, worktree
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
bin/loop <task-name> <task-file>       # worker -> review -> platform merge
```

or drive the stages yourself:

| Command | What it does |
| --- | --- |
| `bin/worker <task> <task-file>` | worktree + branch `mt/<task>`, worker AI runs there with a per-task env profile, commits, pushes the branch, stops |
| `bin/review <task>` | reviewer AI (different model) reads `diff <base>...mt/<task>`, writes `review.md` with a `VERDICT:` line, records the exact commit it reviewed |
| `bin/merge-when-green [--task <task> \| <pr>]` | reads PR checks/review via the platform CLI and enables auto-merge when green — the platform merges; never merges locally |
| `bin/loop <task> <task-file>` | all three in sequence (`--yes` enables auto-merge; otherwise check-only) |
| `bin/status` | prints `STATE.md` + liveness of each task's branch/worktree |
| `bin/pace [meters.json] [--json]` | prints per-pool pace and advised lanes from a meters file |

Everything the kit writes is local and git-ignored: `.overlord/` (config, the
filled skill copy, per-task logs) and `STATE.md`.

### Who merges: the platform

Workers never merge, and neither does this kit. Each worker pushes its branch
and opens a pull request; **the hosting platform does the merging**:

- Branch protection on the base branch requires a PR, required status checks,
  and — with "branches must be up to date" (or a merge queue) — checks that
  ran on the combined result, so the base branch only advances through a PR
  that already passed CI. No local merge, no rollback.
- One PR is **ready** at a time. When its checks and review gates are green,
  `bin/merge-when-green` enables platform auto-merge for that PR
  (`gh pr merge --auto`); the platform lands it.
- A **different model** reviews each change than the one that wrote it, and
  the approval binds to the exact commit: `bin/review` records the SHA it
  reviewed, `bin/merge-when-green --task <task>` refuses a stale or missing
  review, and the platform re-runs required checks on every new head.

Setup (which checks to require, merge queue) is in
[`docs/ci-and-gates.md`](docs/ci-and-gates.md). The coordinator — the overlord —
only plans, briefs, routes, and talks to you; merging is not its job either.

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

### Out in the world

The floor keeps running wherever you are:

<table>
  <tr>
    <td><img src="assets/life-soccer.jpg" alt="A parent on a kids' soccer sideline holds a phone showing the crowned robot overlord running a smoky robot control floor" width="100%"><br>You, on the sideline. I've got the floor.</td>
    <td><img src="assets/life-dinner.jpg" alt="A parent at family dinner holds a phone showing the crowned robot overlord running a robot control floor" width="100%"><br>You, at family dinner. Nothing needs you.</td>
  </tr>
  <tr>
    <td><img src="assets/life-restaurant.jpg" alt="A parent at a candlelit restaurant table holds a phone showing the crowned robot overlord running a robot control floor" width="100%"><br>You, on date night. The plans keep moving.</td>
    <td><img src="assets/life-bar.jpg" alt="A parent at a dim bar holds a phone showing the crowned robot overlord running a robot control floor" width="100%"><br>You, at the bar. I don't drink, I pace.</td>
  </tr>
  <tr>
    <td><img src="assets/life-beach.jpg" alt="A parent on the beach holds a phone showing the crowned robot overlord running a robot control floor" width="100%"><br>You, at the beach. The floor never takes a day off.</td>
  </tr>
</table>

## Grow it later (all optional)

The kit is deliberately the smallest thing that works. As it starts to hurt,
add pieces in this order ([HOW-WE-WORK.md §11](HOW-WE-WORK.md#11-start-small-bootstrap-checklist)):

- **Pacing dashboard** — feed real subscription meters to the bundled engine
  and let it tell the coordinator how many lanes each pool may run
  ([docs/pacing.md](docs/pacing.md); collecting them:
  [docs/collecting-usage.md](docs/collecting-usage.md)).
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

**The engine paces from numbers you supply; it collects nothing.** It reads a
JSON meters file (default: the synthetic `pacing/meters.example.json`; the
schema and how to feed it real numbers are in
[`pacing/README.md`](pacing/README.md)). It does not read your providers' live
subscription usage itself — a collector does that, and most plans have no
official usage API, so usage shows up in a CLI status command, a dashboard
page, or response headers.
[`docs/collecting-usage.md`](docs/collecting-usage.md) explains how to read
each kind honestly and what to record (percent used, reset time, time
collected — and "unknown", never a guess, when a source breaks);
[`docs/prompts/build-collectors.md`](docs/prompts/build-collectors.md) is the
instruction to hand your head overlord so it builds a collector for every plan
you pay for; [`collectors/example-collector/`](collectors/example-collector/)
is a working offline example to copy. A reading older than N heartbeats is
refused outright: the output says `stale` instead of pacing on old numbers.

Want to *see* the advice? [`examples/pacing-meter`](examples/pacing-meter/) —
open in a browser. One self-contained page (inline everything, no network)
that renders the engine's `--json` output as one meter card per plan: a used
bar, a where-you-should-be-by-now pace marker, the reset countdown, and an
on-pace / over / under label.

[`docs/pacing.md`](docs/pacing.md) explains every idea and *why* it is there,
with a worked example and an honest-collection rule (official APIs or your own
exported data only); [`pacing/`](pacing/) holds the dependency-free reference
engine and tests.

## Safety notes

- Worker agents run with **edit permissions inside one isolated worktree**,
  push their branch, and stop; lanes never merge. A different model reviews
  every change.
- **Environment variables are filtered per task**: workers get only the
  variables their task needs, via a per-task profile
  (`.overlord/profiles/<task>.env`, outside worker-writable paths), so
  credentials exported in your shell do not reach them. Worker and reviewer
  commands start from an empty env (`env -i`) plus an allowlist (`PATH`,
  `HOME`, `LANG`, `LC_*`, `TERM`, `TMPDIR`, configurable via
  `OVERLORD_ALLOW_ENV`, plus `OVERLORD_PASS_ENV`).
- **Env filtering is not a sandbox** — it only chooses which variables a
  process starts with. `HOME` is passed through, so credentials kept in
  files under it (for example `~/.config/gh`, `~/.ssh`, `~/.aws`) remain
  readable by a worker running as your user. For production secrets, run
  workers inside a
  container/VM or a separate account with no credentials, and give each task
  its own least-privilege token
  ([HOW-WE-WORK.md §1](HOW-WE-WORK.md#1-the-shape-coordinator-lanes-reviewers)).
- **Approvals bind to the exact commit.** `bin/review` records the commit SHA
  it reviewed; `bin/merge-when-green` refuses a stale or missing review, and
  branch protection re-runs required checks on every new head.
- **The platform merges.** Branch protection + required checks (optionally a
  merge queue) are the merge engine; this kit only enables auto-merge for
  the one ready, green PR.

## Development

`tests/smoke.sh` runs the whole loop with stub worker/reviewer commands — no
AI, no network; it is what CI should run. The pacing engine has its own unit
tests on Node's built-in runner:

```bash
tests/smoke.sh              # also verifies shellcheck cleanliness of the scripts
node --test pacing/         # pace engine unit tests (Node ≥ 20)
node --test tests/          # example-collector tests (smoke.sh runs these too)
```

MIT license — see [LICENSE](LICENSE).
