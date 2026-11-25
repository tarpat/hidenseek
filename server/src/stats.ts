import { haversineM, type GameEngine, type Role } from './engine';

/** [t (ms, server clock), lat, lng, speed (m/s), accuracy (m)] */
export type TrackPoint = number[];

export interface Departed {
  name: string;
  color: string;
  startRole: Role;
  finalRole: Role;
  convertedAt?: number;
  leftAt: number;
}

export interface PlayerStats {
  distanceM: number;
  hiderDistanceM: number;
  seekerDistanceM: number;
  topSpeedMps: number;
  avgMovingSpeedMps: number;
  movingMs: number;
  stillMs: number;
  points: number;
}

const MAX_ACC_M = 25; // drop worse fixes
const MAX_SPEED_MPS = 12; // ~27 mph: anything faster is a GPS glitch
const JITTER_M = 3; // ignore tiny movements (GPS jitter while standing still)
const MOVING_MPS = 0.5;
const MAX_GAP_MS = 30_000; // gaps longer than this are "no data", not "still"

interface Clean {
  t: number;
  lat: number;
  lng: number;
  speed: number; // smoothed m/s
}

/** Filter GPS noise, compute smoothed speed per point. Returns accepted points and total distance pieces. */
export function cleanTrack(track: TrackPoint[], splitAt?: number) {
  const pts = [...track].filter((p) => p.length >= 5).sort((a, b) => a[0] - b[0]);
  const kept: Clean[] = [];
  let ref: TrackPoint | undefined;
  let drops = 0;
  let distBefore = 0;
  let distAfter = 0;
  let moving = 0;
  let still = 0;
  let lastT: number | undefined;

  for (const p of pts) {
    const [t, lat, lng, rawSpeed, acc] = p;
    if (!(acc >= 0 && acc <= MAX_ACC_M)) continue;
    if (!ref) {
      ref = p;
      kept.push({ t, lat, lng, speed: Math.max(0, rawSpeed) });
      lastT = t;
      continue;
    }
    const dt = (t - ref[0]) / 1000;
    if (dt <= 0) continue;
    const d = haversineM({ lat: ref[1], lng: ref[2] }, { lat, lng });
    if (d / dt > MAX_SPEED_MPS && drops < 5) {
      drops++; // glitch: skip this point
      continue;
    }
    drops = 0;
    let speed = rawSpeed >= 0 ? rawSpeed : d / dt;
    speed = Math.min(speed, MAX_SPEED_MPS);
    const gap = lastT === undefined ? 0 : t - lastT;
    if (gap > 0 && gap <= MAX_GAP_MS) {
      if (speed > MOVING_MPS) moving += gap;
      else still += gap;
    }
    lastT = t;
    if (d >= JITTER_M) {
      if (splitAt !== undefined && t >= splitAt) distAfter += d;
      else distBefore += d;
      ref = p; // only advance the reference when we really moved
    }
    kept.push({ t, lat, lng, speed });
  }

  // 3-point moving average for display and top speed
  const smooth = kept.map((k, i) => {
    const a = kept[Math.max(0, i - 1)].speed;
    const c = kept[Math.min(kept.length - 1, i + 1)].speed;
    return { ...k, speed: (a + k.speed + c) / 3 };
  });
  return { kept: smooth, distBefore, distAfter, moving, still };
}

export function computeStats(track: TrackPoint[], startRole: Role, convertedAt?: number): PlayerStats {
  // Distance before the conversion time counts as "hider", after counts as "seeker".
  const split = startRole === 'hider' ? convertedAt : undefined;
  const c = cleanTrack(track, split);
  const total = c.distBefore + c.distAfter;
  const hiderD = startRole === 'hider' ? c.distBefore : 0;
  const seekerD = startRole === 'hider' ? c.distAfter : total;
  const top = c.kept.reduce((m, k) => Math.max(m, k.speed), 0);
  const movingSpeeds = c.kept.filter((k) => k.speed > MOVING_MPS);
  const avg = movingSpeeds.length ? movingSpeeds.reduce((s, k) => s + k.speed, 0) / movingSpeeds.length : 0;
  return {
    distanceM: total,
    hiderDistanceM: hiderD,
    seekerDistanceM: seekerD,
    topSpeedMps: Math.min(top, MAX_SPEED_MPS),
    avgMovingSpeedMps: avg,
    movingMs: c.moving,
    stillMs: c.still,
    points: track.length,
  };
}

/** Ramer–Douglas–Peucker on a local flat projection. Returns kept points as [lat, lng, speed, t]. */
export function simplifyRoute(track: TrackPoint[], toleranceM = 2): number[][] {
  const c = cleanTrack(track).kept;
  if (c.length <= 2) return c.map((p) => [p.lat, p.lng, p.speed, p.t]);
  const lat0 = c[0].lat;
  const kx = 111_320 * Math.cos((lat0 * Math.PI) / 180);
  const ky = 110_540;
  const xy = c.map((p) => [(p.lng - c[0].lng) * kx, (p.lat - lat0) * ky]);
  const keep = new Uint8Array(c.length);
  keep[0] = keep[c.length - 1] = 1;
  const stack: [number, number][] = [[0, c.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop()!;
    let maxD = 0;
    let idx = -1;
    const [ax, ay] = xy[a];
    const [bx, by] = xy[b];
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    for (let i = a + 1; i < b; i++) {
      const [px, py] = xy[i];
      let d: number;
      if (len2 === 0) d = Math.hypot(px - ax, py - ay);
      else {
        const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2));
        d = Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
      }
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx !== -1 && maxD > toleranceM) {
      keep[idx] = 1;
      stack.push([a, idx], [idx, b]);
    }
  }
  // Round to keep the results message small: 6 decimals is ~10 cm, speed to 0.01 m/s.
  const r6 = (x: number) => Math.round(x * 1e6) / 1e6;
  const r2 = (x: number) => Math.round(x * 100) / 100;
  return c.filter((_, i) => keep[i]).map((p) => [r6(p.lat), r6(p.lng), r2(p.speed), Math.round(p.t)]);
}

/** Speed over time, downsampled to at most `max` buckets: [t, m/s]. */
export function speedSeries(track: TrackPoint[], max = 120): number[][] {
  const c = cleanTrack(track).kept;
  if (c.length <= max) return c.map((p) => [Math.round(p.t), Math.round(p.speed * 100) / 100]);
  const size = Math.ceil(c.length / max);
  const out: number[][] = [];
  for (let i = 0; i < c.length; i += size) {
    const chunk = c.slice(i, i + size);
    out.push([Math.round(chunk[0].t), Math.round((chunk.reduce((s, p) => s + p.speed, 0) / chunk.length) * 100) / 100]);
  }
  return out;
}

export interface PlayerResult {
  id: string;
  name: string;
  color: string;
  startRole: Role;
  finalRole: Role;
  convertedAt: number | null;
  left: boolean;
  survivedMs: number;
  tagsMade: number;
  stats: PlayerStats;
  route: number[][];
  speedSeries: number[][];
}

export interface ResultsInput {
  engine: GameEngine;
  tracks: Map<string, TrackPoint[]>;
  departed: Map<string, Departed>;
}

export function buildResults({ engine, tracks, departed }: ResultsInput) {
  const endedAt = engine.endedAt || Date.now();
  const entries: { id: string; name: string; color: string; startRole: Role; finalRole: Role; convertedAt?: number; left: boolean }[] = [];
  for (const p of engine.players.values()) {
    if (p.role === 'referee' || p.startRole === 'referee') continue;
    entries.push({ id: p.id, name: p.name, color: p.color, startRole: p.startRole ?? p.role, finalRole: p.role, convertedAt: p.convertedAt, left: false });
  }
  for (const [id, d] of departed) {
    entries.push({ id, name: d.name, color: d.color, startRole: d.startRole, finalRole: d.finalRole, convertedAt: d.convertedAt, left: true });
  }

  const tags = new Map<string, number>();
  for (const e of engine.events) if (e.type === 'converted' && e.reason === 'tag' && e.by) tags.set(e.by, (tags.get(e.by) ?? 0) + 1);

  const players: PlayerResult[] = entries.map((e) => {
    const track = tracks.get(e.id) ?? [];
    const stats = computeStats(track, e.startRole, e.convertedAt);
    const survivedMs = e.startRole === 'hider' ? Math.max(0, (e.convertedAt ?? endedAt) - engine.huntStartsAt) : 0;
    return {
      id: e.id,
      name: e.name,
      color: e.color,
      startRole: e.startRole,
      finalRole: e.finalRole,
      convertedAt: e.convertedAt ?? null,
      left: e.left,
      survivedMs,
      tagsMade: tags.get(e.id) ?? 0,
      stats,
      route: simplifyRoute(track),
      speedSeries: speedSeries(track),
    };
  });

  const ended = [...engine.events].reverse().find((e) => e.type === 'ended');
  return {
    winner: engine.winner ?? null,
    endReason: ended && ended.type === 'ended' ? ended.reason : null,
    startsAt: engine.startsAt,
    huntStartsAt: engine.huntStartsAt,
    endsAt: engine.endsAt,
    endedAt,
    geofence: engine.settings.center ? { center: engine.settings.center, radiusM: engine.settings.radiusM } : null,
    pings: engine.pings,
    events: engine.events,
    players,
    awards: engine.settings.awards ? computeAwards(players, engine.winner ?? null) : [],
  };
}

export function computeAwards(players: PlayerResult[], winner: 'hiders' | 'seekers' | null) {
  const awards: { id: string; title: string; playerIds: string[]; value?: number }[] = [];
  const withData = players.filter((p) => p.stats.points > 1);
  if (withData.length) {
    const fast = [...withData].sort((a, b) => b.stats.topSpeedMps - a.stats.topSpeedMps)[0];
    if (fast.stats.topSpeedMps > 1) awards.push({ id: 'fastest', title: 'Fastest', playerIds: [fast.id], value: fast.stats.topSpeedMps });
    const far = [...withData].sort((a, b) => b.stats.distanceM - a.stats.distanceM)[0];
    if (far.stats.distanceM > 10) awards.push({ id: 'marathoner', title: 'Marathoner', playerIds: [far.id], value: far.stats.distanceM });
    const hiders = withData.filter((p) => p.startRole === 'hider');
    if (hiders.length > 1) {
      const statue = [...hiders].sort((a, b) => a.stats.distanceM - b.stats.distanceM)[0];
      awards.push({ id: 'statue', title: 'Statue', playerIds: [statue.id], value: statue.stats.distanceM });
    }
  }
  const survivors = players.filter((p) => p.finalRole === 'hider' && !p.left);
  if (winner === 'hiders' && survivors.length) awards.push({ id: 'last_standing', title: 'Last one standing', playerIds: survivors.map((p) => p.id) });
  const tagger = [...players].sort((a, b) => b.tagsMade - a.tagsMade)[0];
  if (tagger && tagger.tagsMade > 0) awards.push({ id: 'top_tagger', title: 'Top tagger', playerIds: [tagger.id], value: tagger.tagsMade });
  return awards;
}
