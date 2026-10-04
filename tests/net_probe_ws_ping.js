// Measures raw client<->server RTT with WebSocket control-frame pings (the
// server's `ws` library answers them itself, so this is pure network + TLS
// proxy time, no game code). Runs alongside the Godot net probe.
// Usage: node tests/net_probe_ws_ping.js <wss-url> <seconds> <out.json>
const path = require("path");
const WebSocket = require(path.join(__dirname, "../signaling-server/node_modules/ws"));
const [url, seconds, out] = process.argv.slice(2);
const t0 = Date.now();
const samples = [];
const ws = new WebSocket(url);
let connect_ms = null;
ws.on("open", () => {
  connect_ms = Date.now() - t0;
  ws.send(JSON.stringify({ type: "set_username", username: "ws-ping-probe" })); // else closed after 5s
  let sent = null; // one ping in flight at a time; a still-pending one counts as lost
  let lost = 0;
  ws.on("pong", () => {
    if (sent === null) return;
    samples.push([Date.now(), Number(process.hrtime.bigint() - sent) / 1e6]);
    sent = null;
  });
  const timer = setInterval(() => {
    if (sent !== null) lost++;
    sent = process.hrtime.bigint();
    ws.ping();
  }, 250);
  setTimeout(() => {
    clearInterval(timer);
    require("fs").writeFileSync(out, JSON.stringify({ connect_ms, samples, lost }));
    process.exit(0);
  }, Number(seconds) * 1000);
});
ws.on("error", (e) => { console.error("ws ping error", e.message); process.exit(1); });
