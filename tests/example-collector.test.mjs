/**
 * Tests for collectors/example-collector — the offline example of reading a
 * usage source and writing the pacing input format. Run: node --test tests/
 *
 * No network: every input is a checked-in synthetic fixture. All numbers are
 * synthetic, and the failure paths matter as much as the happy one — a source
 * that breaks must record unknown, never a guess.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { advise } from "../pacing/pace.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const COLLECTOR = fileURLToPath(new URL("../collectors/example-collector/collector.mjs", import.meta.url));
const FIXTURE = (name) =>
  fileURLToPath(new URL(`../collectors/example-collector/fixtures/${name}`, import.meta.url));

const READ_AT = "2026-11-14T12:01:00Z";

/** Run the collector, returning { code, stdout, stderr, entry? }. */
function run(args) {
  try {
    const stdout = execFileSync(process.execPath, [COLLECTOR, ...args], { encoding: "utf8" });
    return { code: 0, stdout, stderr: "" };
  } catch (err) {
    return { code: err.status ?? 1, stdout: err.stdout ?? "", stderr: err.stderr ?? "" };
  }
}

/** Run the collector printing one pool entry, parsed. */
function collect(fixture, extra = []) {
  const r = run(["--pool", "test-pool", "--fixture", FIXTURE(fixture), "--now", READ_AT, ...extra]);
  return { ...r, entry: r.code === 0 ? JSON.parse(r.stdout) : null };
}

test("reads a text status snippet into the pacing input format", () => {
  const { entry } = collect("cli-status.txt");
  assert.deepEqual(entry, {
    name: "test-pool",
    note: `collected by example-collector from a text fixture at ${new Date(READ_AT).toISOString()}`,
    meter: { usedPercent: 40 },
    collectedAt: new Date(READ_AT).toISOString(),
    windowStart: "2026-11-09T12:00:00.000Z",
    windowEnd: "2026-11-16T12:00:00.000Z",
  });
});

test("reads a JSON usage snippet (the documented-endpoint shape)", () => {
  const { entry } = collect("usage-endpoint.json");
  assert.equal(entry.meter.usedPercent, 44);
  assert.equal(entry.windowStart, "2026-11-01T00:00:00.000Z");
  assert.equal(entry.windowEnd, "2026-12-01T00:00:00.000Z");
});

test("derives the window start from --window-hours when only a reset is shown", () => {
  const { entry } = collect("cli-status-reset-only.txt", ["--window-hours", "5"]);
  assert.equal(entry.meter.usedPercent, 55);
  assert.equal(entry.windowEnd, "2026-11-14T15:00:00.000Z");
  assert.equal(entry.windowStart, "2026-11-14T10:00:00.000Z"); // reset − 5 h, not a guess
});

test("a snippet without --window-hours and without a window start is refused", () => {
  const r = collect("cli-status-reset-only.txt");
  assert.notEqual(r.code, 0);
  assert.match(r.stderr, /--window-hours/);
});

test("a broken source writes meter: null, keeps collectedAt, exits non-zero", () => {
  const r = run(["--pool", "test-pool", "--fixture", FIXTURE("broken.txt"), "--now", READ_AT]);
  assert.notEqual(r.code, 0);
  const entry = JSON.parse(r.stdout);
  assert.equal(entry.meter, null, "unknown is never plenty — never a guess");
  assert.equal(entry.collectedAt, new Date(READ_AT).toISOString());
  assert.match(entry.note, /collection failed/);
  assert.match(entry.note, /no reset time/);
  assert.equal(entry.windowStart, undefined, "a failed read proves no window facts either");
});

test("upsert: facts refresh, the owner's policy and other pools survive", () => {
  const dir = mkdtempSync(join(tmpdir(), "overlord-collector-"));
  const meters = join(dir, "meters.json");
  writeFileSync(
    meters,
    JSON.stringify({
      now: "2026-11-14T00:00:00Z",
      hostMaxLanes: 4,
      pools: [
        {
          name: "test-pool",
          meter: { usedPercent: 10 },
          windowStart: "2026-11-09T12:00:00Z",
          windowEnd: "2026-11-16T12:00:00Z",
          collectedAt: "2026-11-13T00:00:00Z",
          burnPerLaneHour: 4,
          burnSource: "measured",
          reservePercent: 20,
          reserveFor: "code reviews",
          mode: "even",
        },
        { name: "other-pool", meter: { usedPercent: 1 }, windowStart: "2026-11-14T00:00:00Z", windowEnd: "2026-11-15T00:00:00Z" },
      ],
    }),
  );

  const ok = run([
    "--pool", "test-pool", "--fixture", FIXTURE("cli-status.txt"),
    "--meters", meters, "--now", READ_AT,
  ]);
  assert.equal(ok.code, 0);
  const doc = JSON.parse(readFileSync(meters, "utf8"));

  assert.equal(doc.pools.length, 2, "one entry per pool, no duplicates");
  const pool = doc.pools.find((p) => p.name === "test-pool");
  assert.equal(pool.meter.usedPercent, 40, "the fact refreshed");
  assert.equal(pool.collectedAt, new Date(READ_AT).toISOString());
  // policy set by hand in the meters file survives the refresh
  assert.equal(pool.burnPerLaneHour, 4);
  assert.equal(pool.reservePercent, 20);
  assert.equal(pool.reserveFor, "code reviews");
  assert.equal(pool.mode, "even");
  assert.ok(doc.pools.some((p) => p.name === "other-pool"));
  assert.equal(doc.hostMaxLanes, 4);
  assert.equal(doc.now, undefined, "live data: the pinned test 'now' is dropped");

  // a later broken read flips the same pool to unknown and drops its window
  const bad = run([
    "--pool", "test-pool", "--fixture", FIXTURE("broken.txt"),
    "--meters", meters, "--now", "2026-11-14T12:31:00Z",
  ]);
  assert.notEqual(bad.code, 0);
  const after = JSON.parse(readFileSync(meters, "utf8"));
  const flipped = after.pools.find((p) => p.name === "test-pool");
  assert.equal(flipped.meter, null, "the last-known-good number must not keep standing");
  assert.equal(flipped.windowEnd, undefined);
  assert.equal(flipped.reservePercent, 20, "policy still survives a failed read");
});

test("an empty meters file (a crashed earlier write) starts over; a corrupt one is not touched", () => {
  const dir = mkdtempSync(join(tmpdir(), "overlord-collector-"));

  const empty = join(dir, "empty.json");
  writeFileSync(empty, "");
  const ok = run(["--pool", "test-pool", "--fixture", FIXTURE("cli-status.txt"), "--meters", empty, "--now", READ_AT]);
  assert.equal(ok.code, 0);
  assert.equal(JSON.parse(readFileSync(empty, "utf8")).pools[0].meter.usedPercent, 40);

  const corrupt = join(dir, "corrupt.json");
  writeFileSync(corrupt, '{ "pools": [ '); // truncated: damage the collector must not clobber
  const refused = run(["--pool", "test-pool", "--fixture", FIXTURE("cli-status.txt"), "--meters", corrupt, "--now", READ_AT]);
  assert.notEqual(refused.code, 0);
  assert.match(refused.stderr, /refusing to touch it/);
  assert.equal(readFileSync(corrupt, "utf8"), '{ "pools": [ ');
});

test("collected output paces through the engine — and goes stale honestly", () => {
  const dir = mkdtempSync(join(tmpdir(), "overlord-collector-"));
  const meters = join(dir, "meters.json");
  const r = run([
    "--pool", "test-pool", "--fixture", FIXTURE("cli-status.txt"),
    "--meters", meters, "--now", READ_AT, "--burn-per-lane-hour", "4", "--max-lanes", "4",
    "--heartbeat-minutes", "30",
  ]);
  assert.equal(r.code, 0);
  const doc = JSON.parse(readFileSync(meters, "utf8"));

  // pinned "now" 1 heartbeat after the read: fresh, so it paces
  const fresh = advise(doc, Date.parse("2026-11-14T12:31:00Z"));
  assert.equal(fresh.pools[0].name, "test-pool");
  assert.ok(fresh.pools[0].lanes >= 1);
  assert.equal(fresh.stalenessPolicy.heartbeatMinutes, 30);

  // the same reading judged 4 heartbeats later: stale, 0 lanes, said so
  const stale = advise(doc, Date.parse("2026-11-14T15:01:00Z"));
  assert.equal(stale.pools[0].band, "stale");
  assert.equal(stale.pools[0].lanes, 0);
  assert.match(stale.pools[0].reason, /not pacing on old numbers/);
});
