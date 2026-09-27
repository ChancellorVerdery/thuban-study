#!/bin/zsh
# Creates (or refreshes) the gitignored symlink Vendor/ThubanGraph -> the Thuban Graph checkout whose
# Packages/ThubanGraphCore provides ThubanGraphKit (docs: Thuban Graph docs/STUDY_INTEGRATION.md §3).
# THUBAN_GRAPH_ROOT overrides the default (~/Desktop/Claude/Thuban Graph), e.g. a Graph worktree for co-development.
# Every other script calls this first. Prints nothing on success unless the link changed.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="${THUBAN_GRAPH_ROOT:-$HOME/Desktop/Claude/Thuban Graph}"
GIVEN="$ROOT"
# Absolute and resolved: a relative target would be read from Vendor/, not from the repo root.
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)"
if [[ -z "$ROOT" || ! -f "$ROOT/Packages/ThubanGraphCore/Package.swift" ]]; then
  echo "Thuban Graph checkout not found at $GIVEN; set THUBAN_GRAPH_ROOT" >&2
  exit 1
fi
if [[ "${1:-}" == "--revision" ]]; then
  # The linked checkout's short commit, "-dirty" when it has uncommitted changes (Info.plist ThubanGraphKitRevision).
  REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then REV="$REV-dirty"; fi
  echo "$REV"
  exit 0
fi
mkdir -p Vendor
LINK="Vendor/ThubanGraph"
if [[ -L "$LINK" && "$(readlink "$LINK")" == "$ROOT" ]]; then
  exit 0
fi
if [[ -e "$LINK" && ! -L "$LINK" ]]; then
  echo "$LINK exists and is not a symlink; remove it first" >&2
  exit 1
fi
ln -sfn "$ROOT" "$LINK"
if [[ ! -f "$LINK/Packages/ThubanGraphCore/Package.swift" ]]; then
  echo "Linked $LINK -> $ROOT but it does not resolve to ThubanGraphCore" >&2
  exit 1
fi
echo "Linked $LINK -> $ROOT"
