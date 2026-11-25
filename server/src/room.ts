import { createCipheriv, createDecipheriv, createHash, hkdfSync, randomBytes, randomInt } from 'node:crypto';
import type { WebSocket } from 'ws';
import { GameEngine, type Role } from './engine';
import type { Departed, TrackPoint } from './stats';

// No 0/O, 1/I/L so codes are easy to read aloud.
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

export const sha = (t: string) => createHash('sha256').update(t).digest('hex');

export type Channel = 'all' | 'seekers' | 'hiders';
export const CHANNELS: Channel[] = ['all', 'seekers', 'hiders'];
export const canRead = (role: Role, ch: Channel) =>
  ch === 'all' || (ch === 'seekers' && (role === 'seeker' || role === 'referee')) || (ch === 'hiders' && (role === 'hider' || role === 'referee'));

export interface Envelope {
  id: string;
  channel: Channel;
  senderId: string;
  kind: 'text' | 'photo' | 'video' | 'gif';
  body?: string;
  mediaId?: string;
  mime?: string;
  size?: number;
  at: number;
}

export interface Member {
  id: string;
  tokenHash: string;
  socket?: WebSocket;
  avatar?: string; // base64 JPEG, in memory only, never snapshotted
  joinedAt: number;
  disconnectedAt: number;
  trackDone: boolean;
}

export const TEXT_TTL_MS = 10 * 60_000;
export const MEDIA_TTL_MS = 20 * 60_000;
export const MAX_FILE_BYTES = 150 * 1024 * 1024;
export const MAX_TOTAL_MEDIA_BYTES = 200 * 1024 * 1024;

interface Queued {
  env: Envelope;
  pending: Set<string>;
  expires: number;
}
interface StoredMedia {
  buf: Buffer;
  mime: string;
  owner: string;
  pending: Set<string> | null; // null until the chat message that references it is sent
  expires: number;
}

export class Room {
  readonly members = new Map<string, Member>();
  readonly tracks = new Map<string, TrackPoint[]>();
  readonly departed = new Map<string, Departed>();
  readonly queue = new Map<string, Queued>();
  readonly media = new Map<string, StoredMedia>();
  mediaBytes = 0;
  epoch = 0;
  version = 0;
  lastActivity: number;
  lastStatePush = 0;
  lastSnapshotAt = 0;
  stateDirty = true;
  snapshotDirty = true;
  resultsVersion = 0;
  resultsTimer?: NodeJS.Timeout;
  endedHandled = false;
  results?: unknown;

  constructor(readonly code: string, readonly engine: GameEngine, readonly now: () => number = Date.now) {
    this.lastActivity = now();
  }

  // ---- members & sockets ----------------------------------------------------

  isConnected(id: string): boolean {
    const m = this.members.get(id);
    return !!m?.socket && m.socket.readyState === 1;
  }

  connectedIds(): string[] {
    return [...this.members.keys()].filter((id) => this.isConnected(id));
  }

  send(id: string, msg: unknown): void {
    const m = this.members.get(id);
    if (m?.socket && m.socket.readyState === 1) m.socket.send(JSON.stringify(msg));
  }

  broadcast(msg: unknown, except?: string): void {
    const s = JSON.stringify(msg);
    for (const m of this.members.values()) if (m.id !== except && m.socket && m.socket.readyState === 1) m.socket.send(s);
  }

  leaderId(): string | undefined {
    for (const p of this.engine.players.values()) if (p.isLeader) return p.id;
    return undefined;
  }

  stateFor(id: string) {
    const v = this.engine.viewFor(id);
    return {
      type: 'state',
      serverTime: this.now(),
      epoch: this.epoch,
      ...v,
      roster: v.roster.map((r) => ({ ...r, connected: this.isConnected(r.id) })),
    };
  }

  pushStates(): void {
    for (const id of this.connectedIds()) this.send(id, this.stateFor(id));
    this.lastStatePush = this.now();
    this.stateDirty = false;
  }

  avatars(): Record<string, string> {
    const out: Record<string, string> = {};
    for (const m of this.members.values()) if (m.avatar) out[m.id] = m.avatar;
    return out;
  }

  // ---- chat relay (transient, in memory only) -------------------------------

  postChat(env: Envelope): { ok: true } | { ok: false; error: string } {
    const sender = this.engine.players.get(env.senderId);
    if (!sender) return { ok: false, error: 'not in game' };
    if (!canRead(sender.role, env.channel)) return { ok: false, error: 'you cannot post in that channel' };
    let pending: Set<string>;
    pending = new Set();
    for (const p of this.engine.players.values()) if (p.id !== env.senderId && canRead(p.role, env.channel)) pending.add(p.id);
    if (env.mediaId) {
      const m = this.media.get(env.mediaId);
      if (!m || m.owner !== env.senderId) return { ok: false, error: 'media not found' };
      m.pending = new Set(pending);
      m.expires = this.now() + MEDIA_TTL_MS;
    }
    const ttl = env.mediaId ? MEDIA_TTL_MS : TEXT_TTL_MS;
    this.queue.set(env.id, { env, pending, expires: this.now() + ttl });
    for (const id of pending) if (this.isConnected(id)) this.send(id, { type: 'chat', msg: env });
    this.cleanupIfDelivered(env.id);
    return { ok: true };
  }

  /** Send queued envelopes to a (re)connected player, if they may still read them. */
  redeliver(id: string): void {
    const role = this.engine.players.get(id)?.role;
    if (!role) return;
    for (const q of this.queue.values()) {
      if (q.pending.has(id)) {
        if (canRead(role, q.env.channel)) this.send(id, { type: 'chat', msg: q.env });
        else q.pending.delete(id);
      }
    }
  }

  ackChat(id: string, envId: string): void {
    const q = this.queue.get(envId);
    if (!q) return;
    q.pending.delete(id);
    this.cleanupIfDelivered(envId);
  }

  private cleanupIfDelivered(envId: string): void {
    const q = this.queue.get(envId);
    if (!q || q.pending.size > 0) return;
    this.queue.delete(envId);
    if (q.env.mediaId) this.dropMedia(q.env.mediaId);
  }

  putMedia(owner: string, mime: string, buf: Buffer): string {
    const id = randomBytes(12).toString('hex');
    this.media.set(id, { buf, mime, owner, pending: null, expires: this.now() + 5 * 60_000 });
    this.mediaBytes += buf.length;
    return id;
  }

  /** Returns the media only to a recipient who is still waiting for it. */
  getMedia(mediaId: string, playerId: string): StoredMedia | undefined {
    const m = this.media.get(mediaId);
    if (!m || !m.pending || !m.pending.has(playerId)) return undefined;
    return m;
  }

  private dropMedia(id: string): void {
    const m = this.media.get(id);
    if (!m) return;
    this.mediaBytes -= m.buf.length;
    this.media.delete(id);
  }

  sweepRelay(): void {
    const t = this.now();
    for (const [id, q] of this.queue) if (t >= q.expires) {
      this.queue.delete(id);
      if (q.env.mediaId) this.dropMedia(q.env.mediaId);
    }
    for (const [id, m] of this.media) if (t >= m.expires) this.dropMedia(id);
  }

  /** Free everything held for this game. */
  wipe(): void {
    clearTimeout(this.resultsTimer);
    for (const id of [...this.media.keys()]) this.dropMedia(id);
    this.queue.clear();
    this.tracks.clear();
    for (const m of this.members.values()) m.avatar = undefined;
  }

  // ---- snapshots (encrypted, stored by the phones) ----------------------------

  snapshotPlain() {
    return {
      v: 1,
      code: this.code,
      version: this.version,
      epoch: this.epoch,
      engine: this.engine.toJSON(),
      members: [...this.members.values()].map((m) => ({ id: m.id, tokenHash: m.tokenHash, joinedAt: m.joinedAt })),
    };
  }
}

// ---- snapshot crypto -----------------------------------------------------------

function keyFor(secret: string, code: string): Buffer {
  return Buffer.from(hkdfSync('sha256', secret, code, 'hidenseek-snapshot-v1', 32));
}

export function encryptSnapshot(secret: string, code: string, data: unknown): string {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', keyFor(secret, code), iv);
  const enc = Buffer.concat([c.update(JSON.stringify(data), 'utf8'), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), enc]).toString('base64');
}

export function decryptSnapshot(secret: string, code: string, blob: string): any | null {
  try {
    const raw = Buffer.from(blob, 'base64');
    const d = createDecipheriv('aes-256-gcm', keyFor(secret, code), raw.subarray(0, 12));
    d.setAuthTag(raw.subarray(12, 28));
    return JSON.parse(Buffer.concat([d.update(raw.subarray(28)), d.final()]).toString('utf8'));
  } catch {
    return null; // tampered, wrong key, or garbage
  }
}

// ---- registry --------------------------------------------------------------------

export class Registry {
  readonly rooms = new Map<string, Room>();
  constructor(readonly now: () => number = Date.now) {}

  private newCode(): string {
    for (;;) {
      let c = '';
      for (let i = 0; i < 6; i++) c += ALPHABET[randomInt(ALPHABET.length)];
      if (!this.rooms.has(c)) return c;
    }
  }

  create(): Room {
    const room = new Room(this.newCode(), new GameEngine(this.now), this.now);
    this.rooms.set(room.code, room);
    return room;
  }

  get(code: string): Room | undefined {
    return this.rooms.get(code.toUpperCase());
  }

  totalMediaBytes(): number {
    let n = 0;
    for (const r of this.rooms.values()) n += r.mediaBytes;
    return n;
  }

  /** Rebuild a room from a decrypted snapshot (after a server restart). */
  restore(plain: any): Room {
    const engine = GameEngine.fromJSON(plain.engine, this.now);
    engine.resetTimersAfterRestore();
    const room = new Room(plain.code, engine, this.now);
    room.epoch = (plain.epoch ?? 0) + 1;
    room.version = (plain.version ?? 0) + 1;
    for (const m of plain.members as { id: string; tokenHash: string; joinedAt: number }[]) {
      room.members.set(m.id, { id: m.id, tokenHash: m.tokenHash, joinedAt: m.joinedAt, disconnectedAt: this.now(), trackDone: false });
    }
    this.rooms.set(room.code, room);
    return room;
  }

  sweep(maxIdleMs = 30 * 60_000): void {
    const t = this.now();
    for (const [code, r] of this.rooms) {
      const ended = r.engine.status === 'ended' && t - r.engine.endedAt > maxIdleMs;
      const idle = r.connectedIds().length === 0 && t - r.lastActivity > maxIdleMs;
      if (ended || idle) {
        r.wipe();
        this.rooms.delete(code);
      }
    }
  }
}
