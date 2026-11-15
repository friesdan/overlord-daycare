# Example collector (offline, on purpose)

A working collector you can copy for each plan you pay for. It reads a **local
fixture** — a saved status snippet, JSON or plain text — and writes the
[pacing input format](../../pacing/README.md). It never touches the network:
swap the fixture read for your provider's honest source and keep the rest of
the shape. What each source kind looks like, and the rules for reading one,
are in [`docs/collecting-usage.md`](../../docs/collecting-usage.md);
[`docs/prompts/build-collectors.md`](../../docs/prompts/build-collectors.md)
is the instruction that has your head overlord build the real ones.

```bash
# print one pool entry (what the collector learned just now)
node collectors/example-collector/collector.mjs \
  --pool cli-weekly --fixture collectors/example-collector/fixtures/cli-status.txt \
  --now 2026-11-14T12:01:00Z

# upsert it into the meters file the heartbeat paces from (created if missing)
node collectors/example-collector/collector.mjs \
  --pool cli-weekly --fixture collectors/example-collector/fixtures/cli-status.txt \
  --meters .overlord/meters.json

# a snippet that shows only a reset time: derive the window start, don't guess it
node collectors/example-collector/collector.mjs \
  --pool nightly-5h --fixture collectors/example-collector/fixtures/cli-status-reset-only.txt \
  --window-hours 5 --meters .overlord/meters.json

bin/pace .overlord/meters.json    # the advice those numbers produce
```

The fixtures are synthetic (`fixtures/`), including a `broken.txt` that yields
no facts — run the collector on it to see the failure path: the pool is still
written, as `meter: null` with the reason in its `note`, and the script exits
1. Unknown is never plenty; the engine fails that pool closed to 0 lanes.

## What to keep when you copy this

- **Three facts per read** — used %, reset time, time collected
  (`collectedAt`) — plus a `note` saying where they came from.
- **Upsert one pool entry, preserve the policy.** Facts (meter, window,
  `collectedAt`, note) are overwritten every refresh; the owner's policy
  fields in the meters file (`burnPerLaneHour`, reserves, `maxLanes`, `mode`)
  survive it. A collector that invents policy is guessing with extra steps.
- **Fail loud, fail closed.** A source that breaks writes `meter: null` and
  exits non-zero. A collector that dies silently is caught anyway: the
  reading's `collectedAt` goes stale and the engine refuses to pace on it
  (band `stale`, 0 lanes).
- **No credentials here, ever.** The real collector authenticates the way the
  source already does — the provider's own logged-in CLI, or an env var the
  owner sets. Nothing secret belongs in a collector, its fixtures, or its
  logs.

## Tests

`tests/example-collector.test.mjs` covers the JSON and text fixtures, the
derived-window case, the broken-source path, and that the collected output
actually paces (and goes stale) through the reference engine. It runs from
`tests/smoke.sh` and `node --test tests/`; no network anywhere.
