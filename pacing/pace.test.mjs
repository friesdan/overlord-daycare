/**
 * Unit tests for the Overlord Daycare reference pacing engine.
 * Run: node --test pacing/  (Node ≥ 20)
 *
 * All numbers are synthetic. `now` is pinned so every expectation is exact.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import { advise, advisePool, CONFIG } from "./pace.mjs";

const NOW = Date.parse("2026-11-14T12:00:00Z");
const HOUR = 3_600_000;

/** ISO timestamps for a window of `total` hours, `elapsed` hours in. */
function win(elapsedH, leftH) {
  return {
    windowStart: new Date(NOW - elapsedH * HOUR).toISOString(),
    windowEnd: new Date(NOW + leftH * HOUR).toISOString(),
  };
}

// A 100-hour window, 50 hours elapsed (50%) — the base for most cases.
const HALF = win(50, 50);

test("on pace: even burn keeps a modest lane count", () => {
  // used 50 / elapsed 50 → pace 1.0. remaining 50 over 50 h = 1%/h; no gap;
  // burn 5%/lane-h → ceil(0.2) → the floor of 1 lane.
  const a = advisePool(
    { name: "onpace", meter: { usedPercent: 50 }, ...HALF, burnPerLaneHour: 5, maxLanes: 6 },
    { nowMs: NOW },
  );
  assert.equal(a.band, "even");
  assert.equal(a.paceRatio, 1);
  assert.equal(a.lanes, 1);
  assert.match(a.reason, /keep-pace/);
});

test("behind pace: a catch-up term adds lanes beyond the even rate", () => {
  // used 20 / elapsed 50 → pace 0.4. remaining 80 → 1.6%/h keep-pace, plus a
  // 30-point gap closed over 6 h → 5%/h; total 6.6%/h ÷ 5%/lane-h → ceil → 2.
  const a = advisePool(
    { name: "behind", meter: { usedPercent: 20 }, ...HALF, burnPerLaneHour: 5, maxLanes: 6 },
    { nowMs: NOW },
  );
  assert.equal(a.band, "behind");
  assert.equal(a.paceRatio, 0.4);
  assert.equal(a.catchUpPoints, 30);
  assert.equal(a.lanes, 2);
  assert.ok(a.lanes > 1, "catch-up must push past the single-lane floor case");

  // same pool ON pace gets fewer lanes (1) — the catch-up term is what differs
  const even = advisePool(
    { name: "even", meter: { usedPercent: 50 }, ...HALF, burnPerLaneHour: 5, maxLanes: 6 },
    { nowMs: NOW },
  );
  assert.ok(a.lanes > even.lanes);
});

test("ahead of pace (over-spent): 0 new lanes, whatever the budget", () => {
  // used 80 / elapsed 50 → pace 1.6 — burning faster than the clock.
  const a = advisePool(
    { name: "hot", meter: { usedPercent: 80 }, ...HALF, burnPerLaneHour: 5, maxLanes: 6 },
    { nowMs: NOW },
  );
  assert.equal(a.band, "hot");
  assert.equal(a.paceRatio, 1.6);
  assert.equal(a.lanes, 0);
  assert.match(a.reason, /over pace/);
});

test("unknown meter: 0 lanes — unknown is never plenty", () => {
  const a = advisePool(
    { name: "blank", meter: null, ...HALF, burnPerLaneHour: 5, maxLanes: 6 },
    { nowMs: NOW },
  );
  assert.equal(a.band, "unknown");
  assert.equal(a.lanes, 0);
  assert.match(a.reason, /unknown is never plenty/);

  // a used % outside [0, 100] is just as unreadable
  const bad = advisePool(
    { name: "bad", meter: { usedPercent: 140 }, ...HALF, burnPerLaneHour: 5 },
    { nowMs: NOW },
  );
  assert.equal(bad.band, "unknown");
  assert.equal(bad.lanes, 0);
});

test("exhausted: 0 lanes — and confirmation is distinguished from a flaky read", () => {
  // a meter that READS empty is an inference (rounding, staleness)…
  const reads = advisePool(
    { name: "reads-empty", meter: { usedPercent: 100 }, ...HALF, burnPerLaneHour: 5 },
    { nowMs: NOW },
  );
  assert.equal(reads.lanes, 0);
  assert.equal(reads.band, "empty");
  assert.match(reads.reason, /UNCONFIRMED/);

  // …an observed rate limit is a fact, and it wins even at <100% used
  const confirmed = advisePool(
    { name: "confirmed", meter: { usedPercent: 90 }, ...HALF, burnPerLaneHour: 5, exhaustedConfirmed: true },
    { nowMs: NOW },
  );
  assert.equal(confirmed.lanes, 0);
  assert.equal(confirmed.band, "exhausted");
  assert.match(confirmed.reason, /rate limit was observed/);
});

test("reserve is respected: held percent buys fewer (or zero) lanes", () => {
  const base = { meter: { usedPercent: 40 }, ...HALF, burnPerLaneHour: 1, maxLanes: 6 };
  // no reserve: spendable 60 → 1.2 + 1.67 catch-up = 2.87%/h → 3 lanes
  const free = advisePool({ name: "free", ...base }, { nowMs: NOW });
  assert.equal(free.lanes, 3);

  // 50% held for reviews: spendable 10 → 0.2 + 1.67 = 1.87%/h → 2 lanes
  const held = advisePool(
    { name: "held", ...base, reservePercent: 50, reserveFor: "reviews" },
    { nowMs: NOW },
  );
  assert.equal(held.lanes, 2);
  assert.equal(held.spendablePercent, 10);
  assert.match(held.reason, /held for reviews/);
  assert.ok(held.lanes < free.lanes);

  // reserve larger than what is left → nothing spendable → 0 lanes
  const uncovered = advisePool(
    { name: "uncovered", meter: { usedPercent: 60 }, ...HALF, burnPerLaneHour: 1, reservePercent: 50, reserveFor: "reviews" },
    { nowMs: NOW },
  );
  assert.equal(uncovered.lanes, 0);
  assert.match(uncovered.reason, /reserve for reviews uncovered/);
});

test("owner toggles: paused is 0; burn-harder overrides the over-pace gate", () => {
  const paused = advisePool(
    { name: "paused", meter: { usedPercent: 10 }, ...HALF, burnPerLaneHour: 1, mode: "paused" },
    { nowMs: NOW },
  );
  assert.equal(paused.lanes, 0);
  assert.equal(paused.band, "paused");

  // pace 1.6 would be "hot" → 0, but the owner said spend it down
  const burn = advisePool(
    {
      name: "burn",
      meter: { usedPercent: 80 },
      ...HALF,
      burnPerLaneHour: 0.5,
      maxLanes: 4,
      reservePercent: 15,
      mode: "burn-harder",
    },
    { nowMs: NOW },
  );
  assert.equal(burn.band, "even"); // no longer gated as hot
  assert.ok(burn.lanes >= 1);
  assert.match(burn.reason, /burn-harder/);
  assert.equal(burn.spendablePercent, 20); // reserve released: all 20% left
});

test("early window: pace is noise, advice is sized from budget and not suppressed", () => {
  // 0.5 h into a 100-h window at 0.4% used — raw ratio would read 0.8/“hot”
  // territory on noise; the engine must not judge pace this early.
  const a = advisePool(
    { name: "early", meter: { usedPercent: 0.4 }, ...win(0.5, 99.5), burnPerLaneHour: 1, maxLanes: 4 },
    { nowMs: NOW },
  );
  assert.equal(a.band, "early");
  assert.equal(a.paceRatio, null);
  assert.ok(a.lanes >= 1, "early but eligible: at least one lane");
  assert.match(a.reason, /too early to judge pace/);
});

test("lane count is capped by pool max lanes and host capacity", () => {
  // 0% used at mid-window: 2%/h keep-pace + 8.33%/h catch-up → ceil(10.33) = 11
  const uncapped = advisePool(
    { name: "big", meter: { usedPercent: 0 }, ...HALF, burnPerLaneHour: 1, maxLanes: 10 },
    { nowMs: NOW, hostMaxLanes: 3 },
  );
  assert.equal(uncapped.lanes, 3); // host capacity 3 wins over the pool's 10

  const byPool = advisePool(
    { name: "small", meter: { usedPercent: 0 }, ...HALF, burnPerLaneHour: 1, maxLanes: 2 },
    { nowMs: NOW, hostMaxLanes: 8 },
  );
  assert.equal(byPool.lanes, 2); // pool's own cap wins
});

test("a window that should have reset reads as unknown", () => {
  const a = advisePool(
    { name: "stale", meter: { usedPercent: 3 }, ...win(10, -1), burnPerLaneHour: 1 },
    { nowMs: NOW },
  );
  assert.equal(a.band, "unknown");
  assert.equal(a.lanes, 0);
  assert.match(a.reason, /read the meter again/);
});

test("no measured cost per lane-hour: 0 lanes until calibrated", () => {
  const a = advisePool(
    { name: "uncal", meter: { usedPercent: 30 }, ...HALF, maxLanes: 4 },
    { nowMs: NOW },
  );
  assert.equal(a.lanes, 0);
  assert.match(a.reason, /calibrate/);
});

test("advise(): totals, host note, and meters.now are honored", () => {
  const pool = (name) => ({
    name,
    meter: { usedPercent: 0 },
    ...HALF,
    burnPerLaneHour: 1,
    maxLanes: 10,
  });
  const result = advise({ now: "2026-11-14T12:00:00Z", hostMaxLanes: 4, pools: [pool("a"), pool("b")] });
  assert.equal(result.generatedAt, "2026-11-14T12:00:00.000Z");
  assert.equal(result.hostMaxLanes, 4);
  // each pool alone would take 11 lanes (ceil(10.33)), but host capacity caps
  // each at 4 — so the two pools advise 8 against a host that fits 4
  assert.ok(result.pools.every((p) => p.lanes === 4));
  assert.equal(result.totalAdvisedLanes, 8);
  assert.match(result.note, /exceeds host capacity 4/);

  const small = advise({ now: "2026-11-14T12:00:00Z", hostMaxLanes: 20, pools: [pool("a")] });
  assert.equal(small.totalAdvisedLanes, 10); // ceil(10.33) = 11, capped by maxLanes 10
  assert.equal(small.note, null);

  assert.throws(() => advise({ now: "not a date" }), /parseable timestamp/);
});

test("CLI: table and --json run against the synthetic example", () => {
  const cli = fileURLToPath(new URL("./pace.mjs", import.meta.url));
  const json = JSON.parse(
    execFileSync(process.execPath, [cli, "--json"], { encoding: "utf8" }),
  );
  assert.equal(json.pools.length, 6);
  assert.equal(typeof json.totalAdvisedLanes, "number");
  assert.ok(json.pools.every((p) => typeof p.lanes === "number" && typeof p.reason === "string" && p.reason.length > 0));

  const table = execFileSync(process.execPath, [cli], { encoding: "utf8" });
  assert.match(table, /pool\s+band/);
  assert.match(table, /unknown is never plenty/);
  assert.match(table, /total advised lanes/);
});
