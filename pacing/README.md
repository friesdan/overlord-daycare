# The reference pacing engine

`pacing/pace.mjs` is a dependency-free (Node ≥ 20, ESM) engine that turns a
meters file into lane advice: one line per pool with its pace and how many
agent lanes it may run right now, plus the reason. Numbers in, advice out —
it never fetches anything. The design and the *why* behind every rule live in
[`docs/pacing.md`](../docs/pacing.md); start there.

```bash
node pacing/pace.mjs                      # or: bin/pace (from the kit root)
node pacing/pace.mjs my-meters.json       # your own meters
node pacing/pace.mjs my-meters.json --json  # for a coordinator agent
node --test pacing/                       # unit tests
```

## The meters file

A JSON document: an optional pinned `now` (ISO 8601; omit it to use the wall
clock — pin it in scripts and tests for reproducible output), an optional
`hostMaxLanes` (how many lanes the machine can actually run), the optional
staleness policy, and `pools`:

```json
{
  "now": "2026-11-14T12:00:00Z",
  "hostMaxLanes": 6,
  "heartbeatMinutes": 30,
  "staleAfterHeartbeats": 3,
  "pools": [
    {
      "name": "worker-weekly",
      "note": "any text — this field is ignored",
      "meter": { "usedPercent": 40 },
      "windowStart": "2026-11-09T12:00:00Z",
      "windowEnd": "2026-11-16T12:00:00Z",
      "collectedAt": "2026-11-14T11:58:00Z",
      "burnPerLaneHour": 4,
      "burnSource": "measured",
      "maxLanes": 4,
      "reservePercent": 25,
      "reserveFor": "code reviews",
      "mode": "even",
      "exhaustedConfirmed": false
    }
  ]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Pool name. Name it after the **route**, not the model — the same model through two products is two pools with two meters. |
| `meter` | yes | `{ "usedPercent": 40 }` — the pool's usage meter. `null` or a non-numeric/out-of-range `%` reads as **unknown** → 0 lanes. |
| `windowStart` / `windowEnd` | yes | The reset window, ISO 8601. Both are needed (pace compares used % against elapsed %). A window that already ended reads as unknown — read the meter again. |
| `collectedAt` | no | ISO 8601 time the meter was **read** — collectors stamp this on every refresh. Older than `staleAfterHeartbeats` × `heartbeatMinutes` → **stale** → 0 lanes ("not pacing on old numbers"). Missing = not judged (a hand-written file still paces); present but unparseable or in the future → unknown. |
| `burnPerLaneHour` | for lanes | Points of the window one lane burns per hour (a weekly pool at 4 means one lane empties it in 25 lane-hours). Missing/≤ 0 → 0 lanes until you calibrate. |
| `burnSource` | no | `"measured"` or `"assumed"` — a label so advice never mistakes a guess for a number. |
| `maxLanes` | no | The pool's own cap (small plans, owner fiat). |
| `reservePercent` / `reserveFor` | no | Hold this many points of the window for a named purpose (reviews, migrations). Uncoverable reserve → 0 lanes. |
| `mode` | no | Owner toggle: `even` (default), `burn-harder` (reserve released, over-pace gate off), `paused` (0 lanes). |
| `exhaustedConfirmed` | no | `true` = a real rate limit was observed — a fact that beats the meter, cleared only by the window resetting or the owner. |
| `staleAfterHeartbeats` | no | Per-pool override of the staleness limit, for a pool read less often than every heartbeat (e.g. a monthly plan collected daily). |

Document level: `heartbeatMinutes` (default 30) and `staleAfterHeartbeats`
(default 3) set the staleness policy for every pool at once — a reading older
than 90 minutes at the defaults refuses to pace, whatever it says.

`pacing/meters.example.json` is a fully synthetic working example covering
every state (behind, hot, unknown, even, paused, reserved).

## Feeding it real meters

1. **Pick your pools.** One pool per metered route. If two products meter the
   same model separately, they are two entries — never merge meters.
2. **Get `usedPercent` and the window honestly.** Use the provider's official
   usage API with your own key, or a file you export yourself from their usage
   page. **Do not scrape provider pages and do not reuse another tool's login
   tokens — that may break the provider's terms of service**, and those
   integrations leak tokens into logs. A pool you can't read honestly stays
   `meter: null` (0 lanes is the safe answer, not a guess).
   [`docs/collecting-usage.md`](../docs/collecting-usage.md) walks every source
   kind (CLI status command, dashboard page, response headers, usage endpoint);
   [`docs/prompts/build-collectors.md`](../docs/prompts/build-collectors.md) is
   a ready-made instruction for your head overlord to write the collectors, and
   [`collectors/example-collector/`](../collectors/example-collector/) is a
   working offline example to copy.
3. **Estimate `burnPerLaneHour`, then measure it.** Start with a conservative
   assumption and label it `"assumed"`. Once real lanes have run:
   `observed = Δused% ÷ (lanes × hours)` over an interval where you know how
   many lanes ran. Swap the number in, flip the label to `"measured"`, and log
   the assumed-vs-observed gap with the date — that log is what tells you
   which pools still run on guesses. (A daily habit: re-check any pool whose
   advice "feels" wrong; it is usually the burn number.)
4. **Set reserves you mean.** A slice held for reviews only helps if it is
   actually held when lanes are hungry. Name the purpose so the reason line
   explains itself.
5. **Keep the file out of the repo.** Real meters are your spending patterns
   — keep them local (`.overlord/meters.json` is git-ignored) and keep real
   plan prices out of anything shared. `pacing/meters.example.json` stays
   synthetic on purpose.
6. **Record resets.** When a window ends, append one row per pool to a
   reset-waste ledger (pool, window end, kind, used % at last reading,
   left-over %, staleness, lane-hours). Three months of "this plan expired
   59% unused" is how plan decisions stop being vibes.

## Output

The table (default) shows pool, band (`even` / `behind` / `hot` / `early` /
`unknown` / `stale` / `exhausted` / `empty` / `paused`), pace ratio,
used/elapsed, left/spendable, lanes, and the one-line reason. `--json` returns
the same data as an object: `generatedAt`, `hostMaxLanes`,
`stalenessPolicy`, `totalAdvisedLanes`, a `note` when the advised total
exceeds host capacity, and `pools[]` with every input echoed alongside the
advice (`collectedAt` and `stalenessMinutes` included), so a consumer can
check the arithmetic rather than trust it.

Exit codes: `0` advice produced, `1` unreadable file or bad usage. Per-pool
failures never fail the run — they fail closed to 0 lanes with a reason.
