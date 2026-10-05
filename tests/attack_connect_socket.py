#!/usr/bin/env python3
"""Attacker helper: try to connect to a UNIX socket (a persona SPICE display).
Exit 0 if the connection succeeds (a leak), non-zero if it's denied."""
import socket
import sys

s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1])
except OSError as e:
    print(f"denied: {e}", file=sys.stderr)
    sys.exit(1)
print("CONNECTED")
sys.exit(0)
