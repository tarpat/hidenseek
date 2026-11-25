/**
 * Fake extra player for testing with one phone.
 *   npm run bot -- <GAMECODE> [name]
 * Joins the game as a normal player. The leader picks its role in the lobby. Once the game has a play area
 * (or it can see someone), it walks in a ~80 m circle around that point and keeps reporting its location.
 * Set URL to point at another server, e.g. URL=wss://my-app.onrender.com/ws
 */
import WebSocket from 'ws';

const [code, name = 'Bot'] = process.argv.slice(2);
if (!code) {
  console.error('usage: npm run bot -- <GAMECODE> [name]');
  process.exit(1);
}
const ws = new WebSocket(process.env.URL ?? 'ws://localhost:8080/ws');
let center: { lat: number; lng: number } | null = null;
let myId = '';
let angle = 0;
let role = '';

const send = (o: unknown) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify(o));

ws.on('open', () => send({ type: 'join', code, name, color: '#8E4EC6' }));
ws.on('message', (raw) => {
  const m = JSON.parse(raw.toString());
  if (m.type === 'joined') {
    myId = m.playerId;
    console.log(`joined ${m.code} as ${name}. Ask the leader to give it a role.`);
  } else if (m.type === 'error') {
    console.error('server error:', m.message);
    if (m.fatal) process.exit(1);
  } else if (m.type === 'state') {
    if (m.role !== role) console.log(`role: ${m.role}`);
    role = m.role;
    if (!center) {
      const other = m.live.find((p: any) => p.id !== myId);
      center = m.settings.center ?? (other && { lat: other.lat, lng: other.lng }) ?? null;
      if (center) console.log(`walking around ${center.lat.toFixed(5)}, ${center.lng.toFixed(5)}`);
    }
  } else if (m.type === 'event') {
    console.log('event:', m.event.type, m.event.reason ?? '');
  } else if (m.type === 'game_over') {
    send({ type: 'track_done' });
    console.log('game over');
  } else if (m.type === 'chat') {
    send({ type: 'chat_received', id: m.msg.id });
  }
});
ws.on('close', () => {
  console.log('disconnected');
  process.exit(0);
});

const R = 80; // metres
setInterval(() => {
  if (!center) return;
  angle += 0.08; // ~1.5 m/s walking speed
  const lat = center.lat + (R * Math.cos(angle)) / 111_000;
  const lng = center.lng + (R * Math.sin(angle)) / (111_000 * Math.cos((center.lat * Math.PI) / 180));
  send({ type: 'location', lat, lng, acc: 5, speed: 1.5 });
}, 3000);
