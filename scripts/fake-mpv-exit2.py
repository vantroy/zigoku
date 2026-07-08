#!/usr/bin/env python3
"""Fake mpv for the ROD-310 double-join regression guard.

Stands in for mpv when we need a deterministic non-zero exit without a real
stream. Mirrors the macOS user's failure: creates the --input-ipc-server unix
socket, accepts the position-watcher's connection (so player.zig's "client
connected" path runs), lets it send its observe_property commands, then exits 2
("nothing could be opened/played") — the signal player.play maps to
error.MpvOpenFailed. Used by `zig build spike-retry -- scripts/fake-mpv-exit2.py`
(src/spikes/retry_repro.zig) and the macOS CI regression step.
"""
import sys
import os
import socket
import time

ipc_path = None
log_path = None
for a in sys.argv[1:]:
    if a.startswith("--input-ipc-server="):
        ipc_path = a.split("=", 1)[1]
    elif a.startswith("--log-file="):
        log_path = a.split("=", 1)[1]

# mpv writes a log; player.zig keeps it on nonzero exit. Emit a plausible one so
# the whole path (log path exists, kept) is exercised.
if log_path:
    try:
        with open(log_path, "w") as f:
            f.write("[fake-mpv] pretending the CDN 403'd the stream open\n")
    except OSError:
        pass

if ipc_path:
    try:
        if os.path.exists(ipc_path):
            os.unlink(ipc_path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(ipc_path)
        srv.listen(1)
        srv.settimeout(2.0)
        try:
            conn, _ = srv.accept()
            # Drain whatever the watcher writes (observe_property commands), then
            # close — the watcher's read then hits EOF and the thread unwinds,
            # exactly like mpv dying right after the client connected.
            conn.settimeout(0.3)
            try:
                conn.recv(4096)
            except socket.timeout:
                pass
            time.sleep(0.1)
            conn.close()
        except socket.timeout:
            pass
        srv.close()
    except OSError:
        pass

sys.exit(2)
