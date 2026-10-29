"""Measures phys_footprint (Activity Monitor's "Memory") of two minimal browsers
on the same pages: a WKWebView shell (system WebKit) and a fresh Chrome
instance with a throwaway profile. Prints per-process and de-duplicated totals.

usage: python3 -I measure.py <probe-binary> <out.json>
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

PROBE, OUT = (sys.argv[1:3] + ["./webview_probe", "results-import.json"])[:2] if len(sys.argv) < 3 else (sys.argv[1], sys.argv[2])
HERE = os.path.dirname(os.path.abspath(OUT))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PAGES = [
    "https://example.com/",
    "https://developer.mozilla.org/en-US/docs/Web/JavaScript",
    "https://github.com/aardappel/goose",
]
SETTLE_S = 15


def processes():
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        pid, ppid, comm = line.strip().split(None, 2)
        rows[int(pid)] = (int(ppid), comm)
    return rows


def webkit_pids():
    return {p for p, (_, c) in processes().items()
            if os.path.basename(c).startswith("com.apple.WebKit.") and "CoreSimulator" not in c}


def descendants(root):
    rows = processes()
    found, frontier = {root}, [root]
    while frontier:
        parent = frontier.pop()
        for pid, (ppid, _) in rows.items():
            if ppid == parent and pid not in found:
                found.add(pid)
                frontier.append(pid)
    return found


def footprint(pids, label):
    jf = os.path.join(HERE, f"fp-{label}.json")
    subprocess.run(["footprint", "-j", jf] + [str(p) for p in sorted(pids)], capture_output=True)
    d = json.load(open(jf))
    procs = sorted(((p["name"], p["pid"], p["footprint"]) for p in d["processes"]), key=lambda r: -r[2])
    return {"label": label, "total_mb": round(d["total footprint"] / 2**20, 1),
            "processes": [{"name": n, "pid": pid, "mb": round(b / 2**20, 1)} for n, pid, b in procs],
            "errors": d.get("errors")}


def run_webkit(urls, label):
    before = webkit_pids()
    proc = subprocess.Popen([PROBE] + urls, stdout=subprocess.PIPE, text=True)
    pid, done, deadline, log = None, 0, time.time() + 60, []
    while done < len(urls) and time.time() < deadline:
        line = proc.stdout.readline().strip()
        log.append(line)
        if line.startswith("PID "):
            pid = int(line.split()[1])
        elif line.startswith(("LOADED", "FAILED")):
            done += 1
    for _ in urls:  # the TAB lines follow the last load
        log.append(proc.stdout.readline().strip())
    time.sleep(SETTLE_S)
    engine = webkit_pids() - before
    result = footprint({pid} | engine, label)
    result["log"] = log
    proc.terminate()
    proc.wait(timeout=10)
    return result


def run_chrome(urls, label):
    profile = tempfile.mkdtemp(prefix="chrome-probe-", dir=HERE)
    proc = subprocess.Popen([CHROME, f"--user-data-dir={profile}", "--no-first-run",
                             "--no-default-browser-check", "--incognito",
                             "--window-size=1280,800", "--window-position=40,40"] + urls,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(20 + SETTLE_S)  # no load events without CDP: fixed load + settle window
    result = footprint(descendants(proc.pid), label)
    proc.terminate()
    proc.wait(timeout=20)
    shutil.rmtree(profile, ignore_errors=True)
    return result


if __name__ == "__main__":
  results = [
      run_webkit(["about:blank"], "webkit-blank"),
      run_webkit(PAGES, "webkit-3tabs"),
      run_chrome(["about:blank"], "chrome-blank"),
      run_chrome(PAGES, "chrome-3tabs"),
  ]
  json.dump(results, open(OUT, "w"), indent=1)
  for r in results:
      print(f"\n== {r['label']}: {r['total_mb']} MB total across {len(r['processes'])} processes")
      for p in r["processes"]:
          print(f"   {p['mb']:8.1f} MB  {p['name']}")
      if r.get("errors"):
          print("   errors:", r["errors"])
