# Hide n Seek: Design & Architecture

A real-world, location-based hide-and-seek game for iPhone, in the style of Manhunt and Scram. This document describes the system **as built**: what it does, how it's put together, why the main choices were made, and what is still unverified or not built. For setup and usage, see [README.md](README.md).

**Scope.** Friends only, about 20 players at a time (soft cap 50). iOS 17 or later. Runs on free services. No App Store release: the app is sideloaded with a free Apple ID.

**Contents**

1. [Game rules](#1-game-rules)
2. [Requirements and status](#2-requirements-and-status)
3. [Architecture](#3-architecture)
4. [Server design](#4-server-design)
5. [iOS app design](#5-ios-app-design)
6. [Hosting, distribution and cost](#6-hosting-distribution-and-cost)
7. [Privacy and safety](#7-privacy-and-safety)
8. [Testing and verification](#8-testing-and-verification)
9. [Design decisions](#9-design-decisions)
10. [Known limitations and unverified assumptions](#10-known-limitations-and-unverified-assumptions)

---

## 1. Game rules

### 1.1 Roles

| Role | What they can do |
|---|---|
| **Leader** | Creates the game and controls roles and rules before and during play. Can play as a hider or seeker, or act as a **referee** who sees everyone and doesn't play. If the leader is disconnected for 2 minutes, the longest-present connected player becomes leader. |
| **Seeker** | Hunts hiders and can tag them. |
| **Hider** | Hides. Can mark themselves tagged. |

A tagged hider becomes a seeker. There is no elimination, so nobody sits out.

### 1.2 Flow of a game

1. A player creates a game and gets a **6-character code** (alphabet without `0 O 1 I L`) and an invite link `hidenseek://join/CODE`. Others join with it. No sign-in.
2. In the **lobby** the leader assigns roles (manually or randomly), sets the play area, and tunes the rules. A game can't start until everyone has a role and there's at least one hider and one seeker.
3. **Head start** (5 minutes by default): hiders hide, seekers wait. Tagging is disabled.
4. The **hunt** (30 minutes by default) starts when the head start ends. The total game is head start plus hunt, 35 minutes with defaults.
5. **Pings:** the first fires when the head start ends, then one every 5 minutes. At every ping, **everyone receives everyone's position** as of that moment. With defaults that is at 5, 10, 15, 20, 25 and 30 minutes, and the game ends at 35. If the head start is 0, the first ping fires after one interval.
6. A seeker who catches a hider in person taps **Tag**. There is no location or proximity check. Hiders may also tag themselves ("I'm out"), and the leader can force a hider to become a seeker.
7. The game ends when **every hider is tagged** (seekers win) or **time runs out** with at least one hider free (hiders win), or the leader ends it.
8. A **results** screen shows routes, stats and awards. The server then deletes the game.

### 1.3 Visibility

| Viewer | Live between pings | At each ping |
|---|---|---|
| Seeker | Seekers (self and teammates) | Everyone, as of that moment |
| Hider | Hiders (self and teammates) | Everyone, as of that moment |
| Referee | Everyone | n/a |

A player converted to a seeker gets the seeker view only from then on. Their hiders-channel chat history is hidden until the game ends. After the game ends, everyone's live data and full routes are visible to everyone.

Live **speed** follows the same rule as live location: a hider can't see seekers' speeds and vice versa, until the game ends. Teammates' speeds can be turned off by the leader.

### 1.4 Play area (geofence)

A circle: center and radius (10 m to 50 km on the server; the app's slider offers 50 m to 3 km). It can be moved or resized during the game.

- A player counts as **outside** only after **two consecutive** samples where `distance − accuracy > radius`, so GPS noise near the edge doesn't cause false alarms.
- When that happens, **everyone gets an alert with that player's current location**.
- **Hiders** then have a grace period (60 s by default) to come back. If they do, the alert is cleared. If not, they become seekers.
- **Seekers** get the alert and warning only. They are never converted. The leader can turn seeker warnings off.
- If no center is set, the geofence is simply off.

### 1.5 Offline hiders

A hider who sends no location for 2 minutes (airplane mode, killed app, no location permission) is converted to a seeker. This closes the loophole of going dark to avoid pings. The setting is configurable and 0 turns it off. The app re-sends its last fix at least every 15 seconds so a hider standing still in a hiding spot isn't mistaken for offline. After a server restart or a pause, these timers are reset so nobody is converted because of downtime.

### 1.6 Leader settings

All editable before and during the game. The server clamps values to sane ranges and drops unknown keys.

| Setting | Default | Notes |
|---|---|---|
| Head start | 5 min | 0 to 60 min |
| Hunt length | 30 min | Counted after the head start. Changing it mid-game moves the end time |
| Ping interval | 5 min | |
| Out-of-bounds grace | 60 s | |
| Warn seekers who leave the area | on | Warning only |
| Convert offline hiders after | 2 min | 0 = never |
| Hiders can tag themselves | on | |
| Allow joining after start | on | Late joiners become seekers or hiders per setting (default seekers) |
| Seekers see each other live | on | |
| Show teammates' speed | on | |
| Chat / photos and videos | on / on | |
| End-of-game awards | on | |
| Play area center and radius | unset / 500 m | Set from a map |

The leader can also pause and resume (all timers shift by the paused time), trigger an immediate ping, force a hider to become a seeker, change anyone's role, and remove players.

### 1.7 Stats and awards

Each phone records its own route (position, speed, accuracy, timestamp) at up to about 1 sample per second while the game is active.

Samples are cleaned before any stat is computed:
- Drop fixes with accuracy worse than 25 m.
- Drop jumps implying more than 12 m/s (about 27 mph), which are GPS glitches. After 5 consecutive drops the reference point resets so a real relocation isn't stuck.
- Ignore movement under 3 m between samples, so GPS jitter while standing still doesn't add distance.
- Speed uses CoreLocation's speed when valid, otherwise distance over time, smoothed with a 3-point average. "Moving" means above 0.5 m/s. Gaps longer than 30 s count as "no data", not "still".

Per-player stats: total distance (split into hider and seeker distance for converted players), top speed, average moving speed, moving versus still time, time survived (hiders), tags made, and a downsampled speed-over-time series. Awards: Fastest, Marathoner (farthest), Statue (least movement among hiders), Last one standing, Top tagger.

---

## 2. Requirements and status

| Area | Requirement | Status |
|---|---|---|
| Identity | No sign-in. Name, color, photo stored on the phone only. Per-game secret token allows rejoining as the same player | Built |
| Joining | Codes, share links, rejoin after crash or signal loss, soft cap of 50 players | Built |
| Roles | Manual, random, referee, leader hand-over | Built |
| Play area | Circle, live edit, noise-tolerant out-of-bounds flow | Built |
| Timing | Head start, pings to everyone, pause/resume, manual ping, configurable | Built |
| Visibility | Enforced per player on the server | Built |
| Tagging | Seeker tag, hider self-tag, leader override | Built |
| Tracking | Live speed and distance, full routes, gap-free upload | Built |
| Results | Routes map, speed chart, stats, awards, saved on-device | Built |
| Chat | Three channels, text, photos, videos, GIFs, on-device storage | Built |
| Media | Lossless, GPS stripped, no app-side size limit, save to Photos at the end | Built |
| Resilience | Restart recovery from encrypted snapshots held on the phones | Built |
| Settings page | Units (mph/km/h), auto-save media, profile, server address | Built |
| Past games | Saved on-device, deletable | Built |
| Notifications | Local notifications and haptics for pings, tags, out-of-bounds, chat | Built |
| Replay scrubber | Animated playback of a finished game | Not built (routes are kept at full resolution so it can be added) |
| Players pick their own role | Optional lobby mode | Not built |
| Live Activities | Countdown on the lock screen and Dynamic Island | Not built |
| Chat backfill | Phones syncing missed messages from each other | Not built (decided against) |
| Push (APNs), TestFlight, App Store | Need a paid Apple account | Out of scope |

---

## 3. Architecture

```
┌──────────────────── iPhone (SwiftUI, iOS 17+) ────────────────────┐
│  GameClient        connection, state, tracking, chat, snapshots   │
│  LocationService   CoreLocation with background updates           │
│  Local stores      profile · chat + media · route · snapshot ·    │
│                    results (all on the phone only)                │
└───────────────┬───────────────────────────────────────────────────┘
                │ wss:// JSON (game)        https:// (media, GIF search)
┌───────────────▼────────────── Render free web service ────────────┐
│  Node 22 + TypeScript, single process, no database                │
│                                                                   │
│  app.ts     WebSocket commands · HTTP endpoints · timers          │
│  room.ts    a game room: members, chat/media relay, snapshots     │
│  engine.ts  pure rules: roles, pings, geofence, tags, visibility  │
│  stats.ts   route cleaning, stats, simplification, awards         │
└───────────────────────────────────────────────────────────────────┘
        External: GIPHY API (via the server) · Apple MapKit (free)
```

### Core design ideas

1. **The server is the referee.** Phones send locations and commands. The server validates them, runs the clock, and sends each player only the view they're allowed to see. Clients never decide pings, geofence violations, or timer expiry.
2. **No database.** Each active game is an object in memory. It is deleted about 30 minutes after it ends (or after 30 minutes with nobody connected).
3. **The phones are the backup.** Whenever the game changes meaningfully, the server sends every phone an encrypted snapshot only the server can read. After a restart, phones hand it back and the game resumes (section 4.7).
4. **Chat and media live on the phones.** The server is a short-lived relay that forgets a message once everyone has it.
5. **A pure rules engine.** `engine.ts` has no sockets or timers. Time and randomness are injected, so the rules are tested with a fake clock.

### Why a custom server instead of a backend-as-a-service

A game with roles, hidden information, timers, and per-player filtered views fits an authoritative server better than database rules plus a scheduler. One small Node process handles all of it, and its single thread processes commands one at a time, so two simultaneous tags can't race. See the decisions in section 9.

---

## 4. Server design

### 4.1 Files

| File | Responsibility |
|---|---|
| `src/engine.ts` | `GameEngine`: players, roles, settings, head start, pings, geofence, tagging, pause, win conditions, visibility (`viewFor`), serialization for snapshots |
| `src/room.ts` | `Room` (members, sockets, chat and media relay), `Registry` (create, find, restore, sweep), snapshot encryption |
| `src/app.ts` | WebSocket message handling, HTTP routes, the 1-second tick loop, results timing, restore handling, rate limiting |
| `src/stats.ts` | Route cleaning, per-player stats, route simplification, speed series, awards, the results payload |
| `src/index.ts` | Starts the server on `PORT` |

### 4.2 Rules engine

`GameEngine` holds the game status (`lobby`, `active`, `ended`), settings, players, pings, and an event log. Key behaviors:

- `start()` requires a hider, a seeker, and no unassigned players. It computes `huntStartsAt = start + headStart` and `endsAt = huntStartsAt + duration`.
- `tick()` (about once per second) converts hiders past their out-of-bounds grace, converts offline hiders, fires a ping when due, and checks win conditions. If it's late (for example after a restart), missed pings collapse into one.
- `onLocation()` stores the position and applies the geofence rules.
- `viewFor(playerId)` is the only way game data reaches a client (section 4.4).
- `toJSON()` / `fromJSON()` serialize the game for snapshots. `resetTimersAfterRestore()` restarts the dark-hider and out-of-bounds timers.

### 4.3 Protocol

Game traffic is JSON over a WebSocket at `/ws`. Media and GIFs use HTTP.

**Client to server**

| Message | Purpose |
|---|---|
| `create`, `join {code}` | Start or join a game. Carry `name`, `color`, and a small base64 `avatar` |
| `rejoin {code, token}` | Resume as the same player |
| `restore {code, token, version, blob}` | Hand the server an encrypted snapshot after a restart |
| `location {lat, lng, acc, speed}` | Live position, about every 3 s while moving and at least every 15 s otherwise |
| `track_batch {from, points}` | Route history starting at point index `from`. The server replies `track_ack {epoch, count}` |
| `track_done` | The phone has uploaded its full route after the game ended |
| `set_role`, `assign_random`, `update_settings`, `set_geofence` | Leader only |
| `start`, `end`, `pause`, `resume`, `manual_ping`, `force_seeker`, `kick` | Leader only |
| `tag {hiderId}`, `self_tag` | Tagging |
| `chat {id, channel, kind, body, mediaId, mime, size}`, `chat_received {id}` | Send a message and acknowledge one |
| `set_avatar`, `get_results`, `leave`, `ping` | Misc |

**Server to client**

| Message | Purpose |
|---|---|
| `joined {code, playerId, token, epoch}` | Entry confirmed |
| `state` | The player's filtered view of the game (section 4.4), sent immediately on structural changes and at most every 2 s for live positions |
| `event` | Something happened: started, ping, out-of-bounds start or return, converted, paused, resumed, ended. Events are public |
| `avatars` | Map of player id to small photo |
| `chat`, `chat_ack` | An incoming message, and confirmation that the server took yours |
| `track_ack` | How many route points the server holds for you |
| `snapshot {version, blob}` | Encrypted restart snapshot |
| `need_restore` | The server restarted and doesn't know this game. Send `restore` |
| `game_over`, `results {version, results}` | The game ended, and the final results |
| `error {message, fatal}` | A rejected command, or a fatal condition such as being removed |

**HTTP**

| Route | Purpose |
|---|---|
| `GET /health` | Health check, also used by the app to wake the free server |
| `POST /media` | Upload a photo or video to the relay. Returns `mediaId`. Authenticated with `x-code` and `x-token` headers |
| `GET /media/:id` | Download media. Only a recipient who still needs it may fetch it |
| `GET /gifs?q=` | GIPHY search proxy so the API key stays on the server |

### 4.4 Visibility enforcement (anti-cheat)

Every outgoing game payload is built by `viewFor(playerId)`:

- **Between pings:** a hider receives live hider positions, a seeker receives live seeker positions, a referee receives everyone.
- **At a ping:** one ping carrying everyone's position goes to everyone.
- **Speed** follows the same visibility as live position.
- **Roster and counts** (names, roles, hiders left) go to everyone.
- After a role change, the player's next `state` reflects their new role at once.
- **Chat** is routed by the recipient's current role. A hider-channel message is never sent to a seeker.
- **Routes and stats** are sent to everyone only after the game ends.

If the app never receives the other team's coordinates, a modified client can't leak them.

### 4.5 Chat and media relay

Chat and media are held on the phones. The server only relays:

1. A text or GIF message arrives as a `chat` message. The server checks the sender may post in that channel, works out which players may read it, and forwards it. Each recipient replies `chat_received`. When everyone has acknowledged, the server deletes it. Anything unacknowledged expires after **10 minutes**.
2. **Photos and videos** are uploaded first with `POST /media`, then referenced by `mediaId` in a `chat` message. Recipients download with `GET /media/:id`. Media is deleted once all recipients have it, or after **20 minutes**. A file nobody references is dropped after 5 minutes.
3. The sender keeps an outbox and re-sends text and GIFs the server hasn't acknowledged. A phone offline longer than the lifetimes above misses those messages. There is no backfill, by design.
4. Safety ceilings for the 512 MB free server: **150 MB per file**, **200 MB total** buffered. If the buffer is full the upload returns 503 and the app retries.

Media is **lossless**: the server stores and serves the exact bytes the phone uploaded.

### 4.6 Tracks, results and timing

- Each phone uploads its route in batches of up to 300 points. `track_batch {from}` is index-based, so re-sending after a dropout or restart is harmless: the server keeps only what it's missing and replies with its total, and the phone continues from there.
- When the game ends, phones flush the rest of their routes and send `track_done`. The server builds the results when everyone connected has finished, or after **15 seconds**, whichever is first. A late `track_done` triggers a recomputed results message.
- The results payload contains per-player stats, a simplified route (Ramer–Douglas–Peucker at 2 m, coordinates rounded to about 10 cm), a downsampled speed series, awards, pings, and events. Each phone saves it locally.

### 4.7 Restart recovery

Render can restart a free instance at any time, wiping memory. Instead of an external database, the phones hold the backup.

**Saving.** On meaningful changes (and at least every 60 s), at most one per 3 s, the server builds a snapshot and sends it to every connected phone. It contains settings, timers, players (names, colors, roles, token hashes, last locations), pings and events. It does **not** contain avatars, chat, media, or routes. It is encrypted with **AES-256-GCM** using a key derived (HKDF) from the server's `SNAPSHOT_SECRET` and the game code, so phones store it but can't read it, and any tampering is detected.

**Restoring.**
1. After a restart each phone reconnects with `rejoin`. The server doesn't know the game, so it replies `need_restore` and opens a **6-second window**.
2. Each phone answers `restore` with its token and its latest snapshot.
3. The server decrypts the candidates. It only accepts a snapshot whose sender's token matches a member inside it. **The leader's snapshot wins** if the leader is present. Otherwise the highest version wins.
4. The game is rebuilt, `epoch` increases by one, and every phone with a valid token is admitted. Timers continue from their absolute timestamps. Missed pings collapse into one. Dark-hider and out-of-bounds timers restart.
5. Because routes aren't in the snapshot, each phone re-uploads its full route from index 0 (about 70 KB for 30 minutes). Avatars are re-sent, and chat history is already on the phones.

If every phone is closed during the restart, nothing can restore the game. For a friends-only game this is accepted.

### 4.8 Security and abuse protection

- Tokens are random 128-bit values. The server stores only a SHA-256 hash, and a token is valid for one game.
- Commands check the sender's token, role and the game state. Leader-only commands are rejected for anyone else.
- Inputs are validated and clamped: names, colors, coordinates, settings, message sizes, batch sizes (600 points per batch, 20,000 per player), and avatar size.
- Entry messages (create, join, rejoin, restore) are limited to 60 per minute per IP. Locations closer than 400 ms apart are ignored.
- A WebSocket heartbeat every 20 seconds detects dead phones and stops proxies idling connections out.
- All traffic is TLS (Render provides HTTPS and WSS). Join codes have about 887 million combinations.

---

## 5. iOS app design

### 5.1 Structure

| File | Responsibility |
|---|---|
| `HideNSeekApp.swift` | App entry, deep links, and which screen shows for the current game state |
| `GameClient.swift` | The app's brain: WebSocket, session, game state, events, tracking, chat, snapshots, results |
| `LocationService.swift` | CoreLocation with background updates |
| `Models.swift` | Codable types matching the server's JSON, plus formatting |
| `HomeView`, `LobbyView`, `GameView`, `ChatView`, `ResultsView` | Screens |
| `Media.swift` | Lossless photo and video preparation, uploads and downloads, Photos saving, camera, GIF display, notifications |
| `ProfileStore`, `ChatStore`, `Storage` | On-device storage |

The app uses SwiftUI with the iOS 17 `@Observable` model. `GameClient` is the single source of truth, and views only display what it publishes.

### 5.2 Screens and navigation

The root view picks the screen from the game state: Home (no game), a connecting screen, Lobby, Game, or Results.

- **Home:** profile, create or join, past games, profile and settings.
- **Lobby:** join code and share, roster, role assignment, random roles, rules, play area, start.
- **Game:** full-screen map with the play-area circle, live teammates, last-ping positions of everyone else, out-of-bounds markers, a HUD (role, countdown, next ping, hiders left, your speed and distance), Tag or "I'm out", chat, roster, and a leader menu.
- **Chat:** channel tabs for the channels you may see, composer with photo/video, camera and GIF, unread badges.
- **Results:** winner, media-save prompt, awards, and three tabs (routes map, stats, speed chart).

### 5.3 Location and background operation

- The app asks for When In Use, then Always, and runs a background location session (`UIBackgroundModes: location`, with the blue status indicator). That session keeps the app alive with the screen locked, so the WebSocket stays open without push notifications.
- Location uses best accuracy and a 5 m distance filter. CoreLocation sends nothing while you stand still, so a timer re-sends the last fix at least every 15 seconds and records a stationary track point every 5 seconds.
- If location permission is denied, the HUD warns that the player will be removed as a hider.

### 5.4 Connection handling

- The session (code, token, server, player id) is saved so killing the app and reopening it rejoins the game.
- Reconnect uses exponential backoff (up to 15 s). A fresh create or join that can't reach the server gives up after 3 tries with a clear message.
- A 10-second timer sends `ping`. If no `pong` arrives for 35 seconds the app drops the socket and reconnects, which catches half-dead connections iOS doesn't report.
- Countdowns are computed from server timestamps and a measured clock offset, never from local timers alone.

### 5.5 Local storage

Everything for one game is in `Documents/Games/<CODE>/`:

```
chat.json      this game's messages
media/         received and sent photos and videos
track.json     this phone's full route (survives an app kill)
snapshot.json  latest encrypted snapshot (deleted when the game ends)
results.json   final results, which makes it a "past game"
```

Profile and preferences are in UserDefaults, with the avatar in Application Support. Leaving a game before it has results deletes its folder. Finished games stay until the player deletes them.

### 5.6 Media pipeline

- **Sending a photo:** the original bytes are copied through ImageIO without re-encoding and with GPS metadata excluded. If the location can't be removed, the photo isn't sent.
- **Sending a video:** exported with the passthrough preset (no re-encode) with location metadata filtered out.
- **In-app camera:** uses iOS's high-quality setting. A photo taken in-app is encoded once at maximum JPEG quality.
- **Receiving:** photos download automatically, videos on tap. The phone acknowledges only after saving the file, and shows "no longer available" if the relay timed out.
- **Thumbnails** are generated without decoding full-size files.
- **GIFs** are GIPHY URLs shown with a small animated-GIF view. Nothing is stored on the server.
- **Save to Photos** uses add-only permission, creates an album named "Hide n Seek – date", skips GIFs, and never saves the same item twice. The end screen asks, and a setting can auto-save.

### 5.7 Permissions

Location (When In Use and Always), local network (development), notifications, camera, microphone, and Photos (add-only). Each has a plain-language reason in `Info.plist`, generated from `project.yml`.

### 5.8 Project generation

The Xcode project is generated from `ios/project.yml` by XcodeGen and is not committed. Regenerating clears the signing team, which must be selected again in Xcode.

---

## 6. Hosting, distribution and cost

| Component | Choice | Cost |
|---|---|---|
| Server | Render free web service, Node 22, blueprint in `render.yaml` | $0 |
| Maps | Apple MapKit | $0 |
| GIFs | GIPHY API (free beta key) through the server | $0 |
| Code | GitHub | $0 |
| App distribution | Sideloading with each friend's own free Apple ID | $0 |

**Render free-tier behavior to design around** (verify current terms):
- The service sleeps after about 15 minutes without traffic and takes up to a minute to wake. The app calls `/health` when opened to wake it early.
- It can restart at any time, which section 4.7 handles.
- About 512 MB RAM and no persistent disk, which shapes the in-memory design and media ceilings.
- Limited monthly bandwidth. Lossless media is the main consumer: a 15 MB video sent to 20 players is about 300 MB.

**Distribution without a paid Apple account.**
- Apps signed with a free Apple ID **expire after 7 days** and must be refreshed. A free Apple ID allows only a few sideloaded apps at a time.
- Friends install through SideStore, AltStore or Sideloadly, each signing with their own Apple ID, and turn on Developer Mode. Hosting the unsigned `.ipa` as a GitHub Release is the intended path.
- Without a paid account there are no push notifications, no TestFlight, and no universal links, so invites use a custom URL scheme.
- A web app (PWA) isn't viable: iOS Safari can't track location in the background.
- The $99/year Apple Developer Program would remove the 7-day expiry and unlock TestFlight and push. It was deliberately declined.

---

## 7. Privacy and safety

- Location is shared only during an active game, and only with players in it.
- **Profile** (name, color, photo) is stored on the phone. A small 128 px version of the photo, plus name and color, goes to the server on joining and lives in memory only until cleanup.
- **Chat, media, routes and past games** are stored on the phones. The server never writes them to disk.
- **Restart snapshots** exist only as encrypted blobs on the phones. The server keeps no database.
- **Cleanup:** an ended game is kept about 30 minutes so everyone can fetch results, then deleted. Idle games are deleted after 30 minutes with nobody connected.
- **Photos and videos** have GPS metadata removed so they can't reveal a hiding spot. Routes are revealed to everyone only after the game ends.
- Server logs contain no coordinates, names or message contents.
- Safety: obey traffic laws, stay off roads and private property. A "Leave game" control is always available. If any players are minors, their guardians should know about the location sharing.

---

## 8. Testing and verification

**Automated (26 tests, `npm test`)**
- Rules engine (16): validation to start, the 35-minute timeline and ping times, pings carrying everyone, visibility between and at pings, a tagged hider's view, tagging rules and win condition, out-of-bounds with GPS noise and grace, seekers never converted, offline hiders, late pings after a restart, settings changes mid-game, random roles, referee view, nothing mutable after the end.
- Stats (7): distance and speed, glitch and accuracy filtering, jitter, hider/seeker distance split, route simplification, downsampling.
- End to end over real WebSockets and HTTP (3): a full game from lobby to results (roles, settings, head start, pings, visibility, tagging, chat channel privacy, lossless media relay with deletion after delivery, route upload edge cases, results); lobby behavior (random roles, bad codes and tokens, kick, late join rules, pause, leader hand-over, malformed input); and restart recovery (snapshot handback, leader wins over a staler snapshot, tampered or wrong-key snapshots rejected, route re-upload).

**Also verified**
- The server builds and runs in production mode.
- The iOS app compiles for iPhone with no errors or warnings.
- The app's Swift models decode real server messages from a played game.
- The app ran on a real iPhone against a local server, and the Render deployment answered its health check. A full multi-phone game on Render has not been played yet.

**Not covered by automation:** the SwiftUI screens themselves, background location with the screen locked, the camera, Photos saving, GIF search, Render's free-tier behavior over time, and the sideloading flow on friends' phones. Check these on real devices.

---

## 9. Design decisions

| Decision | Why | Alternatives considered |
|---|---|---|
| Native SwiftUI app, iOS only | Best background location and MapKit behavior | Cross-platform frameworks: not needed |
| Custom authoritative Node server | Hidden information, timers and per-player views are simplest in one process | Supabase or Firebase: need row-level rules, a scheduler, and anonymous auth. Firebase's functions and storage need a paid plan |
| In-memory game state, no database | Games are short-lived, and the server is trivially simple | An external database for restart recovery |
| Encrypted snapshots held by the phones | Restart recovery with no database or extra account | Neon free Postgres (considered, then replaced) |
| Render free tier | Free, supports WebSockets, simple deploy | Oracle Always Free VM: generous but capacity, idle-reclamation and ops burden. It remains a fallback, and the same server runs there unchanged |
| TypeScript on Node | A single-threaded game loop avoids locking bugs, with fast iteration | Go: lower memory but needs locks around shared state |
| Pings show everyone to everyone | Fair, simple, and keeps both sides in play | Role-specific pings (the first idea) |
| Head start first, then a 30-minute hunt | The hunt keeps its full length regardless of head start | Counting the head start inside the 30 minutes |
| Server-side visibility filtering | A modified app can't read what it never receives | UI-only hiding |
| Seekers aren't converted for leaving the area | They're already seekers. They get a warning and the alert | Converting or penalizing seekers |
| Offline hiders convert to seekers after 2 minutes | Prevents going dark to avoid pings | Honor system; showing a stale marker |
| Tagging has no proximity check | The group wanted it simple | A distance requirement |
| Chat and media held only on phones, relayed transiently | Privacy, and the free server has no storage | Storing media on the server or Cloudflare R2 |
| Lossless media, no app-side limits, GPS stripped | The group asked for no compression. Stripping location is a lossless privacy requirement | 720p transcoding and size caps (the first plan) |
| No chat backfill | Accepted for simplicity | Phones syncing from each other |
| Index-based route upload | Makes re-sending idempotent after dropouts and restarts | Sequence-numbered batches |
| GIPHY via the server | Keeps the API key out of the app | Tenor, whose API is changing |
| Profile on the phone, no sign-in | The group wanted no accounts | Anonymous server accounts |
| Past games saved on the phone | Matches the device-only data model | Server history |
| Sideloading with free Apple IDs | The group declined the $99 program | TestFlight, a PWA |
| Custom URL scheme for invites | Universal links need a paid account | Universal links |
| mph by default, km/h optional | The group's preference | |
| Static routes map, no replay (yet) | Enough for v1 | Animated replay |
| Auto-save media is an optional setting, off by default | Asking first avoids filling the Photos library | Always auto-save |
| Bundle ID `com.tarunpatanjali.hidenseek` | Chosen by the owner | |

**Changed during the build**
- Restart snapshots moved from an external database to the phones.
- Video limits (15 seconds) and recompression were removed in favor of lossless sending.
- Head start changed from 0 to 5 minutes and became a first-class part of the timeline.
- Dark-hider conversion was added after the loophole was found.
- The route upload protocol changed from numbered batches to index-based batches.
- In-app video recording uses iOS's high-quality setting instead of an explicit 1080p, which the simple camera API doesn't offer.

---

## 10. Known limitations and unverified assumptions

**Limitations**
- Free Apple ID builds expire every 7 days, so friends must refresh before a game.
- The free Render server sleeps and can restart. A restart is recovered from the phones' snapshots, but if every phone is closed at that moment, the game is lost.
- No push notifications. If iOS suspends the app, updates can be delayed until it wakes.
- Continuous GPS drains the battery.
- Phones offline for more than about 10 to 20 minutes miss chat sent meanwhile.
- The GIPHY beta key has a low hourly limit.
- A file over 150 MB can't be relayed by the free server.
- A modified app could still hold a legitimately received hider chat history after being converted. This is hidden by the UI only, and accepted among friends.

**Assumptions to confirm over time**
- Render keeps an active game's instance awake, and its free-tier limits (bandwidth, sleep, restarts) hold up.
- Background location reliably keeps reporting with the screen locked for a full game, including on a friend's older iPhone.
- The sideloading flow (SideStore or AltStore) works smoothly for friends, including the weekly refresh.
- GPS accuracy and the out-of-bounds noise rule behave well near buildings and trees.

**Possible future work**
- Animated replay of a finished game.
- Live Activities and the Dynamic Island countdown.
- Letting players choose their own role in the lobby.
- Polygon play areas, spectators, and power-ups.
- Push notifications and TestFlight, if a paid Apple account is ever bought.
