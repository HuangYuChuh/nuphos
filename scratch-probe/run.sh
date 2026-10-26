#!/bin/bash
# Turns on Screen Sharing for this runner's account and probes it: as our client asks, and as noVNC would.
set -uo pipefail
cd "$(dirname "$0")"
pass=$(openssl rand -hex 12)
sudo sysadminctl -addUser probe -fullName Probe -password "$pass" -admin 2>&1 | tail -1
PROBE_ACCOUNT=probe
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -privs -all -allowAccessFor -allUsers -restart -agent -menu >/dev/null 2>&1 || true
for i in $(seq 1 30); do nc -z 127.0.0.1 5900 && break; sleep 1; done
nc -z 127.0.0.1 5900 && echo "screen sharing listening" || { echo "screen sharing did not start"; exit 1; }
D=../apps/ios/nuphos-ios/Services/Desktop
python3 patch.py $D/RFBClient.swift RFBClient.swift
swiftc -O $D/ZlibStream.swift $D/RFBFramebuffer.swift RFBClient.swift $D/RFBKeysym.swift $D/AppleRemoteDesktopAuth.swift main.swift -o probe || exit 1
swiftc -O $D/ZlibStream.swift zlibcheck.swift -o zlibcheck && ./zlibcheck
# Something changes on screen while it runs.
( sleep 15; open -a Calculator; sleep 5; open -a "System Settings"; sleep 5; open -a TextEdit; sleep 5; osascript -e 'tell application "Finder" to activate' ) &
for round in 1 2 3; do
  echo "== our encodings (ZRLE, CopyRect, Raw + pseudo), round $round"
  PROBE_USER=$PROBE_ACCOUNT PROBE_PASS=$pass PROBE_SECONDS=20 ./probe
done
PROBE_PASS_SAVED=$pass PROBE_ACCOUNT=$PROBE_ACCOUNT python3 - <<'PY'
import os, subprocess
for name, encs in [("noVNC order", "7,-260,16,21,5,2,6,1,0,-26,-254,-223,-224,-308,-239"), ("Raw only", "0,-223,-224")]:
    print("==", name)
    os.environ["PROBE_ENCODINGS"] = encs
    subprocess.run(["python3", "patch.py", "../apps/ios/nuphos-ios/Services/Desktop/RFBClient.swift", "RFBClient.swift"], check=True)
    D = "../apps/ios/nuphos-ios/Services/Desktop"
    subprocess.run(["swiftc", "-O", f"{D}/ZlibStream.swift", f"{D}/RFBFramebuffer.swift", "RFBClient.swift", f"{D}/RFBKeysym.swift", f"{D}/AppleRemoteDesktopAuth.swift", "main.swift", "-o", "probe2"], check=True)
    subprocess.run(["./probe2"], env={**os.environ, "PROBE_USER": os.environ["PROBE_ACCOUNT"], "PROBE_PASS": os.environ["PROBE_PASS_SAVED"], "PROBE_SECONDS": "20"})
PY
