# Pacing: spending every AI subscription evenly

<img src="../assets/the-floor.jpg" alt="The operations floor, where the coordinator watches pacing across every AI subscription" width="720">

You pay for several AI subscriptions, each with its own limits and its own
reset clock. Pacing is the secret sauce: a small dashboard tells the
coordinator how many agents each subscription can run right now, so every
plan is spent evenly — nothing sits unused at reset, nothing runs dry early.

This guide explains how to build one, and *why* each piece is shaped the way it
is. It ships with a tiny reference engine ([`pacing/pace.mjs`](../pacing/pace.mjs),
run as `bin/pace`) that implements everything described here over a plain JSON
file — a teaching artifact and a starting point, not a product. All numbers in
this guide and in the repo are synthetic.

**Honest scope: the engine paces from numbers you supply; it collects
nothing.** `bin/pace` reads a meters file — `bin/pace my-meters.json`, schema
and worked examples in [`pacing/README.md`](../pacing/README.md), synthetic
sample in [`pacing/meters.example.json`](../pacing/meters.example.json) — and
turns those numbers into lane advice. It does **not** read your providers'
live subscription usage: no API calls, no logins, no scraping. Collecting the
real numbers is yours to plug in (official usage APIs or files you export
yourself — see [Collecting meters honestly](#collecting-meters-honestly)
below), refreshed into the meters file as often as your heartbeat needs. This
kit deliberately ships no collector.

## The problem pacing solves

Subscription allowances reset on a clock — every 5 hours, daily, weekly,
monthly, depending on the plan. Two quiet failure modes come with that clock:

- **Too slow** → the window resets while allowance is still left. That allowance
  was paid for and expires unused. Do this every week and a plan is costing
  real money for imaginary compute.
- **Too fast** → the pool runs dry days (or hours) before reset. Work stalls,
  or gets re-routed to a more expensive pool in a hurry.

A human eyeballing "42% left" once a day cannot hit an even burn across five
pools on four different clocks. A coordinator agent *can* — if it gets one
honest, machine-readable answer per pool, every heartbeat, instead of
re-deriving pace arithmetic from memory (which is exactly the arithmetic
humans get wrong, and agents get wrong differently).

## The dashboard card

One card per pool, glanceable, with the verdict up front:

```
┌─ worker-weekly ────────────────────────── behind · pace 0.56 ─┐
│ weekly window · resets in 48 h (Mon 12:00 UTC)                │
│                                                               │
│ used    ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░  40%                         │
│ clock   ░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓  71% elapsed  ← even target  │
│                                                               │
│ lanes: run 2 now   (cap 4 · 4%/lane-hour, measured)           │
│ why: 6.5%/h to spend = 1.3 keep-pace + 5.2 catch-up           │
│      (31 points behind, closed over 6 h) ÷ 4%/lane-h → 2      │
└───────────────────────────────────────────────────────────────┘
```

The one-line summary strip the coordinator actually reads:

```
worker-weekly 2 · review-weekly 3 · sandbox-monthly 1 · nightly-5h 0 (hot) · scout-daily 0 (unknown) · demo-credits 0 (paused)   host 6/6
```

Everything below is why the card says what it says.

## The ideas

### 1. Pools are routes, not model names

A pool is an *execution route* — one metered allowance — and the same model
reached through two different products draws on **two different allowances**.
Model X through a CLI on plan A and model X inside an IDE on plan B are two
pools with two meters, even though "which model?" has one answer.

**Why:** if you merge the meters, every decision downstream is wrong in
opposite directions at once — you'll route work to the "healthy" merged pool
and discover it was the empty half. Meter what actually limits you (the
route), not what the marketing names (the model).

### 2. Every pool has a meter: used % plus a window

Each pool's meter is two facts: **used %** of the allowance and the **window**
it resets on — a start and an end time (or equivalently a reset time plus the
window length). Both are needed. "40% used" alone is uninterpretable; "40%
used, 71% of the window elapsed" is a decision.

**Why the window matters more than the percentage:** 40% used at the start of
a month is a problem; 40% used with 3% of the window left is a surplus you
should be spending *right now*. Raw headroom cannot tell those apart; headroom
against the clock can.

### 3. Pace ratio = used % ÷ elapsed % — the target is an even burn

```
paceRatio = usedPercent / elapsedPercent-of-window
```

- **1.0** — on pace: the pool is burning exactly with the clock and will land
  at reset neither rich nor dry. This is the target.
- **< 1** — behind the burn (under-spent): there is surplus to spend, and
  probably a gap to close (idea 4).
- **> 1** — ahead of the burn (over-spent): the pool is running hotter than
  the clock; new work belongs elsewhere until the window catches up.

**Why a ratio and not a threshold on "left %"**: the same "18% left" is
comfortable on day 6 of 7 and an emergency on day 1 of 7. Dividing by elapsed
puts every pool, on every window length, on one comparable scale where 1.0
always means "evenly". One caution that comes with the ratio: early in a
window (roughly the first 2% elapsed), one lane's spend swings the ratio so
hard it is pure noise — don't judge pace there, and never *suppress* lanes
because of an early spike (the reference engine reports "early" and sizes from
budget alone).

### 4. Lane advice: how many lanes may run *now*

The number the coordinator actually wants: **lanes this pool may run right
now**, computed as

```
keepPace = spendable% ÷ hoursLeft            (%/hour that empties on time)
catchUp  = max(0, elapsed% − used%) ÷ H      (H = a few hours, not the window)

lanes    = ceil((keepPace + catchUp) ÷ burnPerLaneHour)
           → at least 1 when the pool may spend
           → capped by the pool's max lanes and by host capacity
```

where `spendable%` is what's left minus any reserve (idea 7), and
`burnPerLaneHour` is the measured cost of one lane for one hour, in points of
this window (idea 9).

**Why two terms, from real failures of each alone:**

- *Keep-pace alone* spreads the remaining budget across the whole remaining
  window. It guarantees the budget empties exactly at reset — but a pool that
  fell behind stays behind until the final hours, because its catch-up is
  smeared over days. "Eventually even, by reset" is not what you wanted; you
  wanted back on pace this afternoon.
- *Catch-up alone* looks at today's gap only. Once the gap closes, advice
  drops to one lane even if most of the budget is unspent with little time
  left to spend it — the pool stalls while its allowance evaporates.

Summing both fixes both: the pool spends its remainder evenly **and** closes
today's gap soon. `H` is clamped to a few hours (the reference uses 2–6) so
"soon" means this-afternoon, and so the last hour before reset can't demand an
absurd burn rate.

**Why `ceil` and the floor of 1:** half a lane cannot run; rounding *down*
systematically under-spends every pool a hair, every window, forever. The cap
(pool max, host capacity) is the honest brake on the other side — and if the
sum across pools exceeds what the host can run, that is a *note* to the
coordinator ("pick which pools fill the host, reserved purposes first"), not
silent shrinkage of every pool.

### 5. Unknown is never plenty

If a meter can't be read — collector failed, field missing, response
malformed, reading stale past the window end — the advice is **0 lanes**, with
the reason saying why. Never `0% used`. Never "available".

**Why:** this dashboard's consumer is an automated coordinator that acts on
the answer *immediately*. A false "plenty left" is the single most expensive
lie in the system: lanes launch, hit the wall mid-task, and burn the
coordinator's attention cleaning up. A false "empty" costs a little unspent
capacity for one heartbeat until the next read. Fail in the cheap direction.

### 6. Confirmed exhaustion vs a flaky read

"Meter reads 0% left" is an *inference* from a rounded, possibly stale number.
"An agent hit a real rate-limit response" is a *fact*, and it wins even when
the meter still shows a sliver left. Keep them separate:

- **Confirmed exhaustion** — a real rate-limit was observed (by a lane, or by
  the owner trying it). Record it with the window it belongs to. It clears
  only when that window resets or the owner clears it — deliberately
  asymmetric, because one lucky success after a hard rate-limit proves nothing
  (retries, backoff and partial recovery are all real).
- **A flaky read** — 0% shown but nothing confirmed. Still 0 lanes (fail
  closed), but the reason says *unconfirmed* so the owner re-reads instead of
  believing a rounding artifact.

**Why:** conflating them makes "the pool is empty" indistinguishable from
"monitoring failed", and makes resets impossible to reason about (a confirmed
record must expire exactly with its window, or it poisons the pool forever).

### 7. Reserves: hold part of a pool for a named purpose

A reserve is a slice of a pool — in points of the window — held back for a
purpose you name: *reviews*, *the coordinator's own turns*, *the nightly
migration*. `spendable% = (100 − used) − reserve%`. If the reserve can't be
covered, lanes get 0 until it can, and the reason names the purpose.

**Why:** some spend is infrastructure, not capacity. If reviews gate every
merge, burning the reviewer pool on ordinary lanes doesn't "use the plan
fully" — it quietly stops the train on Thursday. A reserve makes that trade
explicit and *named* (anyone reading the advice can see what the slice is
for), instead of an implicit "we got rate-limited at the worst moment".

### 8. Owner-only toggles and manual resets

The dashboard separates *data* from *policy*. Policy — **burn harder**,
**pause**, and **manual reset declarations** — belongs to the owner alone; the
coordinator may propose a change and must keep following current advice
meanwhile.

- **burn harder**: release the reserve and ignore the over-pace gate for this
  pool — "spend it down before it resets" (a window ending rich is waste, and
  the owner has decided to stop caring about even burn here). It never makes
  an exhausted, paused, or unknown pool available.
- **pause**: 0 lanes, full stop — for evaluating a plan, or distrust of its
  meter.
- **manual reset**: the owner declares a reset happened (a redeemed bonus
  reset, a plan change). Record it in the ledger with its kind; re-read the
  meter rather than assuming a number.

**Why owner-only:** these controls move money and starve purposes; an agent
flipping them in response to the very scarcity they manage is a feedback loop.
Auto-tuning *calibration* (idea 9) is fine for the coordinator; anything that
changes what a pool is *for* is not.

### 9. Calibration: assumed vs observed burn per lane-hour

`burnPerLaneHour` — how many points of the window one lane burns in an hour —
is the one number you must *measure*, because it converts budget into lanes:

```
observed = Δused% ÷ (lanes running × hours)      over intervals you know lanes ran
```

Start with a conservative assumption per pool, label it `assumed`, and replace
it with `measured` once real runs exist. Log the gap (assumed vs observed)
with a timestamp whenever you recompute it.

**Why log the gap:** the assumption silently scales every lane count the
dashboard has ever given you. A 2× error halves or doubles the whole fleet's
throughput and you'd never notice from inside — "advice" would just always
seem slightly wrong. The gap log turns "seems wrong" into a number with a
date, and tells you which pools still run on guesses.

### 10. The reset-waste ledger: what each reset left unused

One append-only row per pool per window end, forever:

```json
{"pool":"worker-weekly","windowEnd":"2026-11-16T12:00:00Z","kind":"scheduled",
 "usedAtLastReading":97.9,"leftOverPercent":2.1,"laneHoursObserved":38.5,
 "stalenessMinutes":4}
{"pool":"sandbox-monthly","windowEnd":"2026-12-01T00:00:00Z","kind":"scheduled",
 "usedAtLastReading":41.0,"leftOverPercent":59.0,"laneHoursObserved":11.0,
 "stalenessMinutes":51}
```

Record the pool, window end, reset kind (scheduled / manual / bonus), used %
at the last reading before the reset, the left-over %, how stale that reading
was, and lane-hours if you have them. Prices, if you want them, are the
owner's own plan costs applied at read time — never published ones.

**Why:** "this plan expired 59% unused for three months running" is the
strongest possible argument for downgrading it — and the strongest argument
*against* downgrading is the same ledger showing the waste was one weird
month. Without the ledger, plan decisions are vibes with a receipt problem.
The staleness column keeps the ledger honest about its own evidence.

## A worked example (synthetic numbers)

From [`pacing/meters.example.json`](../pacing/meters.example.json), at
2026-11-14T12:00Z, host capacity 6 lanes:

**worker-weekly** — weekly window Mon 12:00 → next Mon 12:00 (168 h), 120 h
elapsed = **71.4%**. Used **40%** → pace **0.56**, behind. Remaining 60,
no reserve.

- keep-pace: 60% ÷ 48 h left = **1.25 %/h**
- catch-up: 71.4 − 40 = 31.4 points behind ÷ 6 h = **5.24 %/h**
- lanes: ceil(6.49 ÷ 4%/lane-h) = ceil(1.62) = **2 lanes** (cap 4)

**review-weekly** — same window, same 40% used, but 25 points reserved for
*code reviews*: spendable = 60 − 25 = 35.

- keep-pace: 35 ÷ 48 = 0.73 %/h; catch-up 5.24 %/h → 5.97 %/h
- lanes: ceil(5.97 ÷ 2%/lane-h) = ceil(2.99) = 3 → capped at pool max **3 lanes**
- the pool is just as behind as worker-weekly, but 25 points of it are not the
  lanes' to spend — same pace, smaller allowance, honest advice.

**nightly-5h** — 5-hour window, 2 h elapsed (40%), used 55% → pace **1.38**,
over-spent. Budget arithmetic is irrelevant: **0 new lanes** until the clock
catches up. (With ~45% still left, this is exactly the pool a naive
"headroom" read would happily hand to the coordinator.)

**scout-daily** — meter not wired up yet. **0 lanes**, reason "unknown is
never plenty". Not "0% used", not 2 lanes of optimism.

**sandbox-monthly** — 45% elapsed, 44% used → pace 0.98, even. 56% over 396 h
= 0.14 %/h, gap 1 point → 0.17 %/h catch-up; ceil(0.31 ÷ 1) = **1 lane**.

**demo-credits** — owner paused it. **0 lanes**, no arithmetic consulted.

Total advised: 2 + 3 + 1 = **6 of 6 host lanes**. Had it been 8 of 6, the
engine's note would say so and the coordinator — not the arithmetic — would
choose which pools fill the host.

## Collecting meters honestly

The engine in this repo takes numbers; it never fetches them. When you wire up
real collection, one rule:

> **Collect meters only through official APIs or your own exported data.**
> Scraping a provider's pages, or reusing login tokens meant for another tool,
> may break the provider's terms of service — and the brittle, session-shaped
> integrations it produces tend to leak those tokens into logs.

Concretely: prefer a documented usage endpoint with your own key, or a file
the owner exports by hand from the provider's usage page; treat anything else
as a research question, not a collector. If a pool can only be read
dishonestly or not at all, it reads `unknown` — which is safe (idea 5), and
the ledger will tell you if that pool was worth reading anyway.

Privacy follows from the same rule: your meters file contains your spending
patterns. Keep it out of the repo (the reference engine defaults to a
synthetic example file for exactly this reason), and keep real plan prices out
of anything shared.

## The reference implementation

```bash
bin/pace                        # table from pacing/meters.example.json (synthetic)
bin/pace my-meters.json         # your real meters, same JSON shape
bin/pace my-meters.json --json  # machine-readable, for the coordinator agent
node --test pacing/             # unit tests (on/behind/ahead of pace, unknown,
                                # exhausted, reserve, toggles, caps, CLI)
```

Everything above is implemented in [`pacing/pace.mjs`](../pacing/pace.mjs)
(dependency-free Node ≥ 20 ESM): pools as routes, used%/window meters, the
pace ratio with the early-window guard, the two-term lane formula with the
catch-up horizon, fail-closed unknowns, confirmed-vs-flaky exhaustion,
reserves, owner modes (`even` / `burn-harder` / `paused`), pool and host caps.
Calibration and the reset-waste ledger are habits around the engine — see
[`pacing/README.md`](../pacing/README.md) for the meters schema and how to
feed it real numbers.

To grow beyond the reference: keep the engine pure (numbers in, advice out,
clock injected), publish the advice with its reason on every read, and let the
coordinator consume `--json` — the dashboard's job is to be the *one*
calibrated place this arithmetic lives.
