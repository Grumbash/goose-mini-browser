"""Measures the M0 app (app/main) while it sits idle in a real window: CPU time
used, footprint (Activity Monitor's memory figure) and frames presented.
The app quits by itself after IDLE_MS without events.

usage: python3 -I measure_idle.py <path to app/main> <out.json>
"""
import json
import os
import re
import subprocess
import sys
import time

BIN, OUT = sys.argv[1], sys.argv[2]
IDLE_MS = 17000
SETTLE_S, WINDOW_S = 5, 10  # startup costs ~0.1 CPU-seconds in its first half-second


def cpu_seconds(pid):
    t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    m = re.match(r"(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)", t)
    if not m:
        return None
    h, mins, secs = m.groups()
    return int(h or 0) * 3600 + int(mins) * 60 + float(secs)


def footprint_mb(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s+([\d.]+)\s+(KB|MB|GB)", out)
    if not m:
        return None
    return round(float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)], 1)


proc = subprocess.Popen([os.path.abspath(BIN), "--idle-exit", str(IDLE_MS)],
                        cwd=os.path.dirname(os.path.abspath(BIN)),
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(SETTLE_S)  # the window opens and settles; nobody touches it
c0, t0 = cpu_seconds(proc.pid), time.time()
time.sleep(WINDOW_S)
c1, t1 = cpu_seconds(proc.pid), time.time()
mem = footprint_mb(proc.pid)
out, _ = proc.communicate(timeout=60)
m = re.search(r"frames presented: (\d+)", out)
result = {
    "idle_cpu_percent": round((c1 - c0) / (t1 - t0) * 100, 2) if None not in (c0, c1) else None,
    "cpu_seconds_in_window": round(c1 - c0, 3) if None not in (c0, c1) else None,
    "footprint_mb": mem,
    "frames_presented_total": int(m.group(1)) if m else None,
    "idle_window_seconds": round(t1 - t0, 2),
    "output": out.strip()[-200:],
    "note": "Window left idle: no input. Frames include the first paint and any resize.",
}
json.dump(result, open(OUT, "w"), indent=1)
print(json.dumps(result, indent=1))
