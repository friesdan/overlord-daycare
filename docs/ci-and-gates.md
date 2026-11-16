# CI and gates: the platform merges, the gates decide

In [HOW-WE-WORK.md](../HOW-WE-WORK.md) the pipeline ends with the hosting
platform merging a pull request. This guide is the setup that makes that safe:
a stack of automated layers, cheapest first, ending in branch protection that
only lets the base branch advance through a PR whose combined result already
passed CI. There is no local merge and no rollback to build — the platform is
the merge engine.

> **A gate you have to remember to run is not a gate.** Every layer below is a
> hook, a CI job, or a platform rule — something that cannot forget a step,
> cannot be talked out of it under pressure, and cannot play favorites. The
> human sets the gates once; the platform applies them to every PR.

This repo runs the smallest version of the stack
([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)); the templates to
copy into your own project are in [`examples/`](../examples/).

## Layer 0: fast local checks before every push

A pre-push hook runs the fast checks — lint, typecheck, unit tests — and any
failure blocks the push. Fast means seconds, not minutes; anything slower
belongs in CI, not here.

Install it as a git hook so running it is not a decision. A template ships at
[`examples/hooks/pre-push`](../examples/hooks/pre-push); copy it in:

```bash
cp examples/hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

**Why a hook and not a habit:** the moment you most want to skip checks —
"just this once, the fix is obvious" — is precisely the moment mistakes ship.
A habit bends under pressure; a script does not.

**The rule that makes the whole stack work: never skip it.** `--no-verify`
exists; using it is how "reviewed something close" starts. If a check is
genuinely too slow to wait for, move it up into CI — do not remove the gate.

## Layer 1: CI on every push

Every push runs the *same* checks again, plus the slow ones: the full test
suite, the build, anything too heavy to run before each push. The commented
template to copy is
[`examples/github-actions/ci.yml`](../examples/github-actions/ci.yml) (written
for GitHub Actions; any CI that runs on every push is the same layer).

**Why run the same checks twice:** your machine drifts — different tool
versions, cached state, files that exist locally and nowhere else. CI is the
clean room. The merge decision reads CI's answer, never the laptop's, so
re-running the fast checks there costs a few machine-minutes and buys an
environment everyone trusts.

## Layer 2: branch protection — the platform does the merging

Branch protection is the layer that replaces any hand-rolled merge script.
On the base branch, enable:

- **Require a pull request before merging** — no direct pushes to the base
  branch, ever. Every change arrives as a PR from a worker's branch.
- **Required status checks** — select the CI jobs from Layer 1. A PR cannot
  merge while any required check is pending or failing.
- **Require branches to be up to date before merging** — the PR must contain
  the current base branch, so the checks that passed ran on the *combined*
  result (your change plus everything that landed since you branched), not
  on your branch alone. This is the property a local "merge then re-test,
  roll back on failure" script tries to recreate by hand; the platform gives
  it to you directly, with no rollback because the bad combination never
  merges in the first place.
- **Require review approval from a different model than the author** (your
  reviewer lane or review bot posts the approval), and **dismiss stale
  reviews when new commits are pushed** — a new head voids old approvals.
- **Do not allow bypassing the above settings** for worker accounts.

With those on, the base branch can only advance through a PR whose combined
result already passed CI. The kit's [`bin/merge-when-green`](../bin/merge-when-green)
is the thin client for this layer: it reads check and review status through
the platform CLI (`gh pr checks`, `gh pr view`) and enables auto-merge
(`gh pr merge --auto`). It never merges locally.

```bash
# one ready PR at a time:
bin/merge-when-green 42                 # enable auto-merge when green
bin/merge-when-green --task my-task     # same, plus the kit's exact-head
                                        # review binding for that task
bin/merge-when-green 42 --check-only    # report status, change nothing
```

### Optional: a merge queue

If several PRs are often ready at once, enable the platform's **merge queue**
instead of (or as well as) "branches must be up to date". The queue merges
PRs one at a time, testing each against the base branch *plus everything
ahead of it in the queue*, and only lands the combinations that pass. It is
the same guarantee — the base branch only advances through green combined
results — without authors rebasing by hand. Keep the queue's required checks
identical to the branch's, or the guarantee has a hole.

## The exact-head rule

Every check and every review runs on the **exact commit that will merge**. Any
new push — a fix, a rebase, a catch-up merge with the base branch — makes every
previous result stale, and the full set runs again on the new head. Approvals
attach to commits, never to branches or people.

**Why:** "reviewed something close" is how unreviewed code ships. The
dangerous case is the catch-up merge: bringing your change up to date with the
base branch can silently drop another change's logic with *no textual
conflict*, so an old green review plus a fresh build is not green. Stale is
stale, even when the diff looks tiny.

Branch protection enforces most of this (required checks re-run per head;
stale reviews dismissed on push). The kit adds the same binding for its local
review record: `bin/review` records the commit SHA it reviewed, and
`bin/merge-when-green --task <task>` refuses (exit 2) unless that SHA is
exactly the PR head.

## Independent review, then severity triage

The review that gates a merge comes from a **different model family than the
one that wrote the code** — the routing table in
[HOW-WE-WORK.md §3](../HOW-WE-WORK.md#3-choosing-model-and-effort-per-task)
puts a different vendor's strong model on every review. Optionally, an AI
review bot also watches the PR as an outside backstop; it reads the change cold
*after* your own stages have cleaned it, and its findings are judged, not
obeyed.

**Why different families:** a model reviewing its own family's output tends to
share its blind spots — it was trained on the same diet and makes the same
"obvious" assumptions. Independence is the point; a stronger reviewer from the
same family is a louder echo.

**Triage:** only critical findings block the merge — anything that could move
or lose money, leak private data, corrupt records users rely on, or break a
live flow. Everything else is logged as a follow-up **with a trigger** (what it
is, where it lives, what event picks it up), never silently dropped. Reviewers
generate far more findings than matter: blocking on hygiene stalls the train,
while quietly dropping findings loses the real-but-delayed ones. This is the
critical list from
[HOW-WE-WORK.md §5](../HOW-WE-WORK.md#5-fix-versus-defer-a-short-critical-list),
applied to review output.

## Incremental review, one full pass before merge

A long-lived change accumulates review rounds. After the early rounds, review
**only what changed since the last full review** — but keep exactly one full
review of the whole change, on the final head, before it merges.

**Why:** review attention is the scarcest resource in the pipeline (see
[Pacing](#rationing-reviews-with-the-pacing-meter) below). Re-reading unchanged
code every round spends it on already-answered questions. But skipping the
final full pass misses the bugs that come from *interactions between rounds* —
round five's fix quietly undoing round two's fix. Delta rounds keep review
cheap; the one full pass is the net that justifies them.

## One ready change at a time

Exactly one change occupies the **ready** lane — the one whose CI and reviews
are being spent on now, with auto-merge enabled. The platform merges it the
moment everything is green (checks passed, review clean, exact head
confirmed), then the next clean change moves into the lane. The lane is never
held empty waiting for a favorite.

**Why:** serialized merges make every failure attributable to exactly one
change, and they keep CI and reviewers from being spread thin across many
half-checked changes. `bin/merge-when-green` takes exactly one PR per call for
this reason.

## The spiral breaker

Roughly three-to-five consecutive review rounds producing the same *class* of
finding means stop patching sites: fix the underlying design once (one shared
rule, helper, or test) or cut the scope.

**Why:** by that point the repeated finding is a symptom, not a bug — the
design invites it, and each patch round adds a new place for the next instance
to hide. Patch rounds are also how a small change quietly becomes a large,
risky one. The breaker forces the design question while the change is still
small. (This is the spiral rule from
[HOW-WE-WORK.md §4](../HOW-WE-WORK.md#4-the-pipeline-draft-to-merge-in-stages),
stated here as a gate: the counter is part of the review round.)

## Rationing reviews with the pacing meter

Reviews are the expensive layer of the stack: strong models, a different family
per builder, read-only access — and they gate *every* merge. So reviews are
rationed like any other spend: the pacing dashboard
([docs/pacing.md](pacing.md)) decides how many review lanes may run, and a
named slice of the reviewer pool is reserved for reviews so ordinary lanes
cannot burn it.

**Why:** if worker lanes eat the reviewer pool on Tuesday, the train stops on
Wednesday — the next ready change sits fully checked with nobody left to review
it. Reviews gate every merge, so review capacity is infrastructure, not spare
compute; holding a named reserve for it is the pacing guide's reserve idea
doing exactly its job.

## In this repo

| Piece | What it is |
| --- | --- |
| [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | This kit's own CI: the smoke test plus the pacing engine's unit tests, on every push and pull request. |
| [`examples/github-actions/ci.yml`](../examples/github-actions/ci.yml) | The commented template to copy into your own project — same layer structure. |
| [`examples/hooks/pre-push`](../examples/hooks/pre-push) | The pre-push hook template to copy into `.git/hooks/`. |
| [`bin/merge-when-green`](../bin/merge-when-green) | Thin example: enable platform auto-merge for one green PR. Setup is the branch protection above. |

Grow the stack in the order above, and only when a layer's absence has actually
hurt ([HOW-WE-WORK.md §11](../HOW-WE-WORK.md#11-start-small-bootstrap-checklist)):
hook first, CI second, branch protection third, the ready lane and merge queue
once there is more than one change moving. The method is the layering — cheap
deterministic gates first, expensive human-or-model judgment last, and nothing
merges on stale results.
