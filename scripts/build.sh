#!/bin/zsh
# Debug build of the app into .build/DerivedData (ad-hoc signed, runs locally).
# Prints only errors, warnings from our own sources, and the build result.
set -uo pipefail
cd "$(dirname "$0")/.."
scripts/link-graph.sh || exit 1
GRAPH_REV="$(scripts/link-graph.sh --revision)"
LOG=.build/xcodebuild.log
mkdir -p .build
# Incremental builds never remove resources dropped from the target (the Desmos-era Secrets.plist and pages).
scripts/check-bundle.sh --clean ".build/DerivedData/Build/Products/Debug/Thuban Study.app"
xcodebuild -project ThubanStudy.xcodeproj -scheme ThubanStudy -configuration Debug \
  -derivedDataPath .build/DerivedData -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES THUBAN_GRAPH_KIT_REVISION="$GRAPH_REV" build "$@" > "$LOG" 2>&1
STATUS=$?
if [[ $STATUS == 0 ]]; then scripts/check-bundle.sh ".build/DerivedData/Build/Products/Debug/Thuban Study.app" || STATUS=1; fi
grep -E "(error|warning): " "$LOG" | grep -E "ThubanStudy/|ThubanCore/|StudyGraph/|xcodebuild: error" | grep -v "DerivedData" | sort -u | head -60
grep -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*" "$LOG" || echo "** BUILD RESULT UNKNOWN (see $LOG) **"
echo "App: .build/DerivedData/Build/Products/Debug/Thuban Study.app"
exit $STATUS
