# Hide n Seek — Requirements & Architecture

A location-based, real-world hide-and-seek / tag game for iOS, in the style of Manhunt / Scram.

> **Status:** planning doc, revision 6.
> **Key decisions:**
> - Friends-only, ≈20 concurrent players, iOS 17+.
> - **No paid Apple account**: the app is sideloaded to friends' phones (§8).
> - **No sign-in**: the profile is stored on-device only.
> - Backend on **Render's free tier**: in-memory game state over WebSockets. **No database.** Restart recovery uses encrypted snapshots held on the players' own phones (§6.6).
> - Bundle ID: `com.tarunpatanjali.hidenseek`.
> - **Chat and media live on the phones.** The server only relays them transiently in memory. Photos and videos are sent **losslessly** (no recompression).
> - Hiders get a **5-minute head start**. After that, and every 5 minutes, a ping shows **everyone's location to everyone**. All timings are configurable.
> - **Live speed and route tracking**, with an end-of-game results map (§3.9).
>
> Free-tier limits are from memory and change often. Items marked ⚠️ should be re-checked before relying on them.

---

## 1. Game Overview

Players join a game with a code. The leader draws a circular play area (geofence) on a map and assigns roles. Hiders get a **5-minute head start** (configurable) to hide. When it ends, and every **5 minutes** after that (configurable), a "ping" shows **everyone's location to everyone**. Seekers hunt hiders on foot. When a seeker physically tags a hider, the seeker marks it in the app and the hider becomes a seeker. The hunt lasts **30 minutes** (configurable), starting when the head start ends, or until every hider has been tagged. Throughout, the app tracks everyone's speed and route, and the end screen shows each player's path and stats on a map.

**Win conditions**
- Seekers win: all hiders converted before the timer expires.
- Hiders win: at least one hider remains when the timer expires.

**Scope assumptions**
- Audience: a group of friends. Design target ≈ 20 concurrent players, soft cap ~50.
- Distribution: sideloaded builds (no App Store, no TestFlight).
- Platform: iOS 17+ only.

---

## 2. Roles

| Role | Description |
|---|---|
| **Leader (host)** | Creates the game and has full control over settings and roles. Can edit settings before and during the game. Can play as a hider or seeker, or act as a **referee** who sees everything but doesn't play. |
| **Seeker** | Sees seekers' live locations, plus everyone's location at each ping. Can tag hiders. |
| **Hider** | Sees other hiders' live locations, plus everyone's location at each ping. |

Tagged hiders become seekers. There is no elimination, so nobody sits out.

---

## 3. Functional Requirements

### 3.1 Identity & Profile (no sign-in)
- **FR-1** There are **no accounts, emails, passwords, or sign-in screens**. The user opens the app, sets a name and optional profile picture, and joins or creates a game.
- **FR-2** The profile (display name, avatar image, preferred color) is **stored on-device only** (UserDefaults for name/color, an app-container file for the image). It persists between games and is editable from a Profile screen.
- **FR-3** On joining a game, the app sends the name, color, and a **downscaled avatar (~128×128 px, ≤ ~20 KB)** to the server so other players can see it. The server holds the avatar **in memory for the life of that game only**. It's never written to disk, it's excluded from restart snapshots, and it's discarded at cleanup (§3.11).
- **FR-4** Anonymous identity:
  - On first launch the app generates a random **device ID** (UUID, kept in Keychain).
  - Joining a game returns a **per-game secret token**. The app stores it locally and presents it on every connection.
  - If the app crashes, is killed, or the network drops, the token lets the player **rejoin as the same person** with the same role.

### 3.2 Game Creation & Joining
- **FR-5** Leader creates a game and gets a **6-character join code**. The alphabet excludes look-alike characters (no `0/O`, `1/I/L`). The code can be shared as a link using the custom URL scheme `hidenseek://join/ABC123` (universal links need a paid account), as text, or as a QR code.
- **FR-6** Anyone with the code can join. A soft cap (e.g. 50) protects the free server.
- **FR-7** A lobby shows who has joined, live. The leader can kick players. Players can leave.
- **FR-8** Late join is allowed during an active game (leader setting). Late joiners enter as seekers or hiders per a leader setting.

### 3.3 Role Assignment
- **FR-9** **Manual:** the leader taps players to assign Seeker or Hider.
- **FR-10** **Random:** the leader picks the number (or percentage) of seekers and taps "Randomize". The server does the shuffle.
- **FR-11** **Self-select** *(optional)*: players pick their own role in the lobby.
- **FR-12** Roles can be re-assigned before the game starts. During a game, the leader can manually change any player's role.

### 3.4 Geofence (Play Area)
- **FR-13** The leader sets a **circle**: center (drop pin, search an address, or "use my location") plus a radius slider (50 m to several km). The circle is drawn on the map for all players.
- **FR-14** The geofence can be moved or resized **during** the game.
- **FR-15** **Out-of-bounds flow:**
  1. The server detects the player outside the circle.
  2. **Everyone** gets a one-time ping with that player's current location, shown as an "out of bounds" event.
  3. **Hiders:** the offender gets a loud warning and a **60-second countdown** (configurable). If they re-enter in time, the countdown cancels. If not, they are **auto-converted to a seeker** and everyone is notified.
  4. **Seekers:** the same ping and warning happen, but there's no conversion (they're already seekers). A leader setting can disable seeker warnings.
- **FR-16** Players get a warning as they approach the edge (for example within 20 m).
- **FR-17** GPS-noise tolerance. A player counts as outside only if `distance − horizontalAccuracy > radius` for 2 consecutive samples. This prevents unfair conversions from GPS jitter.

### 3.5 Timer, Head Start & Pings
- **FR-18** The hunt lasts **30 minutes** by default (configurable). The 30 minutes **start after the head start ends**, so with defaults a game runs 35 minutes in total: 5 minutes of hiding, then 30 minutes of hunting. `endsAt = startsAt + headStart + duration`. A countdown is shown to all players, first for the head start and then for the hunt.
- **FR-19** **Head start:** when the leader starts the game, hiders get a **5-minute head start** (configurable, 0 allowed) to hide. During it, seekers see a "Hiders are hiding" countdown and only their teammates on the map. Hiders see their fellow hiders live. Nobody sees the other side yet. **Tagging is disabled until the head start ends.**
- **FR-20** **First ping** fires when the head start ends. After that a ping fires **every 5 minutes** (configurable). If the head start is 0, the first ping fires after one interval.
- **FR-21** **At every ping, everyone receives everyone's location**: seekers get all hiders' and all seekers' positions, and hiders get all seekers' and all hiders' positions. The ping is a timestamped snapshot, so it's drawn as "as of" pins that stay on the map until the next ping.
- **FR-22** Pings are server-driven and timestamped, so everyone sees the same moment. The UI shows "Next ping in mm:ss" and "Ping #N, 2 min ago". The leader can trigger a manual ping, pause or resume the game, or end it early. Pausing shifts all timers by the paused time.

**Example timeline (defaults):** `0:00` start and head start begins → `5:00` hunt begins and ping #1 fires → `10:00` ping #2 → `15:00` → `20:00` → `25:00` → `30:00` ping #6 → `35:00` game ends.

### 3.6 Map & Visibility Rules

| Viewer | Live between pings | At each ping |
|---|---|---|
| **Seeker** | Seekers (self and teammates) | Everyone's position (as of the ping time) |
| **Hider** | Hiders (self and teammates) | Everyone's position (as of the ping time) |
| **Leader as referee** | Everyone | n/a |

- **FR-23** These rules are enforced **server-side**, per connection: between pings the server never sends a client the other side's positions. Hiding it in the UI alone isn't enough, because a modified client or a network sniffer could read it. At a ping, the full set is sent to everybody.
- **FR-24** A player converted to a seeker gets the **seeker view only** from that moment on. Between pings they see only seekers live, and their hider-only chat history is hidden (FR-33).
- **FR-25** Older pings show faded, with an age label. Out-of-bounds events are drawn distinctly.
- **FR-26** The map uses native MapKit with the geofence overlay, a "center on me" button, and the player's own live route trail. A stale-signal indicator shows if a player's location is older than N seconds.

### 3.7 Tagging
- **FR-27** A seeker taps **Tag**, picks the hider from the list, and confirms. The hider is converted to a seeker immediately, and everyone gets a notification. **No location or proximity check is applied.**
- **FR-28** Hiders can also **self-report** being tagged ("I'm out"). The leader can override: tag or un-tag anyone.

### 3.8 Chat
- **FR-29** Real-time chat inside every game with **three channels**: *Everyone*, *Seekers only*, *Hiders only*. The server relays each message only to players whose **current role** may read that channel.
- **FR-30** Message types: text, photos, GIFs, videos. System messages (tags, pings, out-of-bounds) are also posted.
- **FR-31** **Chat and media are held on the devices, not on the server.** The server is a relay. It keeps a message or file in memory only until every authorized recipient has received it (or a short timeout passes: ~10 min for text, ~20 min for media), then discards it. Nothing is written to disk, nothing is kept in restart snapshots, and there is no server-side chat history. The sender keeps an outbox and re-sends anything the server hasn't acknowledged.
- **FR-32** **Lossless only.** Photos and videos are sent exactly as captured, with **no resizing, no transcoding, and no quality reduction**.
  - The only changes allowed are lossless ones: stripping **GPS/location metadata** (so a photo can't give away a hiding spot) without re-encoding the image or video, and transport compression (gzip) of text.
  - **Photos** are sent as the original HEIC/JPEG (typically 2–5 MB). There is no size limit in the app.
  - **Videos** have **no length or size limit** in the app and are never recompressed. Videos recorded inside the app use iOS's "high quality" camera setting (the simple camera API has no explicit 1080p option), and clips picked from the library are sent as they are. Clips picked from the library are sent as they are. The only ceiling is a high **server safety limit** (§7.5) that exists to protect the free server.
  - **GIFs** are GIPHY URLs and are cached on the device once viewed.
- **FR-33** Each phone stores its chat history and received media **locally** per game. Unread badges show per channel. When a player is converted to a seeker, the hiders' channel history is **hidden in the app** until the game ends, and then it reappears. Chat history is saved with Past games (FR-46) and can be deleted. Typing indicators, reactions, and report/mute are later additions.

### 3.9 Speed, Route Tracking & Results Map  *(new)*

**Live during the game**
- **FR-34** The app continuously records each player's **position, speed, and timestamp** into a track, at up to ~1 sample/second while a game is active.
- **FR-35** The HUD shows the player's own **current speed**, **distance covered**, and live route trail. Default unit is mph with a km/h toggle.
- **FR-36** Teammates' live speeds (hiders see hiders, seekers see seekers) may appear in the roster. **Speed visibility follows the same visibility rules as location (§3.6).** Seekers can't see hiders' live speed. Stats for everyone are revealed at the end.

**Gap-free tracking**
- **FR-37** The phone keeps the **full-resolution track locally** and uploads it in numbered batches (every ~10 s over the same socket). The server acknowledges the highest sequence number it has stored. Unacknowledged batches are kept and re-sent after a dropout, a reconnect, or a server restart. This fills dead-zone gaps and keeps the results map accurate even when the live connection was spotty.
- **FR-38** Live gameplay (pings, out-of-bounds) uses a separate lightweight `location` message every ~3–5 s while moving. While stationary (when CoreLocation sends no new fixes), the app re-sends its last fix as a **keepalive at least every ~15 s**, which the dark-hider rule relies on. Track batches don't need to be real-time.

**Stat definitions**
- **FR-39** Samples are filtered before computing stats:
  - Drop samples with horizontal accuracy worse than ~25 m.
  - Drop samples whose implied speed exceeds a sanity cap (~12 m/s, or ~27 mph), which are GPS glitches.
  - Ignore movement below ~3 m between consecutive samples when stationary, so GPS jitter doesn't inflate distance.
  - Speed comes from CoreLocation's speed when available and valid, otherwise from distance over time. It's smoothed with a short moving average.
- **FR-40** Per-player stats shown at the end:
  - **Total distance**
  - **Top speed** (from smoothed speed)
  - **Average moving speed** and **moving vs. still time**
  - **Time survived** (hiders) and **tags made** (seekers)
  - **Distance as hider vs. as seeker** for players who were converted
  - A **speed-over-time chart** (Swift Charts) with markers for pings, tags, and out-of-bounds events
- **FR-41** Fun awards computed from the stats, for example *Fastest*, *Marathoner* (farthest), *Statue* (least movement among hiders), *Last one standing*, *Top tagger*. A leader setting can turn them off.

**End-of-game results map**
- **FR-42** After the game, a results screen shows a **map with every player's route superimposed**, one color per player with their avatar at the end point.
  - Toggle players on/off, or filter to hiders or seekers.
  - Speed-colored routes: a gradient from slow to fast.
  - Overlays: the geofence circle, ping locations, tag locations, and out-of-bounds events.
  - Start and end pins for each route.
- **FR-43** **Replay scrubber** *(not in v1; static routes are enough for now)*: a time slider that plays the game back, with dots moving along each route and the clock and role changes shown. The full-resolution tracks are kept so this can be added later.
- **FR-44** The tapped player's card shows their personal stats (FR-40) and highlights their route.
- **FR-45** Full tracks for everyone are revealed to everyone **only after the game ends**, so hiding spots are no longer secret.
- **FR-46** Results are **saved on-device** in a local "Past games" list, so they remain after the server deletes the game (§3.11). This fits the device-only data model. Players can delete past results.

### 3.10 Leader Settings
All of these are editable **before and during** the game, with changes broadcast live.

| Setting | Default | Notes |
|---|---|---|
| Hunt duration | 30 min | Counted from the end of the head start. Changing mid-game adjusts the end time |
| Ping interval | 5 min | The first ping fires when the head start ends |
| Geofence center / radius | set by leader | |
| Out-of-bounds grace period | 60 s | |
| Warn seekers who leave the area | On | Ping and warning only |
| Role assignment | Manual | Manual / random / self-select |
| Seeker count (random) | 1 per 6 players | |
| Head start for hiders | 5 min | Hiders hide, and seekers wait. 0 is allowed |
| Hider self-report tag | On | |
| Auto-convert hiders who go dark | On, after 2 min | A hider with no location update for this long (airplane mode, app killed) is converted to a seeker. 0 = off |
| Allow late join | On | |
| Chat enabled / media allowed | On | |
| Show seekers each other's live location | On | |
| Show live speed to teammates | On | |
| End-of-game awards | On | |
| Units | mph | mph / km/h |

### 3.11 Notifications & Cleanup
- **FR-47** In-app banners, sounds, and haptics for: ping arrived, someone tagged, out-of-bounds, time warnings (10 min, 5 min, 1 min), and game over.
- **FR-48** **Local notifications** when the app is backgrounded. These need no server or paid account.
- **FR-49** Remote push (APNs) is **not available** without a paid Apple account. The app relies on its background-location session to stay connected (§7.2).
- **FR-50** When a game ends, the server keeps it for about **30 minutes** so everyone can fetch the results payload and late reconnects work. Then it **deletes everything**: locations, tracks, avatars, and any undelivered chat or media. Phones delete their stored restart snapshots when the game ends (§6.6). Games with no connections for 30 min are deleted too.
- **FR-51** **Save media to your Photos library at the end.** When the game ends, the results screen asks: *"Save N photos and M videos from this game to your Photos library?"*
  - It includes **photos and videos only. GIFs are excluded.**
  - The media goes into a new album named "Hide n Seek – <date>", in full original quality, and uses **add-only** Photos permission (the app can't read the rest of the library).
  - It saves everything this phone received or sent, including media from channels the player could read at the time. Media from a team-only channel is therefore saved only by that team's phones.
  - The same option stays available from the game's entry in Past games, so a player can say "not now" and save later. A game's media is never saved twice. The **"Automatically save photos & videos to Photos"** toggle in the app's Settings page (off by default, a per-device setting stored locally) skips the prompt and saves straight away.

---

## 4. Non-Functional Requirements

- **Battery:** continuous GPS is the main cost. Use `distanceFilter` ≈ 5 m, with high accuracy only in active games. Slow `location` uploads when stationary, but **never less than one keepalive every ~15 s**. Otherwise a hider sitting still in a hiding spot would look "dark" and get converted. Warn players to start with a charged phone, and suggest low-power-friendly settings.
- **Latency:** live location updates visible within ~2–3 s. Pings fire within ~2 s of the scheduled time.
- **Background operation:** location must keep reporting with the screen locked (§7.2).
- **Resilience:** the app auto-reconnects with the saved token and shows "reconnecting". The server is authoritative, and a reconnecting client receives a full state sync. Track data is backed by local buffering (FR-37).
- **Fairness:** the server, not clients, decides pings, geofence violations, and timer expiry.
- **Privacy:** see §10.
- **Accessibility:** Dynamic Type, VoiceOver labels on map pins and buttons, and color-blind-safe role colors.

---

## 5. Architecture Overview

```
┌─────────────────────────── iOS App (SwiftUI) ────────────────────────────┐
│  Profile · past games · chat & media (all local)   CoreLocation   MapKit  │
│  Track buffer · encrypted snapshot (local)   Swift Charts   Chat UI       │
│  URLSessionWebSocketTask                                                  │
└───────────┬───────────────────────────────────────────────────────────────┘
            │  wss:// (JSON messages) + a few HTTPS endpoints
┌───────────▼─────────────── Render Free Web Service ───────────────────────┐
│  Node.js / TypeScript (or Go) single process                              │
│   Game registry (Map<code, Game>)  ← all live state in memory             │
│   Tick loop: pings, OOB timers, game end                                  │
│   viewFor(game, player): per-connection visibility filter                 │
│   Track store + stats calculator                                          │
│   Snapshot encrypter / restorer (AES-GCM, key in Render env var)          │
│   Chat/media relay (transient, capped) · GIF proxy · /health              │
└───────────────────────────────────────────────────────────────────────────┘
        ▲ the server periodically pushes an encrypted snapshot blob to every
        │ client. Phones store it, but cannot read it. After a restart the
        │ phones hand the newest blob back and the game resumes (§6.6).
        External: GIPHY API (GIFs) · Apple MapKit (maps, free)
```

**Core idea:** a small stateful server. Each active game is an object in memory. Clients hold a WebSocket open and send location updates, track batches, and commands. The server validates them, updates state, and pushes only the allowed view to each client. Whenever game state changes meaningfully, the server sends every client an **encrypted snapshot** of the game. The phones keep it, so a restarted server can recover the game from them. There is no database.

---

## 6. Server Design

### 6.1 In-Memory Model (sketch)

```ts
Game {
  code, status,                 // lobby | active | paused | ended
  leaderId, leaderIsReferee,
  createdAt, startsAt, endsAt, nextPingAt, pingSeq,
  epoch, snapshotVersion,       // epoch increments on every restore
  center: {lat, lng}, radiusM,
  settings: { ... },            // everything from §3.10
  players: Map<playerId, Player>,
  pings: Ping[],                // snapshots, each tagged with the role it's visible to
  events: Event[],              // tagged, oob_start, oob_return, oob_converted, settings, ...
  relay: Map<msgId, {envelope, media?: Buffer, pendingRecipients, expiresAt}>
                                // transient, capped, deleted once delivered or expired
}

Player {
  id, tokenHash, displayName, color, avatar?,   // avatar in memory only, never snapshotted
  role,                         // hider | seeker | referee
  roleHistory: [{role, from}],  // for per-role stats
  isLeader, joinedAt, connected, socket?,
  lastLocation: {lat, lng, accuracyM, speed, at},
  oobSince?, oobStrikes,
  convertedAt?, convertedBy?,
  track: { points: Float32/packed array [t, lat, lng, speed, acc], lastSeq }
}
```

**Track memory budget:** 20 players × 1 Hz × 30 min = 36,000 points. At ~24–40 bytes each that's ~1–1.5 MB, which is trivial for a 512 MB instance.

### 6.2 Messages (WebSocket, JSON)

**Client → server**

| Message | Purpose |
|---|---|
| `join {code, name, color, avatar, deviceId}` / `rejoin {code, token, snapshotVersion}` | Enter or resume a game. The server replies with `token` and a full state sync. If it doesn't know the game (it restarted), it replies `need_restore` |
| `restore {code, version, blob}` | Hand the server an encrypted snapshot so it can rebuild a game after a restart (§6.6) |
| `location {lat, lng, acc, speed, ts}` | Lightweight live position, every ~3–5 s |
| `track_batch {from, points[]}` | Track history starting at point index `from`, every ~10 s. The server appends what it's missing and replies `track_ack {epoch, count}` with how many points it holds, and the phone resumes from there. This makes re-uploading after a restart idempotent |
| `assign_roles`, `set_role` | Leader only |
| `start_game`, `pause`, `resume`, `end_game`, `manual_ping` | Leader only |
| `update_settings {patch}` / `set_geofence {lat, lng, radius}` | Leader only |
| `tag {hiderId}` / `self_tagged` | Tagging (no proximity check) |
| `chat {id, channel, kind, body, media?}` | The server checks the channel against the sender's role, relays it to authorized recipients, and acks the sender. Media goes up as a binary upload (or chunked frames) |
| `chat_received {id}` | Recipient ack. Once all recipients ack, the server discards the message and media |
| `kick {playerId}` / `leave` | Membership |
| `get_results` | Fetch the final results payload |

**Server → client**
`state_sync`, `snapshot {version, blob}`, `need_restore`, `player_joined`/`left`, `role_changed`, `settings_changed`, `locations` (live teammates, including speed per the rules), `ping {seq, positions}`, `oob_warning`, `oob_event`, `tagged`, `chat`, `media_ready`, `track_ack`, `game_over`, `results`, `error`.

### 6.3 Server Logic

- **Tick loop** (≈1 s):
  1. If `now ≥ nextPingAt`: snapshot **all** players' last known positions into one ping and send it to **everyone**. Then advance `nextPingAt` by the interval. At game start, `nextPingAt = startsAt + headStart` (or `startsAt + interval` if the head start is 0). `endsAt = startsAt + headStart + duration`.
  2. For each player with `oobSince`: if the role is hider and `now − oobSince ≥ grace`, convert to seeker and emit events.
  3. If `now ≥ endsAt` or no hiders remain: end the game, compute stats and the winner, send `game_over` and the results, and schedule cleanup.
- **`location` handling:** store the position, then run the geofence check. Use haversine, which is plain math. Apply the 2-consecutive-sample and accuracy rule (FR-17). On the first confirmed exit, set `oobSince` and broadcast the `oob_event` with the position to everyone. Clear `oobSince` on re-entry.
- **`track_batch` handling:** append points in order (skip duplicates by sequence number), update `lastSeq`, and ack.
- **Chat relay:** accept an envelope, check the sender's role and channel, queue it for each authorized recipient currently or soon-to-be connected, and drop it on delivery acks or expiry. Enforce the per-file and total buffer caps (§7.5).
- **Stats calculator:** runs once at game end on the stored tracks (FR-39, FR-40). It outputs per-player stats, awards, and a **simplified polyline** (Ramer–Douglas–Peucker) for rendering. The full-resolution data is also kept for the replay scrubber.
- **Command validation:** every command checks the sender's token, role, and the game state. All mutations run synchronously on the single Node thread, so there are no race conditions such as two simultaneous tags.
- **Leader loss:** if the leader is disconnected longer than N minutes, auto-promote another player.
- **Clock:** the server sends `ends_at` and `next_ping_at` as absolute timestamps plus its current time. Clients compute a clock offset and render countdowns locally.

### 6.4 Visibility Enforcement (anti-cheat)
- There is **one function** that builds the outgoing payload for a player: `viewFor(game, player)`. All `state_sync` and broadcast messages go through it.
- **Between pings**, seekers receive seeker live positions and speeds, and the roster (names, roles, counts).
- **Between pings**, hiders receive hider live positions and speeds, and the roster.
- **At a ping**, everyone receives every player's position. Speeds are not included in pings.
- A referee receives everything.
- Chat messages are fan-out filtered by channel and current role.
- When a role changes (for example a tag), the server immediately sends the affected player a fresh filtered `state_sync`. The converted player gets **seeker view only** from then on.
- Full tracks and stats are only sent after the game ends.
- Never include fields in a payload "just in case". If the app doesn't receive hider coordinates, it can't leak them.

### 6.5 Join Tokens & Abuse Protection
- Tokens are random 128-bit values, and the server stores only a hash. A token is valid for one game.
- Rate-limit joins per IP and per code, cap message sizes, and cap total players and avatar/media sizes.
- Join codes are random enough (31⁶ ≈ 887 M combinations) that guessing is impractical, but also lock out an IP after repeated failures.
- All traffic is TLS (Render provides HTTPS/WSS automatically).

### 6.6 Restart Recovery via On-Device Snapshots
Render can restart a free instance at any time, wiping memory. Instead of an external database, **the players' phones hold the backup**.

**Saving**
- Whenever state changes meaningfully (join/leave, role change, tag, ping, settings or geofence change, game start/pause/end, out-of-bounds conversion) and at least every ~60 s, the server builds a snapshot and sends it to **every connected client** as `snapshot {version, blob}`. `version` is a monotonically increasing counter.
- **Contents:** settings, geofence, timers (as absolute timestamps), players (names, colors, roles, role history, token hashes), pings, and events.
- **Not included:** avatars, **chat and media** (they live on the devices), and **tracks**. Each phone already holds its own full track locally (FR-37). Last-known live locations aren't needed either, because phones resend them within seconds of reconnecting.
- **Size:** a compressed snapshot should be roughly 10–50 KB. Because it's event-driven rather than constant, the cost per phone is a few MB per game.
- **Encryption:** the blob is **AES-GCM encrypted** with a key derived from a server secret (a Render environment variable that survives restarts) and the game code. Phones **store it but can't read it**, so a player can't dig hider or seeker positions out of their own phone's copy. GCM also makes tampering detectable. The server rejects blobs that fail authentication.
- **On the phone:** the latest blob per game is written to a small local file (`SnapshotStore`), so it survives an app kill. It's deleted when the game ends.

**Restoring**
1. The server restarts with no memory. Every phone's socket drops, and the phones auto-reconnect with `rejoin {code, token, snapshotVersion}`.
2. The server doesn't recognize the game and replies `need_restore`. It opens a short **restore window (~10 s)** for that game code and collects the snapshot versions the phones report.
3. The server asks for the blob from the **leader's phone first**, and **the leader's snapshot wins** whenever the leader reconnects within the window. If the leader has lost signal or doesn't show up, the server uses the **highest-version** snapshot reported by any other phone.
4. The phone sends `restore {code, version, blob}`. The server decrypts and validates it, rebuilds the game, increments `epoch`, and sends everyone a fresh `state_sync`.
5. **Timers:** all timers are absolute timestamps, so countdowns continue. Missed pings during downtime collapse into **one** immediate ping, after which the schedule resumes. Out-of-bounds timers **and dark-hider timers** are reset, so players get a fair full grace period and nobody is converted just because the server was down.
6. **Tracks:** the server lost its in-memory tracks, so every phone **re-uploads its full track from sequence 0** whenever it sees a new `epoch`. A 30-minute track is only ~70 KB per player.
7. **Avatars and chat:** clients re-send their avatar on rejoin. Chat history is on each phone, so nothing is lost. Messages that the server was still relaying at the moment of the restart are re-sent from the senders' outboxes.

**Limits**
- If **every** phone is closed or offline during the restart, there's nothing to restore from and the game is lost. That's acceptable for friends-only games.
- A malicious player could replay an old blob they hold, but they only hold ciphertext of their own game, and since the leader's snapshot wins, this is a non-issue among friends.
- A restart before the first snapshot (lobby just created) simply loses the lobby, and players re-create the game.

---

## 7. iOS App Design

### 7.1 Stack
- **Language/UI:** Swift 6 and SwiftUI, iOS 17+ target (new MapKit SwiftUI API, `@Observable`, Swift Charts).
- **Maps:** MapKit with `MapCircle` for the geofence, `MapPolyline` for routes, and custom annotations (with avatars) for pins.
- **Location:** CoreLocation.
- **Charts:** Swift Charts for speed-over-time.
- **Networking:** `URLSessionWebSocketTask` for the game socket. A small `GameClient` wraps it with auto-reconnect and exponential backoff. No third-party SDK is needed.
- **Local storage:** `ProfileStore` (name, color, avatar), `TrackBuffer` (the current game's track, written to a file so it survives an app kill), `SnapshotStore` (the latest encrypted game snapshot for restart recovery), `ChatStore` (chat history and received media files, per game), and `HistoryStore` (saved results and chat, on-device only).
- **Bundle ID:** `com.tarunpatanjali.hidenseek`. Sideloading tools usually rewrite it per Apple ID (§8.2), so it's mostly a label.
- **Media (lossless only):** `PhotosPicker` and `AVCaptureSession` (in-app capture at 1080p HEVC). Strip GPS metadata from photos without re-encoding via `CGImageDestinationCopyImageSource`, and from videos with `AVAssetExportPresetPassthrough`. No resizing or transcoding. Saving to the Photos library uses `PHPhotoLibrary` with **add-only** access (`NSPhotoLibraryAddUsageDescription`), and GIFs are excluded. ⚠️ Verify these APIs when implementing.
- **Architecture:** MVVM with a `GameClient`, a `LocationService`, and the stores above. Keep game logic out of views.
- **Free-account limits:** no push notifications, no Associated Domains (universal links), and no iCloud/CloudKit. This design needs none of them.

### 7.2 Background Location (the hardest iOS part)
- Enable the *Location updates* background mode. ⚠️ Confirm it's allowed under a free personal team in your Xcode version (it normally is).
- Request **When In Use** first, then upgrade to **Always** with a clear in-app explanation. Set `allowsBackgroundLocationUpdates = true` and `showsBackgroundLocationIndicator = true`.
- **How it stays alive without push:** an active background location session keeps the app running, so the WebSocket stays open and location updates keep flowing. This must be tested on real devices early, because the Simulator is no help.
- iOS can still suspend a WebSocket in some conditions. The client reconnects on resume and requests a `state_sync`. If the socket drops in the background, the track buffer keeps recording locally and uploads when the connection returns.
- Local notifications cover "ping arrived" and "you're out of bounds" while backgrounded, but only while the app is running.

### 7.3 GIFs
- Use the **GIPHY API** (free developer key) through a server endpoint (`/gifs/search`) so the key isn't shipped in the app. Store only the GIF URL in the message. ⚠️ Free keys are rate-limited. Google has announced changes to the Tenor API, so check its status before choosing it.

### 7.4 Key Screens
Home (create / join) → **Profile & Settings** (name, photo, color, units, auto-save media toggle) → Lobby (players, roles, settings) → **Map** (main game view with HUD: countdown, next ping, role badge, own speed and distance) → Chat sheet (channel tabs) → Tag sheet → Settings (leader) → **Results** (stats, awards, routes map, speed chart, replay) → **Past games** (local).

### 7.5 Transient Chat Relay on a Small Server
The free Render service has ≈512 MB RAM and no persistent disk ⚠️, and chat/media live on the phones, so the server only needs a **short-lived in-memory relay**.
- **No product limits, but safety ceilings:** the app doesn't limit photo or video size or length, but the server has to protect itself. The in-memory relay buffer is capped (~200 MB total) and a single file has a high ceiling (~150 MB, ⚠️ tune after testing). If the buffer is temporarily full, the sender's app shows "sending…" and retries automatically. A file above the ceiling fails with a clear message, which should be very rare with in-app 1080p recording.
- **Lifetime:** a file is deleted once all authorized recipients have downloaded it, or after ~20 minutes. Text envelopes live ~10 minutes.
- **Bandwidth:** lossless media is bigger than compressed media, and the server sends one copy per recipient. A 15 MB video sent to 20 players is ~300 MB of outbound traffic. Render's free plan includes limited monthly bandwidth ⚠️ (check the current number), so this adds up only if a lot of video is sent. Photos are small by comparison.
- **Phone data use:** the same applies to players' cellular data. Videos download on tap, and photos download automatically.
- **Phone storage:** media stays on each phone until the player deletes the game's chat or past game.
- If bandwidth or memory ever becomes a problem, options are to introduce a video size cap, or to relay media through a free object store such as Cloudflare R2 ⚠️, which needs a card.

### 7.6 Free-Server Limits to Respect
- ~20 players sending `location` every ~4 s plus track batches every ~10 s is only a few messages per second. It's trivial for one Node process.
- A soft cap of ~50 players per game and ~5 concurrent games protects the 512 MB budget.

---

## 8. Hosting, Distribution & Cost

### 8.1 Hosting

| Component | Choice | Cost | Notes |
|---|---|---|---|
| Backend | **Render free web service** ⚠️ | $0 | ~750 instance-hours/mo. WebSockets supported. **Spins down after ~15 min without inbound traffic** (30–60 s cold start). Restarts can happen. ≈512 MB RAM. No persistent disk |
| Cold-start mitigation | App calls `GET /health` on launch and on the Create/Join screen | $0 | Active games keep it awake through constant traffic ⚠️ verify that WebSocket traffic counts |
| Maps | Apple MapKit | $0 | No API key |
| GIFs | GIPHY | $0 | Free key, rate-limited |
| Domain | `*.onrender.com` | $0 | Good enough for friends |

### 8.2 Distribution without a paid Apple account

You can't use TestFlight or Ad Hoc distribution without the $99 program. The free options all work by signing the app with **each phone owner's own free Apple ID**, which has these limits ⚠️:
- Signed apps **expire after 7 days** and must be re-signed (refreshed).
- A free Apple ID is limited to about **3 sideloaded apps at once** and a small number of new app IDs per week.
- Each friend's iPhone needs **Developer Mode** turned on (Settings → Privacy & Security → Developer Mode, iOS 16+).
- Sideloading tools re-sign the app and typically change the bundle ID (for example by adding a suffix tied to the friend's Apple ID). The app mustn't depend on its bundle ID at runtime.

**Options, easiest first**

| Method | How it works | Pros | Cons |
|---|---|---|---|
| **SideStore** (or AltStore) | You build an `.ipa`; each friend installs the sideloading app and uses it to install and refresh Hide n Seek with their own Apple ID | Free. SideStore can refresh on-device, while AltStore needs the friend's computer on the same Wi-Fi | Setup takes ~15–30 min per friend (needs a computer once for pairing). Needs weekly refresh |
| **Sideloadly** | Friend installs the `.ipa` from a Windows/Mac computer using their Apple ID | Simple, one-off install | Same 7-day expiry, with manual re-install every week |
| **Xcode from source** | Friends with Macs clone your GitHub repo and run it on their phone | No extra tools | Only works for friends with Macs and Xcode |

**Practical plan**
1. Build an unsigned `.ipa` (Xcode archive or `xcodebuild` with signing disabled) and host it as a **GitHub Release** (free). Friends download it and sideload it with their own Apple ID. The tool re-signs it for them.
2. Before each game day, ask friends to **refresh the app** so it hasn't expired. Add an in-app "your build expires in N days" reminder if feasible.
3. For a smoother experience, start with 3–5 close friends who are willing to do the setup. You can add more later.

**Trade-offs and cost**
- The weekly re-signing is the main pain point. If it becomes annoying, the $99/yr program (about $5 each if 20 friends split it) removes it, adds TestFlight links with 90-day builds, and unlocks push notifications and universal links. You've decided not to pursue it now, and nothing in the design depends on it.
- **Not recommended:** enterprise certificate resellers (unreliable and risky, and the apps can be revoked without warning), and a web-only PWA (iOS Safari can't track location in the background, which breaks hiding).
- Jailbreak/TrollStore options don't apply to a current iOS 17+ phone.

### 8.3 Why not the alternatives for hosting
- *Supabase:* would work, but needs anonymous auth, Row Level Security, and a cron scheduler. That's more machinery than an in-memory server for a 20-player friends game. It also pauses after a week idle.
- *Oracle Always Free VM:* generous (up to 4 ARM cores / 24 GB RAM ⚠️), never sleeps, and has real disk. But it has capacity and idle-reclamation quirks, and you'd manage the OS, TLS, and updates. It's a good future move if Render's cold starts or restarts annoy you, and the same Node server would run there unchanged.
- *Firebase:* Cloud Functions and Storage require the paid plan ⚠️, and per-read billing suits this poorly.

---

## 9. Edge Cases to Design For

- **Phone dies / loses signal:** the last known location is shown with "stale" age. The phone keeps recording its track and uploads it later, if it comes back before cleanup. A hider with no location for the dark-hider limit (default 2 min, leader setting) is auto-converted to a seeker (decision 30).
- **Player closes or loses the app:** iOS may kill it. Show a "location sharing lost" indicator to the leader, and prompt the player to reopen. The track buffer file survives the kill, so the route can resume.
- **Server cold start or restart:** see §6.6 and §8.1.
- **Leader leaves or loses signal:** auto-promote another player.
- **Changing settings mid-game:** shortening the duration below elapsed time ends the game. Moving the geofence may put players out of bounds immediately, so apply the grace period.
- **Simultaneous tags:** handled by single-threaded processing, so the win check runs after each tag.
- **Role changes and leaks:** a converted player immediately loses hider-channel and hider-live-location access (§6.4).
- **Vehicles and GPS glitches:** samples over ~12 m/s are discarded from distance and top-speed calculations. A rider on a bike or in a car won't skew the stats, though the rest of their route still plots.
- **Stat accuracy indoors:** indoor GPS jitter can add false distance, so the stationary filter in FR-39 matters. Make the thresholds tunable.
- **Clock drift:** server time only.
- **Same device in two games:** disallow, or switch contexts explicitly.
- **Lost token:** if a player deletes the app and returns, they can only rejoin as a new player, since there's no account. The leader can reassign them.
- **Missed chat:** a phone that's offline longer than the relay timeouts (~10 min for text, ~20 min for media) misses those messages. There is no backfill, by design.
- **Phone storage:** lossless media can fill a phone over many games. Past games show their storage size and can be deleted.
- **Expired sideload:** if a friend's build expires on game day, they can't launch the app. See §8.2.

---

## 10. Privacy & Safety

- Location is shared only **during an active game**, and only with players in that game.
- Profile data and past-game results live on your device. The server holds the name, color, and a tiny avatar for the game's lifetime. The avatar is in memory only. Restart snapshots exist only as encrypted blobs on the players' own phones (§6.6), the server has no database, and **everything is deleted at cleanup** (FR-50).
- Full routes are shared with all players of that game, but only after it ends (FR-45).
- Write clear `NSLocationWhenInUseUsageDescription` and `NSLocationAlwaysAndWhenInUseUsageDescription` strings, and show a first-run explanation of what is shared and with whom, including that routes and speeds are recorded and revealed at the end.
- Chat and media live on the players' phones. The server relays them transiently in memory and never writes them to disk. Photos and videos have **GPS metadata stripped** before sending, so they can't reveal a hiding spot.
- Server logs should not contain coordinates, names, or message contents. Log only counts and errors.
- Keep a leader "remove message / kick player" tool.
- In-app safety reminders: obey traffic laws, stay off roads and private property, and no running into traffic. Provide an always-working "Leave game / stop sharing" button.
- If any players are minors, make sure parents or guardians know about the location sharing.

---

## 11. Suggested Roadmap

| Phase | Goal | Contents |
|---|---|---|
| **0 – Spike** (≈1 wk) | Prove the hard parts | Minimal Node WebSocket server on Render. iOS app sends background GPS from a real phone and shows it live on a second phone's map. Test with the screen locked. Sideload one friend's phone with SideStore to confirm the install flow |
| **1 – MVP** (2–4 wks) | One playable game | Local profile, create/join with code, lobby, manual roles, circle geofence, head start + 5-min pings, tagging, win conditions, text chat, rejoin via token, **local track recording + live speed/distance HUD** |
| **2 – Full rules & stats** | Everything in §3 | Random assignment, out-of-bounds flow, live settings changes, team channels, photos/GIFs/video, **save-media-to-Photos prompt**, **track upload, stats, results map, speed chart, awards, past games** |
| **3 – Resilience & polish** | Friends-ready | **device-held encrypted snapshots and restart recovery**, haptics/sound, onboarding, cold-start handling, expiry reminders, crash/reconnect hardening |
| **4 – Later** | Nice to have | Replay scrubber, Live Activities, spectators, polygon geofences, power-ups; push and universal links if you ever buy the Apple account |

---

## 12. Decisions Log

| # | Decision |
|---|---|
| 1 | Seekers who leave the area get a warning and a ping only, with no conversion |
| 2 | A converted seeker gets the seeker view only |
| 3 | Everyone sees the full roster with names and the remaining-hider count |
| 4 | A tag is marked by the seeker alone, with no location or proximity check |
| 5 | The leader can play or act as a referee |
| 6 | ~~Videos capped at 15 seconds~~ Superseded by #25: no product limit |
| 7 | Restarts are tolerated. Recovery uses encrypted snapshots held on the players' phones. The leader's snapshot wins, unless the leader has lost signal, in which case the highest version wins. No external database |
| 8 | No paid Apple account, so friends sideload the app |
| 9 | iOS 17+ only |
| 10 | App name: **Hide n Seek** |
| 11 | Speed, distance, and routes are tracked live, and shown with a results map at the end |
| 12 | Seekers can't see hiders' live speed. Everyone's stats are revealed at the end |
| 13 | Units default to mph, with a km/h toggle |
| 14 | Static routes on the results map. The replay scrubber is deferred |
| 15 | Past games are saved on-device by default |
| 16 | Bundle ID: `com.tarunpatanjali.hidenseek` |
| 17 | Chat and media are stored on devices. The server only relays them transiently |
| 18 | Photos and videos are sent losslessly: no recompression, only GPS metadata is stripped |
| 19 | 5-minute head start, then a ping when it ends and every 5 minutes. Everyone receives everyone's location at each ping. All of these are configurable |
| 20 | Server language: TypeScript on Node (a single-threaded game loop avoids locking bugs) |
| 21 | One repo with `/ios` and `/server` folders |
| 22 | You'll create the GIPHY developer key |
| 23 | The 30-minute hunt starts after the 5-minute head start (35 minutes total with defaults) |
| 24 | During the head start each side sees only its own teammates. The first full ping fires when it ends |
| 25 | No product limit on photo or video size or length. The server keeps a high safety ceiling |
| 26 | No chat backfill for phones that were offline |
| 27 | At the end of a game, the app offers to save all photos and videos (not GIFs) to the Photos library |
| 28 | Saved media is limited to what each phone received, so team-only channel media is saved only by that team |
| 29 | An **"Automatically save photos & videos to Photos"** toggle lives in the app's Settings/Profile page (off by default). When on, the end-of-game prompt is skipped |
| 30 | Hiders who go dark (no location for ~2 min) are auto-converted to seekers, configurable |
| 31 | Phase 0 assumptions (§13 B) are to be verified in the spike. Minor details (§13 C) are settled during the build |

## 13. Still Open

No product questions are waiting on you. These remain:

**A. Hiders going dark: DECIDED.** Hiders with no location update for ~2 minutes are auto-converted to seekers (leader setting, 0 = off). See decision 30.

**B. Assumptions to verify in the phase 0 spike (marked ⚠️ above)**
- Render's free tier keeps the instance awake while WebSockets and location traffic are flowing, and a mid-game restart really recovers from the phones' snapshots.
- Background location keeps the socket alive with the screen locked, and works under a free Apple ID personal team.
- Sideloading flow (SideStore/AltStore) works on a friend's iPhone, including the weekly refresh.
- Render's free bandwidth and RAM are enough for lossless media, and the ~150 MB file ceiling is sensible.
- GIPHY free-key limits are enough for 20 players.
- GPS accuracy and the out-of-bounds jitter rule (FR-17) hold up outdoors and near buildings.

**C. Small details I'll settle while building**
- Minimum players and role counts needed to start (for example at least one hider and one seeker).
- Exact pause/resume behavior, and what happens if the leader is the only referee and disconnects.
- Media upload transport (a binary WebSocket frame or a separate HTTPS upload).
