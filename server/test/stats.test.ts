import test from 'node:test';
import assert from 'node:assert/strict';
import { computeStats, simplifyRoute, speedSeries, cleanTrack } from '../src/stats';

const M = 1 / 111_000; // degrees per metre (latitude)
// Walk north at 2 m/s for n seconds, one sample/second.
const walk = (n: number, t0 = 0, lat0 = 30, speed = 2): number[][] =>
  Array.from({ length: n + 1 }, (_, i) => [t0 + i * 1000, lat0 + i * speed * M, -97, speed, 5]);

test('distance and top speed for a steady walk', () => {
  const s = computeStats(walk(60), 'seeker');
  assert.ok(Math.abs(s.distanceM - 120) < 4, `distance ${s.distanceM}`);
  assert.ok(Math.abs(s.topSpeedMps - 2) < 0.3);
  assert.ok(s.movingMs > 55_000);
});

test('GPS glitches (teleports) and bad-accuracy fixes are ignored', () => {
  const t = walk(30);
  t.splice(10, 0, [10_500, 31, -97, 2, 5]); // 100 km jump
  t.splice(20, 0, [20_500, 30.5, -97, 2, 80]); // terrible accuracy
  const s = computeStats(t, 'seeker');
  assert.ok(s.distanceM < 70 && s.distanceM > 50, `distance ${s.distanceM}`);
  assert.ok(s.topSpeedMps <= 12);
});

test('standing still does not accumulate distance from jitter', () => {
  const t = Array.from({ length: 60 }, (_, i) => [i * 1000, 30 + (i % 2) * 1 * M, -97, 0, 5]);
  const s = computeStats(t, 'hider');
  assert.equal(s.distanceM, 0);
  assert.ok(s.stillMs > 50_000 && s.movingMs === 0);
});

test('distance is split into hider and seeker parts at the conversion time', () => {
  const s = computeStats(walk(60), 'hider', 30_000);
  assert.ok(Math.abs(s.hiderDistanceM - 60) < 6, `hider ${s.hiderDistanceM}`);
  assert.ok(Math.abs(s.seekerDistanceM - 60) < 6, `seeker ${s.seekerDistanceM}`);
});

test('RDP keeps the ends and drops collinear points', () => {
  const r = simplifyRoute(walk(120));
  assert.equal(r.length, 2);
  assert.ok(r[0][0] < r[1][0]);
});

test('RDP keeps corners', () => {
  const north = walk(30);
  const east = Array.from({ length: 30 }, (_, i) => [31_000 + i * 1000, 30 + 60 * M, -97 + (i + 1) * 2 * M, 2, 5]);
  assert.ok(simplifyRoute([...north, ...east]).length >= 3);
});

test('speed series is downsampled', () => {
  assert.ok(speedSeries(walk(1000), 100).length <= 100);
  assert.equal(cleanTrack([]).kept.length, 0);
});
