#!/bin/zsh
# Guards a built "Thuban Study.app" against Desmos-era leftovers. Xcode's incremental builds never delete resources
# that were dropped from the target, so an old product keeps Secrets.plist (with the Desmos API key) and the Desmos
# pages unless they are removed.
#   scripts/check-bundle.sh --clean <app>   removes the retired resources (before a build; a missing app is fine)
#   scripts/check-bundle.sh <app>           fails if any retired resource or Desmos API reference is in the bundle
set -uo pipefail
CLEAN=0
if [[ "${1:-}" == "--clean" ]]; then CLEAN=1; shift; fi
APP="${1:?usage: check-bundle.sh [--clean] <app>}"
RES="$APP/Contents/Resources"
RETIRED=(Secrets.plist Secrets.example.plist web/graph web/calc web/vendor/compute-engine)

if [[ $CLEAN == 1 ]]; then
  [[ -d "$RES" ]] || exit 0
  for item in $RETIRED; do rm -rf "$RES/$item"; done
  exit 0
fi

[[ -d "$RES" ]] || { echo "check-bundle: no bundle at $APP" >&2; exit 1; }
FAIL=0
for item in $RETIRED; do
  if [[ -e "$RES/$item" ]]; then echo "check-bundle: retired resource still in the bundle: $item" >&2; FAIL=1; fi
done
# The key's name, the API host and the calculator script (the app itself only keeps "desmosKey", the purged row).
HITS="$(grep -rIlE 'DesmosAPIKey|desmos\.com|calculator\.js\?apiKey' "$RES" "$APP/Contents/Info.plist" 2>/dev/null)"
if [[ -n "$HITS" ]]; then
  echo "check-bundle: Desmos references in:" >&2
  echo "$HITS" >&2
  FAIL=1
fi
exit $FAIL
