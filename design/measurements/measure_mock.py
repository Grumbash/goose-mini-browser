"""One run, four tabs, per-tab attribution: the numbers the mocks show."""
import json, subprocess, sys, time
sys.path.insert(0, ".")
from measure import webkit_pids, footprint  # reuse the same metric and attribution
urls = ["https://en.wikipedia.org/wiki/Focaccia", "https://example.com/",
        "https://developer.mozilla.org/en-US/docs/Web/JavaScript", "https://github.com/aardappel/goose"]
before = webkit_pids()
proc = subprocess.Popen(["./webview_probe"] + urls, stdout=subprocess.PIPE, text=True)
log, done, pid, deadline = [], 0, None, time.time() + 60
while done < len(urls) and time.time() < deadline:
    line = proc.stdout.readline().strip(); log.append(line)
    if line.startswith("PID "): pid = int(line.split()[1])
    elif line.startswith(("LOADED", "FAILED")): done += 1
for _ in urls: log.append(proc.stdout.readline().strip())
time.sleep(15)
r = footprint({pid} | (webkit_pids() - before), "webkit-mock4")
r["log"] = log
json.dump(r, open("results-mock4.json", "w"), indent=1)
tabs = {int(l.split()[1]): l.split()[2] for l in log if l.startswith("TAB")}
print("total", r["total_mb"])
for p in r["processes"]:
    print(f'{p["mb"]:7.1f}  {p["name"]:32} {tabs.get(p["pid"], "")}')
proc.terminate(); proc.wait(timeout=10)
