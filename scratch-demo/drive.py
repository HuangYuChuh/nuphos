#!/usr/bin/env python3
"""Drives the Desktop screen in a booted simulator with idb: watch, Take over, trackpad, typing, Hand back."""
import json, subprocess, sys, time

udid, idb = sys.argv[1], sys.argv[2]
start = time.time()

def log(text):
    print(f"[{time.time() - start:6.1f}s] {text}", flush=True)

def elements():
    out = subprocess.run([idb, "ui", "describe-all", "--udid", udid, "--json"], capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return []

def find(label, timeout=240):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for e in elements():
            if (e.get("AXLabel") or "").startswith(label) and e.get("enabled", True):
                f = e["frame"]
                return f["x"] + f["width"] / 2, f["y"] + f["height"] / 2, f
        time.sleep(1)
    raise SystemExit(f"never found {label!r}; labels: {[e.get('AXLabel') for e in elements()]}")

def tap(label):
    x, y, _ = find(label)
    subprocess.run([idb, "ui", "tap", "--udid", udid, str(x), str(y)], check=True)
    log(f"tap {label}")

def shot(name):
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", f"{name}.png"], check=True)
    log(f"screenshot {name}")

find("Take over")
log("desktop live, watching the agent type")
time.sleep(12)
shot("1-watching")
tap("Take over")
time.sleep(2)
_, _, pad = find("Drag to move the pointer")
cx, cy = pad["x"] + pad["width"] / 2, pad["y"] + pad["height"] / 2
for dx, dy in [(-90, -40), (120, 20), (-40, 30)]:
    subprocess.run([idb, "ui", "swipe", "--udid", udid, str(cx), str(cy), str(cx + dx), str(cy + dy), "--duration", "0.6"], check=True)
    time.sleep(0.6)
log("trackpad moved the pointer")
tap("Show keyboard")
time.sleep(2)
for word in ["Typed ", "on ", "the ", "iPhone"]:
    subprocess.run([idb, "ui", "text", "--udid", udid, word], check=True)
    time.sleep(0.5)
log("typed on the iPhone")
time.sleep(2)
shot("2-in-control")
tap("Hide keyboard")
time.sleep(1)
tap("Hand back")
time.sleep(4)
shot("3-handed-back")
log("done")
