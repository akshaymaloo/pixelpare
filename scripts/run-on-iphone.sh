#!/bin/bash
# Build, sign, install and launch PixelPare on a connected iPhone.
# Usage: scripts/run-on-iphone.sh [device name or identifier] [-- app launch args]
# The phone must be connected (USB or paired over Wi-Fi), unlocked, trusted, and have Developer Mode on.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

want=${1:-}
[[ "$want" == "--" ]] && want=""
args=()
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--" ]]; then args=("${@:i+1}"); break; fi
done

json=$(mktemp)
trap 'rm -f "$json"' EXIT
xcrun devicectl list devices --json-output "$json" >/dev/null
device=$(python3 - "$json" "$want" <<'E'
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
want = sys.argv[2].lower()
for d in devs:
    p, h = d.get("deviceProperties", {}), d.get("hardwareProperties", {})
    if h.get("platform") != "iOS" or h.get("reality") == "simulated":
        continue
    name = p.get("name", "")
    if want and want not in (name.lower(), d["identifier"].lower(), h.get("udid", "").lower()):
        continue
    print(h.get("udid") or d["identifier"])
    break
E
)
if [[ -z "$device" ]]; then
  echo "No iPhone found. Connect it, unlock it, tap Trust, and turn on Settings > Privacy & Security > Developer Mode." >&2
  exit 1
fi
echo "Using device $device"

/opt/homebrew/bin/xcodegen generate -q
xcodebuild -project PixelPare.xcodeproj -scheme PixelPare-iOS -configuration Debug \
  -destination "id=$device" -derivedDataPath .build/dd-device \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build

app=.build/dd-device/Build/Products/Debug-iphoneos/PixelPare.app
xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device process launch --device "$device" --terminate-existing com.akshaymaloo.pixelpare ${args[@]+"${args[@]}"}
echo "Launched. If iOS says the developer is untrusted: Settings > General > VPN & Device Management > trust your Apple Development profile, then run this again."
