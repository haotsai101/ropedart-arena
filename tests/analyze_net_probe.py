#!/usr/bin/env python3
"""Summarise a tests/run_net_probe.sh results directory.

Usage: python3 tests/analyze_net_probe.py <dir>  (writes <dir>/summary.json too)
"""
import glob
import json
import os
import re
import statistics
import sys

MODES = {0: "unreliable", 1: "unreliable_ordered", 2: "reliable"}


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    k = (len(xs) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def stats(xs):
    if not xs:
        return {"n": 0}
    return {
        "n": len(xs),
        "min": round(min(xs), 1),
        "p50": round(pct(xs, 50), 1),
        "p90": round(pct(xs, 90), 1),
        "p99": round(pct(xs, 99), 1),
        "max": round(max(xs), 1),
        "mean": round(statistics.mean(xs), 1),
        "stdev": round(statistics.pstdev(xs), 1),
    }


def fmt(s):
    if not s or s.get("n", 0) == 0:
        return "n=0"
    return "p50 {p50:>6} | p90 {p90:>6} | p99 {p99:>6} | max {max:>6} | min {min:>6} | sd {stdev:>5} (n={n})".format(**s)


def phase_windows(d):
    m = d["phase_marks_usec"]
    order = ["idle", "latency", "chaos", "finish"]
    w = {}
    for a, b in zip(order, order[1:]):
        if a in m and b in m:
            w[a] = (m[a], m[b])
    return w


def in_window(t, win):
    return win[0] <= t < win[1]


def main(out):
    procs = {}
    for f in sorted(glob.glob(os.path.join(out, "host_*.json")) + glob.glob(os.path.join(out, "guest_*.json"))):
        d = json.load(open(f))
        procs["host" if d["role"] == "host" else "guest%d" % d["peer_id"]] = d
    host = procs.get("host")
    guests = [procs[k] for k in sorted(procs) if k != "host"]
    summary = {"processes": sorted(procs)}
    P = print

    P("=" * 78)
    P("NET PROBE  %s   processes: %s" % (host["url"] if host else "?", ", ".join(sorted(procs))))
    P("=" * 78)

    # ---- HTTP + raw WS RTT --------------------------------------------------
    ht = os.path.join(out, "http_timing.txt")
    if os.path.exists(ht):
        rows = [list(map(float, l.split())) for l in open(ht) if l.strip()]
        P("\n[server path] HTTPS /rooms (s): dns / tcp / tls / ttfb / total")
        for r in rows:
            P("   %.3f / %.3f / %.3f / %.3f / %.3f" % tuple(r))
        summary["http"] = rows
    wsp = os.path.join(out, "ws_ping.json")
    ws_rtt = None
    if os.path.exists(wsp):
        w = json.load(open(wsp))
        ws_rtt = stats([s[1] for s in w["samples"]])
        summary["ws_ping"] = {"connect_ms": w["connect_ms"], "rtt": ws_rtt}
        P("\n[client<->server] raw WebSocket ping RTT ms (ws connect %s ms)" % w["connect_ms"])
        P("   " + fmt(ws_rtt))

    # ---- timeline -----------------------------------------------------------
    P("\n[timeline] ms since each process started")
    labels = ["ws_open", "room_ready", "game_starting", "scene_built", "first_unreliable_rx", "playing"]
    P("   %-8s" % "" + "".join("%14s" % l[:13] for l in labels))
    summary["timeline"] = {}
    for name, d in sorted(procs.items()):
        tl = {m[0]: m[1] for m in d["timeline"]}
        summary["timeline"][name] = tl
        P("   %-8s" % name + "".join("%14s" % ("%.0f" % tl[l] if l in tl else "-") for l in labels))
    if host:
        tl = {m[0]: m for m in host["timeline"]}
        pc = sorted((m[1], m[0]) for m in host["timeline"] if m[0].startswith("peer_connected"))
        P("   host: room created at %.0f ms; %s; all peers %s ms; playing %s ms"
          % (tl["room_ready"][1], ", ".join("%s @%.0f" % (n.replace("peer_connected_", "peer "), t) for t, n in pc),
             "%.0f" % tl["all_peers_connected"][1] if "all_peers_connected" in tl else "-",
             "%.0f" % tl["playing"][1] if "playing" in tl else "-"))
        # same-clock comparison: when did each process reach PLAYING (unix ms)
        if "playing" in tl:
            base = tl["playing"][2]
            spread = {n: round({m[0]: m for m in d["timeline"]}["playing"][2] - base, 1)
                      for n, d in procs.items() if any(m[0] == "playing" for m in d["timeline"])}
            summary["playing_skew_ms"] = spread
            P("   PLAYING reached relative to host (wall clock, ms): %s" % spread)

    # ---- ping RTT -----------------------------------------------------------
    P("\n[RPC ping guest->host->guest through relay] ms, by phase")
    summary["rpc_rtt"] = {}
    for d in guests:
        name = "guest%d" % d["peer_id"]
        summary["rpc_rtt"][name] = {}
        for ph in ["join", "idle", "latency", "chaos"]:
            rs = [p[1] for p in d["pings"] if p[4] == ph]
            if not rs:
                continue
            s = stats(rs)
            up = stats([p[2] for p in d["pings"] if p[4] == ph])
            dn = stats([p[3] for p in d["pings"] if p[4] == ph])
            summary["rpc_rtt"][name][ph] = {"rtt": s, "up": up, "down": dn}
            P("   %-7s %-8s RTT %s" % (name, ph, fmt(s)))
            P("   %-7s %-8s   one-way up p50 %s / down p50 %s" % ("", "", up["p50"], dn["p50"]))
        P("   %-7s unanswered pings at exit: %d" % (name, d["pings_unanswered"]))
    all_rtt = [p[1] for d in guests for p in d["pings"] if p[4] in ("idle", "latency", "chaos")]
    summary["rpc_rtt_all"] = stats(all_rtt)
    P("   ALL guests (in-match): " + fmt(summary["rpc_rtt_all"]))
    if ws_rtt and all_rtt:
        P("   relay overhead vs 2x raw server RTT: p50 %.1f ms (RPC p50 %.1f - 2x%.1f)"
          % (pct(all_rtt, 50) - 2 * ws_rtt["p50"], pct(all_rtt, 50), ws_rtt["p50"]))

    # ---- input latency ------------------------------------------------------
    shown_all = [t[2] for d in guests for t in d["latency_trials"] if len(t) > 2 and t[2] >= 0 and (len(t) < 4 or t[3] == "move")]
    if shown_all:
        summary["input_latency_shown"] = stats(shown_all)
        P("\n[input -> own player moves ON THIS SCREEN (client prediction)] ms")
        P("   ALL     " + fmt(summary["input_latency_shown"]))
    for kind, label in [("slash", "Slash pressed -> swing animation starts"), ("throw", "Throw released -> dart leaves the hand")]:
        xs = [t[2] for d in guests for t in d["latency_trials"] if len(t) > 3 and t[3] == kind and t[2] >= 0]
        miss = sum(1 for d in guests for t in d["latency_trials"] if len(t) > 3 and t[3] == kind and t[2] < 0)
        if xs or miss:
            summary["latency_" + kind] = {"stats": stats(xs), "misses": miss}
            P("\n[%s, ON THIS SCREEN] ms" % label)
            P("   ALL     %s  misses=%d" % (fmt(stats(xs)), miss))
    if any("pred_dart_corrections" in d for d in guests):
        P("\n[dart prediction corrections > 1cm] world units (dart flies 16-26 u/s)")
        summary["pred_dart_corrections"] = {}
        for d in guests:
            c = d.get("pred_dart_corrections", [])
            name = "guest%d" % d["peer_id"]
            summary["pred_dart_corrections"][name] = stats(c)
            P("   %-7s %s" % (name, fmt(stats(c)).replace(" (n=", " (count=")))
    if any("pred_corrections" in d for d in guests):
        P("\n[prediction corrections > 1cm] reconciliation error, world units (player ~1 wide, 6 u/s walk)")
        summary["pred_corrections"] = {}
        for d in guests:
            c = d.get("pred_corrections", [])
            name = "guest%d" % d["peer_id"]
            summary["pred_corrections"][name] = stats(c)
            P("   %-7s %s" % (name, fmt(stats(c)).replace(" (n=", " (count=")))
    P("\n[input -> own player moves in host state (confirmed), seen on guest] ms")
    lat_all = []
    summary["input_latency"] = {}
    for d in guests:
        name = "guest%d" % d["peer_id"]
        mv = [t for t in d["latency_trials"] if len(t) < 4 or t[3] == "move"]
        ok = [t[0] for t in mv if t[0] >= 0]
        miss = sum(1 for t in mv if t[0] < 0)
        lat_all += ok
        summary["input_latency"][name] = {"stats": stats(ok), "misses": miss}
        P("   %-7s %s  misses=%d" % (name, fmt(stats(ok)), miss))
    summary["input_latency_all"] = stats(lat_all)
    P("   ALL     " + fmt(summary["input_latency_all"]))

    # ---- snapshot / input cadence ------------------------------------------
    P("\n[snapshot stream host->guest] inter-arrival ms per guest (host ticks at %s Hz)"
      % (host["physics_tps"] if host else "?"))
    summary["snapshot"] = {}
    host_sends = host["sends_unreliable"] if host else []
    hw = phase_windows(host) if host else {}
    for d in guests:
        name = "guest%d" % d["peer_id"]
        arr = d["arrivals"].get("1:raw1") or d["arrivals"].get("1:1", [])
        gw = phase_windows(d)
        summary["snapshot"][name] = {}
        for ph in ["idle", "latency", "chaos"]:
            if ph not in gw:
                continue
            ts = [a[0] for a in arr if in_window(a[0], gw[ph])]
            gaps = [(b - a) / 1000.0 for a, b in zip(ts, ts[1:])]
            dur = (gw[ph][1] - gw[ph][0]) / 1e6
            burst = sum(1 for g in gaps if g < 2.0)
            s = stats(gaps)
            row = {"interarrival": s, "rate_hz": round(len(ts) / dur, 1),
                   "gaps_over_50ms": sum(1 for g in gaps if g > 50), "gaps_over_100ms": sum(1 for g in gaps if g > 100),
                   "same_frame_bursts": burst}
            summary["snapshot"][name][ph] = row
            P("   %-7s %-8s %5.1f Hz  gaps>50ms %3d  >100ms %3d  bunched(<2ms) %4d | %s"
              % (name, ph, row["rate_hz"], row["gaps_over_50ms"], row["gaps_over_100ms"], burst, fmt(s)))
        # delivery: snapshots host sent during the match vs. guest received
        if host and "idle" in hw and "chaos" in hw:
            pid = d["peer_id"]
            raw = any(len(s) > 3 for s in host_sends)
            sent_n = sum(1 for s in host_sends if hw["idle"][0] <= s[0] < hw["chaos"][1]
                         and (not raw or s[3] == "raw1")
                         and (len(s) < 3 or s[2] == pid or s[2] == 0 or (s[2] < 0 and -s[2] != pid)))
            gw2 = phase_windows(d)
            recv_n = sum(1 for a in arr if gw2.get("idle", (0, 0))[0] <= a[0] < gw2.get("chaos", (0, 0))[1])
            summary["snapshot"][name]["delivery"] = [recv_n, sent_n]
            P("   %-7s delivered %d of %d snapshots sent in idle..chaos (%.1f%%; window edges differ by one-way delay)"
              % (name, recv_n, sent_n, 100.0 * recv_n / max(sent_n, 1)))
    # Stalls: >60ms holes in the 60Hz streams. Same-instant stalls on every
    # connection, in both directions, point at the shared server/path rather
    # than any one client.
    def unix_ms(d, t_usec):
        st = next(m for m in d["timeline"] if m[0] == "start")
        return st[2] + (t_usec - d["t0_usec"]) / 1000.0 - st[1]
    stall_times = {}
    for d in guests:
        ts = [unix_ms(d, a[0]) for a in (d["arrivals"].get("1:raw1") or d["arrivals"].get("1:1", []))]
        stall_times["guest%d" % d["peer_id"]] = [a for a, b in zip(ts, ts[1:]) if b - a > 60]
    if host:
        for key, arr in host["arrivals"].items():
            if key.endswith(":1") or key.endswith(":raw3"):
                ts = [unix_ms(host, a[0]) for a in arr]
                stall_times["host<-peer" + key.split(":")[0]] = [a for a, b in zip(ts, ts[1:]) if b - a > 60]
    if stall_times:
        P("\n[stalls >60ms in the 60Hz streams]")
        ref_name = sorted(stall_times)[0]
        ref = stall_times[ref_name]
        summary["stalls"] = {}
        for name, st in sorted(stall_times.items()):
            iv = [b - a for a, b in zip(st, st[1:])]
            co = sum(1 for t in st if any(abs(t - u) < 30 for u in ref)) if name != ref_name else len(st)
            summary["stalls"][name] = {"count": len(st), "interval_p50_ms": pct(iv, 50), "coincide_with_" + ref_name: co}
            P("   %-14s %4d stalls, every %s ms (p50); %d/%d within 30ms of a %s stall"
              % (name, len(st), "%.0f" % pct(iv, 50) if iv else "-", co, len(st), ref_name))

    if host and host.get("input_queue_samples"):
        P("\n[host input queue] inputs buffered per guest player (each = one 16.7ms tick of delay), by phase")
        summary["input_queue"] = {}
        for pid in sorted({q[1] for q in host["input_queue_samples"]}):
            summary["input_queue"][pid] = {}
            for ph in ["idle", "latency", "chaos"]:
                if ph not in hw:
                    continue
                qs = [q[2] for q in host["input_queue_samples"] if q[1] == pid and in_window(q[0], hw[ph])]
                s = stats(qs)
                summary["input_queue"][pid][ph] = s
                P("   peer %s %-8s mean %s  p50 %s  max %s" % (pid, ph, s.get("mean"), s.get("p50"), s.get("max")))
        targets = {}
        for s in host_sends:
            if len(s) > 2:
                targets[s[2]] = targets.get(s[2], 0) + 1
        summary["host_unreliable_targets"] = targets
        P("   host unreliable frames by relay target peer (0 = broadcast): %s" % targets)
    if host:
        P("\n[input stream guest->host] inter-arrival ms on host, chaos phase")
        summary["input_stream"] = {}
        for key, arr in sorted(host["arrivals"].items()):
            if not (key.endswith(":1") or key.endswith(":raw3")):
                continue
            ts = [a[0] for a in arr if "chaos" in hw and in_window(a[0], hw["chaos"])]
            gaps = [(b - a) / 1000.0 for a, b in zip(ts, ts[1:])]
            s = stats(gaps)
            summary["input_stream"]["peer" + key.split(":")[0]] = s
            P("   from peer %s: %s  gaps>50ms %d" % (key.split(":")[0], fmt(s), sum(1 for g in gaps if g > 50)))

    # ---- bandwidth ----------------------------------------------------------
    P("\n[traffic] relay payload incl. 6-byte relay header (excl. WebSocket/TLS framing)")
    summary["traffic"] = {}
    for name, d in sorted(procs.items()):
        w = phase_windows(d)
        row = {}
        for ph in ["idle", "chaos"]:
            if ph not in w:
                continue
            dur = (w[ph][1] - w[ph][0]) / 1e6
            up = sum(s[1] for s in d["sends_unreliable"] if in_window(s[0], w[ph])) / dur
            dn = sum(a[1] for arr in d["arrivals"].values() for a in arr if in_window(a[0], w[ph])) / dur
            row[ph] = {"up_Bps": round(up), "down_Bps": round(dn)}
        sent_tot = {(MODES[int(k)] if str(k).isdigit() else {"raw1": "snapshot", "raw2": "own_state", "raw3": "input"}.get(k, k)): v
                    for k, v in d["sent"].items()}
        recv_rel = sum(v[1] for k, v in d["recv"].items() if k.endswith(":2"))
        row["sent_totals"] = sent_tot
        row["recv_reliable_bytes"] = recv_rel
        summary["traffic"][name] = row
        P("   %-7s idle up %6.1f KB/s down %6.1f KB/s | chaos up %6.1f KB/s down %6.1f KB/s | reliable sent %s B / recv %s B"
          % (name, row.get("idle", {}).get("up_Bps", 0) / 1000, row.get("idle", {}).get("down_Bps", 0) / 1000,
             row.get("chaos", {}).get("up_Bps", 0) / 1000, row.get("chaos", {}).get("down_Bps", 0) / 1000,
             sent_tot.get("reliable", [0, 0])[1], recv_rel))
    if host:
        snap_sizes = [s[1] for s in host["sends_unreliable"] if len(s) < 4 or s[3] == "raw1"]
        own_sizes = [s[1] for s in host["sends_unreliable"] if len(s) > 3 and s[3] == "raw2"]
        if own_sizes:
            P("   host own-state frame size bytes: " + fmt(stats(own_sizes)))
        summary["snapshot_size"] = stats(snap_sizes)
        P("   host snapshot frame size bytes: " + fmt(summary["snapshot_size"]))
        for d in guests[:1]:
            P("   guest input frame size bytes:   " + fmt(stats([s[1] for s in d["sends_unreliable"]])))
        ch = summary["traffic"]
        server_egress = sum(ch[n].get("chaos", {}).get("down_Bps", 0) for n in ch)
        server_ingress = sum(ch[n].get("chaos", {}).get("up_Bps", 0) for n in ch)
        summary["server_chaos_Bps"] = {"ingress": server_ingress, "egress": server_egress}
        P("   server (this room, chaos): ingress %.1f KB/s, egress %.1f KB/s -> %.0f MB/hour egress"
          % (server_ingress / 1000, server_egress / 1000, server_egress * 3600 / 1e6))

    # ---- health -------------------------------------------------------------
    P("\n[health]")
    summary["health"] = {}
    for name, d in sorted(procs.items()):
        log = os.path.join(out, ("host" if name == "host" else "guest%d" % (int(name[5:]) - 1)) + ".log")
        errs = {}
        if os.path.exists(log):
            for l in open(log, errors="replace"):
                if re.match(r"^(ERROR|SCRIPT ERROR|WARNING)", l):
                    errs[l.strip()[:110]] = errs.get(l.strip()[:110], 0) + 1
        fps = [f for f in d["fps_samples"][20:] if f > 0]  # skip startup
        ob = max((s[1] for s in d["outbound_samples"]), default=0)
        h = {"dropped_unknown_peer": d.get("dropped_unknown_peer", 0), "outbound_max": d["outbound_max"],
             "fps_p50": pct(fps, 50), "fps_min": pct(fps, 5), "log_lines": errs,
             "states": [s[0] for s in d["state_changes"]]}
        summary["health"][name] = h
        P("   %-7s relay-dropped %d | ws outbound backlog max %d B | fps p50 %s p5 %s | states %s"
          % (name, h["dropped_unknown_peer"], h["outbound_max"], h["fps_p50"], h["fps_min"], h["states"]))
        for k, v in errs.items():
            P("            %3dx %s" % (v, k))

    json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=1)
    P("\nsummary written to %s" % os.path.join(out, "summary.json"))


if __name__ == "__main__":
    main(sys.argv[1])
