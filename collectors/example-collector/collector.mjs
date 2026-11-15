#!/usr/bin/env node
/**
 * Overlord Daycare — example usage collector (offline, on purpose).
 *
 * Reads a LOCAL fixture (a saved status snippet: JSON or plain text) and
 * writes one pool entry in the pacing meters format, or upserts it into a
 * meters file. It touches no network: the collector you copy this from swaps
 * the fixture read for whatever the provider honestly offers — its CLI status
 * command, its documented usage endpoint, the dashboard page's own export, or
 * a file the owner pastes numbers into. See docs/collecting-usage.md for how
 * to read each source kind, and docs/prompts/build-collectors.md for the
 * instruction that has an agent build the real ones.
 *
 * The pattern this example teaches:
 *
 *   1. record three facts — used %, the reset time, the time collected;
 *   2. derive windowStart from the reset when only the reset is shown;
 *   3. upsert ONE pool entry, keeping the owner's policy fields intact;
 *   4. when the source breaks, write meter: null (unknown is never plenty)
 *      and exit non-zero — never a remembered or estimated number.
 *
 * Dependency-free, Node >= 20. Exit codes: 0 read ok, 1 the source broke.
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import process from "node:process";

const USAGE = `usage: node collectors/example-collector/collector.mjs --pool <name> --fixture <file> [options]

Reads a local status snippet (JSON or text — no network) and writes the pacing
input format. The fixtures next to this script are synthetic; replace the read
with your provider's honest source, keeping the rest of the shape.

  --pool <name>               pool name in the meters file (name the ROUTE, not
                              the model — two products on one plan are two pools)
  --fixture <file>            the saved status snippet to parse
  --meters <file>             meters file to upsert into (created if missing);
                              default: print the pool entry to stdout
  --window-hours <h>          window length, when the snippet only shows a reset
  --burn-per-lane-hour <%>    calibrated cost per lane-hour (else left as-is: the
                              engine advises 0 lanes until one is calibrated)
  --max-lanes <n>             pool cap
  --heartbeat-minutes <m>     recorded at the meters document level (default 30)
  --now <iso>                 pretend it is this time (for tests; default: now)

A pool that cannot be parsed is still written — as meter: null, with the
failure in its note — and the script exits 1. Unknown beats a guess.`;

// ---- CLI ---------------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = { pool: null, fixture: null, meters: null, now: null };
  const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : undefined);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => (i + 1 < argv.length ? argv[++i] : null);
    if (a === "--help" || a === "-h") opts.help = true;
    else if (a === "--pool") opts.pool = next();
    else if (a === "--fixture") opts.fixture = next();
    else if (a === "--meters") opts.meters = next();
    else if (a === "--window-hours") opts.windowHours = num(next());
    else if (a === "--burn-per-lane-hour") opts.burnPerLaneHour = num(next());
    else if (a === "--max-lanes") opts.maxLanes = num(next());
    else if (a === "--heartbeat-minutes") opts.heartbeatMinutes = num(next());
    else if (a === "--now") opts.now = next();
    else {
      process.stderr.write(`error: unknown argument ${a}\n\n${USAGE}\n`);
      process.exit(1);
    }
  }
  if (opts.help) {
    process.stdout.write(`${USAGE}\n`);
    process.exit(0);
  }
  if (!opts.pool || !opts.fixture) {
    process.stderr.write(`error: --pool and --fixture are required\n\n${USAGE}\n`);
    process.exit(1);
  }
  return opts;
}

// ---- Parsing the source --------------------------------------------------------------------

// Deliberately non-capturing inside, so the sources that embed it keep their
// group numbers stable.
const ISO = /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?/;
const toIso = (v) => {
  if (typeof v !== "string") return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : new Date(t).toISOString();
};
const pct = (v) =>
  typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 100 ? v : null;

/** A JSON snippet (the shape a documented usage endpoint returns). */
function readJsonFixture(doc) {
  const used =
    pct(doc?.usedPercent) ??
    pct(doc?.usage?.usedPercent) ??
    pct(doc?.quota?.usedPercent) ??
    null;
  const end =
    toIso(doc?.windowEnd) ?? toIso(doc?.window?.end) ?? toIso(doc?.resetsAt) ?? toIso(doc?.resetAt);
  const start = toIso(doc?.windowStart) ?? toIso(doc?.window?.start);
  return { used, start, end };
}

/** A text snippet (the shape a CLI status command prints). Loose on purpose:
 *  real CLIs reformat between versions, so match the fact, not the layout —
 *  and fail to unknown the moment any fact is missing. */
function readTextFixture(text) {
  const usedMatch = text.match(/\bused\b[^\d%]*([\d.]+)\s*%/i);
  const windowMatch = text.match(new RegExp(`window[^\\d]*(${ISO.source})\\s*(?:->|→|to)\\s*(${ISO.source})`, "i"));
  const resetMatch = text.match(new RegExp(`resets?(?:\\s+at)?\\s*:?\\s*(${ISO.source})`, "i"));
  return {
    used: usedMatch ? pct(Number(usedMatch[1])) : null,
    start: windowMatch ? toIso(windowMatch[1]) : null,
    end: resetMatch ? toIso(resetMatch[1]) : null,
  };
}

/**
 * Facts from the fixture, or a reason it broke. `windowStart` falls back to
 * reset − windowHours when the source shows only the reset (most do).
 */
function readFixture(path, windowHours) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch (err) {
    return { error: `cannot read fixture ${path}: ${err.message}` };
  }

  let facts;
  let kind = "text";
  try {
    facts = readJsonFixture(JSON.parse(raw));
    kind = "json";
  } catch {
    facts = readTextFixture(raw);
  }

  const { used, end } = facts;
  let { start } = facts;
  if (!end) return { error: "no reset time found in the snippet" };
  if (used === null) return { error: "no usable used % found in the snippet" };
  if (!start) {
    if (!(windowHours > 0)) {
      return { error: "snippet shows only the reset — pass --window-hours so the window start is derived, not guessed" };
    }
    start = new Date(Date.parse(end) - windowHours * 3_600_000).toISOString();
  }
  if (Date.parse(end) <= Date.parse(start)) return { error: "window end is not after its start" };
  return { used, start, end, kind };
}

// ---- Writing the meters format --------------------------------------------------------------

/**
 * Upsert ONE pool entry. Facts (meter, window, collectedAt, note) come from
 * the source; policy (burnPerLaneHour, reserves, maxLanes, mode, …) is the
 * owner's, set by hand in the meters file, and must survive every refresh —
 * so the previous entry is kept and only the facts are overwritten.
 * `dropKeys` removes facts a failed read disproves (a broken source must not
 * leave the last window standing either).
 */
function upsertPool(doc, entry, dropKeys = []) {
  const pools = Array.isArray(doc.pools) ? doc.pools : [];
  const i = pools.findIndex((p) => p && p.name === entry.name);
  if (i >= 0) {
    const merged = { ...pools[i], ...entry };
    for (const k of dropKeys) delete merged[k];
    pools[i] = merged;
  } else {
    pools.push({ ...entry });
  }
  return { ...doc, pools };
}

function main(argv) {
  const opts = parseArgs(argv);
  const nowIso = opts.now ? toIso(opts.now) : new Date().toISOString();
  if (opts.now && !nowIso) {
    process.stderr.write(`error: --now is not a parseable ISO 8601 timestamp\n`);
    return 1;
  }

  const read = readFixture(opts.fixture, opts.windowHours);

  // The entry is written on failure too — as meter: null, with the reason in
  // the note. A broken source must not leave the last number standing.
  const entry = {
    name: opts.pool,
    note: read.error
      ? `collection failed at ${nowIso}: ${read.error} — unknown is never plenty`
      : `collected by example-collector from a ${read.kind} fixture at ${nowIso}`,
    meter: read.error ? null : { usedPercent: read.used },
    collectedAt: nowIso,
  };
  if (!read.error) {
    entry.windowStart = read.start;
    entry.windowEnd = read.end;
  } else {
    delete entry.windowStart; // a failed read proves no window facts either
    delete entry.windowEnd;
  }

  // Explicit flags are the owner acting; anything not given keeps what the
  // meters file already had (upsertPool carries the previous entry forward).
  if (opts.burnPerLaneHour !== undefined) entry.burnPerLaneHour = opts.burnPerLaneHour;
  if (opts.maxLanes !== undefined) entry.maxLanes = opts.maxLanes;

  if (!opts.meters) {
    process.stdout.write(`${JSON.stringify(entry, null, 2)}\n`);
    if (read.error) process.stderr.write(`error: ${read.error}\n`);
    return read.error ? 1 : 0;
  }

  let doc = {};
  if (existsSync(opts.meters)) {
    let prev = "";
    try {
      prev = readFileSync(opts.meters, "utf8");
    } catch (err) {
      process.stderr.write(`error: cannot read meters file ${opts.meters}: ${err.message}\n`);
      return 1;
    }
    if (prev.trim() !== "") {
      // A non-empty file that is not valid JSON is damage we did not cause:
      // refuse to overwrite it, and let the owner look.
      try {
        doc = JSON.parse(prev);
      } catch (err) {
        process.stderr.write(`error: meters file ${opts.meters} is not valid JSON (${err.message}); refusing to touch it\n`);
        return 1;
      }
    } // an empty file (a crashed earlier write) just starts over
  }
  doc = upsertPool(doc, entry, read.error ? ["windowStart", "windowEnd"] : []);
  if (opts.heartbeatMinutes !== undefined) doc.heartbeatMinutes = opts.heartbeatMinutes;
  delete doc.now; // live data now: let the engine use the wall clock
  writeFileSync(opts.meters, `${JSON.stringify(doc, null, 2)}\n`);
  process.stdout.write(`${entry.name}: ${read.error ? "unknown" : `used ${read.used}%`}, collected ${nowIso} -> ${opts.meters}\n`);
  if (read.error) process.stderr.write(`error: ${read.error}\n`);
  return read.error ? 1 : 0;
}

process.exit(main(process.argv.slice(2)));
