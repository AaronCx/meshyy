#!/usr/bin/env python3
# meshyy — design doc §1 benchmark: what does SSH + multiplexer attach + first
# paint actually cost?
# Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
#
# Measures wall time from process spawn to the moment the multiplexer's repaint
# of a known marker reaches the client, across a sweep of injected round-trip
# times. Latency is injected by the in-tree `meshyy-chaos` userspace TCP proxy
# because dummynet needs root (docs/provenance.md, 2026-07-27).
#
# The output that matters is the linear fit: total = fixed + trips * RTT. The
# slope is the number of network round trips a cold attach pays, which is the
# quantity meshyy is trying to reduce to one.
#
# Usage:
#   scripts/bench-attach.py --host 127.0.0.1 --user "$USER" \
#       --key ~/.ssh/meshyy_bench_ed25519 --session meshyy-bench

import argparse
import json
import os
import pty
import re
import select
import signal
import statistics
import subprocess
import sys
import time

MARKER = b"MESHYY_BENCH_READY"
CHAOS_BIN = os.path.join(os.path.dirname(__file__), "..", ".build", "debug", "meshyy-chaos")


def sh(*args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def ensure_session(session, marker_cmd):
    """Create the benchmark tmux session if absent. Never touches other sessions."""
    exists = sh("tmux", "has-session", "-t", session).returncode == 0
    if not exists:
        sh("tmux", "new-session", "-d", "-s", session, "-x", "120", "-y", "40")
        time.sleep(0.4)
    sh("tmux", "send-keys", "-t", session, marker_cmd, "Enter")
    time.sleep(0.5)


def start_proxy(target_host, target_port, rtt_ms):
    """Start meshyy-chaos and return (process, bound_port). rtt_ms 0 still proxies,
    which is how the proxy's own floor cost gets measured and subtracted."""
    proc = subprocess.Popen(
        [CHAOS_BIN, "tcp", "--target", f"{target_host}:{target_port}", "--rtt", str(rtt_ms)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    line = proc.stdout.readline().decode().strip()
    if not line.isdigit():
        err = proc.stderr.read().decode()
        proc.kill()
        raise RuntimeError(f"chaos proxy failed to bind: {line!r} {err!r}")
    return proc, int(line)


def measure_attach(host, port, user, key, session, tmux="tmux", mode="attach", timeout=45.0):
    """Spawn ssh under a pty and time until the marker reaches the client.

    mode="attach" measures the whole user-visible cost: SSH handshake, auth,
    channel + pty request, multiplexer attach, and first paint.
    mode="exec" runs a bare printf instead, isolating the SSH cost so the
    multiplexer's share is the difference between the two.

    Returns seconds from spawn to the marker, or None on timeout."""
    remote = (
        f"{tmux} attach -d -t {session}" if mode == "attach"
        else f"printf '{MARKER.decode()}\\n'"
    )
    argv = [
        "/usr/bin/ssh", "-tt",
        "-i", key,
        "-p", str(port),
        "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        f"{user}@{host}",
        # For attach mode, -d forces a full repaint by detaching any other
        # client, so the marker crosses the wire on every trial rather than
        # only the first.
        remote,
    ]

    primary, replica = pty.openpty()
    start = time.monotonic()
    proc = subprocess.Popen(
        argv, stdin=replica, stdout=replica, stderr=replica,
        preexec_fn=os.setsid, close_fds=True,
    )
    os.close(replica)

    buffer = b""
    elapsed = None
    deadline = start + timeout
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([primary], [], [], 0.05)
            if not ready:
                if proc.poll() is not None and MARKER not in buffer:
                    break
                continue
            try:
                chunk = os.read(primary, 65536)
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            if MARKER in buffer:
                elapsed = time.monotonic() - start
                break
    finally:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait(timeout=5)
        os.close(primary)

    if elapsed is None:
        tail = buffer[-400:].decode(errors="replace")
        print(f"    (no marker; tail={tail!r})", file=sys.stderr)
    return elapsed


def linear_fit(points):
    """Least squares on (rtt_seconds, total_seconds). Returns (fixed, trips)."""
    n = len(points)
    mean_x = sum(x for x, _ in points) / n
    mean_y = sum(y for _, y in points) / n
    denom = sum((x - mean_x) ** 2 for x, _ in points)
    if denom == 0:
        return mean_y, 0.0
    slope = sum((x - mean_x) * (y - mean_y) for x, y in points) / denom
    return mean_y - slope * mean_x, slope


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--user", default=os.environ.get("USER"))
    parser.add_argument("--key", required=True)
    parser.add_argument("--session", default="meshyy-bench")
    parser.add_argument("--tmux", default="tmux",
                        help="path to tmux on the remote host (login shells often lack /opt/homebrew/bin)")
    parser.add_argument("--trials", type=int, default=7)
    parser.add_argument("--rtts", default="0,40,80,150,250")
    parser.add_argument("--json-out", default=None)
    args = parser.parse_args()

    key = os.path.expanduser(args.key)
    rtts = [int(v) for v in args.rtts.split(",")]

    ensure_session(args.session, f'clear; printf "{MARKER.decode()}\\n"')

    results = {}

    def sweep(mode):
        # Direct, no proxy: establishes how much the proxy itself costs.
        direct = []
        print(f"[{mode}] direct (no proxy, port {args.port}):", flush=True)
        for i in range(args.trials):
            t = measure_attach(args.host, args.port, args.user, key,
                               args.session, args.tmux, mode)
            if t is not None:
                direct.append(t)
                print(f"  trial {i + 1}: {t * 1000:7.1f} ms", flush=True)
        results[f"{mode}:direct"] = direct

        for rtt in rtts:
            proc, port = start_proxy(args.host, args.port, rtt)
            try:
                print(f"[{mode}] injected RTT {rtt} ms (port {port}):", flush=True)
                samples = []
                # One warm-up, measured and discarded, so first-touch costs do
                # not land in the reported numbers.
                measure_attach(args.host, port, args.user, key,
                               args.session, args.tmux, mode)
                for i in range(args.trials):
                    t = measure_attach(args.host, port, args.user, key,
                                       args.session, args.tmux, mode)
                    if t is not None:
                        samples.append(t)
                        print(f"  trial {i + 1}: {t * 1000:7.1f} ms", flush=True)
                results[f"{mode}:{rtt}"] = samples
            finally:
                proc.terminate()
                proc.wait(timeout=5)

    for mode in ("exec", "attach"):
        sweep(mode)

    print("\n=== summary ===")
    summary = {}
    for label, samples in results.items():
        if not samples:
            print(f"{label:>8}: no successful trials")
            continue
        summary[label] = {
            "n": len(samples),
            "min_ms": min(samples) * 1000,
            "median_ms": statistics.median(samples) * 1000,
            "max_ms": max(samples) * 1000,
        }
        s = summary[label]
        print(
            f"{label:>8}: n={s['n']} min={s['min_ms']:7.1f} "
            f"median={s['median_ms']:7.1f} max={s['max_ms']:7.1f} ms"
        )

    for mode in ("exec", "attach"):
        fit_points = [
            (int(label.split(":")[1]) / 1000.0, statistics.median(samples))
            for label, samples in results.items()
            if label.startswith(f"{mode}:") and not label.endswith("direct") and samples
        ]
        if len(fit_points) < 2:
            continue
        fixed, trips = linear_fit(fit_points)
        print(f"\n[{mode}] linear fit: total = {fixed * 1000:.1f} ms + {trips:.2f} x RTT")
        print(f"  => about {trips:.1f} network round trips")
        summary[f"fit:{mode}"] = {"fixed_ms": fixed * 1000, "round_trips": trips}

    if "fit:exec" in summary and "fit:attach" in summary:
        e, a = summary["fit:exec"], summary["fit:attach"]
        print(
            f"\nmultiplexer attach adds {a['fixed_ms'] - e['fixed_ms']:.1f} ms fixed "
            f"and {a['round_trips'] - e['round_trips']:.2f} round trips over bare SSH exec"
        )
        print("\nprojection (design doc \u00a71 gate; meshyy target = 1 RTT + 50 ms):")
        for rtt_ms in (40, 60, 80, 120, 150):
            projected = a["fixed_ms"] + a["round_trips"] * rtt_ms
            target = rtt_ms + 50
            print(
                f"  {rtt_ms:3d} ms RTT: SSH+attach {projected:7.1f} ms "
                f"vs meshyy {target:6.1f} ms  (saves {projected - target:7.1f} ms, "
                f"{projected / target:.1f}x)"
            )

    if args.json_out:
        with open(args.json_out, "w") as handle:
            json.dump({"raw": results, "summary": summary}, handle, indent=2)
        print(f"\nwrote {args.json_out}")


if __name__ == "__main__":
    main()
