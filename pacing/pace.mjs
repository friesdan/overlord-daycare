#!/usr/bin/env node
/**
 * Overlord Daycare — reference pacing engine.
 *
 * Reads a meters file (one entry per pool: used %, window start/end, cost per
 * lane-hour, max lanes, optional reserve %) and prints, per pool, the pace and
 * how many agent lanes may run right now, with a one-line reason. `--json`
 * prints the same thing machine-readable for a coordinator agent.
 *
 * The arithmetic (see ../docs/pacing.md for the WHY behind every rule):
 *
 *   paceRatio   = used% / elapsed% of the window      (1.0 = an even burn)
 *   keepPace    = spendable% / hoursLeft               (%/h that empties on time)
 *   catchUp     = max(0, elapsed% − used%) / H         (H = a few hours, not
 *                                                       the whole window)
 *   lanes       = ceil((keepPace + catchUp) / burnPerLaneHour),
 *                 at least 1 when the pool may spend, capped by the pool's
 *                 max lanes and by host capacity
 *
 * Hard rules, in order: owner-paused → 0; unreadable meter or window → 0
 * ("unknown is never plenty"); confirmed exhaustion → 0; meter reads empty → 0;
 * over pace (unless the owner said burn harder) → 0 new lanes; an uncovered
 * reserve → 0; no measured cost per lane-hour → 0 (calibrate first).
 *
 * Collect meters only through official provider APIs or your own exported
 * data — scraping a provider's pages or reusing another tool's login tokens
 * may break the provider's terms of service. This engine takes numbers; it
 * never fetches them.
 *
 * Dependency-free, Node ≥ 20. Pure functions are exported for the tests in
 * pace.test.mjs.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import process from "node:process";

/** Every threshold in one place, so tuning is a one-line change. */
export const CONFIG = Object.freeze({
  // used%/elapsed% above this means the pool is burning faster than the
  // clock: no NEW lanes until the window catches up. 1.05 ≈ the surplus
  // mirror of a 0.95 "clearly under-spent" line.
  hotRatio: 1.05,
  // Below this the pool is clearly behind the even burn (surplus budget).
  behindRatio: 0.95,
  // With less than this % of the window elapsed, used%/elapsed% is noise
  // (one lane skews it wildly). Advice is then sized from budget alone.
  minElapsedPercent: 2,
  // A behind pool closes its gap over AT MOST this many hours — a few hours,
  // never the whole remaining window (catching up "eventually, by reset" is
  // not catching up)…
  catchUpHorizonHours: 6,
  // …and at least this many, so the last hour before reset cannot demand an
  // absurd burn rate.
  catchUpFloorHours: 2,
});

const finite = (x) => typeof x === "number" && Number.isFinite(x);
const r1 = (x) => Math.round(x * 10) / 10;
const r2 = (x) => Math.round(x * 100) / 100;
const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

const HOUR_MS = 3_600_000;

function parseTs(v) {
  if (typeof v !== "string") return null;
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
}

/**
 * Advice for one pool. Pure: `nowMs` is injected, nothing is read or fetched.
 * Always returns an object (fail closed per pool) — a malformed pool advises
 * 0 lanes rather than crashing the whole run.
 */
export function advisePool(pool, { nowMs, hostMaxLanes = Infinity } = {}) {
  const name =
    pool && typeof pool.name === "string" && pool.name.trim() !== ""
      ? pool.name
      : "(unnamed)";
  const used =
    pool && pool.meter && finite(pool.meter.usedPercent)
      ? pool.meter.usedPercent
      : null;

  const zero = (band, reason) => ({
    name,
    band,
    lanes: 0,
    paceRatio: null,
    usedPercent: finite(used) ? r1(used) : null,
    elapsedPercent: null,
    remainingPercent: null,
    reservePercent: null,
    reserveFor: null,
    spendablePercent: null,
    hoursLeft: null,
    catchUpPoints: null,
    burnPerLaneHour: finite(pool?.burnPerLaneHour) ? pool.burnPerLaneHour : null,
    burnSource: typeof pool?.burnSource === "string" ? pool.burnSource : null,
    reason,
  });

  if (!pool || typeof pool !== "object") return zero("unknown", "malformed pool entry — 0 lanes (fail closed)");

  // ---- Owner toggles --------------------------------------------------------
  const mode = pool.mode === undefined ? "even" : pool.mode;
  if (mode === "paused") {
    return zero("paused", "owner paused this pool — 0 lanes until they resume it");
  }
  if (mode !== "even" && mode !== "burn-harder") {
    return zero("unknown", `unrecognized mode "${mode}" — 0 lanes (fail closed)`);
  }

  // ---- The meter: unknown is never plenty ------------------------------------
  if (used === null || used < 0 || used > 100) {
    return zero(
      "unknown",
      "meter unreadable (no usable used %) — unknown is never plenty; 0 lanes",
    );
  }

  // ---- The window -------------------------------------------------------------
  const start = parseTs(pool.windowStart);
  const end = parseTs(pool.windowEnd);
  if (start === null || end === null || end <= start) {
    return zero(
      "unknown",
      "window unreadable (need windowStart and windowEnd) — 0 lanes",
    );
  }
  if (end <= nowMs) {
    return zero(
      "unknown",
      `window ended ${new Date(end).toISOString()} — it should have reset; read the meter again before spending (0 lanes)`,
    );
  }

  // ---- Exhaustion: a confirmed fact vs a flaky read ---------------------------
  if (pool.exhaustedConfirmed === true) {
    return zero(
      "exhausted",
      `confirmed exhausted — a real rate limit was observed (stronger than any rounded %); resets ${new Date(end).toISOString()}; 0 lanes`,
    );
  }
  if (used >= 100) {
    return zero(
      "empty",
      "meter reads empty but exhaustion is UNCONFIRMED (a rounded/flaky read can show 0 left; only an observed rate limit confirms) — 0 lanes; re-read before believing it",
    );
  }

  // ---- Pace: used% vs elapsed% -------------------------------------------------
  const windowHours = (end - start) / HOUR_MS;
  const hoursLeft = (end - nowMs) / HOUR_MS;
  const elapsedPercent = clamp(((nowMs - start) / (end - start)) * 100, 0, 100);
  const paceRatio =
    elapsedPercent >= CONFIG.minElapsedPercent ? r2(used / elapsedPercent) : null;

  // ---- Reserve: part of the pool is not the lanes' to spend --------------------
  const reservePercent = finite(pool.reservePercent)
    ? clamp(pool.reservePercent, 0, 100)
    : 0;
  const reserveFor =
    typeof pool.reserveFor === "string" && pool.reserveFor !== ""
      ? pool.reserveFor
      : null;
  const remainingPercent = r1(100 - used);
  const burnHarder = mode === "burn-harder";
  const spendablePercent = burnHarder
    ? remainingPercent // the owner released the reserve deliberately
    : r1(remainingPercent - reservePercent);

  const band =
    paceRatio === null ? "early" : paceRatio < CONFIG.behindRatio ? "behind" : "even";

  if (spendablePercent <= 0) {
    return {
      ...zero(
        band,
        `reserve for ${reserveFor ?? "a named purpose"} uncovered: ${remainingPercent}% left < ${reservePercent}% held — 0 lanes until it recovers`,
      ),
      elapsedPercent: r1(elapsedPercent),
      paceRatio,
      remainingPercent,
      reservePercent: r1(reservePercent),
      reserveFor,
      hoursLeft: r1(hoursLeft),
    };
  }

  // ---- Over pace: burning faster than the clock --------------------------------
  if (paceRatio !== null && paceRatio > CONFIG.hotRatio && !burnHarder) {
    return {
      ...zero(
        "hot",
        `over pace (${paceRatio}: used ${r1(used)}% vs elapsed ${r1(elapsedPercent)}%) — burning faster than the clock; 0 new lanes, let the window catch up`,
      ),
      elapsedPercent: r1(elapsedPercent),
      paceRatio,
      remainingPercent,
      reservePercent: r1(reservePercent),
      reserveFor,
      spendablePercent,
      hoursLeft: r1(hoursLeft),
    };
  }

  // ---- Lane arithmetic -----------------------------------------------------------
  const burnPerLaneHour = finite(pool.burnPerLaneHour) ? pool.burnPerLaneHour : null;
  if (burnPerLaneHour === null || burnPerLaneHour <= 0) {
    return {
      ...zero(
        band,
        "no cost per lane-hour on record — calibrate (compare assumed vs observed burn on real runs) before spending; 0 lanes",
      ),
      elapsedPercent: r1(elapsedPercent),
      paceRatio,
      remainingPercent,
      reservePercent: r1(reservePercent),
      reserveFor,
      hoursLeft: r1(hoursLeft),
    };
  }

  const keepPaceRate = spendablePercent / hoursLeft; // %/h that empties exactly at reset
  const catchUpPoints = Math.max(0, r1(elapsedPercent - used));
  const catchUpHours = clamp(hoursLeft, CONFIG.catchUpFloorHours, CONFIG.catchUpHorizonHours);
  const catchUpRate = catchUpPoints > 0 ? catchUpPoints / catchUpHours : 0;
  const ratePerHour = keepPaceRate + catchUpRate;

  const cap = Math.min(
    finite(pool.maxLanes) ? Math.max(0, Math.floor(pool.maxLanes)) : Infinity,
    hostMaxLanes,
  );
  let lanes = Math.ceil(ratePerHour / burnPerLaneHour);
  if (lanes < 1) lanes = 1; // a pool that may spend gets at least one lane
  if (lanes > cap) lanes = cap;

  const bits = [
    `${band}${paceRatio !== null ? ` (pace ${paceRatio})` : " (too early to judge pace; sized from budget)"}`,
    `burn ${r1(ratePerHour)}%/h (${r1(keepPaceRate)} keep-pace${catchUpRate > 0 ? ` + ${r1(catchUpRate)} catch-up over ${r1(catchUpHours)} h` : ""}) ÷ ${r1(burnPerLaneHour)}%/lane-h → ${lanes} lane${lanes === 1 ? "" : "s"}`,
    `cap ${cap === Infinity ? "∞" : cap}`,
  ];
  if (reservePercent > 0 && !burnHarder) {
    bits.push(`${r1(reservePercent)}% held for ${reserveFor ?? "reserve"} (${r1(spendablePercent)}% spendable)`);
  }
  if (burnHarder) bits.push("owner burn-harder: reserve released, over-pace gate off");

  return {
    name,
    band,
    lanes,
    paceRatio,
    usedPercent: r1(used),
    elapsedPercent: r1(elapsedPercent),
    remainingPercent,
    reservePercent: r1(reservePercent),
    reserveFor,
    spendablePercent,
    hoursLeft: r1(hoursLeft),
    catchUpPoints: r1(catchUpPoints),
    burnPerLaneHour,
    burnSource: typeof pool.burnSource === "string" ? pool.burnSource : null,
    reason: bits.join("; "),
  };
}

/**
 * Advice for a whole meters document:
 *   { now?, hostMaxLanes?, pools: [...] }
 * `nowMs` overrides the document's `now` (tests); the wall clock is the last
 * resort, so a meters file without `now` still works.
 */
export function advise(meters, nowMs) {
  let now;
  if (nowMs !== undefined && nowMs !== null) {
    now = nowMs;
  } else if (meters && meters.now !== undefined) {
    const t = parseTs(meters.now);
    if (t === null) throw new Error('meters.now is not a parseable timestamp (use ISO 8601, e.g. "2026-11-14T12:00:00Z")');
    now = t;
  } else {
    now = Date.now();
  }

  const hostMaxLanes =
    meters && finite(meters.hostMaxLanes) && meters.hostMaxLanes > 0
      ? Math.floor(meters.hostMaxLanes)
      : Infinity;

  const pools = Array.isArray(meters?.pools) ? meters.pools : [];
  const advised = pools.map((p) => advisePool(p, { nowMs: now, hostMaxLanes }));
  const totalAdvisedLanes = advised.reduce((sum, p) => sum + p.lanes, 0);

  return {
    generatedAt: new Date(now).toISOString(),
    hostMaxLanes: hostMaxLanes === Infinity ? null : hostMaxLanes,
    totalAdvisedLanes,
    note:
      totalAdvisedLanes > hostMaxLanes
        ? `advised total ${totalAdvisedLanes} exceeds host capacity ${hostMaxLanes} — the coordinator picks which pools fill the host (reserved purposes first)`
        : null,
    pools: advised,
  };
}

// ---- CLI ---------------------------------------------------------------------------

const USAGE = `usage: node pacing/pace.mjs [meters.json] [--json]

Prints per-pool pace and advised agent lanes from a meters file (default:
pacing/meters.example.json — synthetic numbers).

  meters.json   path to your meters (shape: pacing/meters.example.json)
  --json        machine-readable output, for a coordinator agent
  --help        this help

Rules: unknown or unreadable meter ⇒ 0 lanes (unknown is never plenty);
confirmed exhaustion ⇒ 0; over-pace ⇒ 0 new lanes; reserves are held back;
lanes are capped by the pool max and host capacity. Numbers in, advice out —
collect real meters only via official APIs or your own exported data.`;

function printTable(result, sourceLabel) {
  const header = ["pool", "band", "pace", "used/el", "left/spend", "lanes", "reason"];
  const rows = result.pools.map((p) => [
    p.name,
    p.band,
    p.paceRatio === null ? "-" : String(p.paceRatio),
    `${p.usedPercent ?? "-"}/${p.elapsedPercent ?? "-"}`,
    `${p.remainingPercent ?? "-"}/${p.spendablePercent ?? "-"}`,
    String(p.lanes),
    p.reason,
  ]);
  const widths = header.map((h, i) =>
    Math.max(h.length, ...rows.map((r) => r[i].length)),
  );
  const line = (cells) =>
    cells.map((c, i) => (i === cells.length - 1 ? c : c.padEnd(widths[i]))).join("  ");

  process.stdout.write(`Overlord Daycare pacing — ${result.generatedAt} — meters: ${sourceLabel}\n\n`);
  process.stdout.write(`${line(header)}\n${widths.map((w) => "-".repeat(w)).join("  ")}\n`);
  for (const r of rows) process.stdout.write(`${line(r)}\n`);
  const host = result.hostMaxLanes === null ? "" : ` of host capacity ${result.hostMaxLanes}`;
  process.stdout.write(`\ntotal advised lanes: ${result.totalAdvisedLanes}${host}\n`);
  if (result.note) process.stdout.write(`note: ${result.note}\n`);
}

function main(argv) {
  let file = null;
  let asJson = false;
  for (const a of argv) {
    if (a === "--json") asJson = true;
    else if (a === "--help" || a === "-h") {
      process.stdout.write(`${USAGE}\n`);
      return 0;
    } else if (a.startsWith("-")) {
      process.stderr.write(`error: unknown option ${a}\n\n${USAGE}\n`);
      return 1;
    } else if (file === null) {
      file = a;
    } else {
      process.stderr.write(`error: unexpected extra argument ${a}\n\n${USAGE}\n`);
      return 1;
    }
  }

  const defaultFile = fileURLToPath(new URL("./meters.example.json", import.meta.url));
  const target = file ?? defaultFile;
  let meters;
  try {
    meters = JSON.parse(readFileSync(target, "utf8"));
  } catch (err) {
    process.stderr.write(`error: cannot read meters file ${target}: ${err.message}\n`);
    return 1;
  }

  const result = advise(meters);
  if (asJson) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  else printTable(result, file === null ? "pacing/meters.example.json (synthetic)" : file);
  return 0;
}

// Run as a CLI only when executed directly (not when imported by the tests).
const invoked = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invoked) process.exit(main(process.argv.slice(2)));
