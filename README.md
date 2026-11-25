# Hide n Seek

A real-world, location-based hide-and-seek game for iPhone, in the style of Manhunt and Scram. Friends join a game with a code, hiders hide inside a play area drawn on a map, and seekers hunt them on foot using periodic location pings. When a seeker tags a hider in person, the hider joins the seekers.

It's built for a group of friends (designed for about 20 players at once) and runs entirely on free services: a small TypeScript server on Render's free tier and a native SwiftUI app that is sideloaded, not distributed through the App Store.

For the full requirements and the reasoning behind the design, see [SPEC.md](SPEC.md).

## Contents

- [How a game works](#how-a-game-works)
- [Features](#features)
- [Tech stack](#tech-stack)
- [Architecture](#architecture)
- [Getting started](#getting-started)
- [Configuration](#configuration)
- [Testing](#testing)
- [Project structure](#project-structure)
- [Privacy](#privacy)
- [Limitations](#limitations)
- [Not built yet](#not-built-yet)

## How a game works

1. **Create or join.** One player creates a game and gets a 6-character code (or an invite link like `hidenseek://join/ABC123`). Everyone else joins with it. There's no sign-in. Your name, color and photo live on your phone.
2. **Set up.** The leader assigns roles (by hand or randomly), drops a pin and sets the radius of the play area, and adjusts the rules. The leader can change nearly all of these during the game too.
3. **Head start.** When the game starts, hiders get a head start (5 minutes by default) to hide. Seekers wait.
4. **Hunt.** The first ping fires when the head start ends, and then one fires every 5 minutes. At every ping, **everyone sees everyone's location** as of that moment. Between pings, each side only sees its own teammates live. The hunt lasts 30 minutes by default.
5. **Tag.** A seeker who catches a hider in person taps **Tag** in the app, and the hider becomes a seeker. Hiders can also mark themselves tagged.
6. **Stay inside.** A player who leaves the play area triggers an alert to everyone with their location. Hiders then have 60 seconds to get back or they become seekers. Seekers who leave just get a warning. A hider who stops sharing their location for 2 minutes also becomes a seeker.
7. **Win.** Seekers win if every hider is tagged before time runs out. Hiders win if at least one is still free when the clock ends.
8. **Results.** The end screen shows everyone's route on one map, plus stats, awards and a speed chart.

The timings above are defaults. Head start, hunt length, ping interval, grace period and the offline limit are all configurable.

## Features

**Game**
- Join codes, share links, and automatic rejoin if the app crashes or loses signal
- Manual or random role assignment, plus a leader who can instead act as a referee who sees everyone
- Circular play area with live out-of-bounds handling that tolerates GPS noise
- Pings that show everyone's position to everyone, and server-enforced visibility between pings, so a modified app can't peek at the other team
- Pause and resume, a manual "ping now", leader role changes, and removing players
- Late joining (leader setting), and automatic leader hand-over if the leader disconnects

**Tracking and results**
- Live speed and distance for yourself, and teammates' speed (leader setting)
- Full route recording on each phone that's uploaded in the background and re-sent after dropouts, so the results map has no gaps
- Results screen with every player's route overlaid on a map (the selected player's route is colored by speed), stats (distance, top speed, average moving speed, moving versus still time, time survived, tags), awards, and a speed-over-time chart
- Imperial or metric units

**Chat**
- Three channels: Everyone, Seekers only, and Hiders only. A tagged hider loses access to the hiders' channel.
- Text, photos, videos and GIFs (GIFs come from GIPHY)
- Photos and videos are sent **losslessly**, with no resizing or recompression. The only change is that location metadata is stripped without re-encoding, so a photo can't give away a hiding spot.
- At the end of a game the app offers to save everyone's photos and videos (not GIFs) to your Photos library, or you can turn on automatic saving

**Privacy and resilience**
- Profile and past games are stored only on the phone
- Chat and media are stored only on the phones. The server just relays them briefly.
- If the free server restarts mid-game, the phones hand back an encrypted snapshot and the game resumes

## Tech stack

| Part | Technology |
|---|---|
| App | Swift, SwiftUI, MapKit, Swift Charts, CoreLocation (iOS 17+) |
| Server | Node.js 22, TypeScript, [`ws`](https://github.com/websockets/ws) (no framework, no database) |
| Realtime | WebSockets for game state, HTTP for media upload/download |
| Hosting | [Render](https://render.com) free web service |
| GIFs | [GIPHY](https://developers.giphy.com) API, called through the server so the key never ships in the app |
| Project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) builds the Xcode project from `ios/project.yml` |

## Architecture

```
┌──────────────── iPhone (SwiftUI) ────────────────┐
│ Profile, chat, media, routes, past games: local  │
│ CoreLocation (background) · MapKit · Swift Charts│
└───────────────┬──────────────────────────────────┘
                │ wss:// (JSON)        https:// (media, GIFs)
┌───────────────▼────── Render (free) ─────────────┐
│ Node + TypeScript, one process, all in memory    │
│  • rules engine: roles, pings, geofence, tags    │
│  • per-player visibility filter (anti-cheat)     │
│  • transient chat/media relay                    │
│  • route stats and results                       │
│  • encrypted snapshots, sent to every phone      │
└──────────────────────────────────────────────────┘
```

Key ideas:

- **The server is the referee.** Clients send their location and commands. The server validates everything, advances the game clock, and sends each player only the view they're allowed to see.
- **There is no database.** Each active game lives in memory and is deleted shortly after it ends.
- **The phones are the backup.** Whenever the game state changes, the server sends every phone an AES-GCM encrypted snapshot that only the server can read. If the server restarts, the phones reconnect and hand the newest snapshot back (the leader's wins), and the game resumes. Each phone also keeps its own full route and re-uploads it after a restart.
- **The rules engine is pure.** `server/src/engine.ts` has no sockets or timers, so it's tested with a fake clock.

## Getting started

### Prerequisites

- A Mac with Xcode (the version that supports iOS 17 or later) and [Homebrew](https://brew.sh)
- Node.js 20 or newer
- An iPhone running iOS 17 or later
- A free Apple ID. A paid Apple Developer account is **not** required.

### 1. Run the server locally

```bash
cd server
npm install
npm run dev        # listens on http://localhost:8080
```

Check it with `curl localhost:8080/health`, which returns `{"ok":true,...}`.

### 2. Build and run the app

```bash
brew install xcodegen
cd ios
xcodegen generate
open HideNSeek.xcodeproj
```

In Xcode:
1. Select the **HideNSeek** target and open **Signing & Capabilities**.
2. Set **Team** to your free Personal Team. If you don't see one, add your Apple ID under **Xcode → Settings → Accounts**.
3. Plug in your iPhone, enable **Developer Mode** (Settings → Privacy & Security), choose the phone as the destination, and press **Run**.
4. On the phone, trust your developer certificate under **Settings → General → VPN & Device Management**.

`xcodegen generate` recreates the Xcode project from `project.yml` and **clears your signing team**, so pick it again after regenerating.

In the app, open **Profile & Settings** and set **Server**:
- Local Mac: `ws://<your Mac's LAN IP>:8080/ws` (phone and Mac on the same Wi-Fi)
- Render: `wss://<your-service>.onrender.com/ws`

### 3. Deploy to Render

1. Push the repo to GitHub.
2. In the Render dashboard choose **New → Blueprint**, connect the repo, and apply. [`render.yaml`](render.yaml) creates a free web service for the `server` folder and generates a `SNAPSHOT_SECRET`.
3. In the service's **Environment** tab, add `GIPHY_API_KEY` (a free key of type **API** from developers.giphy.com). Without it, the GIF button reports that GIFs aren't available.
4. Open `https://<your-service>.onrender.com/health` to confirm the server is up, then use `wss://<your-service>.onrender.com/ws` in the app.

Render's free tier puts the service to sleep after about 15 minutes without traffic, and the first request afterward takes up to a minute. The app calls `/health` when you open it to wake the server early.

### 4. Share the app with friends

The app isn't on the App Store or TestFlight. Friends install it with a sideloading tool such as [SideStore](https://sidestore.io) or [AltStore](https://altstore.io), using their own Apple ID. Apps signed with a free Apple ID **expire after 7 days** and need to be refreshed, so ask friends to refresh before game day. Each friend's phone also needs Developer Mode turned on.

### Try a game with one phone

```bash
cd server
npm run bot -- <GAME CODE> Bot1     # a fake player that walks in circles around the play area
```

Create a game on your phone, add one or two bots, assign roles in the lobby, set a play area, and start. Use short rules (a 1-minute head start and 1-minute pings) to see a whole game quickly. To point a bot at Render, set `URL=wss://<your-service>.onrender.com/ws`.

## Configuration

### Server environment variables

| Variable | Required | Purpose |
|---|---|---|
| `PORT` | no | Port to listen on (default `8080`; Render sets this itself) |
| `SNAPSHOT_SECRET` | yes for restart recovery | Long random string used to encrypt the snapshots the phones hold. If it changes, games in progress can't be restored. `render.yaml` generates one for you. |
| `GIPHY_API_KEY` | no | Enables the GIF picker |

### Leader settings (in the app)

Hunt length, head start, ping interval, out-of-bounds grace period, how long an offline hider is tolerated, whether seekers are warned for leaving the area, whether hiders can tag themselves, late joining, seeker visibility between pings, teammate speed, chat and media on or off, and awards on or off. The play area (center and radius) is set from a map.

### Server limits

| Limit | Value |
|---|---|
| Players per game | 50 (soft cap) |
| Chat relay lifetime | 10 minutes for text, 20 minutes for media |
| Media relay buffer | 200 MB total, 150 MB per file |
| Text message length | 2,000 characters |

Phones that are offline longer than the relay lifetime miss the messages sent meanwhile. There is no backfill by design.

## Testing

```bash
cd server
npm test           # all tests
npm run test:unit  # rules engine and stats only
npm run typecheck
```

The 26 automated tests cover:
- **Rules engine:** head start timing, pings, role-based visibility, tagging, geofence and GPS-noise handling, offline hiders, pause, late pings, and random role assignment
- **Stats:** distance, speed, GPS glitch filtering, and route simplification
- **End to end over real WebSockets and HTTP:** a full game from lobby to results, chat channel privacy, media relay (including byte-for-byte integrity and deletion after delivery), kick/leave/leader hand-over, bad input, and restart recovery including tampered and wrong-key snapshots

The iOS app builds with no errors or warnings, and its models decode real server messages. The SwiftUI screens, background location with the screen locked, camera, and Photos saving have no automated tests, so check those on a real phone.

## Project structure

```
hidenseek/
├── SPEC.md                  Requirements, architecture and design decisions
├── render.yaml              Render blueprint
├── server/
│   ├── src/
│   │   ├── engine.ts        Pure game rules (roles, pings, geofence, tagging, visibility)
│   │   ├── room.ts          A game room: members, chat/media relay, snapshots, registry
│   │   ├── app.ts           WebSocket commands, HTTP media and GIF endpoints, timers
│   │   ├── stats.ts         Route cleaning, stats, simplification, awards
│   │   └── index.ts         Entry point
│   ├── scripts/bot.ts       Fake player for solo testing
│   └── test/                Unit and end-to-end tests
└── ios/
    ├── project.yml          XcodeGen project definition (permissions, URL scheme, background mode)
    └── HideNSeek/
        ├── HideNSeekApp.swift   App entry, navigation by game state
        ├── GameClient.swift     Connection, game state, tracking, chat, snapshots
        ├── Models.swift         Data types shared with the server's JSON
        ├── HomeView / LobbyView / GameView / ChatView / ResultsView
        ├── LocationService.swift  Background location
        ├── Media.swift            Lossless photo/video handling, uploads, Photos saving
        └── ProfileStore / ChatStore / Storage   On-device storage
```

## Privacy

- Location is only shared during an active game, and only with players in that game.
- Your name, color and photo are stored on your phone. A small 128 px version of your photo is sent to the server when you join and held in memory only until the game is cleaned up.
- Chat, photos, videos, routes, and past games are stored on the phones. The server never writes them to disk.
- The server keeps a game in memory for about 30 minutes after it ends (so everyone can fetch results), then deletes it. Restart snapshots exist only as encrypted blobs on the players' phones.
- Server logs contain no coordinates, names, or message contents.
- Photos and videos have GPS metadata removed before sending.

Location sharing is sensitive. If anyone playing is a minor, make sure their parent or guardian knows. Always play somewhere safe: stay off roads and private property.

## Limitations

- **Free Apple ID builds expire after 7 days** and must be re-signed. A paid Apple Developer account would remove this (and unlock TestFlight and push notifications) but isn't required.
- **The free Render server sleeps** when idle and can restart at any time. A restart mid-game is recovered from the phones' snapshots, but if every phone is closed at that moment, the game is lost.
- **No push notifications.** The app relies on its background-location session to stay connected, and uses local notifications. If iOS suspends the app, updates can be delayed until it wakes.
- **Battery:** continuous GPS tracking is expensive. Start a game with a charged phone.
- **The GIPHY beta key** has a low hourly request limit, which is fine for a small group.
- Lossless media means large files. Videos have no size limit in the app, but the free server rejects single files over 150 MB.

## Not built yet

- Animated replay of a finished game (the full-resolution routes are kept, so it can be added)
- Live Activities and Dynamic Island countdown
- Players choosing their own role in the lobby
- Phones backfilling missed chat from each other
- Push notifications and Apple App Store distribution, which would need a paid Apple Developer account

## License

No license has been chosen yet, so all rights are reserved by default. Add a `LICENSE` file if you want others to be able to use the code.
