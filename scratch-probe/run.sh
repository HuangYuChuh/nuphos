#!/bin/bash
# Turns on Screen Sharing for this runner's account and probes it: as our client asks, and as noVNC would.
set -uo pipefail
cd "$(dirname "$0")"
pass=$(openssl rand -hex 12)
sudo sysadminctl -addUser probe -fullName Probe -password "$pass" -admin 2>&1 | tail -1
PROBE_ACCOUNT=probe
echo "probing as $PROBE_ACCOUNT"
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on -privs -all -allowAccessFor -allUsers -restart -agent -menu >/dev/null 2>&1 || true
for i in $(seq 1 30); do nc -z 127.0.0.1 5900 && break; sleep 1; done
nc -z 127.0.0.1 5900 && echo "screen sharing listening" || { echo "screen sharing did not start"; exit 1; }
D=../apps/ios/nuphos-ios/Services/Desktop
python3 patch.py $D/RFBClient.swift RFBClient.swift
swiftc -O $D/ZlibStream.swift $D/RFBFramebuffer.swift RFBClient.swift $D/RFBKeysym.swift $D/AppleRemoteDesktopAuth.swift main.swift -o probe || exit 1
swiftc -O $D/ZlibStream.swift zlibcheck/main.swift -o zlibcheck-bin && ./zlibcheck-bin
swiftc -O flipper/main.swift -o flipper-bin
# Something changes on screen while it runs.
./flipper-bin > flips.log 2>&1 &
echo "== incremental requests (as the app does)"
PROBE_TAG=inc PROBE_USER=$PROBE_ACCOUNT PROBE_PASS=$pass PROBE_SECONDS=15 ./probe
python3 patch.py $D/RFBClient.swift RFBClient.swift
sed -i '' 's/send(Self.updateRequest(incremental: true, width: framebuffer.width, height: framebuffer.height))/send(Self.updateRequest(incremental: false, width: framebuffer.width, height: framebuffer.height))/' RFBClient.swift
grep -c "incremental: false" RFBClient.swift
swiftc -O $D/ZlibStream.swift $D/RFBFramebuffer.swift RFBClient.swift $D/RFBKeysym.swift $D/AppleRemoteDesktopAuth.swift main.swift -o probe-full
echo "== full (non-incremental) requests"
PROBE_TAG=full PROBE_USER=$PROBE_ACCOUNT PROBE_PASS=$pass PROBE_SECONDS=15 ./probe-full

echo "== flips"; cat flips.log | head -40
mkdir -p ../out && for f in frame-*.ppm; do sips -s format png "$f" --out "../out/${f%.ppm}.png" >/dev/null 2>&1; done; ls ../out
