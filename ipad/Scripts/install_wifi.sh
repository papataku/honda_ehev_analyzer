#!/usr/bin/env bash
# Deploy Honda Analyzer with a free Personal Team, from a logged-in home Mac.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage:
  bash ipad/Scripts/install_wifi.sh --list-devices
  bash ipad/Scripts/install_wifi.sh --device <iPad-ID> --team <Apple-Team-ID> [--launch]

Instead of flags, set HONDA_IPAD_DEVICE_ID and HONDA_APPLE_TEAM_ID.
Requires full Xcode, xcodegen, Xcode Personal Team, paired iPad, Developer Mode.
A free provisioning profile expires after seven days: rebuild/reinstall.
HELP
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
DEVICE_ID="${HONDA_IPAD_DEVICE_ID:-}"
TEAM_ID="${HONDA_APPLE_TEAM_ID:-}"
LAUNCH=false
LIST=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) [[ $# -ge 2 ]] || die "--device needs a value"; DEVICE_ID="$2"; shift 2 ;;
    --team) [[ $# -ge 2 ]] || die "--team needs a value"; TEAM_ID="$2"; shift 2 ;;
    --launch) LAUNCH=true; shift ;;
    --list-devices) LIST=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "Run on macOS, not Linux/Docker."
for tool in xcodebuild xcrun xcodegen codesign; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing $tool. Install Xcode and brew install xcodegen."
done
XCODE_DIR="$(xcode-select -p 2>/dev/null || true)"
[[ "$XCODE_DIR" == *Xcode.app/Contents/Developer* ]] ||
  die "Select full Xcode: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
if [[ "$LIST" == true ]]; then
  xcrun devicectl list devices
  exit 0
fi
[[ -n "$DEVICE_ID" ]] || die "Set HONDA_IPAD_DEVICE_ID or --device."
[[ -n "$TEAM_ID" ]] || die "Set HONDA_APPLE_TEAM_ID or --team."
[[ "$TEAM_ID" =~ ^[[:alnum:]]{10}$ ]] || die "Apple Team ID must be 10 alphanumeric characters."
[[ "$DEVICE_ID" != *[$'\n\r\t ']* ]] || die "Device ID must contain no whitespace."
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IPAD_DIR="$ROOT/ipad"
[[ -f "$IPAD_DIR/project.yml" ]] || die "ipad/project.yml is missing."

DEVICES="$(xcrun devicectl list devices)" || die "Device Hub unavailable; pair your iPad in Xcode."
printf '%s\n' "$DEVICES"
printf '%s\n' "$DEVICES" | grep -Fq -- "$DEVICE_ID" ||
  die "iPad not listed. Pair with this Mac in Xcode Device Hub (same Wi-Fi)."

DERIVED="${HONDA_DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData/HondaAnalyzer-WiFi}"
mkdir -p "$DERIVED"
cd "$IPAD_DIR"
xcodegen generate

# devicectl can print a CoreDevice ID that differs from the hardware
# UDID expected by xcodebuild -destination. Build a generic *physical iOS*
# app, then use the exact CoreDevice ID only to install on the selected iPad.
# First pair/register this iPad in Xcode once so the free Personal Team
# development profile already contains the physical device.
xcodebuild \
  -project HondaAnalyzer.xcodeproj \
  -scheme HondaAnalyzer -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  "DEVELOPMENT_TEAM=$TEAM_ID" CODE_SIGN_STYLE=Automatic build

APP="$DERIVED/Build/Products/Debug-iphoneos/HondaAnalyzer.app"
[[ -d "$APP" ]] || die "Built iPad app missing: $APP"
codesign --verify --strict "$APP" || die "iPad app signature invalid."
SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)" ||
  die "Cannot inspect app signature."
printf '%s\n' "$SIGN_INFO" | grep -Fq "TeamIdentifier=$TEAM_ID" ||
  die "App was signed by a different Apple Team."

# No uninstall/delete: replacement installs normally preserve the app's data.
# Never invoke during live vehicle recording; deployment interrupts the app.
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
if [[ "$LAUNCH" == true ]]; then
  xcrun devicectl device process launch \
    --device "$DEVICE_ID" com.papataku.HondaAnalyzer
fi
printf '\nHonda Analyzer installed over Wi-Fi. No cable required after pairing.\n'
printf 'Free provisioning expires in seven days; reinstall before expiry.\n'
printf 'Back up SQLite captures before the first re-sign and reinstall.\n'
