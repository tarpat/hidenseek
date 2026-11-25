/**
 * Pure game rules for Hide n Seek. No sockets, no timers: callers feed in
 * time (via the clock) and locations, and call tick() regularly.
 * Everything here is deterministic given a clock and an RNG, so it is unit-tested.
 */

export type Role = 'unassigned' | 'hider' | 'seeker' | 'referee';
export type Status = 'lobby' | 'active' | 'ended';

export interface Settings {
  durationMs: number; // hunt length, counted AFTER the head start
  headStartMs: number; // hiders hide; 0 allowed
  pingIntervalMs: number;
  graceMs: number; // out-of-bounds grace period
  warnSeekers: boolean; // warn/ping seekers who leave the area (never converts them)
  darkHiderMs: number; // hider with no location this long becomes a seeker; 0 = off
  hiderSelfTag: boolean;
  center?: { lat: number; lng: number };
  radiusM: number;
  allowLateJoin: boolean;
  lateJoinRole: 'hider' | 'seeker';
  chatEnabled: boolean;
  mediaEnabled: boolean;
  showTeamSpeed: boolean; // teammates' live speed
  seekersSeeEachOther: boolean;
  awards: boolean;
}

export const DEFAULT_SETTINGS: Settings = {
  durationMs: 30 * 60_000,
  headStartMs: 5 * 60_000,
  pingIntervalMs: 5 * 60_000,
  graceMs: 60_000,
  warnSeekers: true,
  darkHiderMs: 2 * 60_000,
  hiderSelfTag: true,
  radiusM: 500,
  allowLateJoin: true,
  lateJoinRole: 'seeker',
  chatEnabled: true,
  mediaEnabled: true,
  showTeamSpeed: true,
  seekersSeeEachOther: true,
  awards: true,
};

/** Validate and clamp a settings patch from a client. Unknown keys are dropped. */
export function sanitizeSettings(p: any): Partial<Settings> {
  const out: any = {};
  if (!p || typeof p !== 'object') return out;
  const num = (k: string, min: number, max: number) => {
    if (typeof p[k] === 'number' && Number.isFinite(p[k])) out[k] = Math.min(max, Math.max(min, p[k]));
  };
  const bool = (k: string) => {
    if (typeof p[k] === 'boolean') out[k] = p[k];
  };
  num('durationMs', 1000, 6 * 3_600_000);
  num('headStartMs', 0, 3_600_000);
  num('pingIntervalMs', 1000, 3_600_000);
  num('graceMs', 0, 3_600_000);
  num('darkHiderMs', 0, 3_600_000);
  num('radiusM', 10, 50_000);
  for (const k of ['warnSeekers', 'hiderSelfTag', 'allowLateJoin', 'chatEnabled', 'mediaEnabled', 'showTeamSpeed', 'seekersSeeEachOther', 'awards']) bool(k);
  if (p.lateJoinRole === 'hider' || p.lateJoinRole === 'seeker') out.lateJoinRole = p.lateJoinRole;
  const c = p.center;
  if (c && typeof c.lat === 'number' && typeof c.lng === 'number' && Math.abs(c.lat) <= 90 && Math.abs(c.lng) <= 180) {
    out.center = { lat: c.lat, lng: c.lng };
  }
  return out;
}

export interface Loc {
  lat: number;
  lng: number;
  acc: number;
  speed: number;
  at: number;
}

export interface EPlayer {
  id: string;
  name: string;
  color: string;
  role: Role;
  startRole?: Role; // role when the game started (or when they joined late)
  isLeader: boolean;
  joinedAt: number;
  loc?: Loc;
  outStrikes: number;
  oobSince?: number;
  convertedAt?: number;
  convertedBy?: string;
}

export type ConvertReason = 'tag' | 'self_tag' | 'out_of_bounds' | 'dark' | 'leader';
export type GameEvent =
  | { type: 'started'; at: number }
  | { type: 'ping'; at: number; seq: number }
  | { type: 'oob_start'; at: number; playerId: string; lat: number; lng: number; willConvert: boolean }
  | { type: 'oob_return'; at: number; playerId: string }
  | { type: 'converted'; at: number; playerId: string; reason: ConvertReason; by?: string }
  | { type: 'paused'; at: number }
  | { type: 'resumed'; at: number }
  | { type: 'ended'; at: number; winner: 'hiders' | 'seekers'; reason: 'time' | 'all_tagged' | 'leader' };

export interface PingPosition {
  id: string;
  lat: number;
  lng: number;
  at: number;
}
export interface Ping {
  seq: number;
  at: number;
  positions: PingPosition[]; // EVERYONE's position, sent to EVERYONE
}

const R = 6371000;
export function haversineM(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const rad = (d: number) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

export class GameEngine {
  status: Status = 'lobby';
  settings: Settings;
  readonly players = new Map<string, EPlayer>();
  pings: Ping[] = [];
  events: GameEvent[] = [];
  startsAt = 0;
  huntStartsAt = 0;
  endsAt = 0;
  nextPingAt = 0;
  endedAt = 0;
  paused = false;
  pausedAt = 0;
  winner?: 'hiders' | 'seekers';

  constructor(
    private readonly now: () => number = Date.now,
    private readonly rng: () => number = Math.random,
    settings: Partial<Settings> = {},
  ) {
    this.settings = { ...DEFAULT_SETTINGS, ...settings };
  }

  // ---- lobby -------------------------------------------------------------

  addPlayer(id: string, name: string, color: string, isLeader = false): EPlayer {
    const p: EPlayer = { id, name, color, role: 'unassigned', isLeader, joinedAt: this.now(), outStrikes: 0 };
    this.players.set(id, p);
    return p;
  }

  setRole(id: string, role: Role): void {
    const p = this.players.get(id);
    if (!p) throw new Error('no such player');
    if (this.status === 'ended') throw new Error('game ended');
    p.role = role;
    if (this.status === 'active' && p.startRole === undefined) p.startRole = role;
  }

  /** Remove a player (leave or kick). May end the game if it was the last hider. */
  removePlayer(id: string): GameEvent[] {
    this.players.delete(id);
    return this.finish([]);
  }

  setLeader(id: string): void {
    for (const p of this.players.values()) p.isLeader = p.id === id;
  }

  /** Randomly pick `seekers` players (non-referees) as seekers and the rest as hiders. */
  assignRandom(seekers: number): void {
    const pool = [...this.players.values()].filter((p) => p.role !== 'referee');
    for (let i = pool.length - 1; i > 0; i--) {
      const j = Math.floor(this.rng() * (i + 1));
      [pool[i], pool[j]] = [pool[j], pool[i]];
    }
    pool.forEach((p, i) => (p.role = i < seekers ? 'seeker' : 'hider'));
  }

  updateSettings(patch: Partial<Settings>): void {
    this.settings = { ...this.settings, ...patch };
    if (this.status !== 'active') return;
    this.huntStartsAt = this.startsAt + this.settings.headStartMs;
    this.endsAt = this.huntStartsAt + this.settings.durationMs;
    this.nextPingAt = this.pings.length
      ? this.pings[this.pings.length - 1].at + this.settings.pingIntervalMs
      : this.firstPingAt();
  }

  private firstPingAt(): number {
    const { headStartMs, pingIntervalMs } = this.settings;
    return headStartMs > 0 ? this.startsAt + headStartMs : this.startsAt + pingIntervalMs;
  }

  start(): void {
    if (this.status !== 'lobby') throw new Error('already started');
    const roles = [...this.players.values()].map((p) => p.role);
    if (!roles.includes('hider')) throw new Error('need at least one hider');
    if (!roles.includes('seeker')) throw new Error('need at least one seeker');
    if (roles.includes('unassigned')) throw new Error('everyone needs a role');
    const t = this.now();
    this.status = 'active';
    this.startsAt = t;
    this.huntStartsAt = t + this.settings.headStartMs;
    this.endsAt = this.huntStartsAt + this.settings.durationMs;
    this.nextPingAt = this.firstPingAt();
    for (const p of this.players.values()) p.startRole = p.role;
    this.events.push({ type: 'started', at: t });
  }

  // ---- pause -------------------------------------------------------------

  pause(): GameEvent[] {
    if (this.status !== 'active' || this.paused) throw new Error('cannot pause');
    this.paused = true;
    this.pausedAt = this.now();
    const e: GameEvent = { type: 'paused', at: this.pausedAt };
    this.events.push(e);
    return [e];
  }

  /** Resume and shift every timer forward by the time spent paused. */
  resume(): GameEvent[] {
    if (this.status !== 'active' || !this.paused) throw new Error('not paused');
    const t = this.now();
    const d = t - this.pausedAt;
    this.paused = false;
    this.startsAt += d;
    this.huntStartsAt += d;
    this.endsAt += d;
    this.nextPingAt += d;
    for (const p of this.players.values()) {
      if (p.loc) p.loc.at += d;
      if (p.oobSince !== undefined) p.oobSince += d;
    }
    const e: GameEvent = { type: 'resumed', at: t };
    this.events.push(e);
    return [e];
  }

  // ---- gameplay ----------------------------------------------------------

  /** Record a location. Runs the geofence rules. Returns new events. */
  onLocation(id: string, l: { lat: number; lng: number; acc?: number; speed?: number }): GameEvent[] {
    const p = this.players.get(id);
    if (!p || this.status === 'ended') return [];
    const t = this.now();
    p.loc = { lat: l.lat, lng: l.lng, acc: l.acc ?? 0, speed: l.speed ?? 0, at: t };
    const out: GameEvent[] = [];
    const { center, radiusM, warnSeekers } = this.settings;
    if (this.status !== 'active' || this.paused || !center || p.role === 'referee' || p.role === 'unassigned') return out;
    if (p.role === 'seeker' && !warnSeekers) return out;

    const dist = haversineM(center, l);
    // Tolerate GPS noise: only "outside" when clearly outside, and for 2 samples in a row.
    const clearlyOutside = dist - (l.acc ?? 0) > radiusM;
    if (clearlyOutside) p.outStrikes++;
    else if (dist <= radiusM) p.outStrikes = 0;

    if (p.outStrikes >= 2 && p.oobSince === undefined) {
      p.oobSince = t;
      out.push({ type: 'oob_start', at: t, playerId: id, lat: l.lat, lng: l.lng, willConvert: p.role === 'hider' });
    } else if (dist <= radiusM && p.oobSince !== undefined) {
      p.oobSince = undefined;
      out.push({ type: 'oob_return', at: t, playerId: id });
    }
    this.events.push(...out);
    return out;
  }

  /** A seeker tags a hider. No proximity check by design. */
  tag(seekerId: string, hiderId: string): GameEvent[] {
    const s = this.players.get(seekerId);
    const h = this.players.get(hiderId);
    if (this.status !== 'active') throw new Error('game not active');
    if (this.paused) throw new Error('game is paused');
    if (!s || s.role !== 'seeker') throw new Error('only seekers can tag');
    if (!h || h.role !== 'hider') throw new Error('target is not a hider');
    if (this.now() < this.huntStartsAt) throw new Error('head start still running');
    return this.finish([this.convert(h, 'tag', seekerId)]);
  }

  selfTag(hiderId: string): GameEvent[] {
    const h = this.players.get(hiderId);
    if (this.status !== 'active' || this.paused || !h || h.role !== 'hider' || !this.settings.hiderSelfTag) throw new Error('cannot self-tag');
    return this.finish([this.convert(h, 'self_tag')]);
  }

  /** Leader override. */
  forceSeeker(id: string): GameEvent[] {
    const h = this.players.get(id);
    if (this.status !== 'active' || !h || h.role !== 'hider') throw new Error('not an active hider');
    return this.finish([this.convert(h, 'leader')]);
  }

  manualPing(): GameEvent[] {
    if (this.status !== 'active' || this.paused) throw new Error('cannot ping now');
    return [this.makePing()];
  }

  endNow(): GameEvent[] {
    if (this.status !== 'active') return [];
    return this.end(this.hidersLeft() > 0 ? 'hiders' : 'seekers', 'leader');
  }

  /** Advance time-driven rules. Call about once per second. Returns new events. */
  tick(): GameEvent[] {
    if (this.status !== 'active' || this.paused) return [];
    const t = this.now();
    const out: GameEvent[] = [];

    // 1. Out-of-bounds timers: hiders who stay out past the grace period become seekers.
    for (const p of this.players.values()) {
      if (p.role === 'hider' && p.oobSince !== undefined && t - p.oobSince >= this.settings.graceMs) {
        out.push(this.convert(p, 'out_of_bounds'));
      }
    }

    // 2. Dark hiders: no location for too long (airplane mode, app killed).
    const dark = this.settings.darkHiderMs;
    if (dark > 0) {
      for (const p of this.players.values()) {
        const lastSeen = Math.max(p.loc?.at ?? 0, this.startsAt);
        if (p.role === 'hider' && t - lastSeen >= dark) out.push(this.convert(p, 'dark'));
      }
    }

    // 3. Ping: ONE ping carrying everyone's positions, sent to everyone.
    //    If we're late (e.g. after a server restart) missed pings collapse into one.
    if (t >= this.nextPingAt && this.nextPingAt < this.endsAt) {
      out.push(this.makePing());
      const step = this.settings.pingIntervalMs;
      while (this.nextPingAt <= t) this.nextPingAt += step;
    }

    return this.finish(out);
  }

  private makePing(): GameEvent {
    const t = this.now();
    const seq = this.pings.length + 1;
    const positions: PingPosition[] = [];
    for (const p of this.players.values()) {
      if (p.loc && p.role !== 'referee') positions.push({ id: p.id, lat: p.loc.lat, lng: p.loc.lng, at: p.loc.at });
    }
    this.pings.push({ seq, at: t, positions });
    const e: GameEvent = { type: 'ping', at: t, seq };
    this.events.push(e);
    return e;
  }

  // ---- visibility (anti-cheat) -------------------------------------------

  /**
   * The ONLY thing a client is allowed to see. Between pings, hiders see live hiders
   * and seekers see live seekers. At each ping, everyone gets everyone.
   */
  viewFor(id: string) {
    const me = this.players.get(id);
    if (!me) throw new Error('no such player');
    const s = this.settings;
    const sameTeam = (p: EPlayer) => {
      if (me.role === 'referee') return true;
      if (p.id === me.id) return true;
      if (me.role === 'seeker' && !s.seekersSeeEachOther) return false;
      return p.role === me.role;
    };
    const live = [...this.players.values()]
      .filter((p) => p.loc && p.role !== 'referee' && (sameTeam(p) || this.status === 'ended'))
      .map((p) => ({
        id: p.id,
        lat: p.loc!.lat,
        lng: p.loc!.lng,
        speed: p.id === me.id || s.showTeamSpeed || me.role === 'referee' || this.status === 'ended' ? p.loc!.speed : null,
        at: p.loc!.at,
      }));
    return {
      status: this.status,
      role: me.role,
      paused: this.paused,
      timing: { startsAt: this.startsAt, huntStartsAt: this.huntStartsAt, endsAt: this.endsAt, nextPingAt: this.nextPingAt },
      settings: this.settings,
      roster: [...this.players.values()].map((p) => ({ id: p.id, name: p.name, color: p.color, role: p.role, isLeader: p.isLeader })),
      hidersLeft: this.hidersLeft(),
      live,
      lastPing: this.pings[this.pings.length - 1] ?? null,
      winner: this.winner ?? null,
    };
  }

  // ---- internals ---------------------------------------------------------

  hidersLeft(): number {
    let n = 0;
    for (const p of this.players.values()) if (p.role === 'hider') n++;
    return n;
  }

  private convert(p: EPlayer, reason: ConvertReason, by?: string): GameEvent {
    p.role = 'seeker';
    p.oobSince = undefined;
    p.outStrikes = 0;
    p.convertedAt = this.now();
    p.convertedBy = by;
    const e: GameEvent = { type: 'converted', at: this.now(), playerId: p.id, reason, by };
    this.events.push(e);
    return e;
  }

  /** After any change, check win conditions. Returns events plus an `ended` event if the game ended. */
  private finish(out: GameEvent[]): GameEvent[] {
    if (this.status !== 'active') return out;
    if (this.hidersLeft() === 0) return [...out, ...this.end('seekers', 'all_tagged')];
    if (!this.paused && this.now() >= this.endsAt) return [...out, ...this.end('hiders', 'time')];
    return out;
  }

  private end(winner: 'hiders' | 'seekers', reason: 'time' | 'all_tagged' | 'leader'): GameEvent[] {
    this.status = 'ended';
    this.winner = winner;
    this.endedAt = this.now();
    const e: GameEvent = { type: 'ended', at: this.endedAt, winner, reason };
    this.events.push(e);
    return [e];
  }

  // ---- persistence (for restart recovery) ---------------------------------

  toJSON() {
    return {
      status: this.status,
      settings: this.settings,
      players: [...this.players.values()],
      pings: this.pings,
      events: this.events,
      startsAt: this.startsAt,
      huntStartsAt: this.huntStartsAt,
      endsAt: this.endsAt,
      nextPingAt: this.nextPingAt,
      endedAt: this.endedAt,
      paused: this.paused,
      pausedAt: this.pausedAt,
      winner: this.winner ?? null,
    };
  }

  static fromJSON(d: any, now: () => number = Date.now, rng: () => number = Math.random): GameEngine {
    const g = new GameEngine(now, rng, d.settings);
    g.status = d.status;
    for (const p of d.players) g.players.set(p.id, { ...p });
    g.pings = d.pings ?? [];
    g.events = d.events ?? [];
    g.startsAt = d.startsAt;
    g.huntStartsAt = d.huntStartsAt;
    g.endsAt = d.endsAt;
    g.nextPingAt = d.nextPingAt;
    g.endedAt = d.endedAt ?? 0;
    g.paused = !!d.paused;
    g.pausedAt = d.pausedAt ?? 0;
    g.winner = d.winner ?? undefined;
    return g;
  }

  /**
   * After a restore the server was down for an unknown time. Give everyone a fair fresh start
   * for time-based rules: dark-hider and out-of-bounds timers restart from now.
   */
  resetTimersAfterRestore(): void {
    const t = this.now();
    for (const p of this.players.values()) {
      if (p.loc) p.loc.at = t;
      p.oobSince = undefined;
      p.outStrikes = 0;
    }
    if (this.paused) this.pausedAt = t;
  }
}
