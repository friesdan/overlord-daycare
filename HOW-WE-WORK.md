# How We Work: One Coordinator, Many Lanes

*A method for running software work with AI coding agents, written so another AI agent can copy the way of working. It teaches the method only — no project specifics. The companion `coordinator-skill/SKILL.md` in this package turns the same method into an installable operating manual.*

**Audience:** an AI coding agent with access to several models and subscription plans, working for a human owner who checks in briefly, often from a phone. The core idea: **one long-running coordinator talks to the human and decides; short-lived worker lanes do all the editing; independent models review.**

## 1. The shape: coordinator, lanes, reviewers

- **Coordinator:** one persistent agent session. It reads reports, writes briefs, launches work, runs the merge pipeline, and talks to the owner. It does not write feature code.
- **Lanes:** headless agent sessions, each in its own isolated checkout. One bounded job each: edit, test locally, commit, stop. Lanes never merge, never mark work ready, never talk to the owner.
- **Reviewers:** models from a different family than the builder, reading the exact commit that will ship.

Why: a coordinator that stops to code stops coordinating — while it is heads-down, everything else stalls silently. Isolation (separate checkouts, one writer each) removes a whole class of collisions. Independent review catches blind spots, because a model reviewing its own output tends to agree with itself.

The one exception: the coordinator may make a one-to-three-line mechanical unblocker itself (a missing generated line, taking one side verbatim in a conflict). Anything larger, including long investigations, is lane work with a diagnosis brief.

## 2. Compute: a usage dashboard decides how many lanes run

- A small local service polls every subscription and plan and publishes one machine-readable answer per pool: how many lanes may run right now, and why.
- A "pool" is an execution route, not a model name. The same model reached through two products draws on two allowances, so they are metered separately, never merged.
- Every heartbeat, the coordinator reads the advice, counts its live lanes per pool, and fills each pool to the advised number. It keeps no private routing notes.
- Only the owner changes dashboard policy (thresholds, reserves, burn toggles, quota resets). If advice looks wrong, the coordinator proposes a fix and keeps following current advice meanwhile.

Why: allowances reset on a clock. Too slow wastes allowance at reset; too fast runs dry days early. The goal is an even pace. Pacing arithmetic is easy to get subtly wrong, so it lives in one calibrated place instead of being re-derived from memory. If a provider cannot be read, the dashboard says "unknown" and advises no new lanes — a false "plenty left" is the most expensive lie here, because an automated coordinator acts on it immediately.

Two supporting habits: periodically compare assumed cost per lane-hour with observed burn from real runs and log the gap (measuring turns a guess into a number); and keep a durable ledger of what each reset left unused, so plan decisions become evidence-based.

## 3. Choosing model and effort per task

Pick the cheapest model that is adequate, and set effort explicitly on every launch:

| Task | Route |
| --- | --- |
| Narrow fix, exact location named | Cheap fast model, high effort — name every path |
| Standard implementation, directed fix | Mid-tier coding model, default effort |
| Open-ended diagnosis, design-level fix | Mid-tier model, maximum effort |
| Plan or design of anything new | Strongest model writes; different vendor's strongest reviews |
| Review of a finished change | Different family's strong model, read-only |
| Money, privacy, security, irreversible actions | Always a strong model, never the cheap tier |

Why: cheap models are good at narrow, fully specified fixes and weak at open-ended diagnosis — routing by task shape is where the savings live. Effort is part of the route: start at the vendor's recommended level and raise it only where you have measured a gain. Design is the worst place to save money, since a weak plan that reaches implementation wastes far more than strong planning costs; cheap models implement against strong designs but never author them. Critical work gets a *different* reviewer, not just a stronger one, because same-family review shares assumptions.

Keep a simple outcome ledger (task type, model, effort, accepted or not), review it monthly, and update the table. Measure, don't guess; treat public benchmarks as a starting hint, since they rarely match your task shapes.

## 4. The pipeline: draft to merge in stages

1. **Draft work.** Lanes implement in drafts with a local loop: cheapest deterministic checks first (patterns reviewers usually flag), then model review, fix, re-review.
2. **Scripted push.** One push script runs tests, type checks, and build, then pushes — one pipeline per checkout, lock-serialized. Why: hand-pushes skip checks under pressure; a script cannot forget.
3. **Exact-head review.** On the precise commit that would merge, run the full set again. Approvals never carry across a new commit or a merge with the main branch. Why: "reviewed something close" is how unreviewed code ships — a catch-up merge can silently drop another change's logic with no textual conflict.
4. **Fix-versus-defer triage.** Judge every finding by real harm (next section), not the reviewer's label.
5. **One ready change at a time.** Exactly one change occupies the merge lane; the lane is never held empty for a favorite — priority orders changes that are already clean. Why: serialized merges make every failure attributable to one change.
6. **External review as backstop.** An outside bot reads the ready change cold. A perfect score merges; anything less is judged — fix, merge with the finding logged, or hold only that change. Why: the backstop proves you already did it right; if it keeps finding real problems, fix your earlier stages at the design level instead of paying for repeated external reviews.
7. **Merge, then ship.** Merge on green checks with threads answered. Apply migrations, verify new schema is actually usable by the application (fresh tables often need explicit access grants), and deploy, grouping changes that landed together.

**Spiral rule:** the same class of finding in roughly three consecutive rounds means stop patching sites — fix the underlying design once (one shared rule, helper, or test) or cut that scope. After a handful of total rounds on one change, decide explicitly: finish, split, or defer the rest, and tell the owner in one line.

## 5. Fix versus defer: a short critical list

The question is never "how severe did the reviewer call it?" but "what actually breaks, for whom?"

- **Always fix:** anything that could move or lose money wrongly, corrupt records users rely on, leak private data, break authentication, or break a live flow — plus anything a user would see. Visible broken behavior is always fixed, whatever the score.
- **Defer the rest:** unreachable backend edge cases, hygiene, findings in untouched code. Deferring means reply, resolve, and one durable line: what it is, where it lives, what event triggers picking it up. A deferral without a trigger is a deletion with extra steps.
- **Never defer because a feature ships switched off.** Code must be correct as if the switch were on; what a switch actually gates has repeatedly turned out narrower than believed.

Reviewers generate far more findings than matter. Judging by consequence keeps the queue moving without lowering the bar where harm is real.

## 6. The heartbeat and watchers

- A scheduler wakes the coordinator about every thirty minutes. The scheduled prompt holds no instructions — one line pointing at a single checklist file, which is the only place heartbeat behavior lives. Why: a pointer, not a copy, gives one source of truth; duplicated instructions drift apart within weeks.
- Each heartbeat: read the dashboard and rebalance lanes; survey every open change and running lane; act on stalls; refill the merge lane; check watchers; update the handoff and board if anything changed; otherwise log one line and stop. If nothing has merged by midday, that is a blocker to fix, not a status to report.

**Watchers** report events between heartbeats:

- A watcher is a background command that **exits** the moment its condition changes — only an exiting command wakes the agent. A process that polls forever wakes nobody.
- Watchers exit on **any** change, not the hoped-for outcome. One waiting for "review clean" silently misses the review that returned findings. Fingerprint everything (new or edited bot comments, new threads, check changes, a moved head, a lane exiting), exit on any of it, then read and decide.
- Key on what actually changes: some bots edit their summary comment in place, so watch that comment's identity and edit time rather than waiting for a new one. Cap each watcher at a couple of hours, one per change.

**Never wait in the foreground.** The coordinator never sleeps or polls in its main turn; waiting belongs in scripts. Foreground waiting burns the coordinator's scarcest resource — its own context — for nothing a script could not do.

## 7. Surviving long sessions: compaction and the handoff

A session runs for days; its context window does not. Four pieces make that survivable:

- **Auto-compaction tuned early** — trigger summarization at roughly half the window, at a quiet moment rather than mid-crisis. Defer only while the owner is actively mid-conversation, with a hard ceiling regardless.
- **Pre-compaction hook** — before summarizing, snapshot mechanical state from sources of truth (open changes with next steps, live lanes and what they wait for, watchers, queue tails) into dated files, and instruct the summarizer to preserve verbatim every open item, pending decision, and binding ruling.
- **Post-compaction hook** — after compaction, inject fixed resume steps: re-read the operating manual and values file in full, read the handoff and latest snapshot, verify schedule and watchers, then continue. The agent need not remember its own survival procedure at the moment it has forgotten the most — that is the point.
- **Handoff file kept current every heartbeat** — one file of live state, rewritten when anything changes (never only appended), short enough to actually re-read.

Summarization is lossy and the losses are random; the snapshot and handoff keep load-bearing facts outside the conversation, in files that survive any summary.

## 8. Talking to the owner: a phone-first board

- One board, glanceable at the top: what merges next, what follows, a short "needs you" list. No paragraphs above the fold.
- One row per open change: what it does in plain words, **where it came from** (owner request, program step, review finding — or honestly "unclear, best evidence: …"), its owner, one status chip with its reason, its next step with a rough date, and a collapsed short history. Never guess an origin.
- Multi-change efforts get progress bars from a small structured file per program (plain-language steps: done, in progress, to do), updated on every milestone.
- A **Decisions tab** holds only real owner decisions — visible behavior, wording, product scope, money policy, opening or closing work. Each card gives the question, options, a recommended default, and what happens if they do nothing. The owner answers asynchronously; the coordinator checks every heartbeat and acts. Technical choices never become cards — that discipline keeps the count low enough to still be read.
- A validator runs before every publish and fails it on any disagreement (a listed change that no longer exists, a merged step still marked live, a "needs you" with no card, mismatched counts). A stale board is a bug.

Why: the owner's scarcest resource is attention in short windows — outcome first, plain language, one item at a time. Provenance answers "why does this exist?" before it must be asked.

**Never stall waiting for the owner.** No answer within about half an hour means: pick the option the owner would most likely pick, proceed, and say so in one plain sentence. If exactly one change needs a truly owner-only call, that change alone returns to draft while the rest keeps moving. Routine events (a lane still running, a watcher re-armed) are logged, not messaged.

## 9. Decision values: write down how to judge

A one-page values file, consulted before any judgment call, makes the coordinator's calls consistent and auditable:

- **Who decides what:** the owner decides anything visible (behavior, wording, scope, money policy, opening or closing work); the agent decides everything technical (architecture, fix-versus-defer, scope cuts, routing). No "should I…?" for technical calls — decide, act, report in one line.
- **Proportionate safety:** match rigor to real harm for a small operation, not enterprise checklists; a finding must name who gets hurt and how before it blocks anything.
- **A few defaults:** reducing people's mental load beats adding features; completing the core transaction easily beats guarding unlikely edges; prefer the industry-standard pattern and say why when deviating.
- **Tie-breakers, in order:** Would a user see this, or does it touch the critical list? Which option removes the most load and friction? Which keeps work moving without scope creep? Is there a standard way?

Values in conversation vanish at compaction and differ between sessions. Written down, they survive restarts, can be corrected in one edit, and let the owner audit *why* a call was made. Owner corrections go into the file the same day.

## 10. Hard-won lessons, generalized

- **Lanes must never inherit production credentials.** Shell profiles often export live keys that every lane inherits; one unmocked test run can then hit the production database. Strip production credentials in every launcher and pipeline; production access only via an explicit read-only path. Never trace-debug a credential-loading script — traces echo secrets into logs.
- **Never edit a script while a pipeline runs it.** Shells read scripts incrementally; an in-place edit can kill the run. Write the new version to a temporary file and move it into place, then check what was running.
- **Verify before alarming — and before fixing.** A plausible failure report is a hypothesis. Confirm against actual content, existing check results, and ideally a second model first. New safety tooling warns rather than blocks until proven on real cases.
- **A watcher being armed proves nothing.** Watchers die silently (compute exhaustion, restarts, mis-specified conditions). Verify the world directly every heartbeat; the watcher is an optimization, not the record.
- **One writer per thing; check identities.** One lane, push pipeline, and watcher per checkout or change. Saved process IDs get reused — read the actual command line before trusting or stopping anything.
- **Lanes never wait.** A headless lane ending its turn "waiting for a notification" is finished with work undone. Briefs must require foreground, bounded waits and an exact error report within minutes if blocked. Long commands run detached to a log, polled in short chunks, because an auto-backgrounded command ends a headless session.
- **Briefs name the harm, not the sweep.** "Fix this everywhere" produces sprawling changes. Name what breaks, for whom, and scope to that. Approvals attach to exact commits: after any merge with the main branch touching the same files or functions — even without textual conflict — review starts over.
- **Read paginated results fully; defer durably.** Threads, comments, and file lists truncate at page one, and first-page counts have hidden live critical findings. Every deferral lives in shared storage other agents read at session start, never only in one agent's private memory.

## 11. Start small: bootstrap checklist

Build in this order, growing each piece only when its absence has actually hurt:

1. **Values file** — one page: who decides what, your critical list, three or four defaults.
2. **Coordinator manual** — role, delegate-don't-code rule, pipeline stages. The companion skill in this package is a ready starting point; adapt its placeholders.
3. **One lane launcher plus finisher** — headless agent in an isolated checkout, credentials stripped, effort explicit, brief file as input; the finisher commits, pushes, and reports so no lane needs babysitting.
4. **Push script and exact-head checks script** — tests and build in the push; full review on the exact commit. These two are the pipeline's spine.
5. **Handoff file and heartbeat** — one live-state file, plus a thirty-minute scheduled prompt that only points at a checklist. Update the handoff every heartbeat from day one.
6. **Two compaction hooks** — pre-compaction snapshot, post-compaction re-injection. Cheap, and they pay off at the first survived summary.
7. **Status board** — start with one row per open change (origin, next step); add program progress files at the first multi-change effort and the Decisions tab when chat questions deserve a permanent home.
8. **Usage dashboard** — last, because it needs lane history to calibrate. Start with a simple pace readout per pool; add lane advice once a lane-hour's cost is measured. Until then, cap concurrency by hand and keep numbers honest.

The method is the shape — coordinator, lanes, independent review, written values, a heartbeat, and a handoff — not any particular script.

---

*Companion: `coordinator-skill/SKILL.md` is the same method as an installable operating manual. Hand both files to your agent and keep the manual open while adapting the pieces above.*
