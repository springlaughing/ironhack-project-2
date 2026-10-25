#!/usr/bin/env python3
"""One picture per run (#9, #10): what the voters saw and what the cluster did, on one time axis.

    python3 loadtest/plot.py A        -> loadtest/results/A-timeline.png
                                         loadtest/results/A-per-second.csv

Reads what rollout-test.sh collected in loadtest/results/:
    <RUN>-k6.csv      every vote k6 sent (k6 --out csv): time, status, response time
    <RUN>-pods.csv    every second: each pod of the workload, its version, ready, shutting down
    <RUN>-queue.csv   every second, inside Redis: votes waiting, votes taken by a Worker
    <RUN>-saved.csv   every second, inside PostgreSQL: this run's votes saved so far
    <RUN>-events.txt  when k6 started, when the update started and ended
x axis: seconds since k6 started. Clocks: k6, pods and events use the laptop's clock,
queue and saved the cluster's; rollout-test.sh notes both (1-2 s apart at most).
"""
import csv
import datetime as dt
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")                      # draw into a file, no window needed
import matplotlib.pyplot as plt

RUN = sys.argv[1]
BASE = f"loadtest/results/{RUN}"

# Reference palette (dataviz skill), light mode: categorical slots in fixed order
S1, S2, S3, S4 = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
INK, INK2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"


def secs(hms):
    """'13:15:24' -> seconds since midnight (all files use UTC)."""
    h, m, s = hms.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def read_csv(path):
    try:
        with open(path, newline="") as f:
            return list(csv.DictReader(f))
    except FileNotFoundError:
        print(f"  (no {path}, that panel stays empty)")
        return []


def pct(values, q):
    v = sorted(values)
    return v[round(q * (len(v) - 1))] if v else None


# ---------- events: time zero and the update window ----------
events = []
with open(f"{BASE}-events.txt") as f:
    for line in f:
        t, text = line.split(" ", 1)
        events.append((secs(t), text.strip()))
t0 = next(t for t, text in events if text.startswith("k6 start"))
workload = events[0][1].split(": ", 1)[1].split(" ")[0]       # "run A: deployment/vote (...)" -> deployment/vote
marks = [(t - t0, text.split(":")[0]) for t, text in events if text.startswith(("update start", "update done"))]

# ---------- k6: one row per sample; count per second ----------
per_sec = defaultdict(lambda: defaultdict(int))
durations = defaultdict(list)
for row in read_csv(f"{BASE}-k6.csv"):
    name = row["metric_name"]
    ts = dt.datetime.fromtimestamp(int(float(row["timestamp"])), dt.timezone.utc)
    s = int(secs(ts.strftime("%H:%M:%S")) - t0)
    if name in ("votes_accepted", "refused_by_gateway", "refused_by_vote", "refused_no_answer"):
        per_sec[s][name] += int(float(row["metric_value"]))
    elif name == "http_req_duration":
        durations[s].append(float(row["metric_value"]))

# ---------- pods: which version, serving or not ----------
pods_at = defaultdict(list)
for row in read_csv(f"{BASE}-pods.csv"):
    pods_at[secs(row["time_utc"]) - t0].append(row)
first_versions = {r["version"] for r in pods_at[min(pods_at)]} if pods_at else set()
pod_rows = []
for t in sorted(pods_at):
    c = {"old": 0, "new": 0, "starting": 0, "stopping": 0}
    for r in pods_at[t]:
        if r["terminating"]:
            c["stopping"] += 1                      # deletion started: SIGTERM / preStop running
        elif r["ready"] != "true":
            c["starting"] += 1                      # exists, not Ready yet: gets no traffic
        elif r["version"] in first_versions:
            c["old"] += 1
        else:
            c["new"] += 1
    pod_rows.append((t, c))

# ---------- Redis queue and saved votes (inside the cluster) ----------
queue = [(secs(r["time_utc"]) - t0, int(r["queue"]), int(r["in_progress"]))
         for r in read_csv(f"{BASE}-queue.csv") if r["queue"].isdigit()]
saved = [(secs(r["time_utc"]) - t0, int(r["saved"]))
         for r in read_csv(f"{BASE}-saved.csv") if r["saved"].strip().isdigit()]
saved_rate = [(t2, (n2 - n1) / (t2 - t1)) for (t1, n1), (t2, n2) in zip(saved, saved[1:]) if t2 > t1]

# ---------- the small table, one row per second ----------
seconds = sorted(set(per_sec) | set(durations))
with open(f"{BASE}-per-second.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["second", "accepted", "refused_by_gateway", "refused_by_vote", "refused_no_answer",
                "median_ms", "p95_ms", "max_ms"])
    for s in seconds:
        d = durations[s]
        w.writerow([s, per_sec[s]["votes_accepted"], per_sec[s]["refused_by_gateway"],
                    per_sec[s]["refused_by_vote"], per_sec[s]["refused_no_answer"],
                    round(pct(d, 0.5) or 0), round(pct(d, 0.95) or 0), round(max(d) if d else 0)])

# ---------- the picture: five panels, one shared time axis ----------
plt.rcParams.update({"font.size": 10, "axes.edgecolor": GRID, "axes.labelcolor": INK2,
                     "xtick.color": INK2, "ytick.color": INK2, "axes.titlecolor": INK,
                     "axes.titlesize": 11, "axes.titleweight": "bold", "axes.titlelocation": "left"})
fig, ax = plt.subplots(5, 1, figsize=(11, 13), sharex=True, facecolor=SURFACE,
                       gridspec_kw={"height_ratios": [3, 2, 2, 2, 2]})
for a in ax:
    a.set_facecolor(SURFACE)
    a.set_axisbelow(True)                  # grid lines behind the bars, not across them
    a.grid(axis="y", color=GRID, linewidth=0.8)
    a.spines[["top", "right"]].set_visible(False)
    for t, label in marks:
        a.axvline(t, color=INK2, linewidth=1, linestyle="--")
for t, label in marks:
    ax[0].annotate(label, (t, 1), xycoords=("data", "axes fraction"), xytext=(4, -2),
                   textcoords="offset points", va="top", color=INK2, fontsize=9)

# 1. votes per second
ax[0].set_title("Votes per second")
ax[0].plot(seconds, [per_sec[s]["votes_accepted"] for s in seconds], color=S1, linewidth=2,
           label="accepted by Vote (k6)")
if saved_rate:
    ax[0].plot(*zip(*saved_rate), color=S2, linewidth=2, label="saved in PostgreSQL (Worker)")
ax[0].legend(loc="lower left", frameon=False)

# 2. refused votes, by who answered
ax[1].set_title("Refused votes per second, by who answered")
bottom = [0] * len(seconds)
for key, color, label in [("refused_by_gateway", S1, "Gateway (NGINX error page)"),
                          ("refused_by_vote", S2, "Vote (its own error page)"),
                          ("refused_no_answer", S3, "no answer within 10 s")]:
    values = [per_sec[s][key] for s in seconds]
    if any(values):
        ax[1].bar(seconds, values, bottom=bottom, width=0.9, color=color, label=label,
                  edgecolor=SURFACE, linewidth=1)
        bottom = [b + v for b, v in zip(bottom, values)]
if any(bottom):
    ax[1].legend(loc="upper right", frameon=False)
else:
    ax[1].text(0.5, 0.5, "no refused votes", transform=ax[1].transAxes, ha="center",
               va="center", color=INK2)
    ax[1].set_ylim(0, 1)

# 3. response time
ax[2].set_title("Response time per second (ms)")
ax[2].plot(seconds, [pct(durations[s], 0.5) for s in seconds], color=S1, linewidth=2, label="median")
ax[2].plot(seconds, [pct(durations[s], 0.95) for s in seconds], color=S2, linewidth=2, label="95th percentile")
ax[2].legend(loc="upper right", frameon=False)

# 4. pods
ax[3].set_title(f"Pods of {workload}")
if pod_rows:
    ts = [t for t, _ in pod_rows]
    ax[3].stackplot(ts, [[c[k] for _, c in pod_rows] for k in ("old", "new", "starting", "stopping")],
                    colors=[S1, S2, S3, S4], step="post", edgecolor=SURFACE, linewidth=1,
                    labels=["old version, ready", "new version, ready", "not ready yet", "shutting down"])
    ax[3].legend(loc="upper left", frameon=False, ncol=4, fontsize=9)
    ax[3].set_ylim(0, max(sum(c.values()) for _, c in pod_rows) + 1.5)

# 5. Redis queue
ax[4].set_title("Votes in Redis")
if queue:
    ax[4].plot([t for t, _, _ in queue], [q for _, q, _ in queue], color=S1, linewidth=2, label="waiting in the queue")
    ax[4].plot([t for t, _, _ in queue], [p for _, _, p in queue], color=S2, linewidth=2, label="taken by a Worker, not saved yet")
    ax[4].legend(loc="upper right", frameon=False)
ax[4].set_xlabel("seconds since k6 started")

fig.suptitle(f"Run {RUN}: rolling update of {workload}", x=0.06, ha="left", fontsize=14, fontweight="bold", color=INK)
fig.tight_layout()
fig.savefig(f"{BASE}-timeline.png", dpi=130, facecolor=SURFACE)
print(f"  wrote {BASE}-timeline.png and {BASE}-per-second.csv")
