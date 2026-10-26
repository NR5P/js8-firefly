#!/usr/bin/env bash
# App Store screenshots from the Simulator, using the Debug-only demo mode
# (JS8Call/App/DemoAir.swift): scripted stations are modulated into the real
# decoder, so the waterfall, band activity, chat and inbox all fill for real.
#
#   tools/screenshots.sh            # iPhone 6.3" and iPad 13"
#   tools/screenshots.sh iphone     # just one device
#   WARMUP=150 tools/screenshots.sh # seconds of band traffic before capturing
#
# Output: Docs/AppStore/screenshots/<device>/NN-name.png
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
BUNDLE=com.js8firefly.app
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])')
WARMUP=${WARMUP:-130}
OUT="$ROOT/Docs/AppStore/screenshots"
DD="$ROOT/build/screenshots-dd"
APP="$DD/Build/Products/Debug-iphonesimulator/JS8 Firefly.app"

# name|device type|shots (commands:file, in order; "+" joins commands)
DEVICES=(
  "iphone|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro|tab0:01-live tab1:02-chat tab2:03-stations tab3:04-inbox tab0+bands:05-my-frequencies tab0+levels:06-levels"
  "ipad|com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB|close:01-console bands:02-my-frequencies levels:03-levels"
)

echo "Building Debug for the Simulator..."
xcodebuild -project JS8Call.xcodeproj -scheme JS8Call -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DD" build -quiet

capture() {
  local name=$1 type=$2 shots=$3
  local sim="JS8 Screenshots ($name)"
  local udid
  udid=$(xcrun simctl list devices -j | python3 -c "
import json, sys
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['name'] == '$sim' and d['isAvailable']: print(d['udid']); sys.exit()")
  [ -n "$udid" ] || udid=$(xcrun simctl create "$sim" "$type" "$RUNTIME")
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" >/dev/null
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl install "$udid" "$APP"
  xcrun simctl terminate "$udid" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$udid" "$BUNDLE" -demo YES >/dev/null

  echo "[$name] letting the band fill for ${WARMUP}s..."
  sleep "$WARMUP"
  mkdir -p "$OUT/$name"
  for shot in $shots; do
    local cmds=${shot%%:*} file=${shot#*:}
    xcrun simctl spawn "$udid" notifyutil -p com.js8firefly.demo.close
    sleep 1
    for cmd in ${cmds//+/ }; do
      xcrun simctl spawn "$udid" notifyutil -p "com.js8firefly.demo.$cmd"
      sleep 1.5
    done
    xcrun simctl io "$udid" screenshot "$OUT/$name/$file.png" >/dev/null 2>&1
    # App Store Connect wants screenshots without an alpha channel.
    python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).convert("RGB").save(sys.argv[1])' "$OUT/$name/$file.png"
    echo "[$name] $file.png"
  done
  xcrun simctl spawn "$udid" notifyutil -p com.js8firefly.demo.close
}

for entry in "${DEVICES[@]}"; do
  IFS='|' read -r name type shots <<<"$entry"
  if [ $# -eq 0 ] || [ "$1" = "$name" ]; then
    capture "$name" "$type" "$shots"
  fi
done
echo "Screenshots in $OUT"
