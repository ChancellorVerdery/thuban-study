#!/bin/zsh
# Debug build of the app into .build/DerivedData (ad-hoc signed, runs locally).
# Prints only errors, warnings from our own sources, and the build result.
set -uo pipefail
cd "$(dirname "$0")/.."
LOG=.build/xcodebuild.log
mkdir -p .build
xcodebuild -project ThubanStudy.xcodeproj -scheme ThubanStudy -configuration Debug \
  -derivedDataPath .build/DerivedData -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build "$@" > "$LOG" 2>&1
STATUS=$?
grep -E "(error|warning): " "$LOG" | grep -E "ThubanStudy/|ThubanCore/|xcodebuild: error" | grep -v "DerivedData" | sort -u | head -60
grep -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*" "$LOG" || echo "** BUILD RESULT UNKNOWN (see $LOG) **"
echo "App: .build/DerivedData/Build/Products/Debug/Thuban Study.app"
exit $STATUS
