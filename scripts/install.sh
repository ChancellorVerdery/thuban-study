#!/bin/zsh
# Release build → /Applications/Thuban Study.app (replaces any existing copy, relaunches it if it was running).
# Quits every running "Thuban Study" process first, Debug harness runs included.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
LOG=.build/xcodebuild-release.log
xcodebuild -project ThubanStudy.xcodeproj -scheme ThubanStudy -configuration Release \
  -derivedDataPath .build/DerivedData-Release -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build > "$LOG" 2>&1 || { grep -E "error: " "$LOG" | sort -u | head -30; echo "** BUILD FAILED ** (see $LOG)"; exit 1; }
SRC=".build/DerivedData-Release/Build/Products/Release/Thuban Study.app"
DEST="/Applications/Thuban Study.app"
WAS_RUNNING=0
if pgrep -f "Thuban Study.app/Contents/MacOS" >/dev/null; then WAS_RUNNING=1; pkill -f "Thuban Study.app/Contents/MacOS"; sleep 1; fi
rm -rf "$DEST"
cp -R "$SRC" "$DEST" || exit 1
echo "Installed $DEST"
if [[ "$WAS_RUNNING" == "1" ]]; then open "$DEST"; fi
