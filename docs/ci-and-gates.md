# CI and gates: the layers that let the coordinator merge

In [HOW-WE-WORK.md](../HOW-WE-WORK.md) the pipeline says the coordinator may
merge on its own "once you trust those gates." This guide is what those gates
are: a stack of automated layers, cheapest first, each one catching what it
catches for a fraction of the cost of the layer above it. Layered gates are the
whole reason a coordinator can be allowed to merge without a human watching —
not because the coordinator is trusted, but because the gates are.

> **A gate you have to remember to run is not a gate.** Every layer below is a
> hook, a script, or a bot — something that cannot forget a step, cannot be
> talked out of it under pressure, and cannot play favorites. The human sets
> the gates; the machinery applies them; the coordinator merges only on green.

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
A habit bends under pressure; a script does not. It is the same reason the
method gives lanes a scripted push ([HOW-WE-WORK.md §4](../HOW-WE-WORK.md#4-the-pipeline-draft-to-merge-in-stages)):
a script cannot forget.

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

**Optional, for heavy suites:** a self-hosted runner on a spare machine runs
the slow jobs without spending hosted CI minutes. Give the heavy jobs their own
runner lane (a label they select with `runs-on`) so a long build never blocks
the quick checks — the quick lane is the one the coordinator waits on, and a
fast red answer is worth more than a slow green one.

## The exact-head rule

Every check and every review runs on the **exact commit that will merge**. Any
new push — a fix, a rebase, a catch-up merge with the main branch — makes every
previous result stale, and the full set runs again on the new head. Approvals
attach to commits, never to branches or people.

**Why:** "reviewed something close" is how unreviewed code ships. The
dangerous case is the catch-up merge: bringing your change up to date with the
main branch can silently drop another change's logic with *no textual
conflict*, so an old green review plus a fresh build is not green. Stale is
stale, even when the diff looks tiny.

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

## One ready change at a time, merged by a script

Exactly one change occupies the **ready** lane — the one whose CI and reviews
are being spent on now. A small merge script merges it the moment everything is
green (checks passed, review verdict clean, exact head confirmed), then the
next clean change moves into the lane. The lane is never held empty waiting for
a favorite.

**Why:** serialized merges make every failure attributable to exactly one
change, and they keep CI and reviewers from being spread thin across many
half-checked changes. The merging is done by a script for the same reason as
every other layer: a script cannot forget a step of the checklist, cannot be
persuaded to merge "just this once," and cannot play favorites about what
merges next. The starter kit's merge gate — tests re-run plus a CLEAN
independent verdict — is the smallest version of that script.

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

Grow the stack in the order above, and only when a layer's absence has actually
hurt ([HOW-WE-WORK.md §11](../HOW-WE-WORK.md#11-start-small-bootstrap-checklist)):
hook first, CI second, exact-head review third, the ready lane and merge script
once there is more than one change moving. The method is the layering — cheap
deterministic gates first, expensive human-or-model judgment last, and nothing
merges on stale results.
