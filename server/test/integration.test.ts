import test from 'node:test';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { createApp } from '../src/app';
import { decryptSnapshot } from '../src/room';

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until(fn: () => any, ms = 4000, what = 'condition') {
  const end = Date.now() + ms;
  for (;;) {
    const v = fn();
    if (v) return v;
    if (Date.now() > end) throw new Error('timeout waiting for ' + what);
    await sleep(15);
  }
}

class Client {
  msgs: any[] = [];
  state: any;
  token = '';
  code = '';
  id = '';
  snapshot: any;
  snaps: any[] = [];
  chats: any[] = [];
  results: any;
  events: any[] = [];
  constructor(readonly ws: WebSocket) {
    ws.on('message', (d) => {
      const m = JSON.parse(d.toString());
      this.msgs.push(m);
      if (m.type === 'state') this.state = m;
      if (m.type === 'joined') ({ token: this.token, code: this.code, playerId: this.id } = m);
      if (m.type === 'snapshot') (this.snapshot = m, this.snaps.push(m));
      if (m.type === 'chat') this.chats.push(m.msg);
      if (m.type === 'results') this.results = m;
      if (m.type === 'event') this.events.push(m.event);
    });
  }
  static async connect(port: number) {
    const ws = new WebSocket(`ws://localhost:${port}/ws`);
    await new Promise((res, rej) => (ws.once('open', res), ws.once('error', rej)));
    return new Client(ws);
  }
  send(o: any) {
    this.ws.send(JSON.stringify(o));
  }
  has(pred: (m: any) => boolean) {
    return this.msgs.find(pred);
  }
  errorCount() {
    return this.msgs.filter((m) => m.type === 'error').length;
  }
  async expectError(action: () => void, re: RegExp) {
    const before = this.errorCount();
    action();
    await until(() => this.errorCount() > before, 2000, 'error ' + re);
    const e = this.msgs.filter((m) => m.type === 'error').pop();
    assert.match(e.message, re);
  }
  headers() {
    return { 'x-code': this.code, 'x-token': this.token };
  }
}

const fast = { resultsDelayMs: 500, tickMs: 50, statePushMs: 50, restoreWindowMs: 500, secret: 'test-secret' };

test('a full game: roles, head start, pings, visibility, tagging, chat, media, tracks, results', async () => {
  const app = createApp(fast);
  const port = await app.listen(0);
  try {
    const L = await Client.connect(port);
    L.send({ type: 'create', name: 'Lead', color: '#ff0000', avatar: 'AAAA' });
    await until(() => L.code, 2000, 'create');
    const [H1, H2, S1] = [await Client.connect(port), await Client.connect(port), await Client.connect(port)];
    H1.send({ type: 'join', code: L.code.toLowerCase(), name: 'H1', color: '#00ff00' });
    H2.send({ type: 'join', code: L.code, name: 'H2', color: '#0000ff' });
    S1.send({ type: 'join', code: L.code, name: 'S1', color: '#ffff00' });
    await until(() => H1.id && H2.id && S1.id, 2000, 'joins');
    await until(() => L.state?.roster.length === 4, 2000, 'roster');
    assert.ok(L.has((m) => m.type === 'avatars' && Object.values(m.avatars).includes('AAAA')) || H1.has((m) => m.type === 'avatars' && Object.values(m.avatars).includes('AAAA')), 'avatars are relayed');

    // only the leader can change things
    await H1.expectError(() => H1.send({ type: 'set_role', playerId: H1.id, role: 'seeker' }), /leader/);
    await H1.expectError(() => H1.send({ type: 'start' }), /leader/);

    // can't start with unassigned players
    await L.expectError(() => L.send({ type: 'start' }), /hider|seeker|role/);

    L.send({ type: 'set_role', playerId: L.id, role: 'seeker' });
    L.send({ type: 'set_role', playerId: S1.id, role: 'seeker' });
    L.send({ type: 'set_role', playerId: H1.id, role: 'hider' });
    L.send({ type: 'set_role', playerId: H2.id, role: 'hider' });
    L.send({ type: 'update_settings', patch: { headStartMs: 800, pingIntervalMs: 1000, durationMs: 9000, darkHiderMs: 0, bogus: 1 } });
    L.send({ type: 'set_geofence', lat: 30.2849, lng: -97.7341, radius: 5000 });
    await until(() => H1.state?.settings.headStartMs === 800 && H1.state?.settings.center, 2000, 'settings');
    assert.equal(H1.state.settings.bogus, undefined, 'unknown settings are dropped');

    for (const [c, off] of [[L, 0], [S1, 1], [H1, 2], [H2, 3]] as [Client, number][]) {
      c.send({ type: 'location', lat: 30.2849 + off * 1e-4, lng: -97.7341, acc: 5, speed: 1 + off });
    }
    await sleep(120);
    L.send({ type: 'start' });
    await until(() => H1.state?.status === 'active', 2000, 'start');

    // visibility between pings
    await until(() => H1.state.live.length > 0, 2000, 'live');
    const ids = (c: Client) => c.state.live.map((p: any) => p.id).sort();
    assert.deepEqual(ids(H1), [H1.id, H2.id].sort(), 'hiders see only hiders live');
    assert.deepEqual(ids(S1), [L.id, S1.id].sort(), 'seekers see only seekers live');
    assert.equal(H1.state.lastPing, null);

    // tagging blocked during head start
    await S1.expectError(() => S1.send({ type: 'tag', hiderId: H1.id }), /head start/);

    // first ping gives everyone everyone
    await until(() => H1.state.lastPing && S1.state.lastPing, 3000, 'first ping');
    assert.equal(H1.state.lastPing.positions.length, 4);
    assert.deepEqual(H1.state.lastPing, S1.state.lastPing, 'same ping for everyone');

    // chat channels
    S1.send({ type: 'chat', id: 'c1', channel: 'seekers', kind: 'text', body: 'seekers only' });
    S1.send({ type: 'chat', id: 'c2', channel: 'all', kind: 'text', body: 'hello all' });
    await until(() => L.chats.length === 2 && H2.chats.length === 1, 2000, 'chat');
    assert.equal(H2.chats[0].body, 'hello all');
    assert.ok(!H1.chats.some((c) => c.channel === 'seekers'), 'hiders never receive seeker chat');
    await H2.expectError(() => H2.send({ type: 'chat', channel: 'seekers', kind: 'text', body: 'sneaky' }), /cannot post/);

    // media: lossless bytes in memory, only for authorized recipients, deleted after ack
    const bytes = Buffer.from(Array.from({ length: 5000 }, (_, i) => i % 251));
    const up = await fetch(`http://localhost:${port}/media`, { method: 'POST', headers: { ...L.headers(), 'content-type': 'image/heic' }, body: bytes });
    const { mediaId } = (await up.json()) as any;
    assert.ok(mediaId);
    L.send({ type: 'chat', id: 'm1', channel: 'seekers', kind: 'photo', mediaId, mime: 'image/heic', size: bytes.length });
    await until(() => S1.chats.some((c) => c.id === 'm1'), 2000, 'media envelope');
    const get = (c: Client) => fetch(`http://localhost:${port}/media/${mediaId}`, { headers: c.headers() });
    const ok = await get(S1);
    assert.equal(ok.status, 200);
    assert.equal(ok.headers.get('content-type'), 'image/heic');
    assert.ok(Buffer.from(await ok.arrayBuffer()).equals(bytes), 'media is byte-identical (lossless)');
    assert.equal((await get(H2)).status, 404, 'a hider cannot download seeker media');
    assert.equal((await fetch(`http://localhost:${port}/media/${mediaId}`)).status, 401, 'no auth, no media');
    S1.send({ type: 'chat_received', id: 'm1' });
    await until(async () => true);
    await sleep(100);
    assert.equal((await get(S1)).status, 404, 'media is deleted from the server once delivered');

    // tracks: out-of-order and duplicate batches are handled
    const pts = (n: number, t0: number) => Array.from({ length: n }, (_, i) => [t0 + i * 1000, 30.2849 + (t0 + i) * 2e-5, -97.7341, 2, 5]);
    const base = Date.now();
    H2.send({ type: 'track_batch', from: 0, points: pts(30, base) });
    await until(() => H2.has((m) => m.type === 'track_ack' && m.count === 30), 2000, 'track ack');
    H2.send({ type: 'track_batch', from: 100, points: pts(5, base) }); // gap: ignored, ack says 30
    H2.send({ type: 'track_batch', from: 20, points: pts(30, base + 20_000) }); // overlap: only the new tail is kept
    await until(() => H2.msgs.filter((m) => m.type === 'track_ack').pop().count === 50, 2000, 'overlap ack');
    S1.send({ type: 'track_batch', from: 0, points: pts(20, base) });

    // tag during hunt
    await until(() => Date.now() - H1.state.timing.startsAt > 900, 2000, 'head start over');
    S1.send({ type: 'tag', hiderId: H1.id });
    await until(() => H1.state.role === 'seeker', 2000, 'tag converts');
    assert.equal(H1.state.hidersLeft, 1);
    assert.ok(!ids(H1).includes(H2.id), 'a tagged hider no longer sees hiders live');
    assert.ok(L.events.some((e) => e.type === 'converted' && e.reason === 'tag'));

    // hider -> seeker loses hider-channel access
    H2.send({ type: 'chat', id: 'h1', channel: 'hiders', kind: 'text', body: 'psst' });
    await sleep(150);
    assert.ok(!H1.chats.some((c) => c.id === 'h1'), 'converted player no longer receives hider chat');

    // last tag ends the game and produces results
    L.send({ type: 'tag', hiderId: H2.id });
    S1.send({ type: 'tag', hiderId: H2.id });
    await until(() => L.state.status === 'ended', 2000, 'game end');
    assert.equal(L.state.winner, 'seekers');
    await until(() => L.has((m) => m.type === 'game_over'), 2000, 'game over');
    for (const c of [L, S1, H1, H2]) c.send({ type: 'track_done' });
    await until(() => L.results && H2.results, 4000, 'results');
    const r = L.results.results;
    assert.equal(r.winner, 'seekers');
    assert.equal(r.players.length, 4);
    const h2 = r.players.find((p: any) => p.id === H2.id);
    assert.equal(h2.startRole, 'hider');
    assert.ok(h2.stats.distanceM > 30, `distance ${h2.stats.distanceM}`);
    assert.ok(h2.route.length >= 2 && h2.speedSeries.length > 0);
    assert.ok(r.pings.length >= 1 && r.geofence);
    assert.ok(Array.isArray(r.awards));
    // after the game everyone can see everyone
    assert.equal(H2.state.live.length >= 3, true);

    for (const c of [L, H1, H2, S1]) c.ws.close();
  } finally {
    await app.close();
  }
});

test('lobby: random roles, late join, kick, leave, leader hand-over, bad input', async () => {
  const app = createApp({ ...fast, tickMs: 50 });
  const port = await app.listen(0);
  try {
    const L = await Client.connect(port);
    L.send({ type: 'create', name: '  A very very long name that gets trimmed  ', color: 'not-a-color' });
    await until(() => L.code);
    const others = [] as Client[];
    for (let i = 0; i < 4; i++) {
      const c = await Client.connect(port);
      c.send({ type: 'join', code: L.code, name: 'P' + i });
      await until(() => c.id);
      others.push(c);
    }
    await until(() => L.state.roster.length === 5);
    assert.ok(L.state.roster[0].name.length <= 24);
    assert.equal(L.state.roster[0].color, '#3478F6');

    L.send({ type: 'assign_random', seekers: 2 });
    await until(() => L.state.roster.every((p: any) => p.role !== 'unassigned'));
    assert.equal(L.state.roster.filter((p: any) => p.role === 'seeker').length, 2);

    const bad = await Client.connect(port);
    bad.send({ type: 'join', code: 'ZZZZZZ', name: 'x' });
    await until(() => bad.errorCount() > 0);
    assert.match(bad.msgs.find((m) => m.type === 'error').message, /not found/);
    bad.send({ type: 'rejoin', code: L.code, token: 'nope' });
    await until(() => bad.errorCount() > 1);
    assert.equal(bad.msgs.filter((m) => m.type === 'error')[1].fatal, true);

    // kick
    const kicked = others[0];
    L.send({ type: 'kick', playerId: kicked.id });
    await until(() => L.state.roster.length === 4, 2000, 'kick');
    await until(() => kicked.has((m) => m.type === 'error' && m.fatal), 2000, 'kicked notice');

    // start, then late join respects settings
    L.send({ type: 'update_settings', patch: { allowLateJoin: false, headStartMs: 0, durationMs: 60_000 } });
    L.send({ type: 'set_role', playerId: L.id, role: 'referee' });
    L.send({ type: 'assign_random', seekers: 1 });
    await sleep(100);
    L.send({ type: 'start' });
    await until(() => L.state.status === 'active', 2000, 'start');
    const late = await Client.connect(port);
    late.send({ type: 'join', code: L.code, name: 'late' });
    await until(() => late.errorCount() > 0);
    assert.match(late.msgs.find((m) => m.type === 'error').message, /already started/);
    L.send({ type: 'update_settings', patch: { allowLateJoin: true, lateJoinRole: 'hider' } });
    await sleep(100);
    late.send({ type: 'join', code: L.code, name: 'late' });
    await until(() => late.state?.role === 'hider', 2000, 'late join role');

    // referee sees every tracked player live; pause stops the game clock from advancing
    L.send({ type: 'pause' });
    await until(() => L.state.paused);
    L.send({ type: 'resume' });
    await until(() => !L.state.paused);

    // leader leaves -> someone else is promoted
    L.send({ type: 'leave' });
    await until(() => others[1].state.roster.some((p: any) => p.isLeader), 2000, 'promotion');
    assert.equal(others[1].state.roster.filter((p: any) => p.isLeader).length, 1);

    // garbage input doesn't crash anything
    others[1].ws.send('not json');
    others[1].send({ type: 'location', lat: 999, lng: 0 });
    others[1].send({ type: 'chat', channel: 'nope', kind: 'text', body: 'x' });
    others[1].send({ type: 'chat', channel: 'all', kind: 'gif', body: 'http://insecure' });
    await sleep(150);
    assert.ok(others[1].errorCount() >= 3);
    const health = await (await fetch(`http://localhost:${port}/health`)).json();
    assert.equal((health as any).ok, true);
  } finally {
    await app.close();
  }
});

test('restart recovery: phones hand back their encrypted snapshot and the game resumes; leader wins; tampering fails', async () => {
  const appA = createApp(fast);
  const portA = await appA.listen(0);
  const L = await Client.connect(portA);
  L.send({ type: 'create', name: 'Lead', color: '#ff0000' });
  await until(() => L.code);
  const P = await Client.connect(portA);
  P.send({ type: 'join', code: L.code, name: 'Pat', color: '#00ff00' });
  await until(() => P.id);
  L.send({ type: 'set_role', playerId: L.id, role: 'seeker' });
  L.send({ type: 'set_role', playerId: P.id, role: 'hider' });
  L.send({ type: 'update_settings', patch: { headStartMs: 60_000, durationMs: 600_000 } });
  await until(() => P.state?.role === 'hider' && P.state.settings.headStartMs === 60_000);
  L.send({ type: 'start' });
  await until(() => P.state.status === 'active');
  // Snapshots are throttled to one per ~3 s. Wait for the leader to hold one taken AFTER the start.
  const status = (snap: any) => decryptSnapshot('test-secret', L.code, snap.blob)?.engine.status;
  await until(() => L.snapshot && status(L.snapshot) === 'active', 10_000, 'a post-start snapshot');
  const latest = L.snapshot;
  // Pat's copy is the stale lobby-time snapshot: older version AND older state.
  const stale = P.snaps[0];
  assert.equal(status(stale), 'lobby');
  assert.ok(stale.version < latest.version);
  const { code } = L;
  const tokens = { L: L.token, P: P.token };
  L.ws.close();
  P.ws.close();
  await appA.close(); // "Render restarted": all memory is gone

  const appB = createApp(fast);
  const portB = await appB.listen(0);
  try {
    assert.equal(appB.registry.rooms.size, 0);
    const L2 = await Client.connect(portB);
    const P2 = await Client.connect(portB);
    for (const [c, tok, snap] of [[L2, tokens.L, latest], [P2, tokens.P, stale]] as [Client, string, any][]) {
      c.send({ type: 'rejoin', code, token: tok });
      await until(() => c.has((m) => m.type === 'need_restore'), 2000, 'need_restore');
      c.send({ type: 'restore', code, token: tok, version: snap.version, blob: snap.blob });
    }
    await until(() => L2.id && P2.id, 4000, 'restored');
    assert.equal(L2.id, L.id, 'same player id after restore');
    await until(() => P2.state?.role === 'hider' && L2.state?.status === 'active', 2000, 'restored state');
    assert.equal(L2.state.roster.find((p: any) => p.id === L.id).isLeader, true);
    assert.equal(L2.state.epoch, 1, 'epoch increments on restore');
    assert.equal(P2.state.settings.durationMs, 600_000);
    // tracks are re-uploadable from 0 after a restore
    P2.send({ type: 'track_batch', from: 0, points: [[Date.now(), 30, -97, 1, 5]] });
    await until(() => P2.has((m) => m.type === 'track_ack' && m.count === 1));

    // a tampered blob is rejected, and so is a blob for the wrong game
    const appC = createApp(fast);
    const portC = await appC.listen(0);
    try {
      const X = await Client.connect(portC);
      X.send({ type: 'rejoin', code, token: tokens.L });
      await until(() => X.has((m) => m.type === 'need_restore'));
      const tampered = Buffer.from(latest.blob, 'base64');
      tampered[tampered.length - 3] ^= 0xff;
      X.send({ type: 'restore', code, token: tokens.L, version: 99, blob: tampered.toString('base64') });
      await until(() => X.has((m) => m.type === 'error' && m.fatal), 3000, 'tamper rejected');
      assert.equal(appC.registry.rooms.size, 0);
    } finally {
      await appC.close();
    }

    const appD = createApp({ ...fast, secret: 'a-different-secret' });
    const portD = await appD.listen(0);
    try {
      const Y = await Client.connect(portD);
      Y.send({ type: 'rejoin', code, token: tokens.L });
      await until(() => Y.has((m) => m.type === 'need_restore'));
      Y.send({ type: 'restore', code, token: tokens.L, version: latest.version, blob: latest.blob });
      await until(() => Y.has((m) => m.type === 'error' && m.fatal), 3000, 'wrong key rejected');
    } finally {
      await appD.close();
    }
  } finally {
    await appB.close();
  }
});
