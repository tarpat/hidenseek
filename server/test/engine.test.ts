import test from 'node:test';
import assert from 'node:assert/strict';
import { GameEngine, haversineM } from '../src/engine';

const MIN = 60_000;
const CENTER = { lat: 30.2849, lng: -97.7341 };
// ~0.001 deg lat ≈ 111 m
const at = (metersNorth: number) => ({ lat: CENTER.lat + metersNorth / 111_000, lng: CENTER.lng, acc: 3 });

function setup(opts: Partial<ConstructorParameters<typeof GameEngine>[2]> = {}) {
  let t = 1_000_000;
  const clock = { now: () => t, advance: (ms: number) => (t += ms), set: (v: number) => (t = v) };
  const g = new GameEngine(clock.now, () => 0.5, { center: CENTER, radiusM: 200, ...opts });
  g.addPlayer('L', 'Leader', '#f00', true);
  g.addPlayer('H1', 'Hider1', '#0f0');
  g.addPlayer('H2', 'Hider2', '#00f');
  g.addPlayer('S1', 'Seeker1', '#ff0');
  g.setRole('L', 'seeker');
  g.setRole('H1', 'hider');
  g.setRole('H2', 'hider');
  g.setRole('S1', 'seeker');
  return { g, clock };
}
const locAll = (g: GameEngine) => {
  g.onLocation('L', at(0));
  g.onLocation('H1', at(50));
  g.onLocation('H2', at(60));
  g.onLocation('S1', at(10));
};

test('haversine is roughly right', () => {
  assert.ok(Math.abs(haversineM(CENTER, at(111)) - 111) < 1);
});

test('cannot start without a hider and a seeker, or with unassigned players', () => {
  const g = new GameEngine();
  g.addPlayer('a', 'a', '#fff');
  assert.throws(() => g.start(), /hider/);
  g.setRole('a', 'hider');
  assert.throws(() => g.start(), /seeker/);
  g.addPlayer('b', 'b', '#fff');
  assert.throws(() => g.start(), /seeker/);
  g.setRole('b', 'seeker');
  g.addPlayer('c', 'c', '#fff');
  assert.throws(() => g.start(), /role/);
});

test('timeline: 5 min head start, first ping at 5:00, every 5 min, ends at 35:00', () => {
  const { g, clock } = setup();
  const t0 = clock.now();
  g.start();
  assert.equal(g.huntStartsAt, t0 + 5 * MIN);
  assert.equal(g.endsAt, t0 + 35 * MIN);
  locAll(g);

  const pingTimes: number[] = [];
  for (let s = 1; s <= 35 * 60; s++) {
    clock.advance(1000);
    // Everyone keeps reporting so nobody is treated as "dark".
    if (s % 30 === 0) locAll(g);
    for (const e of g.tick()) if (e.type === 'ping') pingTimes.push((e.at - t0) / MIN);
  }
  assert.deepEqual(pingTimes, [5, 10, 15, 20, 25, 30]);
  assert.equal(g.status, 'ended');
  assert.equal(g.winner, 'hiders');
});

test('every ping contains everyone, and is the same for every player', () => {
  const { g, clock } = setup();
  g.start();
  locAll(g);
  clock.advance(5 * MIN);
  g.tick();
  const ping = g.pings[0];
  assert.equal(ping.positions.length, 4);
  for (const id of ['L', 'H1', 'H2', 'S1']) assert.deepEqual(g.viewFor(id).lastPing, ping);
});

test('between pings: hiders see only live hiders, seekers only live seekers', () => {
  const { g } = setup();
  g.start();
  locAll(g);
  const ids = (v: ReturnType<GameEngine['viewFor']>) => v.live.map((p) => p.id).sort();
  assert.deepEqual(ids(g.viewFor('H1')), ['H1', 'H2']);
  assert.deepEqual(ids(g.viewFor('S1')), ['L', 'S1']);
  assert.equal(g.viewFor('H1').lastPing, null); // nothing from the other side before the first ping
});

test('a tagged hider gets seeker view only, and never sees hiders live again', () => {
  const { g, clock } = setup({ headStartMs: 0 });
  g.start();
  locAll(g);
  g.tag('S1', 'H1');
  const v = g.viewFor('H1');
  assert.equal(v.role, 'seeker');
  assert.deepEqual(v.live.map((p) => p.id).sort(), ['H1', 'L', 'S1']);
  assert.equal(v.hidersLeft, 1);
  clock.advance(1);
});

test('tagging is blocked during the head start, then works, and the last tag ends the game', () => {
  const { g, clock } = setup();
  g.start();
  locAll(g);
  assert.throws(() => g.tag('S1', 'H1'), /head start/);
  clock.advance(5 * MIN);
  assert.throws(() => g.tag('H2', 'H1'), /only seekers/);
  assert.throws(() => g.tag('S1', 'L'), /not a hider/);
  g.tag('S1', 'H1');
  assert.equal(g.status, 'active');
  const ev = g.tag('S1', 'H2');
  assert.ok(ev.some((e) => e.type === 'ended' && e.winner === 'seekers' && e.reason === 'all_tagged'));
  assert.equal(g.status, 'ended');
});

test('out of bounds needs 2 clear samples; hider converts after grace; returning cancels', () => {
  const { g, clock } = setup();
  g.start();
  locAll(g);
  let ev = g.onLocation('H1', at(400)); // 1st sample outside
  assert.equal(ev.length, 0);
  ev = g.onLocation('H1', at(400)); // 2nd sample outside
  assert.equal(ev[0].type, 'oob_start');
  // Re-enter in time
  clock.advance(30_000);
  ev = g.onLocation('H1', at(100));
  assert.equal(ev[0].type, 'oob_return');
  clock.advance(2 * MIN);
  g.onLocation('H1', at(100));
  assert.equal(g.players.get('H1')!.role, 'hider');

  // Leave again and stay out
  g.onLocation('H2', at(400));
  g.onLocation('H2', at(400));
  clock.advance(59_000);
  g.onLocation('H2', at(400));
  assert.equal(g.tick().some((e) => e.type === 'converted'), false);
  clock.advance(2000);
  g.onLocation('H2', at(400));
  const conv = g.tick().find((e) => e.type === 'converted');
  assert.ok(conv && conv.type === 'converted' && conv.reason === 'out_of_bounds');
  assert.equal(g.players.get('H2')!.role, 'seeker');
});

test('GPS noise: a poor-accuracy fix near the edge does not count as outside', () => {
  const { g } = setup();
  g.start();
  locAll(g);
  const edge = { ...at(210), acc: 50 }; // 210 m away but ±50 m, so possibly inside
  g.onLocation('H1', edge);
  assert.equal(g.onLocation('H1', edge).length, 0);
});

test('seekers who leave get a warning but are never converted', () => {
  const { g, clock } = setup();
  g.start();
  locAll(g);
  g.onLocation('S1', at(500));
  const ev = g.onLocation('S1', at(500));
  assert.equal(ev[0].type, 'oob_start');
  clock.advance(10 * MIN);
  g.onLocation('S1', at(500));
  g.tick();
  assert.equal(g.players.get('S1')!.role, 'seeker');
});

test('hider who goes dark for 2 min is converted; setting 0 turns it off', () => {
  const a = setup();
  a.g.start();
  locAll(a.g);
  a.clock.advance(2 * MIN - 1000);
  a.g.onLocation('H2', at(60)); // H2 keeps reporting
  a.g.onLocation('S1', at(10));
  a.g.tick();
  assert.equal(a.g.players.get('H1')!.role, 'hider');
  a.clock.advance(1000);
  const ev = a.g.tick();
  assert.ok(ev.some((e) => e.type === 'converted' && e.playerId === 'H1' && e.reason === 'dark'));
  assert.equal(a.g.players.get('H2')!.role, 'hider');

  const b = setup({ darkHiderMs: 0 });
  b.g.start();
  locAll(b.g);
  b.clock.advance(20 * MIN);
  b.g.tick();
  assert.equal(b.g.players.get('H1')!.role, 'hider');
});

test('late pings (e.g. after a server restart) collapse into one', () => {
  const { g, clock } = setup({ darkHiderMs: 0 });
  g.start();
  locAll(g);
  clock.advance(18 * MIN); // missed pings at 5, 10, 15
  const pings = g.tick().filter((e) => e.type === 'ping');
  assert.equal(pings.length, 1);
  assert.equal(g.nextPingAt, g.startsAt + 20 * MIN);
});

test('changing settings mid-game moves the end time', () => {
  const { g } = setup();
  g.start();
  g.updateSettings({ durationMs: 10 * MIN });
  assert.equal(g.endsAt, g.startsAt + 15 * MIN);
  g.updateSettings({ headStartMs: 2 * MIN });
  assert.equal(g.huntStartsAt, g.startsAt + 2 * MIN);
});

test('zero head start: first ping after one interval', () => {
  const { g } = setup({ headStartMs: 0 });
  g.start();
  assert.equal(g.nextPingAt, g.startsAt + 5 * MIN);
});

test('random assignment makes the requested number of seekers and skips referees', () => {
  const g = new GameEngine(Date.now, () => 0.3);
  for (const id of 'abcdefg') g.addPlayer(id, id, '#fff');
  g.setRole('a', 'referee');
  g.assignRandom(2);
  const roles = [...g.players.values()].map((p) => p.role);
  assert.equal(roles.filter((r) => r === 'seeker').length, 2);
  assert.equal(roles.filter((r) => r === 'hider').length, 4);
  assert.equal(g.players.get('a')!.role, 'referee');
});

test('referee sees everyone live, and nobody can mutate state after the game ends', () => {
  const { g } = setup();
  g.setRole('L', 'referee');
  g.start();
  locAll(g);
  assert.equal(g.viewFor('L').live.length, 3); // referee isn't a tracked player
  g.endNow();
  assert.equal(g.status, 'ended');
  assert.throws(() => g.tag('S1', 'H1'), /not active/);
  assert.deepEqual(g.onLocation('H1', at(0)), []);
});
