/**
 * Dartrope Arena — WebRTC Signaling Server
 * Handles room creation, join, and SDP/ICE relay for WebRTC peer negotiation.
 * Deploy on Render.com as a Web Service (Node, npm start).
 */

const http = require("http");
const { WebSocketServer } = require("ws");

const PORT = process.env.PORT || 8080;
const MAX_GUESTS = 5; // host + 5 guests = 6 players max

// rooms[code] = { host: ws, guests: [ws, ws, ...] }
const rooms = {};

// ws_meta[ws] = { code, peer_id }  — reverse lookup for disconnect cleanup
const ws_meta = new WeakMap();

function generateCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no ambiguous chars
  let code = "";
  for (let i = 0; i < 6; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  // Retry on collision (astronomically rare but correct)
  return rooms[code] ? generateCode() : code;
}

function send(ws, obj) {
  if (ws && ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

function getPeerById(room, peer_id) {
  if (peer_id === 1) return room.host;
  const guestIndex = peer_id - 2; // guests are peer_id 2, 3, 4, 5, 6
  return room.guests[guestIndex] || null;
}

function handleMessage(ws, raw) {
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch {
    send(ws, { type: "error", message: "Invalid JSON" });
    return;
  }

  const type = msg.type || "";

  switch (type) {
    case "create": {
      const code = generateCode();
      rooms[code] = { host: ws, guests: [] };
      ws_meta.set(ws, { code, peer_id: 1 });
      send(ws, { type: "created", code, peer_id: 1 });
      break;
    }

    case "join": {
      const code = (msg.code || "").toUpperCase();
      const room = rooms[code];
      if (!room) {
        send(ws, { type: "error", message: "Room not found" });
        return;
      }
      if (room.guests.length >= MAX_GUESTS) {
        send(ws, { type: "error", message: "Room is full" });
        return;
      }
      room.guests.push(ws);
      const peer_id = room.guests.length + 1; // 2, 3, 4, 5, 6
      ws_meta.set(ws, { code, peer_id });

      // Tell the new guest their peer_id and current peer count
      send(ws, {
        type: "joined",
        code,
        peer_id,
        peer_count: room.guests.length, // total guests now in room (including self)
      });

      // Notify host so it can initiate WebRTC offer to this guest
      send(room.host, { type: "guest_joined", peer_id });
      break;
    }

    case "offer":
    case "answer": {
      const room = rooms[(msg.code || "").toUpperCase()];
      if (!room) return;
      const target = getPeerById(room, msg.peer_id);
      const meta = ws_meta.get(ws);
      // Forward to target, stamping the sender's peer_id so target knows who sent it
      send(target, {
        type,
        peer_id: meta ? meta.peer_id : 0,
        sdp: msg.sdp,
      });
      break;
    }

    case "candidate": {
      const room = rooms[(msg.code || "").toUpperCase()];
      if (!room) return;
      const target = getPeerById(room, msg.peer_id);
      const meta = ws_meta.get(ws);
      send(target, {
        type: "candidate",
        peer_id: meta ? meta.peer_id : 0,
        candidate: msg.candidate,
      });
      break;
    }

    default:
      send(ws, { type: "error", message: "Unknown message type: " + type });
  }
}

function handleDisconnect(ws) {
  const meta = ws_meta.get(ws);
  if (!meta) return;
  const { code, peer_id } = meta;
  const room = rooms[code];
  if (!room) return;

  if (peer_id === 1) {
    // Host disconnected — tear down the whole room, notify all guests
    for (const g of room.guests) {
      send(g, { type: "peer_disconnected", peer_id: 1 });
    }
    delete rooms[code];
  } else {
    // Guest disconnected — remove from list, notify host and remaining guests
    const idx = room.guests.indexOf(ws);
    if (idx !== -1) room.guests.splice(idx, 1);
    send(room.host, { type: "peer_disconnected", peer_id });
    for (const g of room.guests) {
      send(g, { type: "peer_disconnected", peer_id });
    }
  }
  ws_meta.delete(ws);
}

// --- HTTP server (health check for Render.com) ---
const httpServer = http.createServer((req, res) => {
  res.writeHead(200);
  res.end("OK");
});

// --- WebSocket server ---
const wss = new WebSocketServer({ server: httpServer });

wss.on("connection", (ws) => {
  ws.on("message", (data) => handleMessage(ws, data.toString()));
  ws.on("close", () => handleDisconnect(ws));
  ws.on("error", (err) => {
    console.error("WS error:", err.message);
    handleDisconnect(ws);
  });
});

httpServer.listen(PORT, () => {
  console.log(`Dartrope signaling server listening on port ${PORT}`);
});
