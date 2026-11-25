import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { WebSocketServer, type WebSocket } from 'ws';
import { sanitizeSettings, type GameEvent, type Role } from './engine';
import {
  CHANNELS,
  MAX_FILE_BYTES,
  MAX_TOTAL_MEDIA_BYTES,
  Registry,
  decryptSnapshot,
  encryptSnapshot,
  sha,
  type Channel,
  type Envelope,
  type Member,
  type Room,
} from './room';
import { buildResults } from './stats';

export interface AppOptions {
  secret?: string; // key for encrypting restart snapshots (set SNAPSHOT_SECRET on Render!)
  giphyKey?: string;
  resultsDelayMs?: number; // how long to wait for phones to flush their tracks after a game ends
  restoreWindowMs?: number; // how long to collect snapshots from phones after a server restart
  tickMs?: number;
  statePushMs?: number;
  now?: () => number;
}

interface Conn {
  room?: Room;
  member?: Member;
  alive: boolean;
  ip: string;
  lastLocAt: number;
}

interface Entry {
  ws: WebSocket;
  token: string;
  version: number;
  blob?: string;
  avatar?: string;
}

const COLOR = /^#[0-9a-fA-F]{6}$/;
const ROLES: Role[] = ['unassigned', 'hider', 'seeker', 'referee'];
const MAX_PLAYERS = 50;

const cleanName = (v: unknown) => (typeof v === 'string' ? v.trim().slice(0, 24) : '') || 'Player';
const cleanColor = (v: unknown) => (typeof v === 'string' && COLOR.test(v) ? v : '#3478F6');
const cleanAvatar = (v: unknown) => (typeof v === 'string' && v.length > 0 && v.length <= 60_000 ? v : undefined);
const num = (v: unknown, min: number, max: number) => (typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max ? v : null);
const rid = (n = 6) => randomBytes(n).toString('hex');

export function createApp(opts: AppOptions = {}) {
  const now = opts.now ?? Date.now;
  const secret = opts.secret ?? process.env.SNAPSHOT_SECRET ?? randomBytes(32).toString('hex');
  if (!opts.secret && !process.env.SNAPSHOT_SECRET) {
    console.warn('SNAPSHOT_SECRET is not set: restart recovery will not work across restarts.');
  }
  const giphyKey = opts.giphyKey ?? process.env.GIPHY_API_KEY;
  const resultsDelay = opts.resultsDelayMs ?? 15_000;
  const restoreWindow = opts.restoreWindowMs ?? 6_000;
  const statePushMs = opts.statePushMs ?? 2_000;
  const registry = new Registry(now);
  const conns = new WeakMap<WebSocket, Conn>();
  const pendingRestores = new Map<string, { entries: Map<WebSocket, Entry>; timer: NodeJS.Timeout }>();
  const hits = new Map<string, { n: number; reset: number }>();

  const rateLimited = (ip: string) => {
    const t = now();
    const h = hits.get(ip);
    if (!h || t > h.reset) {
      hits.set(ip, { n: 1, reset: t + 60_000 });
      return false;
    }
    return ++h.n > 60;
  };

  const sendTo = (ws: WebSocket, msg: unknown) => {
    if (ws.readyState === 1) ws.send(JSON.stringify(msg));
  };
  const fail = (ws: WebSocket, message: string, fatal = false) => sendTo(ws, { type: 'error', message, fatal });

  // ---- shared helpers ----------------------------------------------------------

  function attach(ws: WebSocket, conn: Conn, room: Room, member: Member) {
    if (conn.member && conn.member !== member && conn.member.socket === ws) {
      conn.member.socket = undefined;
      conn.room?.pushStates();
    }
    if (member.socket && member.socket !== ws) member.socket.close(4000, 'replaced');
    member.socket = ws;
    member.disconnectedAt = 0;
    conn.room = room;
    conn.member = member;
    room.lastActivity = now();
  }

  function sendSnapshot(room: Room, only?: string) {
    if (room.engine.status === 'ended') return;
    room.version++;
    const blob = encryptSnapshot(secret, room.code, room.snapshotPlain());
    const msg = { type: 'snapshot', version: room.version, blob };
    if (only) room.send(only, msg);
    else room.broadcast(msg);
    room.lastSnapshotAt = now();
    room.snapshotDirty = false;
  }

  function enter(ws: WebSocket, conn: Conn, room: Room, member: Member, token: string) {
    attach(ws, conn, room, member);
    sendTo(ws, { type: 'joined', code: room.code, playerId: member.id, token, epoch: room.epoch });
    sendTo(ws, { type: 'avatars', avatars: room.avatars() });
    if (member.avatar) room.broadcast({ type: 'avatars', avatars: { [member.id]: member.avatar } }, member.id);
    room.pushStates();
    room.redeliver(member.id);
    room.snapshotDirty = true;
  }

  function recordDeparture(room: Room, id: string) {
    const p = room.engine.players.get(id);
    if (p && room.engine.status !== 'lobby' && p.role !== 'referee') {
      room.departed.set(id, {
        name: p.name,
        color: p.color,
        startRole: p.startRole ?? p.role,
        finalRole: p.role,
        convertedAt: p.convertedAt,
        leftAt: now(),
      });
    }
  }

  function removeMember(room: Room, id: string, reason?: string) {
    recordDeparture(room, id);
    const wasLeader = room.leaderId() === id;
    const m = room.members.get(id);
    const events = room.engine.removePlayer(id);
    room.members.delete(id);
    if (m?.socket) {
      if (reason) sendTo(m.socket, { type: 'error', message: reason, fatal: true });
      m.socket.close(4001, reason ?? 'left');
    }
    if (wasLeader) promoteLeader(room);
    emit(room, events);
    room.stateDirty = true;
    room.pushStates();
    room.snapshotDirty = true;
  }

  function promoteLeader(room: Room) {
    const next = [...room.members.values()].filter((m) => room.isConnected(m.id)).sort((a, b) => a.joinedAt - b.joinedAt)[0];
    if (next) {
      room.engine.setLeader(next.id);
      room.stateDirty = true;
    }
  }

  function emit(room: Room, events: GameEvent[]) {
    if (!events.length) return;
    for (const e of events) room.broadcast({ type: 'event', event: e });
    room.pushStates();
    room.snapshotDirty = true;
    if (events.some((e) => e.type === 'ended') && !room.endedHandled) onEnded(room);
  }

  function onEnded(room: Room) {
    room.endedHandled = true;
    for (const m of room.members.values()) m.trackDone = false;
    room.broadcast({ type: 'game_over', winner: room.engine.winner });
    room.resultsTimer = setTimeout(() => sendResults(room), resultsDelay);
  }

  function sendResults(room: Room) {
    clearTimeout(room.resultsTimer);
    room.results = buildResults({ engine: room.engine, tracks: room.tracks, departed: room.departed });
    room.resultsVersion++;
    room.broadcast({ type: 'results', version: room.resultsVersion, results: room.results });
  }

  function maybeSendResultsEarly(room: Room) {
    if (!room.endedHandled) return;
    const connected = room.connectedIds();
    if (connected.length && connected.every((id) => room.members.get(id)!.trackDone)) {
      clearTimeout(room.resultsTimer);
      room.resultsTimer = setTimeout(() => sendResults(room), room.results ? 1500 : 200);
    }
  }

  // ---- entry: create / join / rejoin / restore ---------------------------------

  function admitNew(ws: WebSocket, conn: Conn, room: Room, name: string, color: string, avatar: string | undefined, leader: boolean) {
    const token = randomBytes(16).toString('hex');
    const id = rid();
    const member: Member = { id, tokenHash: sha(token), joinedAt: now(), disconnectedAt: 0, trackDone: false, avatar };
    room.engine.addPlayer(id, name, color, leader);
    room.members.set(id, member);
    if (room.engine.status === 'active') room.engine.setRole(id, room.engine.settings.lateJoinRole);
    enter(ws, conn, room, member, token);
  }

  function findMember(room: Room, token: string): Member | undefined {
    const h = sha(token);
    for (const m of room.members.values()) if (m.tokenHash === h) return m;
    return undefined;
  }

  function queueRestore(ws: WebSocket, code: string, entry: Entry) {
    let p = pendingRestores.get(code);
    if (!p) {
      p = { entries: new Map(), timer: setTimeout(() => finalizeRestore(code), restoreWindow) };
      pendingRestores.set(code, p);
    }
    p.entries.set(ws, entry);
    sendTo(ws, { type: 'need_restore', code });
  }

  function finalizeRestore(code: string) {
    const p = pendingRestores.get(code);
    pendingRestores.delete(code);
    if (!p) return;
    const entries = [...p.entries.values()].filter((e) => e.ws.readyState === 1);
    if (registry.get(code)) return; // someone else already restored it
    // Candidates: valid snapshot whose owner (by token) is inside it. Leader's snapshot wins; otherwise highest version.
    let best: { plain: any; version: number; leader: boolean } | undefined;
    for (const e of entries) {
      if (!e.blob) continue;
      const plain = decryptSnapshot(secret, code, e.blob);
      if (!plain || plain.code !== code) continue;
      const me = (plain.members as { id: string; tokenHash: string }[]).find((m) => m.tokenHash === sha(e.token));
      if (!me) continue;
      const leader = !!(plain.engine.players as { id: string; isLeader: boolean }[]).find((pl) => pl.id === me.id)?.isLeader;
      const cand = { plain, version: plain.version as number, leader };
      if (!best || (cand.leader && !best.leader) || (cand.leader === best.leader && cand.version > best.version)) best = cand;
    }
    if (!best) {
      for (const e of entries) fail(e.ws, 'game lost', true);
      return;
    }
    const room = registry.restore(best.plain);
    for (const e of entries) {
      const conn = conns.get(e.ws);
      const member = findMember(room, e.token);
      if (!conn || !member) {
        fail(e.ws, 'cannot rejoin', true);
        continue;
      }
      if (e.avatar) member.avatar = e.avatar;
      enter(e.ws, conn, room, member, e.token);
    }
    console.log(`restored game ${code} (v${best.version}, epoch ${room.epoch}) from ${entries.length} phone(s)`);
  }

  function handleEntry(ws: WebSocket, conn: Conn, m: any): boolean {
    if (m.type !== 'create' && m.type !== 'join' && m.type !== 'rejoin' && m.type !== 'restore') return false;
    if (rateLimited(conn.ip)) {
      fail(ws, 'too many requests, slow down');
      return true;
    }
    const avatar = cleanAvatar(m.avatar);
    switch (m.type) {
      case 'create': {
        admitNew(ws, conn, registry.create(), cleanName(m.name), cleanColor(m.color), avatar, true);
        return true;
      }
      case 'join': {
        const room = typeof m.code === 'string' ? registry.get(m.code) : undefined;
        if (!room) return fail(ws, 'game not found'), true;
        if (room.engine.status === 'ended') return fail(ws, 'that game has ended'), true;
        if (room.engine.status === 'active' && !room.engine.settings.allowLateJoin) return fail(ws, 'game already started'), true;
        if (room.members.size >= MAX_PLAYERS) return fail(ws, 'game is full'), true;
        admitNew(ws, conn, room, cleanName(m.name), cleanColor(m.color), avatar, false);
        return true;
      }
      default: {
        // rejoin / restore: both carry code + token. 'restore' also carries a snapshot.
        if (typeof m.code !== 'string' || typeof m.token !== 'string') return fail(ws, 'cannot rejoin', true), true;
        const code = m.code.toUpperCase();
        const room = registry.get(code);
        if (room) {
          const member = findMember(room, m.token);
          if (!member) return fail(ws, 'cannot rejoin', true), true;
          if (avatar) member.avatar = avatar;
          enter(ws, conn, room, member, m.token);
          return true;
        }
        const entry: Entry = {
          ws,
          token: m.token,
          version: typeof m.version === 'number' ? m.version : 0,
          blob: m.type === 'restore' && typeof m.blob === 'string' && m.blob.length < 900_000 ? m.blob : undefined,
          avatar,
        };
        const pending = pendingRestores.get(code);
        const existing = pending?.entries.get(ws);
        if (existing && !entry.blob) entry.blob = existing.blob; // keep a blob we already received
        queueRestore(ws, code, entry);
        return true;
      }
    }
  }

  // ---- in-game commands -----------------------------------------------------------

  function handle(ws: WebSocket, conn: Conn, m: any) {
    if (m.type === 'ping') return sendTo(ws, { type: 'pong', t: now() });
    if (handleEntry(ws, conn, m)) return;
    const { room, member } = conn;
    if (!room || !member) return;
    room.lastActivity = now();
    const eng = room.engine;
    const me = eng.players.get(member.id);
    if (!me) return;
    const needLeader = () => {
      if (!me.isLeader) throw new Error('only the leader can do that');
    };

    try {
      switch (m.type) {
        case 'location': {
          const t = now();
          if (t - conn.lastLocAt < 400) return;
          const lat = num(m.lat, -90, 90);
          const lng = num(m.lng, -180, 180);
          if (lat === null || lng === null) return;
          conn.lastLocAt = t;
          const events = eng.onLocation(member.id, { lat, lng, acc: num(m.acc, 0, 1e5) ?? 0, speed: num(m.speed, 0, 200) ?? 0 });
          room.stateDirty = true;
          return emit(room, events);
        }
        case 'track_batch': {
          const pts: unknown = m.points;
          const from = num(m.from, 0, 1e7);
          if (!Array.isArray(pts) || from === null || pts.length > 600) return;
          const track = room.tracks.get(member.id) ?? [];
          room.tracks.set(member.id, track);
          if (from <= track.length) {
            const fresh = (pts as number[][]).slice(track.length - from).filter((p) => Array.isArray(p) && p.length >= 5 && p.every((x) => typeof x === 'number'));
            if (track.length + fresh.length <= 20_000) track.push(...fresh);
          }
          return sendTo(ws, { type: 'track_ack', epoch: room.epoch, count: track.length });
        }
        case 'track_done':
          member.trackDone = true;
          return maybeSendResultsEarly(room);
        case 'get_results':
          return room.results ? sendTo(ws, { type: 'results', version: room.resultsVersion, results: room.results }) : sendTo(ws, { type: 'results_pending' });
        case 'set_avatar': {
          const a = cleanAvatar(m.avatar);
          if (a) {
            member.avatar = a;
            room.broadcast({ type: 'avatars', avatars: { [member.id]: a } });
          }
          return;
        }
        case 'leave':
          return removeMember(room, member.id);

        // --- leader commands ---
        case 'set_role': {
          needLeader();
          if (!ROLES.includes(m.role) || !eng.players.has(m.playerId)) throw new Error('bad role');
          eng.setRole(m.playerId, m.role);
          break;
        }
        case 'assign_random': {
          needLeader();
          if (eng.status !== 'lobby') throw new Error('roles can only be randomized before the game starts');
          eng.assignRandom(Math.max(1, Math.min(MAX_PLAYERS, Math.floor(Number(m.seekers) || 1))));
          break;
        }
        case 'update_settings':
          needLeader();
          eng.updateSettings(sanitizeSettings(m.patch));
          break;
        case 'set_geofence': {
          needLeader();
          const lat = num(m.lat, -90, 90);
          const lng = num(m.lng, -180, 180);
          const radius = num(m.radius, 10, 50_000);
          if (lat === null || lng === null || radius === null) throw new Error('bad geofence');
          eng.updateSettings({ center: { lat, lng }, radiusM: radius });
          break;
        }
        case 'start': {
          needLeader();
          eng.start();
          for (const mm of room.members.values()) mm.trackDone = false;
          return emit(room, [{ type: 'started', at: eng.startsAt }]);
        }
        case 'end':
          needLeader();
          return emit(room, eng.endNow());
        case 'pause':
          needLeader();
          return emit(room, eng.pause());
        case 'resume':
          needLeader();
          return emit(room, eng.resume());
        case 'manual_ping':
          needLeader();
          return emit(room, eng.manualPing());
        case 'force_seeker':
          needLeader();
          return emit(room, eng.forceSeeker(String(m.playerId)));
        case 'kick': {
          needLeader();
          const target = String(m.playerId);
          if (target === member.id || !room.members.has(target)) throw new Error('bad target');
          return removeMember(room, target, 'You were removed from the game');
        }

        // --- tagging ---
        case 'tag':
          return emit(room, eng.tag(member.id, String(m.hiderId)));
        case 'self_tag':
          return emit(room, eng.selfTag(member.id));

        // --- chat ---
        case 'chat': {
          const s = eng.settings;
          if (!s.chatEnabled) throw new Error('chat is turned off');
          const kind = m.kind;
          if (!['text', 'photo', 'video', 'gif'].includes(kind)) throw new Error('bad message kind');
          if (!CHANNELS.includes(m.channel)) throw new Error('bad channel');
          if ((kind === 'photo' || kind === 'video') && (!s.mediaEnabled || typeof m.mediaId !== 'string')) throw new Error('media not allowed');
          if (kind === 'text' && (typeof m.body !== 'string' || !m.body.trim() || m.body.length > 2000)) throw new Error('bad text');
          if (kind === 'gif' && (typeof m.body !== 'string' || !/^https:\/\//.test(m.body) || m.body.length > 600)) throw new Error('bad gif');
          const id = typeof m.id === 'string' && m.id.length <= 64 ? m.id : rid(8);
          if (room.queue.has(id)) return sendTo(ws, { type: 'chat_ack', id }); // resend of an outbox message
          const env: Envelope = {
            id,
            channel: m.channel as Channel,
            senderId: member.id,
            kind,
            body: typeof m.body === 'string' ? m.body : undefined,
            mediaId: typeof m.mediaId === 'string' ? m.mediaId : undefined,
            mime: typeof m.mime === 'string' ? m.mime.slice(0, 80) : undefined,
            size: typeof m.size === 'number' ? m.size : undefined,
            at: now(),
          };
          const r = room.postChat(env);
          if (!r.ok) throw new Error(r.error);
          return sendTo(ws, { type: 'chat_ack', id });
        }
        case 'chat_received':
          return room.ackChat(member.id, String(m.id));
        default:
          return;
      }
      // set_role / assign_random / update_settings / set_geofence fall through to here
      room.stateDirty = true;
      room.pushStates();
      room.snapshotDirty = true;
    } catch (e: any) {
      fail(ws, e?.message ?? 'error');
    }
  }

  // ---- HTTP (health, media, gifs) ---------------------------------------------------

  function authHttp(req: http.IncomingMessage): { room: Room; member: Member } | null {
    const code = req.headers['x-code'];
    const token = req.headers['x-token'];
    if (typeof code !== 'string' || typeof token !== 'string') return null;
    const room = registry.get(code);
    const member = room && findMember(room, token);
    return room && member ? { room, member } : null;
  }

  const json = (res: http.ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) => {
    res.writeHead(status, { 'content-type': 'application/json', ...headers });
    res.end(JSON.stringify(body));
  };

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://x');
    try {
      if (url.pathname === '/health') {
        return json(res, 200, { ok: true, games: registry.rooms.size, uptime: Math.round(process.uptime()) });
      }
      if (url.pathname === '/media' && req.method === 'POST') {
        const a = authHttp(req);
        if (!a) return json(res, 401, { error: 'unauthorized' });
        if (!a.room.engine.settings.mediaEnabled) return json(res, 403, { error: 'media is turned off' });
        const len = Number(req.headers['content-length']);
        if (!Number.isFinite(len) || len <= 0) return json(res, 411, { error: 'content-length required' });
        if (len > MAX_FILE_BYTES) return json(res, 413, { error: 'file too large for the server' });
        if (registry.totalMediaBytes() + len > MAX_TOTAL_MEDIA_BYTES) return json(res, 503, { error: 'server busy, retry' }, { 'retry-after': '5' });
        const chunks: Buffer[] = [];
        let got = 0;
        req.on('data', (c: Buffer) => {
          got += c.length;
          if (got > len) return req.destroy();
          chunks.push(c);
        });
        req.on('end', () => {
          if (got !== len) return json(res, 400, { error: 'incomplete upload' });
          const mime = String(req.headers['content-type'] ?? 'application/octet-stream').slice(0, 80);
          json(res, 200, { mediaId: a.room.putMedia(a.member.id, mime, Buffer.concat(chunks)) });
        });
        return;
      }
      const dl = url.pathname.match(/^\/media\/([0-9a-f]{24})$/);
      if (dl && req.method === 'GET') {
        const a = authHttp(req);
        if (!a) return json(res, 401, { error: 'unauthorized' });
        const media = a.room.getMedia(dl[1], a.member.id);
        if (!media) return json(res, 404, { error: 'expired or not available' });
        res.writeHead(200, { 'content-type': media.mime, 'content-length': media.buf.length });
        return void res.end(media.buf);
      }
      if (url.pathname === '/gifs' && req.method === 'GET') {
        if (!authHttp(req)) return json(res, 401, { error: 'unauthorized' });
        if (!giphyKey) return json(res, 501, { error: 'GIPHY_API_KEY is not configured on the server' });
        const q = (url.searchParams.get('q') ?? '').trim().slice(0, 80);
        const api = q
          ? `https://api.giphy.com/v1/gifs/search?api_key=${giphyKey}&q=${encodeURIComponent(q)}&limit=24&rating=pg-13`
          : `https://api.giphy.com/v1/gifs/trending?api_key=${giphyKey}&limit=24&rating=pg-13`;
        const r = await fetch(api);
        if (!r.ok) return json(res, 502, { error: 'gif provider error' });
        const body: any = await r.json();
        const out = (body.data ?? []).map((g: any) => ({
          id: g.id,
          url: g.images?.fixed_height?.url,
          preview: g.images?.fixed_height_small_still?.url ?? g.images?.fixed_height?.url,
          w: Number(g.images?.fixed_height?.width) || 200,
          h: Number(g.images?.fixed_height?.height) || 200,
        }));
        return json(res, 200, { gifs: out.filter((g: any) => g.url) });
      }
      res.writeHead(404);
      res.end();
    } catch (e) {
      if (!res.headersSent) json(res, 500, { error: 'server error' });
    }
  });

  // ---- WebSocket ----------------------------------------------------------------------

  const wss = new WebSocketServer({ server, path: '/ws', maxPayload: 1024 * 1024 });
  wss.on('connection', (ws, req) => {
    const conn: Conn = { alive: true, ip: req.socket.remoteAddress ?? '?', lastLocAt: 0 };
    conns.set(ws, conn);
    ws.on('pong', () => (conn.alive = true));
    ws.on('message', (raw) => {
      let m: any;
      try {
        m = JSON.parse(raw.toString());
      } catch {
        return fail(ws, 'bad json');
      }
      if (m && typeof m.type === 'string') handle(ws, conn, m);
    });
    ws.on('close', () => {
      const { room, member } = conn;
      if (room && member && member.socket === ws) {
        member.socket = undefined;
        member.disconnectedAt = now();
        room.stateDirty = true;
        room.pushStates();
      }
    });
  });

  // ---- timers -----------------------------------------------------------------------------

  let ticks = 0;
  const tickTimer = setInterval(() => {
    ticks++;
    const t = now();
    for (const room of registry.rooms.values()) {
      emit(room, room.engine.tick());
      const leader = room.leaderId() ? room.members.get(room.leaderId()!) : undefined;
      if (leader && leader.disconnectedAt && t - leader.disconnectedAt > 120_000) promoteLeader(room);
      if (room.stateDirty && t - room.lastStatePush >= statePushMs) room.pushStates();
      if (room.engine.status !== 'ended' && room.connectedIds().length > 0) {
        if ((room.snapshotDirty && t - room.lastSnapshotAt >= 3000) || t - room.lastSnapshotAt >= 60_000) sendSnapshot(room);
      }
      room.sweepRelay();
    }
    if (ticks % 60 === 0) registry.sweep();
  }, opts.tickMs ?? 1000);

  // Heartbeat keeps proxies from idling the socket out and detects dead phones.
  const hb = setInterval(() => {
    for (const ws of wss.clients) {
      const c = conns.get(ws);
      if (!c) continue;
      if (!c.alive) {
        ws.terminate();
        continue;
      }
      c.alive = false;
      ws.ping();
    }
  }, 20_000);

  return {
    server,
    registry,
    listen: (port: number) =>
      new Promise<number>((resolve) => server.listen(port, () => resolve((server.address() as { port: number }).port))),
    close: () =>
      new Promise<void>((resolve) => {
        clearInterval(tickTimer);
        clearInterval(hb);
        for (const p of pendingRestores.values()) clearTimeout(p.timer);
        for (const r of registry.rooms.values()) clearTimeout(r.resultsTimer);
        for (const ws of wss.clients) ws.terminate();
        server.close(() => resolve());
        server.closeAllConnections?.();
      }),
  };
}
