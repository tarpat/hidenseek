# Hide n Seek

Location-based hide-and-seek for iOS. See [SPEC.md](SPEC.md) for the full requirements and architecture.

Repo layout: `/server` (TypeScript game server) and `/ios` (SwiftUI app).

## What's built

| Area | Status |
|---|---|
| Create/join with a code, deep links (`hidenseek://join/CODE`), rejoin after a crash | done |
| On-device profile (name, color, photo), units, auto-save toggle, past games | done |
| Lobby: manual and random roles, leader settings, play-area editor | done |
| Head start, pings (everyone sees everyone), geofence and out-of-bounds, dark hiders, tagging, pause, win conditions | done, covered by tests |
| Role-based visibility enforced on the server | done, covered by tests |
| Live speed and distance, full route recording, gap-free upload | done |
| Results: awards, stats, routes map, speed chart | done |
| Chat with channels, photos, videos, GIFs (relayed, stored only on phones, lossless, GPS stripped) | done |
| Save photos & videos to Photos at the end (not GIFs) | done |
| Restart recovery from encrypted snapshots held on the phones | done, covered by tests |
| Replay scrubber, Live Activities, peer chat backfill | not built (deferred in the spec) |

**Tested here:** server logic and protocol (`npm test`: rules engine, stats, a full game over real WebSockets, media relay, restart recovery), and the app compiles for iOS. The Swift models were decoded against real server messages.
**Not tested here (needs your phone):** the SwiftUI screens, background location with the screen locked, camera, Photos saving, GIFs (needs a GIPHY key), and how Render behaves on the free tier.

## Server
```bash
cd server
npm install
npm run dev            # http://localhost:8080  (health: /health, WebSocket: /ws)
npm test               # unit + end-to-end tests
npm run bot -- ABC123  # fake extra player for solo testing
```
Environment variables: `SNAPSHOT_SECRET` (encrypts restart snapshots; set a long random value), `GIPHY_API_KEY` (optional), `PORT`.

Deploy on Render with the blueprint in `render.yaml` (free web service, root dir `server`). Add your `GIPHY_API_KEY` in the dashboard.

## iOS app
```bash
brew install xcodegen
cd ios && xcodegen generate && open HideNSeek.xcodeproj
```
In Xcode: Signing & Capabilities, choose your free Personal Team, plug in an iPhone (iOS 17+), and Run.
In the app: Profile & Settings, set Server to `wss://<your-app>.onrender.com/ws`, or `ws://<Mac LAN IP>:8080/ws` for local testing.

## Try a game with one phone
1. Run the server (`npm run dev`) and the app; create a game.
2. `npm run bot -- <CODE> Bot1` (and `Bot2`) to add fake players.
3. Assign roles in the lobby, set a play area, and start. Use short settings (head start 1 min, ping every 1 min) to see everything quickly.
4. Walk around with the phone locked and watch the server log, or check the other players' view with a second phone.
