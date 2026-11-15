# Prompt: build my usage collectors

Hand this to your **head overlord** (the coordinator agent) once, after the
kit is initialized. It turns "make pacing work from live usage" into a bounded
task the coordinator can do without you typing any numbers. The background it
needs is [`docs/collecting-usage.md`](../collecting-usage.md); the engine's
input format is [`pacing/README.md`](../../pacing/README.md).

Copy everything in the block and edit the first list to name your actual
plans.

---

```text
Build live usage collection for pacing. For each plan I pay for:

  - an AI coding subscription: <name it, e.g. "the weekly coding plan">
  - a chat plan with a coding CLI: <name it> (its CLI allowance is a
    separate pool from the chat app)
  - a flat monthly plan: <name it>

do this:

1. FIND where its usage is shown. It is one of four sources — a status
   command in the plan's own CLI, the provider's dashboard page, response
   headers on traffic we already make, or a documented usage endpoint. Read
   docs/collecting-usage.md for how to read each kind. Verify the exact
   command, flags, fields or header names against the provider's own public
   docs or our own captured traffic before you rely on them; if you cannot
   verify a read-only way to read usage, that pool stays unknown — say so
   and stop, do not improvise one.

2. WRITE a small read-only collector under collectors/<pool-name>/ modeled
   on collectors/example-collector/ (Node, no dependencies). It reads its
   source and upserts exactly one pool entry into the meters file
   (.overlord/meters.json): usedPercent, windowStart/windowEnd, collectedAt
   and a short note. It writes meter: null with the failure reason in note
   when the source breaks, and exits non-zero. It does not write policy
   fields (burnPerLaneHour, reserves, maxLanes, mode) — those are mine.

3. ADD it to the heartbeat: every beat, run each collector, then
   bin/pace --json, and read the lane advice. Record in the heartbeat
   checklist which collectors exist and how a failure is surfaced to me.

4. TEST it: a checked-in fixture per collector (a snippet of real status
   output with anything account-specific removed), a test in tests/ that
   runs the collector against the fixture with NO network, and the test
   wired into tests/smoke.sh. Also test the failure path: a fixture the
   collector cannot parse must produce meter: null, not a guess.

Guardrails — these are hard rules, not preferences:

  - Read-only. Collectors run a status query and write the meters file.
    Nothing else. Never mutate account state, never spend quota to measure
    it, never send anything to the provider beyond the status query.
  - No credentials in the repo. Ever. Use the provider's own logged-in CLI
    (it holds its own session) or an environment variable I set. Never copy
    a token, cookie or session into the repo, a collector, a log line, or a
    worker shell.
  - Official surfaces only: documented commands and endpoints, the page's
    own export, or a file I paste numbers into. No scraping provider pages,
    no reusing another tool's login tokens, no undocumented endpoints found
    in a network tab.
  - Stale or unknown beats a guess, every time. If a number is not
    actually read, it is meter: null. No estimated, remembered, or
    last-known-good percentages, ever.
  - Real meters stay out of the repo (.overlord/ is git-ignored); fixtures
    in the repo are synthetic or scrubbed of anything account-specific.

Report back: one line per plan — where its usage lives, what you built, the
test that covers it — plus any pool you could NOT read honestly and why.
```

---

## Definition of done

- [ ] One collector directory per plan under `collectors/`, each with a
      fixture and a no-network test wired into `tests/smoke.sh`.
- [ ] `bin/pace --json` runs off the collected meters file, and every pool
      shows a fresh `collectedAt` after a heartbeat.
- [ ] Breaking a fixture (edit it to garbage) makes that pool read
      `meter: null`, and the heartbeat notices the non-zero exit.
- [ ] Letting a pool's reading go stale (skip its collector for N beats)
      makes `bin/pace` report band `stale` with 0 lanes for it.
- [ ] `git grep` finds no token, cookie, account email or account id in the
      repo — fixtures included.
- [ ] A pool you cannot read honestly is *documented* as unknown, with the
      reason, not silently omitted from the meters file.
