"""Measures the Goose demo browser while it sits idle in a real window: CPU time
used, frames drawn, and footprint (Activity Monitor's memory figure).

usage: python3 -I measure_demo.py <path to browser/mini_browser> <page> <out.json>
"""
import json
import os
import re
import subprocess
import sys
import time

BIN, PAGE, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
FRAMES = 1200  # the demo exits by itself after this many frames


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


start = time.time()
proc = subprocess.Popen([os.path.abspath(BIN), PAGE, "--frames", str(FRAMES)],
                        cwd=os.path.dirname(os.path.abspath(BIN)),
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(3)  # let the window open and settle; nobody touches it
c0, t0 = cpu_seconds(proc.pid), time.time()
time.sleep(5)
c1, t1 = cpu_seconds(proc.pid), time.time()
mem = footprint_mb(proc.pid)
out, _ = proc.communicate(timeout=60)
elapsed = time.time() - start
m = re.search(r"drew (\d+) frames", out)
result = {
    "idle_cpu_percent": round((c1 - c0) / (t1 - t0) * 100, 1) if None not in (c0, c1) else None,
    "footprint_mb": mem,
    "frames_drawn": int(m.group(1)) if m else None,
    "wall_seconds": round(elapsed, 2),
    "frames_per_second": round(int(m.group(1)) / elapsed, 1) if m else None,
    "page": PAGE,
    "note": "Window left idle the whole time: no input, nothing loading.",
}
json.dump(result, open(OUT, "w"), indent=1)
print(json.dumps(result, indent=1))
