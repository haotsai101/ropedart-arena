# Dartrope Signaling Server

WebSocket-based WebRTC signaling server for Dartrope Arena.

## Deploy to Render.com

1. Push the `signaling-server/` directory to a GitHub repository (or push the full repo).
2. Go to [Render.com](https://render.com) → New → Web Service.
3. Connect the repository. Render auto-detects `render.yaml` if the file is at the repo root; otherwise manually set:
   - **Build command**: `npm install`
   - **Start command**: `npm start`
   - **Environment**: Node
4. Deploy. Copy the generated URL (e.g. `https://dartrope-signaling.onrender.com`).
5. In Godot, open the lobby → ONLINE mode → paste the URL into the signaling server field (use `wss://` prefix).

## Local testing

```
npm install
npm start
```

Server listens on `PORT` env var or `8080` by default. Connect with `ws://localhost:8080`.
