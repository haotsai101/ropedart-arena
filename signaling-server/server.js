/**
 * Dartrope Arena — WebRTC Signaling Server (v2)
 * Handles room creation, join, settings, SDP/ICE relay for WebRTC peer negotiation.
 * Deploy on Render.com as a Web Service (Node, npm start).
 */

const http = require("http");
const { WebSocketServer } = require("ws");

const PORT = process.env.PORT || 8080;
const USERNAME_TIMEOUT_MS = 5000;

// rooms[code] = {
//   code,
//   host_socket,
//   host_username,
//   players: [ { socket, username, peer_id } ],  // index 0 = host (peer_id 1)
//   settings: { max_players: 4, bot_difficulty: 0, map_id: 0 },
//   started: false
// }
const rooms = {};

// ws_meta[ws] = { code, peer_id }  — reverse lookup for disconnect cleanup
const ws_meta = new WeakMap();

function generateCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no ambiguous chars
  let code = "";
  for (let i = 0; i < 6; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return rooms[code] ? generateCode() : code;
}

function send(ws, obj) {
  if (ws && ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

function getPeerById(room, peer_id) {
  const player = room.players.find((p) => p.peer_id === peer_id);
  return player ? player.socket : null;
}

function broadcastToRoom(room, obj) {
  for (const p of room.players) {
    send(p.socket, obj);
  }
}

function buildPlayerList(room) {
  return room.players.map((p) => ({ username: p.username, peer_id: p.peer_id }));
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

  // Handle username registration — must come first
  if (type === "set_username") {
    if (ws._username_timer) {
      clearTimeout(ws._username_timer);
      ws._username_timer = null;
    }
    ws.username = String(msg.username || "Player").trim().slice(0, 32) || "Player";
    return;
  }

  switch (type) {
    case "create": {
      const code = generateCode();
      const max_players = Math.min(6, Math.max(2, parseInt(msg.max_players) || 4));
      const bot_difficulty = Math.min(2, Math.max(0, parseInt(msg.bot_difficulty) || 0));
      const map_id = Math.min(1, Math.max(0, parseInt(msg.map_id) || 0));
      const username = ws.username || "Player";
      rooms[code] = {
        code,
        host_socket: ws,
        host_username: username,
        players: [{ socket: ws, username, peer_id: 1 }],
        settings: { max_players, bot_difficulty, map_id },
        started: false,
      };
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
      if (room.started) {
        send(ws, { type: "error", message: "Game already started" });
        return;
      }
      if (room.players.length >= room.settings.max_players) {
        send(ws, { type: "error", message: "Room is full" });
        return;
      }
      const peer_id = room.players.length + 1; // 2, 3, 4, ...
      const username = ws.username || "Player";
      room.players.push({ socket: ws, username, peer_id });
      ws_meta.set(ws, { code, peer_id });

      // Tell the new joiner their peer_id and current settings
      send(ws, {
        type: "joined",
        code,
        peer_id,
        settings: room.settings,
      });

      // Broadcast updated player list to everyone in the room
      broadcastToRoom(room, { type: "player_list", players: buildPlayerList(room) });

      // Notify host to initiate WebRTC offer to this guest
      send(room.host_socket, { type: "guest_joined", peer_id });
      break;
    }

    case "update_settings": {
      const meta = ws_meta.get(ws);
      if (!meta) return;
      const room = rooms[meta.code];
      if (!room) return;
      // Only host can update settings
      if (meta.peer_id !== 1) return;

      const new_max = Math.min(6, Math.max(2, parseInt(msg.max_players) || room.settings.max_players));
      const new_diff = Math.min(2, Math.max(0, parseInt(msg.bot_difficulty) ?? room.settings.bot_difficulty));
      const new_map = Math.min(1, Math.max(0, parseInt(msg.map_id) ?? room.settings.map_id ?? 0));

      // max_players cannot be set below the current human player count
      if (new_max < room.players.length) {
        send(ws, {
          type: "error",
          message: "max_players cannot be less than current player count (" + room.players.length + ")",
        });
        return;
      }

      room.settings.max_players = new_max;
      room.settings.bot_difficulty = new_diff;
      room.settings.map_id = new_map;

      broadcastToRoom(room, { type: "settings_updated", settings: room.settings });
      break;
    }

    case "start_game": {
      const meta = ws_meta.get(ws);
      if (!meta) return;
      const room = rooms[meta.code];
      if (!room) return;
      // Only host can start
      if (meta.peer_id !== 1) return;
      room.started = true;
      broadcastToRoom(room, { type: "game_starting" });
      break;
    }

    case "offer":
    case "answer": {
      const room = rooms[(msg.code || "").toUpperCase()];
      if (!room) return;
      const target = getPeerById(room, msg.peer_id);
      const meta = ws_meta.get(ws);
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
    // Host disconnected — close the room, notify all guests
    for (const p of room.players) {
      if (p.peer_id !== 1) {
        send(p.socket, { type: "host_disconnected" });
      }
    }
    delete rooms[code];
  } else {
    // Guest disconnected — remove from list, notify others
    const idx = room.players.findIndex((p) => p.peer_id === peer_id);
    if (idx !== -1) room.players.splice(idx, 1);

    // Broadcast updated player list and peer_disconnected
    broadcastToRoom(room, { type: "player_list", players: buildPlayerList(room) });
    broadcastToRoom(room, { type: "peer_disconnected", peer_id });
  }
  ws_meta.delete(ws);
}

// --- HTTP server ---
const httpServer = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/rooms") {
    const public_rooms = Object.values(rooms)
      .filter((r) => !r.started)
      .map((r) => ({
        code: r.code,
        host: r.host_username,
        player_count: r.players.length,
        max_players: r.settings.max_players,
        bot_difficulty: r.settings.bot_difficulty,
        map_id: r.settings.map_id || 0,
      }));
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(public_rooms));
    return;
  }
  // Default health check
  res.writeHead(200);
  res.end("OK");
});

// --- WebSocket server ---
const wss = new WebSocketServer({ server: httpServer });

wss.on("connection", (ws) => {
  ws.username = "";
  // Give the client 5s to send set_username, then close if not received
  ws._username_timer = setTimeout(() => {
    if (!ws.username) {
      ws.close(1008, "Username not set within 5s");
    }
  }, USERNAME_TIMEOUT_MS);

  ws.on("message", (data) => handleMessage(ws, data.toString()));
  ws.on("close", () => {
    if (ws._username_timer) clearTimeout(ws._username_timer);
    handleDisconnect(ws);
  });
  ws.on("error", (err) => {
    console.error("WS error:", err.message);
    if (ws._username_timer) clearTimeout(ws._username_timer);
    handleDisconnect(ws);
  });
});

httpServer.listen(PORT, () => {
  console.log(`Dartrope signaling server v2 listening on port ${PORT}`);
});
