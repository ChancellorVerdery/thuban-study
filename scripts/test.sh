#!/bin/zsh
# Runs the ThubanCore package tests, then the StudyGraph package tests (the Thuban Graph engine bridge: tool
# execution, persistence, migration, theme). Extra arguments go to both `swift test` runs.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/link-graph.sh
(cd Packages/ThubanCore && swift test "$@")
(cd Packages/StudyGraph && swift test "$@")
