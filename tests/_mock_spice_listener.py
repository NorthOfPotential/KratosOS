#!/usr/bin/env python3
"""A stand-in for QEMU's SPICE display socket: bind AND listen, then accept
forever, so the only thing stopping a client is filesystem permission, not a
missing listener. Used by attack_isolation.sh. Args: <socket-path>."""
import os
import socket
import sys

path = sys.argv[1]
try:
    os.unlink(path)
except OSError:
    pass
s = socket.socket(socket.AF_UNIX)
s.bind(path)
s.listen(16)
while True:
    try:
        conn, _ = s.accept()
        conn.close()
    except OSError:
        break
