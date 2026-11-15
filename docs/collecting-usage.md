# Collecting live usage for pacing

The pacing engine ([`docs/pacing.md`](pacing.md), `bin/pace`) takes numbers and
gives lane advice — it never fetches anything. Nobody should hand-type those
numbers either: they go stale within one heartbeat and typos route real work.
This doc is how your kit reads **live subscription usage** instead, without an
official usage API existing for most plans.

The honest reality of subscription plans: usage shows up somewhere, but rarely
in a documented API. It surfaces in one of four places — a **status command**
in the plan's own CLI, the provider's **dashboard page**, **response headers**,
or a **usage endpoint** the provider does publish. Each is readable honestly;
below is how, what to record, and what to do when it breaks.

Everything here is generic on purpose — it names *kinds* of plans, not
accounts:

- an **AI coding subscription** — a monthly plan whose allowance is spent by a
  coding agent CLI and/or IDE;
- a **chat plan with a coding CLI** — a consumer chat subscription that also
  meters a terminal CLI, usually as a *separate* allowance from the chat app;
- a **flat monthly plan** — one allowance, calendar-month reset, no per-model
  meters.

Naming products that exist is fine (Claude Code, Codex CLI and Gemini CLI are
all coding CLIs of the first two kinds). Their exact commands and fields are
**not** reproduced here: flags and output shapes change between versions, so
verify against the provider's own docs before writing them into a collector —
where this doc is unsure it says *"check the provider's docs for the status
command"*, and your collector should do the same.

## What every collector records

Three facts, per pool, on every heartbeat — whatever the source:

| Fact | Field in the meters file | Notes |
| --- | --- | --- |
| percent used | `meter.usedPercent` | 0–100. If the source shows used and allowance in units (requests, credits), `usedPercent = used ÷ allowance × 100`. **If the allowance isn't shown, the meter is `null` — never guess the denominator.** |
| the reset time | `windowEnd` (+ `windowStart`) | Most sources show only the reset. `windowStart = reset − window length` (168 h weekly, 24 h daily, 5 h for the short windows, calendar month for a flat plan). Both are needed: pace compares used % against elapsed %. |
| the time collected | `collectedAt` | ISO 8601, stamped when the source was *read*. This is what makes staleness detectable later. |

A collector that succeeds writes one pool entry in the
[pacing input format](../pacing/README.md) and never touches anything else:

```json
{
  "name": "cli-weekly",
  "note": "read by collectors/cli-status at 2026-11-14T12:01:03Z",
  "meter": { "usedPercent": 40 },
  "windowStart": "2026-11-09T12:00:00Z",
  "windowEnd": "2026-11-16T12:00:00Z",
  "collectedAt": "2026-11-14T12:01:03Z"
}
```

Policy fields — `burnPerLaneHour`, `reservePercent`, `maxLanes`, `mode` — are
the owner's, set by hand in the meters file. A collector that invented them
would be guessing with extra steps; it writes the four facts above (and a
`note`) only. Collectors *upsert* their one pool entry into the meters file
(`.overlord/meters.json`, git-ignored), leaving every other pool alone.

## The four sources

### 1. A status command in the plan's own CLI

An AI coding subscription almost always ships a CLI that can print where the
allowance stands — current usage and the reset time — for the account it is
logged into. A chat plan with a coding CLI works the same way, and meters the
CLI separately from the chat app: that is **two pools with two meters**, even
though one subscription pays for both (see
[docs/pacing.md §1, pools are routes](pacing.md#1-pools-are-routes-not-model-names)).

How to read it:

1. Find the exact status/usage command in the provider's docs for the version
   you run, and pin the collector to what the docs show. Don't guess flags —
   an invented flag either errors (fine) or means something else (not fine).
   If the docs don't name one, check the CLI's own help; if you still can't
   verify a read-only status command exists, the pool reads `unknown`.
2. Run it as the already-logged-in user. The CLI holds its own session — that
   is the credential, and it stays inside the CLI. Never copy its token into
   the repo, a config file, or a lane's environment.
3. Parse the output *loosely*: percent used, reset time. CLIs reformat their
   status output between versions; a regex that matches more than your one
   pinned version will break silently. When the parse misses, write
   `meter: null` (below), not a best effort.
4. Record `collectedAt` at the moment you read it.

A worked (fully synthetic) text parser ships in the kit:
[`collectors/example-collector/`](../collectors/example-collector/) reads a
text status snippet from a local fixture and writes the meters format, with no
network at all — copy its shape for a real CLI.

### 2. The provider's dashboard page

Most plans without a usage API still show a usage or limits page in the
account console — a bar, a percentage, and usually a "resets …" line next to
it. That page is made for a human's eyes, so read it the way a human would:

- **Use the page's own export** if it has one (a download button, a CSV/JSON
  export). The exported file is your fixture; a collector parses the file, not
  the page.
- **Or have the owner paste the two numbers** (used %, reset time) into a
  small local file on a schedule. Clunky, but honest, and it takes ten
  seconds: this is the intended path for a flat monthly plan checked once a
  day — set that pool's `staleAfterHeartbeats` accordingly.
- A calendar-month reset (flat plan) means `windowStart` is the first of the
  month; the page rarely says this, the plan's billing date does.

What is **not** OK: driving the page headlessly with a reused session cookie,
or scraping its HTML. That breaks the provider's terms of service, rots the
moment they redesign, and leaks session tokens into logs — see
[Collecting meters honestly](pacing.md#collecting-meters-honestly). If a page
cannot be read through its own export or by the owner's hand, the pool reads
`unknown`, which is safe: the reset-waste ledger will tell you whether that
plan was worth reading anyway.

### 3. Response headers

Some providers put usage or rate-limit information in headers on *every*
response — remaining quota, limit, and a reset time (often as a Unix
timestamp). Common shapes are a remaining/limit pair and a reset epoch, but
**header names differ per provider: check the provider's docs for the exact
names before trusting any of them**, and don't hardcode a name you haven't
verified against your own traffic.

How to read them honestly:

- Read them **passively** — from the logs or proxy your lanes already
  produce. Never send extra requests just to read a header; the collector's
  job is to look, not to spend.
- `usedPercent = (limit − remaining) ÷ limit × 100`.
- The reset epoch converts to `windowEnd` (`new Date(epoch * 1000)` when it is
  in seconds); `collectedAt` is the time of the response that carried it.
- Keep the latest snapshot per pool. Headers are per-response, so they go
  stale faster than any other source — which is exactly what
  `collectedAt` + the staleness rule are for. If two routes hit different
  headers, they are different pools.

### 4. The provider's own usage endpoint

The cleanest source when it exists: some plans document a usage or quota
endpoint you may call with **your own key**. It usually returns used, limit
and reset as JSON, which is why the example collector also parses a JSON
fixture.

- The key comes from an environment variable the owner sets — never from the
  repo, never echoed into logs, and never handed to a worker shell (the kit
  already scrubs secret-shaped variables; keep it that way).
- Undocumented endpoints do not count. If you only know an endpoint exists
  because you watched the dashboard's network tab, it is the provider's
  plumbing, not a contract: it changes without notice and using it is the
  same terms-of-service gray zone as scraping. Such a pool reads `unknown`
  until the provider documents it.

## Refresh on every heartbeat

The heartbeat ([HOW-WE-WORK.md §6](../HOW-WE-WORK.md#6-the-heartbeat-and-watchers),
~30 minutes) runs the loop:

1. Run every collector; each upserts its pool into the meters file.
2. Run `bin/pace --json`; the coordinator reads the lane advice.

A collector that fails **writes its pool as unknown before exiting non-zero**:

```json
{
  "name": "cli-weekly",
  "note": "collection failed at 2026-11-14T12:31:00Z: status command exited 1 (output format changed?)",
  "meter": null,
  "windowStart": "2026-11-09T12:00:00Z",
  "windowEnd": "2026-11-16T12:00:00Z",
  "collectedAt": "2026-11-14T12:31:00Z"
}
```

The window is worth keeping: it lets the ledger and the reset logic keep
working even when the percentage is gone.

**Stale is the failure you don't see.** A collector can also die *silently* —
crashed scheduler, hung CLI, laptop asleep. The meters file then holds
yesterday's numbers, which look perfectly healthy. This is why `collectedAt`
is not optional in a collector's output, and why the engine refuses to pace on
it: a reading older than `staleAfterHeartbeats` × `heartbeatMinutes`
(defaults: 3 × 30 min = 90 min; configurable per document, or per pool with
its own `staleAfterHeartbeats` — a monthly plan collected daily wants a much
larger number) comes back as band `stale`, **0 lanes**, reason
"not pacing on old numbers". Unknown or stale always beats a guess — a false
"plenty left" launches lanes that hit a wall mid-task; a false "empty" costs
one heartbeat of unspent capacity ([idea 5](pacing.md#5-unknown-is-never-plenty)).

One exception, on purpose: **confirmed exhaustion** (a lane observed a real
rate-limit response) is a recorded fact that outlives a stale meter — it is
cleared only by the window resetting or by the owner, never by a lucky
re-read. Collectors don't write it; lanes do.

## The rules, in one list

Every collector, no exceptions:

1. **Read-only.** It runs a status query and writes the meters file. It never
   mutates account state, never sends anything to the provider beyond the
   status query itself.
2. **No credentials in the repo.** Use the provider's own logged-in CLI (it
   holds its session), or an env var the owner sets. Keep credentials out of
   worker shells.
3. **Official surfaces only.** Documented commands, documented endpoints, the
   page's own export, or the owner's own paste. No scraping, no reused session
   tokens, no undocumented endpoints.
4. **Verify before you hardcode.** Command flags, output fields, header names
   and endpoint paths come from the provider's docs or your own captured
   traffic — never from a guess. Unsure means `unknown`.
5. **Unknown or stale, never a guess.** A broken source writes
   `meter: null` and says why in `note`. No estimated, remembered, or
   last-known-good percentages — the engine fails closed, which is the cheap
   direction.

Ready to have an agent build these?
[`docs/prompts/build-collectors.md`](prompts/build-collectors.md) is the
instruction to hand your head overlord.
