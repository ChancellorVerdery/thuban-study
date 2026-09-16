#!/bin/zsh
# Runs the ThubanCore package tests.
set -euo pipefail
cd "$(dirname "$0")/../Packages/ThubanCore"
swift test "$@"
